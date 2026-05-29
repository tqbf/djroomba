import XCTest
@testable import ContextWindow

final class ContextStoreTests: XCTestCase {

    private func makeStore() throws -> SQLiteContextStore {
        let store = try SQLiteContextStore.inMemory()
        try store.initialize()
        return store
    }

    func testInitializeIsIdempotent() throws {
        let store = try makeStore()
        // Calling initialize again must not throw or destroy data.
        let ctx = try store.createContext(name: "a")
        try store.initialize()
        let fetched = try store.getContext(name: "a")
        XCTAssertEqual(fetched.id, ctx.id)
    }

    func testCreateAndGetContext() throws {
        let store = try makeStore()
        let created = try store.createContext(name: "alpha")
        let fetched = try store.getContext(name: "alpha")
        XCTAssertEqual(created.id, fetched.id)
        XCTAssertEqual(fetched.name, "alpha")
    }

    func testGetMissingContextThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.getContext(name: "nope")) { error in
            XCTAssertEqual(
                error as? ContextWindowError,
                .contextNotFound("nope")
            )
        }
    }

    func testNameUniquenessIsEnforced() throws {
        let store = try makeStore()
        _ = try store.createContext(name: "dup")
        XCTAssertThrowsError(try store.createContext(name: "dup")) { error in
            XCTAssertEqual(
                error as? ContextWindowError,
                .contextNameAlreadyExists("dup")
            )
        }
    }

    func testInsertRecordComputesTokensAtInsertTime() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "c")
        let rec = try store.insertRecord(
            contextID: ctx.id,
            source: .prompt,
            content: "one two three four",
            live: true
        )
        XCTAssertEqual(rec.estimatedTokens, 4)
        XCTAssertEqual(rec.source, .prompt)
        XCTAssertTrue(rec.live)
        XCTAssertGreaterThan(rec.id, 0)
    }

    func testListLiveRecordsExcludesDeadAndOrdersByTimestamp() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "c")
        let r1 = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "first", live: true)
        let r2 = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "second dead", live: false)
        let r3 = try store.insertRecord(contextID: ctx.id, source: .modelResponse, content: "third", live: true)

        let live = try store.listLiveRecords(contextID: ctx.id)
        XCTAssertEqual(live.map(\.id), [r1.id, r3.id])
        XCTAssertFalse(live.contains { $0.id == r2.id })
        // Timestamp ascending.
        XCTAssertTrue(live[0].timestamp <= live[1].timestamp)
    }

    func testListRecordsIncludesDead() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "c")
        _ = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "a", live: true)
        _ = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "b", live: false)
        let all = try store.listRecords(contextID: ctx.id)
        XCTAssertEqual(all.count, 2)
    }

    func testDeadenRecordsBySource() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "c")
        _ = try store.insertRecord(contextID: ctx.id, source: .systemPrompt, content: "sys1", live: true)
        _ = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "user", live: true)
        try store.deadenRecords(contextID: ctx.id, source: .systemPrompt)

        let live = try store.listLiveRecords(contextID: ctx.id)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.source, .prompt)
    }

    func testDeleteContextRemovesRecordsAndTools() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "doomed")
        _ = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "x", live: true)
        try store.upsertContextTool(contextID: ctx.id, toolName: "calc", definition: "{}")

        try store.deleteContext(name: "doomed")
        XCTAssertThrowsError(try store.getContext(name: "doomed"))
        XCTAssertEqual(try store.listContexts().count, 0)
    }

    func testDeleteMissingContextThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.deleteContext(name: "ghost")) { error in
            XCTAssertEqual(error as? ContextWindowError, .contextNotFound("ghost"))
        }
    }

    func testUpsertContextToolReplaces() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "c")
        try store.upsertContextTool(contextID: ctx.id, toolName: "calc", definition: "v1")
        try store.upsertContextTool(contextID: ctx.id, toolName: "calc", definition: "v2")
        let tools = try store.listContextTools(contextID: ctx.id)
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools.first?.definition, "v2")
    }

    func testExportReturnsContextRecordsAndTools() throws {
        let store = try makeStore()
        let ctx = try store.createContext(name: "exp")
        _ = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "hello world", live: true)
        _ = try store.insertRecord(contextID: ctx.id, source: .modelResponse, content: "hi", live: false)
        try store.upsertContextTool(contextID: ctx.id, toolName: "search", definition: "{\"name\":\"search\"}")

        let export = try store.exportContext(name: "exp")
        XCTAssertEqual(export.context.id, ctx.id)
        XCTAssertEqual(export.records.count, 2) // includes dead record
        XCTAssertEqual(export.tools.count, 1)
        XCTAssertEqual(export.tools.first?.toolName, "search")
    }

    func testExportMissingContextThrows() throws {
        let store = try makeStore()
        XCTAssertThrowsError(try store.exportContext(name: "absent")) { error in
            XCTAssertEqual(error as? ContextWindowError, .contextNotFound("absent"))
        }
    }

    func testFilePersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("cw.sqlite").path

        var ctxID: UUID
        do {
            let store = try SQLiteContextStore(path: path)
            try store.initialize()
            let ctx = try store.createContext(name: "persisted")
            ctxID = ctx.id
            _ = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "alpha beta", live: true)
        }
        // Re-open from disk: same DB must decode identically.
        let reopened = try SQLiteContextStore(path: path)
        let ctx = try reopened.getContext(name: "persisted")
        XCTAssertEqual(ctx.id, ctxID)
        let live = try reopened.listLiveRecords(contextID: ctx.id)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.estimatedTokens, 2)
    }
}
