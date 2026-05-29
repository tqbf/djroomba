import XCTest
import ContextWindow
@testable import ContextWindowOpenAI

/// All offline: every test injects ``StubTransport``. No network occurs.
final class OpenAIChatModelTests: XCTestCase {

    private func record(
        _ id: Int64,
        _ source: RecordType,
        _ content: String,
        _ ts: TimeInterval = 0
    ) -> Record {
        Record(
            id: id,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + ts),
            source: source,
            content: content,
            live: true,
            estimatedTokens: 1,
            contextID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
    }

    // MARK: Missing key

    func testMissingAPIKeyThrows() {
        XCTAssertThrowsError(
            try OpenAIChatModel(model: "gpt-4.1-mini", apiKey: "", transport: StubTransport(json: "{}"))
        ) { error in
            XCTAssertEqual(error as? OpenAIError, .missingAPIKey)
        }
    }

    // MARK: Request shape — record → message mapping

    func testRecordToMessageMappingAndToolSerialization() async throws {
        let stub = StubTransport(json: """
        {"choices":[{"message":{"role":"assistant","content":"hello back"}}],
         "usage":{"total_tokens":12}}
        """)
        let tool = ToolDefinition(
            schema: JSONSchemaToolDefinition(
                name: "search",
                description: "search the web",
                parameters: .object(["type": .string("object")]),
                strict: true
            ),
            runner: ClosureToolRunner { _ in "" }
        )
        let executor = FakeToolExecutor(outputs: [:], tools: [tool])
        let model = try OpenAIChatModel(
            model: "gpt-4.1-mini",
            apiKey: "test-key",
            toolExecutor: executor,
            transport: stub
        )

        let records = [
            record(1, .systemPrompt, "be terse", 0),
            record(2, .prompt, "hi", 1),
            record(3, .modelResponse, "earlier reply", 2),
            record(4, .toolCall, #"search({"q":"swift"})"#, 3),
            record(5, .toolOutput, "swift docs", 4),
        ]

        let result = try await model.call(records)

        XCTAssertEqual(result.events.map(\.source), [.modelResponse])
        XCTAssertEqual(result.events.first?.content, "hello back")
        XCTAssertEqual(result.tokensUsed, 12)
        XCTAssertEqual(stub.sendCount, 1)

        let body = stub.bodyJSON(0)
        XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini")
        let messages = body["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.count, 5)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "be terse")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["content"] as? String, "earlier reply")
        // toolCall record → assistant message carrying synthetic tool_calls
        XCTAssertEqual(messages[3]["role"] as? String, "assistant")
        let tc = (messages[3]["tool_calls"] as! [[String: Any]]).first!
        let fn = tc["function"] as! [String: Any]
        XCTAssertEqual(fn["name"] as? String, "search")
        XCTAssertEqual(fn["arguments"] as? String, #"{"q":"swift"}"#)
        // toolOutput record → tool message
        XCTAssertEqual(messages[4]["role"] as? String, "tool")
        XCTAssertEqual(messages[4]["content"] as? String, "swift docs")

        // Tool schema serialized from JSONSchemaToolDefinition
        let tools = body["tools"] as! [[String: Any]]
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["type"] as? String, "function")
        let toolFn = tools[0]["function"] as! [String: Any]
        XCTAssertEqual(toolFn["name"] as? String, "search")
        XCTAssertEqual(toolFn["description"] as? String, "search the web")
        XCTAssertEqual(toolFn["strict"] as? Bool, true)
        XCTAssertNotNil(toolFn["parameters"])

        // Authorization header carries the key (never logged elsewhere).
        XCTAssertEqual(
            stub.capturedRequests[0].headers["Authorization"],
            "Bearer test-key"
        )
        XCTAssertTrue(
            stub.capturedRequests[0].url.absoluteString.hasSuffix("/chat/completions")
        )
    }

    // MARK: Response → ModelResult events

    func testPlainResponseMapsToSingleModelResponseEvent() async throws {
        let stub = StubTransport(json: """
        {"choices":[{"message":{"role":"assistant","content":"42"}}],
         "usage":{"total_tokens":7}}
        """)
        let model = try OpenAIChatModel(
            model: "gpt-4.1-mini", apiKey: "k", transport: stub
        )
        let result = try await model.call([record(1, .prompt, "answer?")])
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].source, .modelResponse)
        XCTAssertEqual(result.events[0].content, "42")
        XCTAssertEqual(result.events[0].live, true)
        XCTAssertEqual(result.tokensUsed, 7)
    }

    // MARK: Full tool-call loop (two scripted round trips, offline)

    func testToolCallLoopDrivesExecutorAndCollectsAllEvents() async throws {
        let firstResponse = """
        {"choices":[{"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"call_abc","type":"function",
            "function":{"name":"add","arguments":"{\\"a\\":2,\\"b\\":3}"}}]}}],
         "usage":{"total_tokens":10}}
        """
        let secondResponse = """
        {"choices":[{"message":{"role":"assistant","content":"the sum is 5"}}],
         "usage":{"total_tokens":15}}
        """
        let stub = StubTransport(responses: [
            .init(status: 200, json: firstResponse),
            .init(status: 200, json: secondResponse),
        ])
        let executor = FakeToolExecutor(outputs: ["add": "5"])
        let model = try OpenAIChatModel(
            model: "gpt-4.1-mini",
            apiKey: "k",
            toolExecutor: executor,
            transport: stub
        )

        let result = try await model.call([record(1, .prompt, "what is 2+3?")])

        // Two round trips total (the loop, offline).
        XCTAssertEqual(stub.sendCount, 2)

        // Executor was driven with the parsed name + raw args JSON.
        XCTAssertEqual(executor.executedCalls.count, 1)
        XCTAssertEqual(executor.executedCalls[0].name, "add")
        XCTAssertEqual(executor.executedCalls[0].args, #"{"a":2,"b":3}"#)

        // Events: tool call + tool output + final assistant message, in order.
        XCTAssertEqual(
            result.events.map(\.source),
            [.toolCall, .toolOutput, .modelResponse]
        )
        XCTAssertEqual(result.events[0].content, #"add({"a":2,"b":3})"#)
        XCTAssertEqual(result.events[1].content, "5")
        XCTAssertEqual(result.events[2].content, "the sum is 5")
        // Tokens summed across both round trips.
        XCTAssertEqual(result.tokensUsed, 25)

        // The continuation request carried the assistant tool_calls turn and
        // the tool output message.
        let secondBody = stub.bodyJSON(1)
        let messages = secondBody["messages"] as! [[String: Any]]
        XCTAssertEqual(messages.last?["role"] as? String, "tool")
        XCTAssertEqual(messages.last?["content"] as? String, "5")
        XCTAssertEqual(messages.last?["tool_call_id"] as? String, "call_abc")
    }

    // MARK: HTTP error surfaces

    func testNon2xxStatusThrowsHTTPStatus() async throws {
        let stub = StubTransport(responses: [
            .init(status: 429, json: #"{"error":{"message":"rate limited"}}"#)
        ])
        let model = try OpenAIChatModel(
            model: "gpt-4.1-mini", apiKey: "k", transport: stub
        )
        do {
            _ = try await model.call([record(1, .prompt, "x")])
            XCTFail("expected throw")
        } catch let OpenAIError.httpStatus(code, body) {
            XCTAssertEqual(code, 429)
            XCTAssertTrue(body.contains("rate limited"))
        }
    }

    // MARK: ContextWindow integration (window IS the ToolExecutor) — offline

    func testEndToEndThroughContextWindowOffline() async throws {
        let store = try SQLiteContextStore.inMemory()
        let firstResponse = """
        {"choices":[{"message":{"role":"assistant","content":null,
          "tool_calls":[{"id":"c1","type":"function",
            "function":{"name":"echo","arguments":"{\\"v\\":\\"hi\\"}"}}]}}],
         "usage":{"total_tokens":4}}
        """
        let secondResponse = """
        {"choices":[{"message":{"role":"assistant","content":"done"}}],
         "usage":{"total_tokens":6}}
        """
        let stub = StubTransport(responses: [
            .init(status: 200, json: firstResponse),
            .init(status: 200, json: secondResponse),
        ])

        // Late-bind the window into the model's executor: one window both
        // drives the tool loop and persists every record.
        let executorRef = LateBoundToolExecutor()
        let model = try OpenAIChatModel(
            model: "gpt-4.1-mini",
            apiKey: "k",
            toolExecutor: executorRef,
            transport: stub
        )
        let cw = try ContextWindow(
            store: store, contextName: "c", model: model
        )
        executorRef.bind(cw)
        try await cw.registerTool(
            schema: JSONSchemaToolDefinition(
                name: "echo",
                parameters: .object(["type": .string("object")])
            ),
            runner: ClosureToolRunner { data in
                String(decoding: data, as: UTF8.self)
            }
        )

        try await cw.addPrompt("call echo")
        let reply = try await cw.callModel()
        XCTAssertEqual(reply, "done")

        // The window persisted toolCall + toolOutput + modelResponse.
        let all = try await cw.allRecords()
        let sources = all.map(\.source)
        XCTAssertTrue(sources.contains(.toolCall))
        XCTAssertTrue(sources.contains(.toolOutput))
        XCTAssertEqual(all.last?.source, .modelResponse)
        XCTAssertEqual(all.last?.content, "done")

        let total = await cw.metrics.totalModelTokens
        XCTAssertEqual(total, 10)
    }
}
