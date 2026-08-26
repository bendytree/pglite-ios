import XCTest
@testable import PGliteKit

final class PGliteDatabaseTests: XCTestCase {
    var root: URL!
    var db: PGliteDatabase!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pglite-db-test-\(UUID().uuidString)")
        db = try PGliteDatabase(root: root)
    }

    override func tearDown() async throws {
        await db.close()
        try? FileManager.default.removeItem(at: root)
    }

    func testFastBootUsedPristineSeed() throws {
        // The pristine archive carries a marker file that in-guest initdb
        // would never create; its presence proves the seed path ran.
        let marker = root.appendingPathComponent("tmp/pglite/base/.pgios-pristine")
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path),
                      "seed marker missing — initdb ran instead of the pristine seed")
    }

    func testParameterizedQuery() async throws {
        let r = try await db.execute("SELECT $1::int + $2::int AS sum", [.int(40), .int(2)])
        XCTAssertEqual(r.rows[0].int("sum"), 42)
        XCTAssertEqual(r.tag, "SELECT 1")
    }

    func testTypedRoundTrip() async throws {
        try await db.execute("""
            CREATE TABLE t (id serial primary key, name text, score float8,
                            ok bool, blob bytea, uid uuid, at timestamptz)
            """)
        let uid = UUID()
        let blob = Data([0xde, 0xad, 0xbe, 0xef])
        try await db.execute(
            "INSERT INTO t (name, score, ok, blob, uid, at) VALUES ($1, $2, $3, $4, $5, $6)",
            [.string("naïve — ⚡️"), .double(2.5), .bool(true), .bytes(blob),
             .uuid(uid), .date(Date(timeIntervalSince1970: 1_756_200_000))]
        )
        let r = try await db.execute("SELECT * FROM t")
        let row = r.rows[0]
        XCTAssertEqual(row.text("name"), "naïve — ⚡️")
        XCTAssertEqual(row.double("score"), 2.5)
        XCTAssertEqual(row.bool("ok"), true)
        XCTAssertEqual(row.bytes("blob"), blob)
        XCTAssertEqual(row.uuid("uid"), uid)
        XCTAssertNotNil(row.text("at"))
    }

    func testNullHandling() async throws {
        let r = try await db.execute("SELECT $1::text AS v", [nil])
        XCTAssertTrue(r.rows[0].isNull(0))
        XCTAssertNil(r.rows[0].text("v"))
    }

    func testErrorMapping() async throws {
        do {
            _ = try await db.execute("SELECT 1/0")
            XCTFail("expected error")
        } catch let e as PGError {
            XCTAssertEqual(e.sqlState, "22012")
            XCTAssertTrue(e.message.contains("division by zero"))
        }
        // instance survives
        let r = try await db.execute("SELECT $1::int AS ok", [.int(7)])
        XCTAssertEqual(r.rows[0].int("ok"), 7)
    }

    func testTransactionRollback() async throws {
        try await db.execute("CREATE TABLE tx (v int)")
        struct Boom: Error {}
        do {
            try await db.withTransaction { db in
                try await db.execute("INSERT INTO tx VALUES ($1)", [.int(1)])
                throw Boom()
            }
            XCTFail("expected rethrow")
        } catch is Boom {}
        let r = try await db.execute("SELECT count(*) AS n FROM tx")
        XCTAssertEqual(r.rows[0].int("n"), 0)

        let inserted: Int = try await db.withTransaction { db in
            try await db.execute("INSERT INTO tx VALUES ($1), ($2)", [.int(1), .int(2)])
            return 2
        }
        XCTAssertEqual(inserted, 2)
        let r2 = try await db.execute("SELECT count(*) AS n FROM tx")
        XCTAssertEqual(r2.rows[0].int("n"), 2)
    }

    func testVectorParams() async throws {
        try await db.execute("CREATE EXTENSION IF NOT EXISTS vector")
        try await db.execute("CREATE TABLE items (id serial primary key, e vector(3))")
        for v in [[1, 2, 3], [4, 5, 6], [0, 0, 1]].map({ $0.map(Float.init) }) {
            try await db.execute("INSERT INTO items (e) VALUES ($1::vector)", [.vector(v)])
        }
        let r = try await db.execute(
            "SELECT id, e, e <-> $1::vector AS dist FROM items ORDER BY dist LIMIT 2",
            [.vector([1, 2, 3])]
        )
        XCTAssertEqual(r.rows.count, 2)
        XCTAssertEqual(r.rows[0].int("id"), 1)
        XCTAssertEqual(r.rows[0].vector("e"), [1, 2, 3])
        XCTAssertEqual(r.rows[0].double("dist"), 0)
        XCTAssertEqual(r.rows[1].int("id"), 3)
    }

    func testMultiStatementScript() async throws {
        let r = try await db.exec("""
            CREATE TABLE s (v int);
            INSERT INTO s VALUES (1), (2), (3);
            SELECT sum(v) AS total FROM s;
            """)
        XCTAssertEqual(r.rows[0].int("total"), 6)
    }
}
