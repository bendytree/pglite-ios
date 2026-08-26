import CryptoKit
import Network
import XCTest
@testable import PGliteKit

/// Minimal blocking wire client over NWConnection for exercising the
/// localhost server exactly the way an external Postgres driver would.
private final class WireClient {
    let conn: NWConnection
    private var buffer = Data()

    init(port: UInt16) {
        conn = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        conn.start(queue: DispatchQueue(label: "wire-client"))
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { e in
                e.map { c.resume(throwing: $0) } ?? c.resume()
            })
        }
    }

    private func receiveChunk() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
                data, _, complete, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else if complete { c.resume(returning: nil) }
                else { c.resume(returning: Data()) }
            }
        }
    }

    /// Read backend messages until (and including) the wanted type.
    func readUntil(_ type: Character) async throws -> [Wire.BackendMessage] {
        var msgs: [Wire.BackendMessage] = []
        while true {
            while buffer.count >= 5 {
                let len = Int(buffer.dropFirst().prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
                guard len >= 4, buffer.count >= 1 + len else { break }
                let msg = Wire.BackendMessage(
                    type: buffer[buffer.startIndex],
                    body: buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + 1 + len))
                )
                buffer.removeFirst(1 + len)
                msgs.append(msg)
                if msg.type == type.asciiValue! { return msgs }
            }
            guard let chunk = try await receiveChunk() else { return msgs }
            buffer.append(chunk)
        }
    }

    func startup(user: String, password: String, expectFailure: Bool = false) async throws -> Bool {
        var w = Wire.Writer()
        w.int32(196608)
        w.cstring("user")
        w.cstring(user)
        w.cstring("database")
        w.cstring("template1")
        w.uint8(0)
        var msg = Data()
        var len = UInt32(w.data.count + 4).bigEndian
        withUnsafeBytes(of: &len) { msg.append(contentsOf: $0) }
        msg.append(w.data)
        try await send(msg)

        let auth = try await readUntil("R")
        guard let r = auth.last, r.type == UInt8(ascii: "R"),
              r.body.prefix(4).reduce(UInt32(0), { $0 << 8 | UInt32($1) }) == 5 else {
            return false
        }
        let salt = r.body.subdata(in: (r.body.startIndex + 4)..<(r.body.startIndex + 8))
        func md5hex(_ d: Data) -> String {
            Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        let inner = md5hex(Data((password + user).utf8))
        let response = "md5" + md5hex(Data(inner.utf8) + salt)

        var pw = Wire.Writer()
        pw.cstring(response)
        var pmsg = Data([UInt8(ascii: "p")])
        var plen = UInt32(pw.data.count + 4).bigEndian
        withUnsafeBytes(of: &plen) { pmsg.append(contentsOf: $0) }
        pmsg.append(pw.data)
        try await send(pmsg)

        if expectFailure {
            let reply = try await readUntil("E")
            return !reply.contains { $0.type == UInt8(ascii: "E") }
        }
        let ready = try await readUntil("Z")
        return ready.contains { $0.type == UInt8(ascii: "Z") }
    }

    func query(_ sql: String) async throws -> [Wire.BackendMessage] {
        try await send(Wire.simpleQuery(sql))
        return try await readUntil("Z")
    }

    func close() {
        conn.cancel()
    }
}

final class PGliteServerTests: XCTestCase {
    var root: URL!
    var db: PGliteDatabase!
    var server: PGliteServer!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pglite-srv-test-\(UUID().uuidString)")
        db = try PGliteDatabase(root: root)
        server = PGliteServer(
            db: db,
            credentials: .init(password: "sekret")
        )
        try server.start()
        XCTAssertGreaterThan(server.port, 0)
    }

    override func tearDown() async throws {
        server.stop()
        await db.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testTCPQueryRoundTrip() async throws {
        let client = WireClient(port: server.port)
        defer { client.close() }
        let ok = try await client.startup(user: "postgres", password: "sekret")
        XCTAssertTrue(ok, "handshake failed")

        let msgs = try await client.query("SELECT 6 * 7 AS answer")
        let rows = msgs.filter { $0.type == UInt8(ascii: "D") }.map { Wire.dataRow($0.body) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0].flatMap { String(data: $0, encoding: .utf8) }, "42")
        XCTAssertTrue(msgs.contains { $0.type == UInt8(ascii: "C") })
    }

    func testWrongPasswordRejected() async throws {
        let client = WireClient(port: server.port)
        defer { client.close() }
        let ok = try await client.startup(
            user: "postgres", password: "wrong", expectFailure: true)
        XCTAssertFalse(ok, "wrong password was accepted")
    }

    func testServerAndActorShareData() async throws {
        try await db.execute("CREATE TABLE shared (v int)")
        try await db.execute("INSERT INTO shared VALUES ($1)", [.int(7)])

        let client = WireClient(port: server.port)
        defer { client.close() }
        _ = try await client.startup(user: "postgres", password: "sekret")
        let msgs = try await client.query("SELECT v FROM shared")
        let rows = msgs.filter { $0.type == UInt8(ascii: "D") }.map { Wire.dataRow($0.body) }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0].flatMap { String(data: $0, encoding: .utf8) }, "7")

        // and back: TCP write visible to the actor
        _ = try await client.query("INSERT INTO shared VALUES (8)")
        let r = try await db.execute("SELECT count(*) AS n FROM shared")
        XCTAssertEqual(r.rows[0].int("n"), 2)
    }

    func testAbandonedTransactionIsRolledBack() async throws {
        try await db.execute("CREATE TABLE txguard (v int)")
        let client = WireClient(port: server.port)
        _ = try await client.startup(user: "postgres", password: "sekret")
        _ = try await client.query("BEGIN")
        _ = try await client.query("INSERT INTO txguard VALUES (1)")
        client.close() // vanish mid-transaction
        try await Task.sleep(nanoseconds: 300_000_000)

        // shared session must be usable and the orphan insert rolled back
        let r = try await db.execute("SELECT count(*) AS n FROM txguard")
        XCTAssertEqual(r.rows[0].int("n"), 0)
    }
}
