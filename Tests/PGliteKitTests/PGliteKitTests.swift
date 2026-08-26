import XCTest
@testable import PGliteKit

final class PGliteKitTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pglite-test-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSelectOne() throws {
        let db = try PGlite(root: root)
        defer { db.close() }
        let rows = try db.rows("SELECT 1")
        XCTAssertEqual(rows, [["1"]])
    }

    func testSQLAndPersistence() throws {
        do {
            let db = try PGlite(root: root)
            try db.query("CREATE TABLE fruit (id serial primary key, name text, qty int)")
            try db.query("INSERT INTO fruit (name, qty) VALUES ('apple', 3), ('pear', 7)")
            XCTAssertEqual(
                try db.rows("SELECT name, qty FROM fruit ORDER BY id"),
                [["apple", "3"], ["pear", "7"]]
            )
            // ERROR recovery: the instance must survive a SQL error
            XCTAssertThrowsError(try db.query("SELECT 1/0")) { error in
                XCTAssertTrue("\(error)".contains("22012"))
            }
            XCTAssertEqual(try db.rows("SELECT count(*) FROM fruit"), [["2"]])
            db.close()
        }
        // reboot: data persisted
        do {
            let db = try PGlite(root: root)
            defer { db.close() }
            XCTAssertEqual(
                try db.rows("SELECT name FROM fruit ORDER BY id"),
                [["apple"], ["pear"]]
            )
        }
    }

    func testPgvector() throws {
        let db = try PGlite(root: root)
        defer { db.close() }
        try db.query("CREATE EXTENSION IF NOT EXISTS vector")
        try db.query("CREATE TABLE items (id serial primary key, e vector(3))")
        try db.query("INSERT INTO items (e) VALUES ('[1,2,3]'), ('[4,5,6]'), ('[0,0,1]')")
        XCTAssertEqual(
            try db.rows("SELECT id FROM items ORDER BY e <-> '[1,2,3]' LIMIT 1"),
            [["1"]]
        )
        try db.query("CREATE INDEX ON items USING hnsw (e vector_l2_ops)")
        try db.query("SET enable_seqscan = off")
        XCTAssertEqual(
            try db.rows("SELECT id FROM items ORDER BY e <-> '[4,5,6]' LIMIT 1"),
            [["2"]]
        )
    }
}
