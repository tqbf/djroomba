# Phase 3 — Provider adapters, package polish, compatibility harness

Full spec: see [swift-port-plan.md](swift-port-plan.md) §"Phase 3".
Builds on Phases 1–2 (do not regress earlier tests).

## Checklist

- [x] `ContextWindowOpenAI` target: `OpenAIChatModel` (first), `OpenAIResponsesModel` (second)
- [x] Chat record-type mapping per spec; tool-call loop (append calls → execute → append outputs → repeat); persist call + output records
- [x] Responses adapter: newline-flatten initial input; function-call output items + `previous_response_id` for continuation
- [x] `ContextWindowCLI` example target matching MVP usage snippet
- [x] Compatibility harness: Swift writes DB → re-opens & verifies; golden JSON exports in `Fixtures/go-parity/` stable mod timestamps/UUIDs; schema-shape assertions lock durable format
- [x] Docs: README quick start, porting notes, provider adapter contract, tool definition format, compaction lifecycle
- [x] All tests green incl. Phases 1–2 (61 tests, 3 skipped, 0 failures; P1+P2 still 45)
- [x] `PROGRESS.md` updated

## OpenAI cost discipline (hard requirement)

- All adapter logic tested with stub HTTP / FakeModel — **zero** network by default.
- Live tests gated behind `CONTEXTWINDOW_LIVE_OPENAI=1`, skipped otherwise.
- At most 2 real OpenAI round trips total (1 Chat completion; optionally 1
  Chat tool-call loop). The orchestrator runs these once; do not loop/retry.
- Use a cheap model (e.g. `gpt-4.1-mini`) and tiny prompts.

## Notes / decisions

- **HTTP injection.** Adapters depend on `OpenAITransport`
  (`send(OpenAIHTTPRequest) -> (Data, HTTPURLResponse)`). Production impl
  `URLSessionOpenAITransport` is the *only* network-capable type and the suite
  never constructs one. Tests inject `StubTransport` (canned JSON, captures
  request bodies). Default `swift test` = zero network, confirmed.
- **Chat adapter.** `Model` conformance. Record→message mapping exactly per
  spec; `.toolCall` record content `name(args)` parsed back into a synthetic
  `tool_calls` entry for coherent replay. Tool loop: emit `.toolCall` event →
  `executor.executeTool` → emit `.toolOutput` event → append to wire → re-issue
  → terminate on plain assistant msg → emit `.modelResponse`. All call/output
  events + final message returned in `ModelResult.events` (window persists
  them); `tokensUsed` summed across round trips; `maxToolRoundTrips` cap.
- **Responses adapter.** Initial `input` = live records newline-flattened with
  `role:` tags. Continuation sends only `function_call_output` items +
  `previous_response_id` from the prior response (server carries history).
  `input` is a polymorphic enum (string | items).
- **`LateBoundToolExecutor`.** New small `Sendable` box resolving the
  model↔window construction cycle (`ContextWindow` *is* the `ToolExecutor` but
  each needs the other at init). Build model with the ref, build window with
  the model, `ref.bind(cw)`. Replaced an awkward placeholder-window pattern.
- **CLI.** `Sources/ContextWindowCLI/main.swift`, product/target
  `contextwindow`. Mirrors the MVP snippet (SQLite store + `OpenAIChatModel` +
  `ContextWindow`; system prompt, prompt, callModel, print reply + token use).
  Flags `--db/--model/--context/--system`. Default model `gpt-4.1-mini`.
- **Compatibility harness (adapted, no Go binary).** Three parts:
  (1) round-trip — write SQLite, re-open fresh store, assert decoded ==
  persisted-read baseline (compares persisted-read vs reopen-read, not the
  pre-persist in-memory `Date()`, because SQLite `DATETIME` is second-grained;
  the durable guarantee is reader-consistency); (2) schema-shape — exact
  tables/indexes/columns/index-columns asserted via raw SQL (separate file so
  GRDB's `Record` doesn't clash with the domain `Record`); (3) golden —
  normalized JSON (UUID→zero, ts→epoch, id→position) == committed
  `Fixtures/go-parity/context-export.json`. Fixture committed in both the test
  bundle (`Bundle.module`) and repo-root `Fixtures/`; regen via
  `CONTEXTWINDOW_REGEN_FIXTURES=1`.
- **Live tests gated.** `LiveOpenAITests`: a gate test asserts default = no
  network; two round-trip tests `XCTSkipUnless(CONTEXTWINDOW_LIVE_OPENAI==1)`
  (skip *before* any model/transport is built). Tool-loop one additionally
  opt-in via `CONTEXTWINDOW_LIVE_OPENAI_TOOLS=1`. ≤2 real round trips total,
  `gpt-4.1-mini`, tiny prompts.
- **Skills N/A.** Phase 3 is library + CLI with no SwiftUI/UI; `swiftui-pro`,
  `typography-designer`, `macos-design` intentionally skipped (documented in
  `docs/porting-notes.md`). No GUI invented.
- **No new SPM deps** (only GRDB, as required). No tiktoken added; whitespace
  counter retained.
