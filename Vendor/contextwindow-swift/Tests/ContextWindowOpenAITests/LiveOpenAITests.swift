import XCTest
import ContextWindow
@testable import ContextWindowOpenAI

/// Gated live OpenAI integration. **Skipped by default** — these are the only
/// tests in the suite that can touch the network, and they no-op unless
/// `CONTEXTWINDOW_LIVE_OPENAI=1` is set.
///
/// Cost discipline: at most **2 real round trips total** (one Chat completion,
/// one optional Chat tool-call loop = 2 HTTP calls), a cheap model
/// (`gpt-4.1-mini`), and tiny prompts. The orchestrator runs these once, by
/// hand. Never loop or retry.
///
/// Run (orchestrator only — repo `.envrc` exports `OPENAI_API_KEY`):
/// ```
/// CONTEXTWINDOW_LIVE_OPENAI=1 swift test --filter LiveOpenAITests
/// ```
final class LiveOpenAITests: XCTestCase {

    private var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["CONTEXTWINDOW_LIVE_OPENAI"] == "1"
    }

    /// Confirms the gate works: with the env var unset (the default suite),
    /// these tests must no-op. This assertion itself makes no network call.
    func testLiveGateSkipsByDefault() throws {
        try XCTSkipIf(
            liveEnabled,
            "live mode enabled; the gated round-trip tests carry the calls"
        )
        XCTAssertFalse(liveEnabled, "default suite must not touch the network")
    }

    /// ROUND TRIP 1 of ≤2: a single Chat completion against a cheap model.
    func testLiveChatCompletionSingleRoundTrip() async throws {
        try XCTSkipUnless(liveEnabled, "set CONTEXTWINDOW_LIVE_OPENAI=1 to run")

        let model = try OpenAIChatModel(model: "gpt-4.1-mini")
        let store = try SQLiteContextStore.inMemory()
        let cw = try ContextWindow(store: store, contextName: "live", model: model)
        try await cw.setSystemPrompt("Answer in one short word.")
        try await cw.addPrompt("Say hi.")
        let reply = try await cw.callModel()
        XCTAssertFalse(reply.isEmpty)
        let total = await cw.metrics.totalModelTokens
        XCTAssertGreaterThan(total, 0)
    }

    /// ROUND TRIP 2 of ≤2 (optional): one Chat tool-call loop. The model is
    /// asked something that should trigger the single registered tool; the
    /// adapter executes it and the model replies — at most two HTTP calls.
    func testLiveChatToolCallLoopOptional() async throws {
        try XCTSkipUnless(liveEnabled, "set CONTEXTWINDOW_LIVE_OPENAI=1 to run")
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CONTEXTWINDOW_LIVE_OPENAI_TOOLS"] == "1",
            "tool-loop live test is opt-in (set CONTEXTWINDOW_LIVE_OPENAI_TOOLS=1)"
        )

        // Late-bind the window into the model's executor so a single window
        // both drives the loop and persists records (no placeholder dance).
        let store = try SQLiteContextStore.inMemory()
        let executorRef = LateBoundToolExecutor()
        let model = try OpenAIChatModel(
            model: "gpt-4.1-mini",
            toolExecutor: executorRef
        )
        let cw = try ContextWindow(store: store, contextName: "live-tools", model: model)
        executorRef.bind(cw)
        try await cw.registerTool(
            schema: JSONSchemaToolDefinition(
                name: "current_time",
                description: "Returns the current time as a fixed string.",
                parameters: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ])
            ),
            runner: ClosureToolRunner { _ in "12:00 UTC" }
        )
        try await cw.setSystemPrompt("Use the current_time tool, then answer.")
        try await cw.addPrompt("What time is it? Use the tool.")
        let reply = try await cw.callModel()
        XCTAssertFalse(reply.isEmpty)
    }
}
