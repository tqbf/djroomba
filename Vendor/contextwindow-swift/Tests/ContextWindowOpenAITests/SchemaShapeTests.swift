import XCTest
import GRDB
@testable import ContextWindow

/// Part 2 of the adapted Go-parity harness: assert the **durable schema shape**
/// (exact table names, index names, and per-table column name/type/notnull/pk)
/// so a future Go build can open and interoperate with DBs this Swift port
/// writes.
///
/// This file imports GRDB and uses *raw SQL only* (no domain `Record`/`Context`
/// types — GRDB ships its own `Record`, so the domain types are kept out of
/// this translation unit to avoid the name clash). Offline.
final class SchemaShapeTests: XCTestCase {

    func testSchemaShapeIsLockedForGoInterop() throws {
        let path = NSTemporaryDirectory() + "cw-schema-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteContextStore(path: path)
        try store.initialize()

        let dbQueue = try DatabaseQueue(path: path)
        try dbQueue.read { db in
            // Tables (exact set, excluding sqlite internal).
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='table' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            XCTAssertEqual(tables, ["context_tools", "contexts", "records"])

            // Explicit (named) indexes we created.
            let indexes = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type='index' AND name NOT LIKE 'sqlite_%'
                ORDER BY name
                """)
            XCTAssertEqual(indexes, [
                "idx_contexts_name",
                "idx_records_live",
                "idx_records_timestamp",
            ])

            func columnSig(_ table: String) throws -> [String] {
                try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))").map { row in
                    let name: String = row["name"]
                    let type: String = row["type"]
                    let notnull: Int = row["notnull"]
                    let pk: Int = row["pk"]
                    return "\(name)|\(type)|\(notnull)|\(pk)"
                }
            }

            XCTAssertEqual(try columnSig("contexts"), [
                "id|TEXT|1|1",
                "name|TEXT|1|0",
                "start_time|DATETIME|1|0",
            ])

            XCTAssertEqual(try columnSig("records"), [
                "id|INTEGER|0|1",
                "timestamp|DATETIME|1|0",
                "source|INTEGER|1|0",
                "content|TEXT|1|0",
                "live|BOOLEAN|1|0",
                "est_tokens|INTEGER|1|0",
                "context_id|TEXT|1|0",
            ])

            XCTAssertEqual(try columnSig("context_tools"), [
                "context_id|TEXT|1|1",
                "tool_name|TEXT|1|2",
                "definition|TEXT|1|0",
            ])

            // Index target columns are part of the durable contract too.
            func indexColumns(_ index: String) throws -> [String] {
                try Row.fetchAll(db, sql: "PRAGMA index_info(\(index))")
                    .map { $0["name"] as String }
            }
            XCTAssertEqual(try indexColumns("idx_contexts_name"), ["name"])
            XCTAssertEqual(try indexColumns("idx_records_live"), ["context_id", "live"])
            XCTAssertEqual(try indexColumns("idx_records_timestamp"), ["context_id", "timestamp"])
        }
    }
}
