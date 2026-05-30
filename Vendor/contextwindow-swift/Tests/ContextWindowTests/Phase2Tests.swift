import XCTest
@testable import ContextWindow

final class Phase2Tests: XCTestCase {

    private func makeStore() throws -> SQLiteContextStore {
        try SQLiteContextStore.inMemory()
    }

    // MARK: Acceptance: FakeModel sees only live records (exact set, order)

    func testFakeModelReceivesExactlyTheLiveSetInOrder() async throws {
        let store = try makeStore()
        let model = FakeModel(reply: "ok")
        let cw = try ContextWindow(store: store, contextName: "c", model: model)

        _ = try await cw.setSystemPrompt("sys")
        _ = try await cw.addPrompt("first")
        // A dead record that must NOT be visible to the model.
        _ = try await cw.insertRecord(source: .modelResponse, content: "DEAD", live: false)
        _ = try await cw.addPrompt("second")

        // The live set the model *should* see, captured before the call
        // (callModel inserts the reply, which would otherwise change it).
        let liveBefore = try await cw.liveRecords()

        _ = try await cw.callModel()

        let seen = try XCTUnwrap(model.lastCall)

        // Exactly the live set at call time...
        XCTAssertEqual(seen.map(\.id), liveBefore.map(\.id))
        XCTAssertEqual(seen.map(\.content), ["sys", "first", "second"])
        XCTAssertFalse(seen.contains { $0.content == "DEAD" })
        // ...in timestamp ascending order.
        for i in 1..<seen.count {
            XCTAssertLessThanOrEqual(seen[i - 1].timestamp, seen[i].timestamp)
            XCTAssertLessThan(seen[i - 1].id, seen[i].id)
        }
    }

    // MARK: Acceptance: FakeModel emits multiple events; all persisted

    func testMultipleEmittedEventsAllPersisted() async throws {
        let store = try makeStore()
        let model = FakeModel(result: ModelResult(
            events: [
                RecordEvent(source: .toolCall, content: "search(\"swift\")"),
                RecordEvent(source: .toolOutput, content: "result text"),
                RecordEvent(source: .modelResponse, content: "final answer"),
            ],
            tokensUsed: 42
        ))
        let cw = try ContextWindow(store: store, contextName: "c", model: model)
        _ = try await cw.addPrompt("question")

        let returned = try await cw.callModel()
        XCTAssertEqual(returned, "final answer") // last event content

        let all = try await cw.allRecords()
        // prompt + 3 emitted events
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(
            all.map(\.source),
            [.prompt, .toolCall, .toolOutput, .modelResponse]
        )
        XCTAssertEqual(
            all.map(\.content),
            ["question", "search(\"swift\")", "result text", "final answer"]
        )
        // All emitted events default to live.
        XCTAssertTrue(all.dropFirst().allSatisfy { $0.live })

        // tokensUsed was added to metrics.
        let total = await cw.metrics.totalModelTokens
        XCTAssertEqual(total, 42)
    }

    func testCallModelReturnsLastEmittedEventContent() async throws {
        let store = try makeStore()
        let model = FakeModel(result: ModelResult(
            events: [
                RecordEvent(source: .modelResponse, content: "intermediate"),
                RecordEvent(source: .modelResponse, content: "LAST"),
            ],
            tokensUsed: 1
        ))
        let cw = try ContextWindow(store: store, contextName: "c", model: model)
        let out = try await cw.callModel()
        XCTAssertEqual(out, "LAST")
    }

    func testCallModelWithoutModelThrows() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")
        do {
            _ = try await cw.callModel()
            XCTFail("expected noModelConfigured")
        } catch let error as ModelError {
            XCTAssertEqual(error, .noModelConfigured)
        }
    }

    func testCallModelEmptyResultThrows() async throws {
        let store = try makeStore()
        let model = FakeModel(result: ModelResult(events: [], tokensUsed: 0))
        let cw = try ContextWindow(store: store, contextName: "c", model: model)
        do {
            _ = try await cw.callModel()
            XCTFail("expected emptyModelResult")
        } catch let error as ModelError {
            XCTAssertEqual(error, .emptyModelResult)
        }
    }

    func testCallModelPreservesEventLiveness() async throws {
        let store = try makeStore()
        let model = FakeModel(result: ModelResult(
            events: [
                RecordEvent(source: .modelResponse, content: "live one", live: true),
                RecordEvent(source: .modelResponse, content: "dead one", live: false),
            ],
            tokensUsed: 0
        ))
        let cw = try ContextWindow(store: store, contextName: "c", model: model)
        _ = try await cw.callModel()
        let all = try await cw.allRecords()
        let liveOne = all.first { $0.content == "live one" }
        let deadOne = all.first { $0.content == "dead one" }
        XCTAssertEqual(liveOne?.live, true)
        XCTAssertEqual(deadOne?.live, false)
    }

    // MARK: Acceptance: summarizeLiveContext errors without summarizer

    func testSummarizeWithoutSummarizerThrows() async throws {
        let store = try makeStore()
        let model = FakeModel(reply: "ignored")
        let cw = try ContextWindow(store: store, contextName: "c", model: model)
        do {
            _ = try await cw.summarizeLiveContext()
            XCTFail("expected noSummarizerConfigured")
        } catch let error as ModelError {
            XCTAssertEqual(error, .noSummarizerConfigured)
        }
    }

    // MARK: Acceptance: summarizer prepends prompt, takes last event

    func testSummarizePrependsPromptAndUsesLastEvent() async throws {
        let store = try makeStore()
        let summarizer = FakeModel(result: ModelResult(
            events: [
                RecordEvent(source: .modelResponse, content: "draft"),
                RecordEvent(source: .modelResponse, content: "THE SUMMARY"),
            ],
            tokensUsed: 7
        ))
        let cw = try ContextWindow(
            store: store, contextName: "c", summarizer: summarizer
        )
        _ = try await cw.addPrompt("alpha beta")        // 2 tokens
        _ = try await cw.addPrompt("gamma")             // 1 token

        let result = try await cw.summarizeLiveContext()
        XCTAssertEqual(result.summary, "THE SUMMARY")   // last event
        XCTAssertEqual(result.replaced.count, 2)
        XCTAssertEqual(result.originalTokenCount, 3)    // 2 + 1
        XCTAssertEqual(result.summaryTokenCount, 7)     // tokensUsed

        // The summarizer saw the prompt prepended ahead of the live records.
        let seen = try XCTUnwrap(summarizer.lastCall)
        XCTAssertEqual(seen.count, 3) // prompt + 2 live
        XCTAssertEqual(seen.first?.source, .systemPrompt)
        XCTAssertEqual(seen.first?.content, SummarizerPrompt.default)
        XCTAssertEqual(seen.dropFirst().map(\.content), ["alpha beta", "gamma"])

        // summarizeLiveContext must NOT mutate storage.
        let live = try await cw.liveRecords()
        XCTAssertEqual(live.map(\.content), ["alpha beta", "gamma"])
    }

    // MARK: Acceptance: acceptSummary deadens originals transactionally

    func testAcceptSummaryDeadensOriginalsAndInsertsSummary() async throws {
        let store = try makeStore()
        let summarizer = FakeModel(reply: "SUM")
        let cw = try ContextWindow(
            store: store, contextName: "c", summarizer: summarizer
        )
        _ = try await cw.addPrompt("one")
        _ = try await cw.addPrompt("two")

        let result = try await cw.summarizeLiveContext()
        try await cw.acceptSummary(result)

        let live = try await cw.liveRecords()
        // Originals deadened; summary is the single live record.
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.source, .modelResponse)
        XCTAssertEqual(live.first?.content, "SUM")
        XCTAssertTrue(live.first?.live ?? false)

        // History retains the original (now-dead) records.
        let all = try await cw.allRecords()
        XCTAssertEqual(all.count, 3)
        let originals = all.filter { $0.content == "one" || $0.content == "two" }
        XCTAssertEqual(originals.count, 2)
        XCTAssertTrue(originals.allSatisfy { !$0.live })
    }

    func testAcceptSummaryIsAtomic() throws {
        // Directly exercise the store's transactional replaceRecords: a
        // failing insert (NOT NULL violation) must roll back the deadens too.
        let store = try makeStore()
        try store.initialize()
        let ctx = try store.createContext(name: "atomic")
        let r1 = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "a", live: true)
        let r2 = try store.insertRecord(contextID: ctx.id, source: .prompt, content: "b", live: true)

        // Force the insert to fail by targeting a non-existent context for the
        // FK (the records.context_id REFERENCES contexts(id)). We instead use
        // an invalid scenario: deaden valid IDs but insert into a bogus ctx so
        // the transaction cannot fully commit; verify originals stay live.
        let bogus = UUID()
        XCTAssertThrowsError(
            try store.replaceRecords(
                deadenIDs: [r1.id, r2.id],
                contextID: bogus, // FK violation -> whole tx rolls back
                source: .modelResponse,
                content: "summary",
                live: true
            )
        )

        // Atomicity: because the insert failed, the deadens must NOT persist.
        let live = try store.listLiveRecords(contextID: ctx.id)
        XCTAssertEqual(Set(live.map(\.id)), Set([r1.id, r2.id]))
        XCTAssertTrue(live.allSatisfy { $0.live })
    }

    // MARK: Acceptance: rejectSummary no-ops storage

    func testRejectSummaryDoesNotMutateStorage() async throws {
        let store = try makeStore()
        let summarizer = FakeModel(reply: "SUM")
        let cw = try ContextWindow(
            store: store, contextName: "c", summarizer: summarizer
        )
        _ = try await cw.addPrompt("keep one")
        _ = try await cw.addPrompt("keep two")

        let result = try await cw.summarizeLiveContext()
        await cw.rejectSummary(result)

        let live = try await cw.liveRecords()
        XCTAssertEqual(live.map(\.content), ["keep one", "keep two"])
        XCTAssertTrue(live.allSatisfy { $0.live })
        let all = try await cw.allRecords()
        XCTAssertEqual(all.count, 2) // nothing inserted
    }

    // MARK: Acceptance: tools register, list, execute, persist context_tools

    func testToolsRegisterListExecuteAndPersistHint() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")

        let schema = JSONSchemaToolDefinition(
            name: "echo",
            description: "echoes its input",
            parameters: .object([
                "type": .string("object"),
                "properties": .object([
                    "text": .object(["type": .string("string")])
                ]),
            ]),
            strict: true
        )
        let runner = ClosureToolRunner { data in
            "echoed:\(String(decoding: data, as: UTF8.self))"
        }
        try await cw.registerTool(schema: schema, runner: runner)

        // Listed.
        let listed = await cw.registeredTools()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.name, "echo")

        // Executed.
        let out = try await cw.executeTool(
            name: "echo", args: Data("hi".utf8)
        )
        XCTAssertEqual(out, "echoed:hi")

        // context_tools hint persisted with the JSON-encoded schema.
        let export = try await cw.export()
        XCTAssertEqual(export.tools.count, 1)
        XCTAssertEqual(export.tools.first?.toolName, "echo")
        let decoded = try JSONDecoder().decode(
            JSONSchemaToolDefinition.self,
            from: Data((export.tools.first?.definition ?? "").utf8)
        )
        XCTAssertEqual(decoded.name, "echo")
        XCTAssertEqual(decoded.description, "echoes its input")
        XCTAssertEqual(decoded.strict, true)
        XCTAssertEqual(decoded.parameters, schema.parameters)
    }

    func testExecuteUnregisteredToolThrows() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")
        do {
            _ = try await cw.executeTool(name: "ghost", args: Data())
            XCTFail("expected toolNotRegistered")
        } catch let error as ModelError {
            XCTAssertEqual(error, .toolNotRegistered("ghost"))
        }
    }

    func testReregisteringToolReplaces() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")
        let s1 = JSONSchemaToolDefinition(name: "t", parameters: .object([:]))
        try await cw.registerTool(schema: s1, runner: ClosureToolRunner { _ in "v1" })
        try await cw.registerTool(schema: s1, runner: ClosureToolRunner { _ in "v2" })

        let listed = await cw.registeredTools()
        XCTAssertEqual(listed.count, 1)
        let out = try await cw.executeTool(name: "t", args: Data())
        XCTAssertEqual(out, "v2")
        let export = try await cw.export()
        XCTAssertEqual(export.tools.count, 1)
    }

    // MARK: Acceptance: middleware receives tool-call + tool-result callbacks

    func testMiddlewareReceivesToolCallAndResult() async throws {
        let store = try makeStore()

        actor Recorder {
            var events: [MiddlewareEvent] = []
            func add(_ e: MiddlewareEvent) { events.append(e) }
        }
        let recorder = Recorder()
        let mw = ClosureMiddleware(
            onToolCall: { name, args in
                await recorder.add(.toolCall(name: name, args: args))
            },
            onToolResult: { name, output in
                await recorder.add(.toolResult(name: name, output: output))
            }
        )

        let cw = try ContextWindow(
            store: store, contextName: "c", middleware: mw
        )
        let schema = JSONSchemaToolDefinition(name: "adder", parameters: .object([:]))
        try await cw.registerTool(
            schema: schema,
            runner: ClosureToolRunner { _ in "sum=3" }
        )

        let out = try await cw.executeTool(
            name: "adder", args: Data("{\"a\":1}".utf8)
        )
        XCTAssertEqual(out, "sum=3")

        let events = await recorder.events
        XCTAssertEqual(events, [
            .toolCall(name: "adder", args: Data("{\"a\":1}".utf8)),
            .toolResult(name: "adder", output: "sum=3"),
        ])
    }

    // MARK: addToolCall / addToolOutput surface

    func testAddToolCallAndOutputPersistAsRecords() async throws {
        let store = try makeStore()
        let cw = try ContextWindow(store: store, contextName: "c")
        _ = try await cw.addToolCall(name: "calc", args: "{\"x\":2}")
        _ = try await cw.addToolOutput("4")
        let live = try await cw.liveRecords()
        XCTAssertEqual(live.map(\.source), [.toolCall, .toolOutput])
        XCTAssertEqual(live[0].content, "calc({\"x\":2})")
        XCTAssertEqual(live[1].content, "4")
    }

    // MARK: JSONValue round-trips

    func testJSONValueRoundTrips() throws {
        let value: JSONValue = .object([
            "s": .string("hi"),
            "n": .number(3.5),
            "b": .bool(true),
            "nul": .null,
            "arr": .array([.number(1), .string("two")]),
            "nested": .object(["k": .bool(false)]),
        ])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, value)
    }
}
