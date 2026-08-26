import Foundation
import PGliteC
#if canImport(AppleArchive)
import AppleArchive
import System
#endif

public enum PGliteError: Error, CustomStringConvertible {
    case openFailed(String)
    case sqlError(String)
    case engineDead

    public var description: String {
        switch self {
        case .openFailed(let m): return "PGlite open failed: \(m)"
        case .sqlError(let m): return m
        case .engineDead: return "PGlite engine died"
        }
    }
}

/// Low-level handle to a single-connection embedded PostgreSQL instance
/// (PGlite compiled from wasm to native code) rooted at a sandbox directory.
///
/// Blocking and not thread-safe — prefer `PGliteDatabase` (an actor).
public final class PGlite {
    private var db: OpaquePointer?

    /// The root directory holding the engine's filesystem
    /// (`<root>/tmp/pglite/...`).
    public let root: URL

    /// Prepare `root` (seeding the runtime filesystem — and, when bundled,
    /// a pristine pre-initdb'd data directory — from package resources if
    /// absent) and boot the engine. With the pristine seed, first boot skips
    /// initdb entirely.
    public init(root: URL) throws {
        self.root = root
        try Self.seedRuntimeFS(at: root)
        try Self.seedPristineData(at: root)

        var err = [CChar](repeating: 0, count: 256)
        guard let handle = root.path.withCString({ cRoot in
            pgl_open(cRoot, &err, err.count)
        }) else {
            throw PGliteError.openFailed(String(cString: err))
        }
        db = handle
    }

    deinit { close() }

    /// Checkpoint and shut down. The data directory remains resumable.
    public func close() {
        if let db { pgl_close(db) }
        db = nil
    }

    /// Run one SQL statement (simple protocol). Returns rows as
    /// tab-separated text lines; lines starting with `#` are command tags.
    @discardableResult
    public func query(_ sql: String) throws -> String {
        guard let db else { throw PGliteError.engineDead }
        var out = [CChar](repeating: 0, count: 1 << 20)
        let rc = pgl_exec(db, sql, &out, out.count)
        let text = String(cString: out)
        switch rc {
        case 0: return text
        case -1: throw PGliteError.sqlError(text)
        default:
            close()
            throw PGliteError.engineDead
        }
    }

    /// Convenience: rows only (command-tag lines stripped), split into
    /// tab-separated columns.
    public func rows(_ sql: String) throws -> [[String]] {
        try query(sql)
            .split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    /// Raw wire-protocol exchange: send frontend-message bytes, receive all
    /// backend bytes up to (and including) ReadyForQuery.
    public func execWire(_ payload: Data) throws -> Data {
        guard let db else { throw PGliteError.engineDead }
        var out: UnsafeMutableRawPointer?
        let n = payload.withUnsafeBytes { buf in
            pgl_exec_wire_alloc(db, buf.baseAddress, buf.count, &out)
        }
        guard n >= 0, let out else {
            close()
            throw PGliteError.engineDead
        }
        defer { pgl_free(out) }
        return Data(bytes: out, count: n)
    }

    // MARK: seeding

    private static func seedRuntimeFS(at root: URL) throws {
        let fm = FileManager.default
        let target = root.appendingPathComponent("tmp/pglite")
        if fm.fileExists(atPath: target.path) { return }
        guard let source = Bundle.module.url(forResource: "pgroot", withExtension: nil) else {
            throw PGliteError.openFailed("bundled pgroot resource missing")
        }
        try fm.createDirectory(at: root.appendingPathComponent("tmp"),
                               withIntermediateDirectories: true)
        try fm.copyItem(
            at: source.appendingPathComponent("tmp/pglite"),
            to: target
        )
    }

    /// Seed `<root>/tmp/pglite/base` from the bundled pristine PGDATA
    /// archive (Apple Archive, lzma). Skipping in-guest initdb cuts first
    /// boot from ~1.5 s to milliseconds.
    private static func seedPristineData(at root: URL) throws {
        let fm = FileManager.default
        let base = root.appendingPathComponent("tmp/pglite/base")
        if fm.fileExists(atPath: base.path) { return }
        guard let aar = Bundle.module.url(forResource: "pgdata-pristine", withExtension: "aar") else {
            return // no pristine bundle: pgl_open will run initdb
        }
        #if canImport(AppleArchive)
        let dst = root.appendingPathComponent("tmp/pglite")
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        guard let readStream = ArchiveByteStream.fileStream(
                path: FilePath(aar.path), mode: .readOnly,
                options: [], permissions: FilePermissions(rawValue: 0o644)),
              let decompress = ArchiveByteStream.decompressionStream(readingFrom: readStream),
              let decode = ArchiveStream.decodeStream(readingFrom: decompress),
              let extract = ArchiveStream.extractStream(
                extractingTo: FilePath(dst.path),
                flags: [.ignoreOperationNotPermitted])
        else {
            return // fall back to initdb
        }
        defer {
            try? extract.close()
            try? decode.close()
            try? decompress.close()
            try? readStream.close()
        }
        _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract)
        #endif
    }
}

/// Async, actor-isolated PostgreSQL interface: parameterized queries with
/// typed values, transactions, and PostgreSQL error mapping.
public actor PGliteDatabase {
    private let engine: PGlite

    public init(root: URL) throws {
        engine = try PGlite(root: root)
    }

    public func close() {
        engine.close()
    }

    /// Execute one statement via the extended protocol with text-format
    /// parameters (`$1`, `$2`, …).
    @discardableResult
    public func execute(_ sql: String, _ params: [PGValue?] = []) throws -> PGResult {
        let reply = try engine.execWire(Wire.extendedQuery(sql, params: params))
        return try Self.parseResult(reply)
    }

    /// Execute a multi-statement script via the simple protocol; returns the
    /// result of the last statement that produced one.
    @discardableResult
    public func exec(_ script: String) throws -> PGResult {
        let reply = try engine.execWire(Wire.simpleQuery(script))
        return try Self.parseResult(reply)
    }

    /// Raw wire passthrough for the localhost server: forwards one client
    /// batch (…Sync or a simple Query) and returns the backend bytes.
    public func rawExchange(_ payload: Data) throws -> Data {
        try engine.execWire(payload)
    }

    /// BEGIN / body / COMMIT — ROLLBACK on any thrown error.
    public func withTransaction<T: Sendable>(
        _ body: (PGliteDatabase) async throws -> T
    ) async throws -> T {
        _ = try execute("BEGIN")
        do {
            let result = try await body(self)
            _ = try execute("COMMIT")
            return result
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    static func parseResult(_ reply: Data) throws -> PGResult {
        var columns: [PGColumn] = []
        var index: [String: Int] = [:]
        var rows: [PGRow] = []
        var tag = ""
        var error: PGError?

        for frame in Wire.frames(reply) {
            switch frame.type {
            case UInt8(ascii: "T"):
                columns = Wire.rowDescription(frame.body)
                index = Dictionary(
                    columns.enumerated().map { ($1.name, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                rows = []
            case UInt8(ascii: "D"):
                rows.append(PGRow(columns: columns,
                                  values: Wire.dataRow(frame.body),
                                  index: index))
            case UInt8(ascii: "C"):
                var r = Wire.Reader(frame.body)
                tag = r.cstring() ?? ""
            case UInt8(ascii: "E"):
                if error == nil {
                    error = PGError(fields: Wire.errorFields(frame.body))
                }
            default:
                break // 1, 2, n, s, N, S, K, Z, R…
            }
        }
        if let error { throw error }
        return PGResult(columns: columns, rows: rows, tag: tag)
    }
}
