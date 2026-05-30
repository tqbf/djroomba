# Porting notes from Go

## No Go source exists

There is **no Go `contextwindow` source in this repo or on this machine**. The
plan documents (`plans/swift-port-plan.md` and the per-phase docs) are the spec
of record. "Port exactly" throughout the plan means "match the *described*
semantics exactly," not "translate Go line by line." Every behavioral guarantee
here was implemented from the prose spec and the acceptance tests.

## Deviations from a literal port

1. **Go-parity harness is adapted.** With no Go binary to round-trip against,
   the durable-format guarantee is preserved three other ways
   (`Tests/ContextWindowOpenAITests/CompatibilityHarnessTests.swift` +
   `SchemaShapeTests.swift`):
   - **Round trip:** Swift writes a SQLite DB, re-opens it with a fresh store,
     and asserts the decoded contexts/records/tools equal a baseline read of
     the persisted data. (We compare *persisted-read vs reopen-read*, not the
     pre-persist in-memory `insertRecord` return: SQLite `DATETIME` stores
     second granularity and drops the sub-second precision of an in-memory
     `Date()`. The guarantee that matters is that every reader — Swift now, Go
     later — sees byte-identical data on every open.)
   - **Schema shape:** exact table names (`contexts`, `records`,
     `context_tools`), index names (`idx_contexts_name`, `idx_records_live`,
     `idx_records_timestamp`), and per-table column name/type/notnull/pk and
     index target columns are asserted, locking the on-disk contract.
   - **Golden export:** a normalized JSON export (UUIDs → all-zero,
     timestamps → epoch, `records.id` → 1-based position) is asserted equal to
     the committed `Fixtures/go-parity/context-export.json`. Regenerate with
     `CONTEXTWINDOW_REGEN_FIXTURES=1 swift test --filter testRegenerateGoldenFixture`.

2. **Provider layer redesigned (opinionated cut).** Core semantics are ported
   faithfully; the provider layer is redesigned around a neutral
   `JSONSchemaToolDefinition` + typed `ModelResult` so no provider `Any`/SDK
   type leaks into core. There is no official OpenAI Swift SDK, so the adapters
   talk HTTP directly via `URLSession` + `Codable`.

3. **HTTP injected behind a `Sendable` protocol.** `OpenAITransport` is the
   cost-discipline seam: the default suite injects a stub returning canned
   JSON, so `swift test` performs **zero** network I/O. The only
   network-capable type is `URLSessionOpenAITransport`, which the suite never
   constructs.

4. **Token counter.** `WhitespaceTokenCounter` (matching the Go
   `strings.Fields` fallback) remains the default. A `cl100k_base`/tiktoken
   counter was deferred — no Swift BPE dependency is added (the plan allows the
   whitespace fallback; adding a tokenizer SPM dep was out of scope and would
   violate the "no new deps beyond GRDB" constraint).

5. **Concurrency.** Swift 6 strict concurrency is on. `ContextWindow` and
   `Metrics` are actors; the window *is* the `ToolExecutor` (actor isolation
   satisfies `Sendable` + `async`). `LateBoundToolExecutor` resolves the
   model↔window construction cycle without a placeholder.

6. **`.envrc` / key handling.** The adapter reads `OPENAI_API_KEY` from the
   environment; it is never hardcoded, never logged, and only ever placed in an
   `Authorization: Bearer` header. The repo `.envrc` exports the key for local
   and gated-live use.

## UI / design skills

`CLAUDE.md` asks for the `swiftui-pro`, `typography-designer`, and
`macos-design` skills before/after deciding on code. Phase 3 is a **library +
example CLI with no SwiftUI and no UI at all**, so those three skills are not
applicable and were intentionally skipped. No GUI was invented.
