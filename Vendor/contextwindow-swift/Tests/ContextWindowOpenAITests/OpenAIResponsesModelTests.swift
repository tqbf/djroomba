import XCTest
import ContextWindow
@testable import ContextWindowOpenAI

/// All offline: every test injects ``StubTransport``. No network occurs.
final class OpenAIResponsesModelTests: XCTestCase {

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
            contextID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
    }

    // MARK: Initial request flattens records to newline-delimited input

    func testInitialInputIsNewlineFlattened() async throws {
        let stub = StubTransport(json: """
        {"id":"resp_1","output":[
          {"type":"message","role":"assistant",
           "content":[{"type":"output_text","text":"flat reply"}]}],
         "usage":{"total_tokens":9}}
        """)
        let model = try OpenAIResponsesModel(
            model: "gpt-4.1-mini", apiKey: "k", transport: stub
        )

        let records = [
            record(1, .systemPrompt, "be terse", 0),
            record(2, .prompt, "hello", 1),
            record(3, .modelResponse, "prior", 2),
        ]
        let result = try await model.call(records)

        XCTAssertEqual(result.events.map(\.source), [.modelResponse])
        XCTAssertEqual(result.events.first?.content, "flat reply")
        XCTAssertEqual(result.tokensUsed, 9)
        XCTAssertEqual(stub.sendCount, 1)

        let body = stub.bodyJSON(0)
        XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini")
        let input = body["input"] as? String
        XCTAssertEqual(input, "system: be terse\nuser: hello\nassistant: prior")
        XCTAssertNil(body["previous_response_id"])
        XCTAssertTrue(
            stub.capturedRequests[0].url.absoluteString.hasSuffix("/responses")
        )
    }

    // MARK: Tool-call continuation: function_call_output + previous_response_id

    func testToolCallContinuationUsesFunctionCallOutputAndPreviousResponseID() async throws {
        let first = """
        {"id":"resp_A","output":[
          {"type":"function_call","name":"lookup","call_id":"fc_1",
           "arguments":"{\\"id\\":7}"}],
         "usage":{"total_tokens":5}}
        """
        let second = """
        {"id":"resp_B","output":[
          {"type":"message","role":"assistant",
           "content":[{"type":"output_text","text":"the answer is X"}]}],
         "usage":{"total_tokens":8}}
        """
        let stub = StubTransport(responses: [
            .init(status: 200, json: first),
            .init(status: 200, json: second),
        ])
        let executor = FakeToolExecutor(outputs: ["lookup": "X"])
        let model = try OpenAIResponsesModel(
            model: "gpt-4.1-mini",
            apiKey: "k",
            toolExecutor: executor,
            transport: stub
        )

        let result = try await model.call([record(1, .prompt, "look up 7")])

        XCTAssertEqual(stub.sendCount, 2)
        XCTAssertEqual(executor.executedCalls.count, 1)
        XCTAssertEqual(executor.executedCalls[0].name, "lookup")
        XCTAssertEqual(executor.executedCalls[0].args, #"{"id":7}"#)

        XCTAssertEqual(
            result.events.map(\.source),
            [.toolCall, .toolOutput, .modelResponse]
        )
        XCTAssertEqual(result.events[0].content, #"lookup({"id":7})"#)
        XCTAssertEqual(result.events[1].content, "X")
        XCTAssertEqual(result.events[2].content, "the answer is X")
        XCTAssertEqual(result.tokensUsed, 13)

        // First request: flat string input, no previous_response_id.
        let firstBody = stub.bodyJSON(0)
        XCTAssertEqual(firstBody["input"] as? String, "user: look up 7")
        XCTAssertNil(firstBody["previous_response_id"])

        // Continuation: input is an array of function_call_output items and it
        // carries previous_response_id from the first response.
        let secondBody = stub.bodyJSON(1)
        XCTAssertEqual(secondBody["previous_response_id"] as? String, "resp_A")
        let items = secondBody["input"] as! [[String: Any]]
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["type"] as? String, "function_call_output")
        XCTAssertEqual(items[0]["call_id"] as? String, "fc_1")
        XCTAssertEqual(items[0]["output"] as? String, "X")
    }

    // MARK: Missing key

    func testMissingAPIKeyThrows() {
        XCTAssertThrowsError(
            try OpenAIResponsesModel(model: "gpt-4.1-mini", apiKey: "", transport: StubTransport(json: "{}"))
        ) { error in
            XCTAssertEqual(error as? OpenAIError, .missingAPIKey)
        }
    }
}
