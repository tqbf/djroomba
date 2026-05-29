# Phase 1 — Domain model + SQLite spine

Full spec: see [swift-port-plan.md](swift-port-plan.md) §"Phase 1".

## Scope

Swift package builds; domain model + GRDB store; no model calls.

## Checklist

- [x] `Package.swift` (Swift 6, `ContextWindow` library target, GRDB dep, test target)
- [x] `RecordType`, `Record`, `Context`, `ContextExport` types
- [x] `ContextStore` protocol + `SQLiteContextStore` (GRDB) impl
- [x] Schema: `contexts`, `records`, `context_tools`; live-record + timestamp indexes
- [x] `TokenCounting` protocol + whitespace impl (tiktoken counter deferred to P3; whitespace fallback works & is default)
- [x] `Metrics` (token usage accounting, actor-safe — implemented as an `actor`)
- [x] `ContextWindow` actor: init (named/unnamed), system prompt deadening, current-context resolution, delete-context fallback
- [x] All Phase 1 acceptance tests green via `swift test` (28 tests, 0 failures)
- [x] `PROGRESS.md` updated

## Acceptance tests

- unnamed ContextWindow generates a UUID-ish context name
- named contexts enforce name uniqueness
- setting a system prompt deadens prior system prompts
- live records return in timestamp order
- deleting current context switches to another or creates default
- export returns context + all records + tools
- token usage = sum(estimatedTokens for live records)

## Notes / decisions

Completed 2026-05-16. `swift build` clean (no warnings); `swift test` = 28
tests, 0 failures, zero network.

**Files delivered** (`Sources/ContextWindow/`): `Record.swift` (types + errors),
`TokenCounter.swift`, `Metrics.swift`, `ContextStore.swift`,
`ContextWindow.swift`. Tests in `Tests/ContextWindowTests/`
(`ContextStoreTests.swift` 14, `ContextWindowTests.swift` 14).

**Dependency:** GRDB pinned `from: "7.10.0"` (latest 7.x; verified it resolves
on Swift 6.3.1). `Package.swift` declares only the `ContextWindow` library +
`ContextWindowTests`; CLI/OpenAI targets intentionally deferred to Phase 3.

**Schema (durable format — preserved exactly):**

- `contexts(id TEXT PK, name TEXT, start_time DATETIME)` +
  unique index `idx_contexts_name(name)`.
- `records(id INTEGER PK AUTOINCREMENT, timestamp, source INTEGER, content
  TEXT, live BOOLEAN, est_tokens INTEGER, context_id TEXT FK→contexts(id) ON
  DELETE CASCADE)` + `idx_records_live(context_id, live)` +
  `idx_records_timestamp(context_id, timestamp)`.
- `context_tools(context_id TEXT FK, tool_name TEXT, definition TEXT,
  PK(context_id, tool_name))`.
- `initialize()` is idempotent (`CREATE … IF NOT EXISTS`).

**Semantic decisions:**

- `insertRecord` computes `est_tokens` via the injected `TokenCounting` impl
  at insert time and stores it; token usage never re-tokenizes history.
- `listLiveRecords` filters `live == true`, orders `timestamp ASC, id ASC`
  (id tiebreak makes ordering deterministic when timestamps collide within a
  millisecond — important since tests insert rapidly).
- Name uniqueness enforced by the unique index; the GRDB constraint error is
  caught and rethrown as `ContextWindowError.contextNameAlreadyExists`.
  `getContext`/`deleteContext`/`exportContext` throw `.contextNotFound`.
- Unnamed `ContextWindow` init → context name `context-<lowercased-uuid>`
  (acceptance test parses the suffix back to a `UUID`).
- Named init **adopts** an existing same-name context if present (the master
  plan's MVP usage repeatedly constructs `ContextWindow(... contextName:)`);
  explicit `createContext(name:)` still surfaces the uniqueness error.
- `setSystemPrompt` deadens all prior `systemPrompt` records for the context
  (`UPDATE … SET live=0 …`) then inserts a new live systemPrompt; non-system
  live records are untouched.
- `deleteContext` of the current context switches to the earliest remaining
  context by `start_time`; if none remain, creates a fresh generated default
  and adopts it. Deleting a non-current context leaves `currentContext` alone.
- `deleteContext` issues explicit child deletes in addition to the FK
  `ON DELETE CASCADE`, so it works regardless of the `foreign_keys` pragma.
- `ContextStore` protocol kept sync `throws` per the master plan signature;
  `ContextWindow`/`Metrics` are `actor`s, so callers `await`. Concurrency
  serialized by GRDB `DatabaseQueue`. Two extra protocol methods added that
  the plan's semantics require but didn't enumerate: `deadenRecords` (system
  prompt deadening) and `upsertContextTool`/`listContextTools` (export needs
  tools, acceptance test "export returns context + records + tools").

**Deviation note:** the master plan's `ContextStore` listed 8 methods; the
described semantics (deadening, tool export) need helpers, so the protocol has
those 3 extra methods. No specified method was changed or removed. tiktoken /
cl100k counter explicitly deferred to Phase 3 per this doc's allowance — the
whitespace counter is the working default.
