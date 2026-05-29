# Phase 2 — Model abstraction, call loop, summarization, tools

Full spec: see [swift-port-plan.md](swift-port-plan.md) §"Phase 2".
Builds on Phase 1 (do not regress Phase 1 tests).

## Checklist

- [x] `Model` protocol, `ModelResult`, `RecordEvent`
- [x] `ContextWindow` surface: addPrompt / addToolCall / addToolOutput / setSystemPrompt / liveRecords / callModel / tokenUsage
- [x] Call loop exact order: resolve ctx → load live → call model → add tokens → insert events → return last content
- [x] `Summarizer` protocol, `SummaryResult`
- [x] `summarizeLiveContext` / `acceptSummary` (transactional deaden+insert) / `rejectSummary`
- [x] `JSONValue` Codable+Sendable; `JSONSchemaToolDefinition`; `ToolRunner`; `ToolExecutor`; `ToolDefinition`
- [x] Tool register/list/execute + `context_tools` hint persistence
- [x] Middleware hooks for tool-call and tool-result callbacks
- [x] `FakeModel` test double (no network)
- [x] All Phase 2 tests green; Phase 1 tests still green (45 total: 28 P1 + 17 P2)
- [x] `PROGRESS.md` updated

## Acceptance tests (all FakeModel — zero network)

- FakeModel sees only live records
- FakeModel emits multiple events; all persisted
- callModel returns last emitted event content
- summarizeLiveContext errors without summarizer
- acceptSummary deadens originals transactionally; rejectSummary no-ops storage
- tools register, list, execute, persist context_tools hint
- middleware receives tool-call and tool-result callbacks

## Notes / decisions

Completed 2026-05-16. Files added: `Sources/ContextWindow/Models.swift`,
`Summarizer.swift`, `Tools.swift`; `ContextStore.swift` +
`ContextWindow.swift` extended; tests
`Tests/ContextWindowTests/FakeModel.swift` + `Phase2Tests.swift`.

Key implementation decisions:

- **Model boundary is neutral.** `Model.call([Record]) async throws ->
  ModelResult`. No provider `Any` anywhere in core. `RecordEvent.live`
  defaults `true` but the call loop preserves whatever the model emits.
- **Call loop is the exact spec order.** Resolve ctx id → `listLiveRecords`
  → `model.call(live)` → `metrics.addModelTokens(tokensUsed)` → insert
  every event (source/content/live verbatim) → return last event content.
  Empty event list → `ModelError.emptyModelResult`. No auto-summarize.
- **`acceptSummary` is one DB transaction** via new store method
  `replaceRecords(deadenIDs:contextID:source:content:live:)`. A single
  `DatabaseQueue.write` block = one GRDB transaction → deaden + insert is
  all-or-nothing. Atomicity proven by an FK-violation rollback test
  (`testAcceptSummaryIsAtomic`). `rejectSummary` touches no storage.
- **`summarizeLiveContext`** prepends a synthetic, non-persisted
  `.systemPrompt` record (id 0, `SummarizerPrompt.default`) ahead of live
  records, calls the summarizer, takes the LAST event as the summary.
  `originalTokenCount` = Σ replaced `estimatedTokens`; `summaryTokenCount`
  = summarizer's `tokensUsed` (also added to `metrics`).
- **Tools**: in-memory name→`ToolDefinition` map (last wins, mirrors the
  `context_tools` upsert). `registerTool` persists the JSON-encoded
  `JSONSchemaToolDefinition` (sortedKeys) as the `context_tools` hint via
  the P1 `upsertContextTool`. `ContextWindow: ToolExecutor` via empty
  extension (actor isolation satisfies Sendable + async).
- **Middleware**: optional `Sendable` protocol, non-throwing async
  `onToolCall`/`onToolResult`. `executeTool` fires call → run → result;
  observation cannot break the loop. Closure/event adapters for tests.
- P1 `registerToolHint` retained for raw-hint callers (no runner).
- `FakeModel` uses `NSLock.withLock` (Swift 6 forbids `lock()/unlock()` in
  async contexts) and captures every `[Record]` it is called with.

`swift build` clean; `swift test`: 45 / 0 failures, zero network.
