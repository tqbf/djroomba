# PROGRESS.md

State tracker for the ContextWindow Swift port. Read with `PLAN.md`.

## Status

| Phase | State | Notes |
|---|---|---|
| Setup | ✅ done | plans/ docs + PLAN.md + PROGRESS.md scaffolded |
| Phase 1 — Domain + SQLite | ✅ done | Package + domain model + GRDB 7.10.0 store + ContextWindow actor; 28 tests green, zero network |
| Phase 2 — Model loop | ✅ done | Model boundary + call loop + summarization + tools + middleware; 45 tests green (28 P1 + 17 P2), zero network, FakeModel only |
| Phase 3 — Providers + harness | ✅ done | OpenAI Chat+Responses adapters (injected HTTP), CLI, adapted compat harness + golden fixture, docs; 61 tests green (45 P1+P2 + 16 P3), 3 skipped (2 gated live + 1 fixture-regen), zero network |
| Live OpenAI check | ✅ verified | Orchestrator ran `CONTEXTWINDOW_LIVE_OPENAI=1 swift test --filter LiveOpenAITests` once on 2026-05-16: `testLiveChatCompletionSingleRoundTrip` PASSED (1 real Chat round trip, ~2s); tool-loop + gate tests skipped. Chat adapter confirmed working against the real API. Tool-loop opt-in (`CONTEXTWINDOW_LIVE_OPENAI_TOOLS=1`) intentionally NOT run to cap cost at 1 call. |
| Phase 4 — Package for SPM reuse | ✅ done | tools 6.0 kept; MIT license; initial local commit + tag 0.1.0 (NOT pushed, no remote); CLI relocated to Examples/BasicClient (standalone); `.envrc` git-ignored & absent from git; 61 tests green / 3 skipped, zero network; external `.package(path:)` consumer verified |

## Environment

- Swift 6.3.1, Xcode 26.4.1, macOS (arm64). Swift 6 strict concurrency on
  (`swiftLanguageMode(.v6)` on both targets; `tools-version: 6.0`).
- Persistence: GRDB 7.10.0 (`from: "7.10.0"`, resolved & verified).
  `ContextWindow` is an `actor`; `Metrics` is an `actor`; store is `Sendable`.
- No Go source exists; plan docs are the spec. Phase 3 Go-parity harness
  adapted to schema-compat + Swift golden fixtures (see master plan deviations).
- OpenAI key in `.envrc` (`OPENAI_API_KEY`). Live tests gated by
  `CONTEXTWINDOW_LIVE_OPENAI=1`, ≤2 real round trips total. (No model/network
  code exists yet — Phase 2.)

## Phase 1 — what shipped

- `Package.swift`: package `ContextWindow`, library target `ContextWindow`
  (GRDB dep), test target `ContextWindowTests`. No CLI/OpenAI targets yet.
- `Sources/ContextWindow/Record.swift`: `RecordType`, `Record`, `Context`,
  `ContextTool`, `ContextExport`, `TokenUsage`, `ContextWindowError`.
- `Sources/ContextWindow/TokenCounter.swift`: `TokenCounting` protocol +
  `WhitespaceTokenCounter` (default; tiktoken/cl100k deferred to Phase 3).
- `Sources/ContextWindow/Metrics.swift`: `Metrics` actor (model-token
  accumulator; unused in P1, wired in P2 call loop).
- `Sources/ContextWindow/ContextStore.swift`: `ContextStore` protocol +
  `SQLiteContextStore` (GRDB). Schema = exactly `contexts`, `records`,
  `context_tools` with `idx_records_live`, `idx_records_timestamp`,
  `idx_contexts_name` (unique). `.inMemory()` factory for tests.
- `Sources/ContextWindow/ContextWindow.swift`: `ContextWindow` actor —
  named/unnamed init, system-prompt deadening, current-context resolution,
  delete-context fallback, export, token usage.
- `Tests/ContextWindowTests/`: 28 XCTest cases, in-memory + temp-file SQLite,
  zero network. Covers every Phase 1 acceptance test.

`swift build` clean (no warnings). `swift test`: 28 tests, 0 failures.

## Phase 2 — what shipped

- `Sources/ContextWindow/Models.swift`: `Model` protocol (`call([Record])
  async throws -> ModelResult`), `ModelResult` (`events`, `tokensUsed`),
  `RecordEvent` (`source`, `content`, `live`; defaults `live: true`),
  `ModelError` (`noModelConfigured`, `noSummarizerConfigured`,
  `toolNotRegistered`, `emptyModelResult`).
- `Sources/ContextWindow/Summarizer.swift`: `Summarizer: Model`,
  `SummaryResult` (`summary`, `replaced`, `originalTokenCount`,
  `summaryTokenCount`), `SummarizerPrompt.default`.
- `Sources/ContextWindow/Tools.swift`: `JSONValue` (Codable+Sendable
  recursive enum: object/array/string/number/bool/null),
  `JSONSchemaToolDefinition`, `ToolRunner` (+ `ClosureToolRunner`),
  `ToolDefinition` (schema + runner), `ToolExecutor`, `MiddlewareEvent`,
  `Middleware` (+ `ClosureMiddleware`).
- `ContextStore` extended with `replaceRecords(deadenIDs:contextID:source:
  content:live:)` — one `DatabaseQueue.write` (single transaction):
  deaden-by-id then insert, all-or-nothing.
- `ContextWindow` actor: optional `model`/`summarizer`/`middleware` ctor
  params + in-memory `tools` map. Added `addToolCall(name:args:)`,
  `addToolOutput(_:)`, `callModel()`, `summarizeLiveContext(prompt:)`,
  `acceptSummary(_:)`, `rejectSummary(_:)`, `registerTool(...)`,
  `registeredTools()`, `executeTool(name:args:)`. Conforms to
  `ToolExecutor` (actor isolation satisfies Sendable + async). P1
  `registerToolHint` kept for raw-hint callers.
- Call loop order (exact): resolve ctx id → `listLiveRecords` → `model.call`
  → `metrics.addModelTokens` → insert every event (source/content/live
  preserved) → return last event content. Does NOT auto-summarize. Empty
  event list → `ModelError.emptyModelResult`.
- `Tests/ContextWindowTests/FakeModel.swift`: network-free
  `Model`+`Summarizer` double; captures every `[Record]` it's called with
  (NSLock.withLock box; lock/unlock are async-unavailable in Swift 6).
- `Tests/ContextWindowTests/Phase2Tests.swift`: 17 cases covering every
  Phase 2 acceptance test (live-set exactness + order, multi-event persist,
  last-content return, no-model/no-summarizer/empty errors, prompt prepend,
  accept transactional + atomicity rollback, reject no-op, tool
  register/list/execute/persist, middleware call+result, JSONValue
  round-trip, addToolCall/Output).

`swift build` clean (no warnings). `swift test`: 45 tests (28 P1 + 17 P2),
0 failures, zero network.

## Phase 3 — what shipped

- `Package.swift`: added library target/product `ContextWindowOpenAI` (deps
  `ContextWindow`), executable target `ContextWindowCLI` (product
  `contextwindow`), test target `ContextWindowOpenAITests` (copies
  `Tests/.../Fixtures` as a bundle resource). Existing targets/tests intact.
- `Sources/ContextWindowOpenAI/OpenAITransport.swift`: `OpenAITransport`
  `Sendable` protocol + `OpenAIHTTPRequest`; `URLSessionOpenAITransport`
  (the *only* network-capable type); `OpenAIError` (missingAPIKey,
  nonHTTPResponse, httpStatus, decoding, emptyResponse,
  toolLoopLimitExceeded).
- `Sources/ContextWindowOpenAI/OpenAIChatModel.swift`: `Model` conformance,
  `POST /v1/chat/completions`. Record→message mapping per spec; full tool-call
  loop driving the injected `ToolExecutor`; returns all `.toolCall` +
  `.toolOutput` + final `.modelResponse` events; tokens summed across round
  trips; `maxToolRoundTrips` cap. Key from `OPENAI_API_KEY`, never logged.
- `Sources/ContextWindowOpenAI/OpenAIResponsesModel.swift`: `Model`
  conformance, `POST /v1/responses`. Initial `input` = live records flattened
  newline-delimited (role-tagged); tool continuation = `function_call_output`
  items + `previous_response_id`. Polymorphic `input` enum.
- `Sources/ContextWindowOpenAI/LateBoundToolExecutor.swift`: `Sendable`
  `ToolExecutor` box resolving the model↔window init cycle (`bind(_:)` after
  construction).
- `Sources/ContextWindowCLI/main.swift`: example CLI (product
  `contextwindow`) mirroring the MVP usage snippet; flags
  `--db/--model/--context/--system`, default model `gpt-4.1-mini`. May make
  real calls when a human runs it; never exercised by the suite.
- `Tests/ContextWindowOpenAITests/`: `StubTransport` (offline canned JSON +
  request capture), `FakeToolExecutor`; `OpenAIChatModelTests` (6 — request
  shape, mapping, tool serialization, response→events, full 2-RT tool loop
  offline, HTTP error, end-to-end through `ContextWindow`),
  `OpenAIResponsesModelTests` (3 — newline flatten, function-call
  continuation + `previous_response_id`, missing key), `SchemaShapeTests` (1 —
  tables/indexes/columns locked), `CompatibilityHarnessTests` (3 —
  round-trip, golden vs fixture, gated regen), `LiveOpenAITests` (3 — gate +
  2 gated round trips, skipped by default).
- `Fixtures/go-parity/context-export.json` committed (also mirrored in the
  test bundle for `Bundle.module`).
- Docs: `README.md` (quick start), `docs/porting-notes.md`,
  `docs/provider-adapter-contract.md`, `docs/tool-definition-format.md`,
  `docs/compaction-lifecycle.md`. Linked from PLAN.md's doc map.

`swift build` clean (no warnings). `swift test`: 61 tests (28 P1 + 17 P2 +
16 P3), 0 failures, 3 skipped (2 gated live + 1 fixture-regen helper), zero
network — every adapter test injects `StubTransport`; live tests skip before
constructing any model/transport.

### How the orchestrator runs the live OpenAI check

The repo `.envrc` exports `OPENAI_API_KEY` (do not print it). To run the
gated live check (orchestrator only, once — do not loop/retry):

```sh
CONTEXTWINDOW_LIVE_OPENAI=1 swift test --filter LiveOpenAITests
```

That targets `LiveOpenAITests`:
- `testLiveGateSkipsByDefault` — no-ops when live mode is on (carries no call).
- `testLiveChatCompletionSingleRoundTrip` — **1 real round trip** (one Chat
  completion, `gpt-4.1-mini`, tiny prompt).
- `testLiveChatToolCallLoopOptional` — skipped unless *also*
  `CONTEXTWINDOW_LIVE_OPENAI_TOOLS=1`; if enabled, **1 tool-call loop = up to
  2 HTTP calls**.

Default (Chat only) = **1 real round trip**. With the optional tools flag the
total is **≤2 round trips** as specified. Without `CONTEXTWINDOW_LIVE_OPENAI`
all three skip and zero network occurs.

## Phase 4 — what shipped

- `Package.swift`: `swift-tools-version: 6.0` kept; platforms bumped to
  `[.macOS(.v14), .iOS(.v17)]`; products = exactly the two libraries
  `ContextWindow` + `ContextWindowOpenAI`; **executable product/target
  removed**; GRDB the only dependency; both library targets keep
  `.swiftLanguageMode(.v6)`; both test targets unchanged
  (`ContextWindowOpenAITests` keeps its `Fixtures` copy resource).
- `Sources/ContextWindowCLI/` deleted from the main package. New
  `Examples/BasicClient/` is a **standalone** SwiftPM package
  (`swift-tools-version: 6.0`, macOS 14 / iOS 17) depending on the library
  via `.package(path: "../..")`. It imports `ContextWindow` +
  `ContextWindowOpenAI` and runs **fully offline by default** (in-memory
  store, open context, set system prompt, add prompt, print live records +
  token usage); real `OpenAIChatModel` wiring is present but guarded behind
  `CONTEXTWINDOW_EXAMPLE_LIVE=1` (unset by default → never executed). Source
  file `BasicClient.swift` (not `main.swift`) so `@main` is legal. Builds &
  runs standalone. The root package never builds `Examples/` (explicit
  targets in `Sources/`; verified via `swift package describe`).
- Public API audit: core `ContextWindow` has **zero** import/symbol
  dependency on `ContextWindowOpenAI` (grep-verified); no global mutable
  state; no hardcoded keys/paths/bundle-IDs/app-names. OpenAI endpoint was
  already injectable (`baseURL:` default `https://api.openai.com/v1` on both
  adapters + injectable `OpenAITransport`) — requirement already satisfied,
  no code change required.
- `LICENSE` added: MIT, `Copyright (c) 2026 Thomas <thomas@sockpuppet.org>`.
- `README.md` rewritten per step 5: what it does; supported-platforms table;
  SPM install with `<owner>/<repo>` placeholder URL + `.package(path:)` local
  note; minimal **offline** usage example + OpenAI example; configuration
  (API key via env, injectable transport, `baseURL` override); GRDB note;
  explicit application-independent statement; updated package layout; doc
  index + LICENSE preserved/linked.
- `.gitignore` created **before any `git add`**: `.envrc`, `.build/`,
  `.swiftpm/`, `Package.resolved`, `Examples/*/.build/`,
  `Examples/*/.swiftpm/`, `.DS_Store`, `*.xcuserstate`, Xcode cruft.
- `swift package clean && swift build && swift test` (no env var): clean
  build (no warnings), **61 tests, 3 skipped, 0 failures, zero network**
  (target platform `arm64e-apple-macos14.0`). Live OpenAI tests not run.
- External validation: a throwaway `/tmp/cw-consume-check` package consumed
  the library via `.package(path: "/Users/agentzero/codebase/contextwindow")`,
  `import ContextWindow`; its executable built & ran offline
  (`OK live=2 tokens=7`) and a test target built & passed (1 test, 0
  failures). Scratch package deleted afterward.

## Decisions log

- 2026-05-16: Set up scaffold. Confirmed no Go source anywhere; building from
  plan spec. Chose GRDB per plan recommendation.
- 2026-05-16: Phase 1 complete. GRDB pinned to 7.10.0 (latest 7.x, resolves
  on Swift 6.3). Decisions:
  - Schema-compat tables/indexes named & shaped per master plan; `id`
    autoincrement on `records`, `context_id` FK with `ON DELETE CASCADE`
    (plus explicit deletes so behavior is pragma-independent).
  - `WhitespaceTokenCounter` is the default & only counter in P1
    (`split(whereSeparator: isWhitespace)`); tiktoken/cl100k deferred to P3
    per the phase doc's allowance.
  - Unnamed contexts named `context-<lowercased-uuid>` so they remain unique
    and addressable; the unique index on `contexts.name` enforces uniqueness
    and is mapped to `ContextWindowError.contextNameAlreadyExists`.
  - Named init *adopts* an existing same-name context rather than erroring
    (the MVP usage target in the master plan constructs by name repeatedly);
    explicit `createContext(name:)` still surfaces the uniqueness error.
  - `setSystemPrompt` deadens via `UPDATE records SET live=0 WHERE
    context_id=? AND source=?` then inserts the new live systemPrompt.
  - `deleteContext` of the current context switches to the earliest
    remaining context, else creates a fresh generated default.
  - `ContextStore` ops are sync `throws` (per the plan's protocol); actor
    methods wrap them, so callers `await`. GRDB `DatabaseQueue` serializes.
  - `Metrics` made an `actor` (not just Sendable) so P2's call loop can
    accumulate tokens across the actor boundary safely.
- 2026-05-16: Phase 2 complete. Decisions:
  - `Model.call` takes `[Record]` (the live set) and returns typed
    `ModelResult`; no provider `Any` in core. `RecordEvent.live` defaults
    `true` but is preserved verbatim by the call loop (a model may emit dead
    events).
  - `callModel()` follows the exact 6-step order; throws
    `emptyModelResult` if the model returns no events (so step 6 always has
    a "last content"). Does not auto-summarize (Go parity).
  - Atomic accept = new store method `replaceRecords`. `DatabaseQueue.write`
    is itself one transaction in GRDB, so deaden-then-insert in one `write`
    block is all-or-nothing; verified by an FK-violation rollback test
    (GRDB enables `foreign_keys` by default). Kept store ops sync `throws`;
    actor wraps. `acceptSummary` inserts the summary as a live
    `.modelResponse`.
  - `summarizeLiveContext` prepends a synthetic, non-persisted
    `.systemPrompt` record (id 0) carrying `SummarizerPrompt.default` ahead
    of the live records, calls the summarizer, takes the LAST event as the
    summary. `summaryTokenCount` = summarizer's reported `tokensUsed`;
    `originalTokenCount` = sum of replaced `estimatedTokens`. Summarizer
    tokens are also added to `metrics` (it is a model call).
  - Tools: in-memory `[String: ToolDefinition]` map keyed by name (last
    wins, mirrors the `context_tools` upsert). `registerTool` persists the
    JSON-encoded `JSONSchemaToolDefinition` (sortedKeys) as the
    `context_tools` hint via P1 `upsertContextTool`. `ContextWindow`
    conforms to `ToolExecutor` via empty extension — actor isolation
    satisfies the `Sendable` + `async` requirements.
  - Middleware is an optional `Sendable` protocol with non-throwing async
    `onToolCall`/`onToolResult`; `executeTool` fires call → run → result so
    observation never breaks the loop. `MiddlewareEvent` enum + closure
    adapters provided for ergonomic tests.
  - P1 `registerToolHint(name:definition:)` retained for raw-hint callers
    that have no runner; the P1 `testExportReturnsContextRecordsAndTools`
    still uses it (unchanged, still green).
  - Test double `FakeModel` uses an `NSLock`-via-`withLock` box: Swift 6
    makes `NSLock.lock()/unlock()` unavailable in async contexts.
- 2026-05-16: Phase 3 complete. Decisions:
  - HTTP injected behind `OpenAITransport` (`Sendable`) — the cost-discipline
    seam. `URLSessionOpenAITransport` is the only network-capable type and the
    suite never builds one; every adapter test injects `StubTransport`. `swift
    test` (no env var) = zero network, confirmed.
  - Chat adapter ported first, then Responses, per the master plan order.
    Record→message mapping exactly per spec. `.toolCall` records (content
    `name(args)`) are parsed back into synthetic `tool_calls` for coherent
    replay. Tool loop returns *all* call + output + final-message events so
    `ContextWindow.callModel()` persists the whole exchange; `tokensUsed`
    summed across round trips; `maxToolRoundTrips` (default 8) caps runaway
    loops with `OpenAIError.toolLoopLimitExceeded`.
  - Responses adapter: initial `input` is the live set newline-flattened with
    `role:` tags; tool continuation sends only `function_call_output` items +
    `previous_response_id` (server carries history). `input` modeled as a
    polymorphic `Encodable` enum (string | items).
  - Added `LateBoundToolExecutor` (small `Sendable` box) to resolve the
    model↔window construction cycle cleanly — build model with the ref, build
    window with the model, `ref.bind(cw)`. Replaced an awkward
    double-window/placeholder-transport workaround in two tests.
  - Compat harness round-trip compares *persisted-read vs reopen-read*, not
    the pre-persist in-memory `insertRecord` return: SQLite `DATETIME` stores
    second granularity and drops the sub-second precision of an in-memory
    `Date()`, so the in-memory value never equals the stored one. The durable
    guarantee that matters is reader-consistency (every open yields identical
    bytes — Swift now, Go later), which this comparison proves.
  - Schema-shape assertions live in a *separate* file (`SchemaShapeTests`)
    because importing GRDB brings `GRDB.Record`, which clashes with the domain
    `Record`; that file uses raw SQL only and never names the domain types.
  - Golden fixture is normalized (UUID→all-zero, timestamp→epoch,
    `records.id`→1-based position) so it's byte-stable; committed at repo-root
    `Fixtures/go-parity/` and mirrored into the test bundle for
    `Bundle.module`. Regenerate with `CONTEXTWINDOW_REGEN_FIXTURES=1 swift
    test --filter testRegenerateGoldenFixture` (skipped otherwise).
  - Live tests skip *before* constructing any model/transport
    (`XCTSkipUnless` first), so even importing them is network-free. ≤2 real
    round trips total when enabled; cheap model, tiny prompts; never looped.
  - CLAUDE.md's `swiftui-pro`/`typography-designer`/`macos-design` skills are
    N/A — Phase 3 is a library + headless CLI with no UI. Intentionally
    skipped and documented in `docs/porting-notes.md`. No GUI invented.
  - No new SPM dependency (GRDB only). No tiktoken added; `WhitespaceTokenCounter`
    remains the default per the phase doc's allowance.
- 2026-05-16: **Phase 4 complete — packaged for SPM reuse.** Decisions:
  - Kept `swift-tools-version: 6.0` + `.swiftLanguageMode(.v6)` on both
    library targets (locked; template 5.10 rejected — would weaken the
    verified Swift 6 actor/Sendable design). Platforms bumped
    `[.macOS(.v13)]` → `[.macOS(.v14), .iOS(.v17)]`; iOS feasible (GRDB +
    `URLSession` build for it; transport is injectable & platform-neutral),
    so no platform scoping needed.
  - Removed the `contextwindow` executable product + `ContextWindowCLI`
    target; relocated the CLI to `Examples/BasicClient/` as a standalone
    `.package(path: "../..")` consumer that defaults to a fully offline demo
    (real OpenAI wiring guarded behind an unset env var, never executed). The
    root package's targets are explicit & in `Sources/`, so `swift
    build`/`swift test` never builds `Examples/` (confirmed via `swift
    package describe`).
  - API audit: core has zero `ContextWindowOpenAI` coupling; no global
    mutable state; no hardcoded secrets/paths/IDs. The OpenAI base URL was
    *already* injectable (`baseURL:` default + injectable transport) — the
    requirement was pre-satisfied, no code change made.
  - MIT `LICENSE` (© 2026 Thomas <thomas@sockpuppet.org>); README rewritten
    per step 5 (offline-first example, platform table, placeholder remote URL
    + local-path note, config/transport/`baseURL` section, GRDB note,
    application-independent statement).
  - Credential safety: `.gitignore` created **before** any `git add`
    (covers `.envrc`, `.build/`, `.swiftpm/`, `Package.resolved`,
    `Examples/*/.build/`, `.DS_Store`, `*.xcuserstate`). Verified `.envrc`
    is **NOT** in `git ls-files` and **NOT** in `git diff --cached`; a cached
    `git grep 'sk-[A-Za-z0-9]'` + `git diff --cached | grep 'sk-'` found
    **no** API-key-shaped string in any staged file; no `OPENAI_API_KEY=`
    staged. The key value was never echoed/logged.
  - The single initial commit is the one annotated tag **`0.1.0`** points
    at (`git rev-parse 0.1.0^{commit}` is the authoritative hash; the agent
    report records the exact 40-char value). The tag was created **locally
    only — NOT pushed** (no remote exists; `git remote -v` empty). A commit
    cannot embed its own final hash (each amend re-hashes), so the durable
    record of the hash is the git tag itself, not a string duplicated inside
    the commit it names. `.envrc` confirmed git-ignored and absent from
    `git ls-files` at commit time.
  - External consumability proven from a throwaway `/tmp/cw-consume-check`
    package using `.package(path:)`: executable built & ran offline
    (`OK live=2 tokens=7`), test target built & passed (1/0). Deleted after.
  - CLAUDE.md skills `swiftui-pro`/`typography-designer`/`macos-design`:
    N/A and skipped — headless library + non-UI example, no SwiftUI/UI, no
    GUI invented (consistent with the Phase 3 decision).

## Next step

**All planned phases (1–4) are complete.** Library is packaged for SPM reuse:
two library products (`ContextWindow`, `ContextWindowOpenAI`), MIT-licensed,
tools-version 6.0, initial local commit + tag `0.1.0` (never pushed; no
remote). 61 tests green / 3 skipped, zero network by default; provider
independence of the core preserved. If a remote is later added, `git push
--tags` would publish `0.1.0` and consumers can switch the README's
placeholder `.package(url:)` to the real URL. No further phase is queued.
