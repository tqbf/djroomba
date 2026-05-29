import XCTest
@testable import ContextWindow

final class ContextWindowTests: XCTestCase {

    private func makeStore() throws -> SQLiteContextStore {
        try SQLiteContextStore.inMemory()
    }

    // MARK: Acceptance: unnamed window generates a UUID-ish name

    func testUnnamedWindowGeneratesUUIDishName() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store)
        let name = await cw.currentContext.name
        XCTAssertTrue(name.hasPrefix("context-"))
        // The suffix must parse as a UUID.
        let suffix = String(name.dropFirst("context-".count))
        XCTAssertNotNil(UUID(uuidString: suffix), "name suffix is not a UUID: \(name)")
    }

    func testTwoUnnamedWindowsGetDistinctNames() async throws {
        let store = try makeStore()
        let a = try ContextWindow(store: store)
        let b = try ContextWindow(store: store)
        let an = await a.currentContext
        let bn = await b.currentContext
        XCTAssertNotEqual(an.name, bn.name)
        XCTAssertNotEqual(an.id, bn.id)
    }

    // MARK: Acceptance: named contexts enforce uniqueness

    func testNamedWindowAdoptsExistingContext() async throws {
        let store = try makeStore()
        let first = try ContextWindow(store: store, contextName: "shared")
        let second = try ContextWindow(store: store, contextName: "shared")
        let fid = await first.currentContext.id
        let sid = await second.currentContext.id
        XCTAssertEqual(fid, sid)
        XCTAssertEqual(try store.listContexts().count, 1)
    }

    func testCreateDuplicateNamedContextThrows() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "primary")
        do {
            _ = try await cw.createContext(name: "primary")
            XCTFail("expected uniqueness error")
        } catch let error as ContextWindowError {
            XCTAssertEqual(error, .contextNameAlreadyExists("primary"))
        }
    }

    // MARK: Acceptance: system prompt deadening

    func testSetSystemPromptDeadensPriorSystemPrompts() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")
        _ = try await cw.setSystemPrompt("first system")
        _ = try await cw.addPrompt("a user message")
        _ = try await cw.setSystemPrompt("second system")

        let live = try await cw.liveRecords()
        let liveSystem = live.filter { $0.source == .systemPrompt }
        XCTAssertEqual(liveSystem.count, 1)
        XCTAssertEqual(liveSystem.first?.content, "second system")

        // The user message must remain live; only system prompts deadened.
        XCTAssertTrue(live.contains { $0.source == .prompt && $0.content == "a user message" })

        // History still has both system prompts.
        let all = try await cw.allRecords()
        XCTAssertEqual(all.filter { $0.source == .systemPrompt }.count, 2)
    }

    // MARK: Acceptance: live records return in timestamp order

    func testLiveRecordsReturnInTimestampOrder() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")
        _ = try await cw.addPrompt("one")
        _ = try await cw.insertRecord(source: .modelResponse, content: "two")
        _ = try await cw.addPrompt("three")

        let live = try await cw.liveRecords()
        XCTAssertEqual(live.map(\.content), ["one", "two", "three"])
        for i in 1..<live.count {
            XCTAssertLessThanOrEqual(live[i - 1].timestamp, live[i].timestamp)
            XCTAssertLessThan(live[i - 1].id, live[i].id)
        }
    }

    // MARK: Acceptance: deleting current context switches or creates default

    func testDeleteCurrentContextSwitchesToAnother() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "first")
        try await cw.createContext(name: "second") // now current
        let cur1 = await cw.currentContext.name
        XCTAssertEqual(cur1, "second")

        try await cw.deleteContext(name: "second")
        // Falls back to the only remaining context.
        let cur2 = await cw.currentContext.name
        XCTAssertEqual(cur2, "first")
    }

    func testDeleteCurrentContextCreatesDefaultWhenNoneRemain() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "only")
        try await cw.deleteContext(name: "only")

        // A fresh generated default context must now be current.
        let cur = await cw.currentContext.name
        XCTAssertTrue(cur.hasPrefix("context-"))
        XCTAssertNotEqual(cur, "only")
        XCTAssertEqual(try store.listContexts().count, 1)
        XCTAssertEqual(try store.listContexts().first?.name, cur)
    }

    func testDeleteNonCurrentContextKeepsCurrent() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "keep")
        try await cw.createContext(name: "throwaway")
        try await cw.switchContext(name: "keep")

        try await cw.deleteContext(name: "throwaway")
        let cur = await cw.currentContext.name
        XCTAssertEqual(cur, "keep")
        XCTAssertEqual(try store.listContexts().count, 1)
    }

    // MARK: Acceptance: export returns context + all records + tools

    func testExportReturnsContextRecordsAndTools() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "ex")
        _ = try await cw.setSystemPrompt("sys")
        _ = try await cw.addPrompt("hello there world")
        _ = try await cw.insertRecord(source: .modelResponse, content: "dead one", live: false)
        try await cw.registerToolHint(name: "calc", definition: "{\"name\":\"calc\"}")

        let export = try await cw.export()
        XCTAssertEqual(export.context.name, "ex")
        XCTAssertEqual(export.records.count, 3) // includes the dead record
        XCTAssertEqual(export.tools.count, 1)
        XCTAssertEqual(export.tools.first?.toolName, "calc")
    }

    // MARK: Acceptance: token usage = sum(estimatedTokens for live records)

    func testTokenUsageIsSumOfLiveEstimatedTokens() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "tok")
        _ = try await cw.addPrompt("one two")            // 2
        _ = try await cw.addPrompt("three four five")    // 3
        _ = try await cw.insertRecord(source: .modelResponse, content: "dead tokens here", live: false) // not counted

        let usage = try await cw.tokenUsage()
        XCTAssertEqual(usage.liveTokens, 5)

        // Cross-check against the live records directly.
        let manual = try await cw.liveRecords().reduce(0) { $0 + $1.estimatedTokens }
        XCTAssertEqual(usage.liveTokens, manual)
    }

    func testTokenUsageZeroForEmptyContext() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "empty")
        let usage = try await cw.tokenUsage()
        XCTAssertEqual(usage.liveTokens, 0)
    }

    // MARK: Metrics actor

    func testMetricsAccumulates() async {
        let metrics = Metrics()
        await metrics.addModelTokens(10)
        await metrics.addModelTokens(5)
        let total = await metrics.totalModelTokens
        XCTAssertEqual(total, 15)
        await metrics.reset()
        let afterReset = await metrics.totalModelTokens
        XCTAssertEqual(afterReset, 0)
    }

    // MARK: TokenCounter

    func testWhitespaceTokenCounter() {
        let c = WhitespaceTokenCounter()
        XCTAssertEqual(c.count(""), 0)
        XCTAssertEqual(c.count("   "), 0)
        XCTAssertEqual(c.count("one"), 1)
        XCTAssertEqual(c.count("one two\tthree\nfour"), 4)
        XCTAssertEqual(c.count("  leading and trailing  "), 3)
    }
}
