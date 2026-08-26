import CryptoKit
import Foundation
import Network

/// A localhost PostgreSQL wire-protocol server in front of a
/// `PGliteDatabase`, so ordinary Postgres drivers (PostgresNIO, libpq,
/// node-postgres in a JS runtime, …) can connect with a normal connection
/// string while the app is running.
///
/// Security model — iOS loopback is device-global, so any app on the device
/// can reach this port while it is open. Therefore:
/// - The MD5 handshake is verified HERE, host-side, against the credentials
///   you configure (the embedded engine's own password check is a stub).
/// - The port is ephemeral (random) by default.
/// - One client at a time; additional connections are refused until the
///   current one disconnects. All queries share the engine's single backend
///   session, serialized through the same actor the app uses.
public final class PGliteServer: @unchecked Sendable {
    public struct Credentials: Sendable {
        public let user: String
        public let password: String
        public init(user: String = "postgres", password: String) {
            self.user = user
            self.password = password
        }
        /// Random per-launch password. This is the default: nothing can
        /// connect unless the app explicitly hands out `connectionString`.
        public static func ephemeral() -> Credentials {
            Credentials(password: UUID().uuidString + UUID().uuidString)
        }
    }

    private let db: PGliteDatabase
    public let credentials: Credentials
    private let queue = DispatchQueue(label: "pglite-server")
    private var listener: NWListener?
    private var active: NWConnection?

    /// Credentials default to a random per-launch password; consumers can
    /// only connect if the app passes them `connectionString`.
    public init(db: PGliteDatabase, credentials: Credentials = .ephemeral()) {
        self.db = db
        self.credentials = credentials
    }

    /// The one artifact to hand to a consumer (webview bridge, JS runtime,
    /// native driver). Valid once `start()` has completed.
    public var connectionString: String {
        "postgresql://\(credentials.user):\(credentials.password)@127.0.0.1:\(port)/template1"
    }

    /// Start listening on 127.0.0.1. Pass `port: 0` (default) for an
    /// ephemeral port; read `port` afterwards for the connection string.
    public func start(port: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        self.listener = listener
        // wait for ready to learn the ephemeral port
        let sem = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { sem.signal() }
            if case .failed = state { sem.signal() }
        }
        _ = sem.wait(timeout: .now() + 5)
    }

    /// The bound port (0 until `start` completes).
    public var port: UInt16 {
        listener?.port?.rawValue ?? 0
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        active?.cancel()
        active = nil
    }

    // MARK: - connection handling

    private func accept(_ conn: NWConnection) {
        if active != nil {
            conn.cancel() // single backend session: one client at a time
            return
        }
        active = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async {
                    if self?.active === conn { self?.active = nil }
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
        Task { await self.session(conn) }
    }

    private func session(_ conn: NWConnection) async {
        do {
            guard try await handshake(conn) else {
                conn.cancel()
                return
            }
            var pending = Data()
            while true {
                let batch = try await readBatch(conn, buffered: &pending)
                guard let batch else { break } // client closed
                if batch.first == UInt8(ascii: "X") { break } // Terminate
                let reply = try await db.rawExchange(batch)
                try await send(conn, reply)
            }
        } catch {
            // connection error or engine death; drop the client
        }
        // A client that vanished mid-transaction must not poison the shared
        // backend session (the app's actor uses the same one).
        _ = try? await db.rawExchange(Wire.simpleQuery("ROLLBACK"))
        conn.cancel()
    }

    /// StartupMessage → MD5 challenge → verify → synthesized auth-ok
    /// preamble. Nothing reaches the engine until this passes.
    private func handshake(_ conn: NWConnection) async throws -> Bool {
        var pending = Data()
        // startup message: int32 len, int32 protocol, k/v pairs
        guard let startup = try await readStartup(conn, buffered: &pending) else {
            return false
        }
        let proto = startup.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
        if proto == 80877103 || proto == 80877104 {
            // SSLRequest / GSSENCRequest → "no", client retries plaintext
            try await send(conn, Data([UInt8(ascii: "N")]))
            return try await handshake(conn)
        }
        guard proto == 196608 else { return false }

        var salt = Data(count: 4)
        salt.withUnsafeMutableBytes { buf in
            buf.storeBytes(of: UInt32.random(in: .min ... .max), as: UInt32.self)
        }
        try await send(conn, authMessage(kind: 5, extra: salt))

        guard let pw = try await readMessage(conn, buffered: &pending),
              pw.type == UInt8(ascii: "p") else { return false }
        var r = Wire.Reader(pw.body)
        let offered = r.cstring() ?? ""
        guard constantTimeEquals(offered, expectedMD5(salt: salt)) else {
            try await send(conn, errorMessage(
                code: "28P01",
                message: "password authentication failed for user \"\(credentials.user)\""))
            return false
        }

        var preamble = Data()
        preamble.append(authMessage(kind: 0, extra: Data()))
        for (k, v) in [("server_version", "17.5"), ("client_encoding", "UTF8"),
                       ("server_encoding", "UTF8"), ("DateStyle", "ISO, MDY"),
                       ("integer_datetimes", "on"), ("standard_conforming_strings", "on")] {
            preamble.append(backendMessage("S") {
                $0.cstring(k)
                $0.cstring(v)
            })
        }
        preamble.append(backendMessage("K") {
            $0.int32(1)
            $0.int32(0)
        })
        preamble.append(backendMessage("Z") { $0.uint8(UInt8(ascii: "I")) })
        try await send(conn, preamble)
        return true
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let da = Data(a.utf8), db = Data(b.utf8)
        guard da.count == db.count else { return false }
        return zip(da, db).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func expectedMD5(salt: Data) -> String {
        func md5hex(_ d: Data) -> String {
            Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        let inner = md5hex(Data((credentials.password + credentials.user).utf8))
        return "md5" + md5hex(Data(inner.utf8) + salt)
    }

    // MARK: - message framing

    private struct Message {
        let type: UInt8
        let body: Data
        let raw: Data
    }

    private func readStartup(_ conn: NWConnection, buffered: inout Data) async throws -> Data? {
        while buffered.count < 4 {
            guard let chunk = try await receive(conn) else { return nil }
            buffered.append(chunk)
        }
        let len = Int(buffered.prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        guard len >= 8, len < 10_000 else { return nil }
        while buffered.count < len {
            guard let chunk = try await receive(conn) else { return nil }
            buffered.append(chunk)
        }
        let body = buffered.subdata(in: 4..<len)
        buffered.removeFirst(len)
        return body
    }

    private func readMessage(_ conn: NWConnection, buffered: inout Data) async throws -> Message? {
        while buffered.count < 5 {
            guard let chunk = try await receive(conn) else { return nil }
            buffered.append(chunk)
        }
        let len = Int(buffered.dropFirst().prefix(4).reduce(0) { $0 << 8 | UInt32($1) })
        guard len >= 4 else { return nil }
        while buffered.count < 1 + len {
            guard let chunk = try await receive(conn) else { return nil }
            buffered.append(chunk)
        }
        let raw = buffered.prefix(1 + len)
        let msg = Message(
            type: buffered[buffered.startIndex],
            body: raw.subdata(in: (raw.startIndex + 5)..<raw.endIndex),
            raw: Data(raw)
        )
        buffered.removeFirst(1 + len)
        return msg
    }

    /// Read client messages up to and including a batch terminator: Sync,
    /// simple Query, or Terminate. The whole batch goes to the engine as
    /// one exchange (the engine replies through ReadyForQuery).
    private func readBatch(_ conn: NWConnection, buffered: inout Data) async throws -> Data? {
        var batch = Data()
        while true {
            guard let msg = try await readMessage(conn, buffered: &buffered) else {
                return batch.isEmpty ? nil : batch
            }
            batch.append(msg.raw)
            switch msg.type {
            case UInt8(ascii: "S"), UInt8(ascii: "Q"), UInt8(ascii: "X"):
                return batch
            default:
                continue
            }
        }
    }

    private func receive(_ conn: NWConnection) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - backend message builders

    private func backendMessage(_ type: String, _ body: (inout Wire.Writer) -> Void) -> Data {
        var w = Wire.Writer()
        body(&w)
        var out = Data()
        out.append(type.utf8.first!)
        var len = UInt32(w.data.count + 4).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(w.data)
        return out
    }

    private func authMessage(kind: Int32, extra: Data) -> Data {
        backendMessage("R") {
            $0.int32(kind)
            $0.raw(extra)
        }
    }

    private func errorMessage(code: String, message: String) -> Data {
        backendMessage("E") {
            $0.uint8(UInt8(ascii: "S"))
            $0.cstring("FATAL")
            $0.uint8(UInt8(ascii: "C"))
            $0.cstring(code)
            $0.uint8(UInt8(ascii: "M"))
            $0.cstring(message)
            $0.uint8(0)
        }
    }
}
