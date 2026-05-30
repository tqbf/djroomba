# ContextWindow — Swift Port Plan (master)

Port of the Go `contextwindow` library to Swift: a named-context + append-only
record store with live/dead compaction, token accounting, a model call loop,
summarization, tools, and OpenAI provider adapters.

## Context & deviations (read this first)

- **There is no Go source in this repo or on this machine.** This plan is the
  spec of record. We implement from the behavioral description below, not by
  reading Go. Where the plan says "port exactly," it means "match the described
  semantics exactly."
- **Phase 3 Go-parity harness is adapted.** With no Go binary to round-trip
  against, we instead guarantee:
  1. The SQLite schema shape is exactly as specified (`contexts`, `records`,
     `context_tools` + live-record and timestamp indexes), so a future Go build
     can open our DBs.
  2. Swift-internal golden JSON export fixtures (stable modulo timestamps/UUIDs)
     committed under `Fixtures/go-parity/`, plus a round-trip test that a DB
     written by Swift re-opens with identical decoded records.
  This preserves the durable-format guarantee that motivated the harness.
- **Toolchain:** Swift 6.3.1, Xcode 26.4.1, macOS. Swift 6 strict concurrency is
  on; all public types are `Sendable`, `ContextWindow` is an `actor`.
- **Persistence:** GRDB (per plan recommendation — typed records, migrations,
  transactions, async).
- **API cost discipline:** All logic is tested with `FakeModel`. Real OpenAI
  round trips are gated behind an env var and kept to 1–2 calls total, run once.

## Phase 1 — Domain model + SQLite spine

Deliverable: a Swift package that can create context windows, persist records,
list live records, export contexts, and report token usage **without calling a
model**.

Files: `ContextWindow.swift`, `Record.swift`, `ContextStore.swift`,
`TokenCounter.swift`, `Metrics.swift`.

Core types:

```swift
public enum RecordType: Int, Codable, Sendable {
    case prompt = 0
    case modelResponse = 1
    case toolCall = 2
    case toolOutput = 3
    case systemPrompt = 4
}

public struct Record: Codable, Identifiable, Sendable {
    public let id: Int64
    public let timestamp: Date
    public let source: RecordType
    public let content: String
    public let live: Bool
    public let estimatedTokens: Int
    public let contextID: UUID
}

public struct Context: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let startTime: Date
}
```

Store protocol (port these operations exactly):

```swift
public protocol ContextStore {
    func initialize() throws
    func createContext(name: String) throws -> Context
    func listContexts() throws -> [Context]
    func getContext(name: String) throws -> Context
    func deleteContext(name: String) throws
    func insertRecord(contextID: UUID, source: RecordType, content: String, live: Bool) throws -> Record
    func listLiveRecords(contextID: UUID) throws -> [Record]
    func listRecords(contextID: UUID) throws -> [Record]
    func exportContext(name: String) throws -> ContextExport
}
```

Semantics: `insertRecord` computes token count at insert time;
`listLiveRecords` is the primary read path before model calls. Schema = three
tables (`contexts`, `records`, `context_tools`) with live-record + timestamp
indexes; preserve schema shape for fixture parity.

Token counting is pluggable:

```swift
public protocol TokenCounting: Sendable {
    func count(_ text: String) -> Int
}
```

Initial impl: whitespace fallback. Then add a `cl100k_base`-compatible counter
(`tiktoken`) via a Swift package / C / shim; fall back to whitespace split if
tokenizer init fails (matches Go `cl100k_base` + `strings.Fields` fallback).

`ContextWindow` is an `actor` holding model, store, max tokens, summarizer,
middleware, metrics, current context, registered tools, runners.

Acceptance tests (Phase 1):

- creating an unnamed ContextWindow generates a UUID-ish context name
- creating named contexts enforces name uniqueness
- setting a system prompt deadens prior system prompts
- live records return in timestamp order
- deleting current context switches to another context or creates default
- export returns context + all records + tools
- token usage = sum(estimatedTokens for live records)

## Phase 2 — Model abstraction, call loop, summarization, tools

Deliverable: provider-independent `ContextWindow` that calls a fake model,
persists model events, summarizes live context, accepts/rejects summaries, runs
tools.

Model boundary:

```swift
public protocol Model: Sendable {
    func call(_ records: [Record]) async throws -> ModelResult
}
public struct ModelResult: Sendable {
    public var events: [RecordEvent]
    public var tokensUsed: Int
}
public struct RecordEvent: Sendable {
    public var source: RecordType
    public var content: String
    public var live: Bool
}
```

`ContextWindow` actor surface:

```swift
public func addPrompt(_ text: String) async throws
public func addToolCall(name: String, args: String) async throws
public func addToolOutput(_ output: String) async throws
public func setSystemPrompt(_ text: String) async throws
public func liveRecords() async throws -> [Record]
public func callModel() async throws -> String
public func tokenUsage() async throws -> TokenUsage
```

Call loop (exact semantics):

1. resolve current context ID
2. load live records
3. call model
4. add tokens used to metrics
5. insert every returned event as a record
6. return the last event content

Note: like Go today, `callModel()` does **not** auto-trigger summarization.
Summarization is a separate subsystem:

```swift
public protocol Summarizer: Model {}
public struct SummaryResult: Sendable {
    public var summary: String
    public var replaced: [Record]
    public var originalTokenCount: Int
    public var summaryTokenCount: Int
}
func summarizeLiveContext() async throws -> SummaryResult
func acceptSummary(_ result: SummaryResult) async throws
func rejectSummary(_ result: SummaryResult)
```

Summarizer prepends a summarizer prompt to live records, calls a model, takes
the last returned event as the summary, returns a `SummaryResult`. Accepting
marks replaced records dead and inserts the summary as a live `modelResponse`
(transactionally). Rejecting is a no-op on storage.

Tools (neutral representation — do NOT leak provider `Any` into core):

```swift
public protocol ToolRunner: Sendable {
    func run(args: Data) async throws -> String
}
public struct JSONSchemaToolDefinition: Codable, Sendable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue
    public var strict: Bool
}
public protocol ToolExecutor: Sendable {
    func executeTool(name: String, args: Data) async throws -> String
    func registeredTools() async -> [ToolDefinition]
}
```

`JSONValue` = a `Codable, Sendable` JSON enum. Provider adapters translate from
this neutral representation.

Tests (Phase 2, all FakeModel):

- FakeModel sees only live records
- FakeModel can emit multiple events; all are persisted
- callModel returns the last emitted event content
- summarizeLiveContext errors without summarizer
- acceptSummary deadens original live records transactionally
- tools register, list, execute, and persist context_tools hint
- middleware gets tool-call and tool-result callbacks

## Phase 3 — Provider adapters, package polish, compatibility harness

Deliverable: usable Swift package with OpenAI adapter, parity fixtures, docs,
example CLI.

Package layout:

```text
Package.swift
Sources/ContextWindow/{ContextWindow,ContextStore,Models,Summarizer,Tools,TokenCounter}.swift
Sources/ContextWindowOpenAI/{OpenAIChatModel,OpenAIResponsesModel}.swift
Sources/ContextWindowCLI/main.swift
Tests/{ContextWindowTests,ContextWindowOpenAITests}
Fixtures/go-parity/
```

OpenAI adapters (after model boundary is stable). Port Chat first, then
Responses.

Chat record-type mapping:

```text
systemPrompt -> system
prompt       -> user
modelResponse-> assistant
toolCall     -> assistant tool_calls (legacy representation)
toolOutput   -> tool / user output depending on endpoint
```

Chat adapter handles tool-call loops: append assistant tool calls, execute via
`ToolExecutor`, append tool messages, repeat until no tool calls remain; persist
both tool call and tool output as records.

Responses adapter: flatten records to newline-delimited string for initial
input; use function-call output items + `previous_response_id` during tool-call
continuation.

Compatibility harness (adapted — no Go binary):

1. Swift test writes a SQLite DB with contexts/records/tools.
2. Swift test re-opens the same DB and verifies decoded contexts/records/tools.
3. Golden JSON exports committed under `Fixtures/go-parity/`, asserted stable
   modulo timestamps/UUIDs.
4. Schema-shape assertions (table + index names/columns) lock the durable
   format so a future Go build can interoperate.

Docs:

- README: Swift quick start
- "Porting notes from Go" (this plan + deviations)
- "Provider adapter contract"
- "Tool definition format"
- "Compaction lifecycle"

MVP usage target:

```swift
let store = try SQLiteContextStore(path: "contextwindow.sqlite")
let model = OpenAIChatModel(model: "gpt-4.1")
let cw = try await ContextWindow(store: store, model: model, contextName: "default")
try await cw.setSystemPrompt("You are concise.")
try await cw.addPrompt("What is the Go programming language?")
let reply = try await cw.callModel()
let usage = try await cw.tokenUsage()
```

Opinionated cut: port **core semantics** faithfully; **redesign the provider
layer** around neutral `JSONSchemaToolDefinition` + typed `ModelResult`.

## Execution protocol

- Phases run in **serial** subagents (never parallel). Phase N+1 starts only
  after Phase N's subagent reports success and `swift build`/`swift test` pass.
- Every subagent updates `PROGRESS.md` before returning.
- OpenAI round trips minimized: FakeModel everywhere; real calls gated by
  `CONTEXTWINDOW_LIVE_OPENAI=1`, ≤2 total, run once by the orchestrator.
