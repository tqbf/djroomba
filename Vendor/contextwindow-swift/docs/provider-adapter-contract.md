# Provider adapter contract

A provider adapter is anything that conforms to `Model`:

```swift
public protocol Model: Sendable {
    func call(_ records: [Record]) async throws -> ModelResult
}
```

`ContextWindow.callModel()` drives it with an exact, unchangeable order:

1. resolve the current context ID
2. load its **live** records (timestamp ascending)
3. `model.call(liveRecords)`
4. add `result.tokensUsed` to `metrics`
5. insert **every** `result.events` entry as a record (source/content/live
   preserved verbatim)
6. return the **last** event's content

So an adapter's job is: translate `[Record]` → provider request, perform the
call (through an injected transport), and translate the provider response →
`[RecordEvent]`.

## Record → message mapping (the durable contract)

| `RecordType`     | Chat message                                      | Responses flatten tag |
|------------------|---------------------------------------------------|-----------------------|
| `.systemPrompt`  | `{role: "system"}`                                | `system:`             |
| `.prompt`        | `{role: "user"}`                                  | `user:`               |
| `.modelResponse` | `{role: "assistant"}`                             | `assistant:`          |
| `.toolCall`      | `{role: "assistant", tool_calls: [...]}` (legacy) | `tool_call:`          |
| `.toolOutput`    | `{role: "tool"}`                                  | `tool_output:`        |

A `.toolCall` record's content is the self-describing string `name(args)`
(matching `ContextWindow.addToolCall`); adapters parse it back into a synthetic
`tool_calls` entry so replayed history stays coherent.

## Tool-call loop

If the provider response requests tool calls, the adapter must:

1. emit a `.toolCall` `RecordEvent` (`name(args)`) per call,
2. execute each through the injected `ToolExecutor`
   (`executeTool(name:args:)` — args are the raw JSON arguments `Data`),
3. emit a `.toolOutput` `RecordEvent` carrying the tool's string result,
4. append the call + outputs to the wire conversation and re-issue,
5. repeat until the provider returns a plain assistant message,
6. emit a final `.modelResponse` `RecordEvent`.

The returned `ModelResult.events` therefore contains **every** `.toolCall`,
**every** `.toolOutput`, and the final `.modelResponse`, so the window persists
the whole exchange in one `callModel()`. `tokensUsed` is summed across all
round trips. A `maxToolRoundTrips` cap throws
`OpenAIError.toolLoopLimitExceeded`.

## Wiring the executor

`ContextWindow` *is* a `ToolExecutor`, but `OpenAIChatModel` needs an executor
at init while the window needs the model at init. Resolve the cycle with
`LateBoundToolExecutor`:

```swift
let ref = LateBoundToolExecutor()
let model = try OpenAIChatModel(model: "gpt-4.1-mini", toolExecutor: ref)
let cw = try ContextWindow(store: store, contextName: "x", model: model)
ref.bind(cw)               // now the model's tool loop drives this window
```

## HTTP transport (cost-discipline seam)

Adapters depend on `OpenAITransport`, not `URLSession` directly:

```swift
public protocol OpenAITransport: Sendable {
    func send(_ request: OpenAIHTTPRequest) async throws -> (Data, HTTPURLResponse)
}
```

- Production: `URLSessionOpenAITransport` (the *only* network-capable type).
- Tests: a stub returning canned JSON — the suite is fully offline.

The API key is read from `OPENAI_API_KEY` (or passed explicitly), never logged,
and only ever sent as an `Authorization: Bearer` header. Non-2xx responses
throw `OpenAIError.httpStatus(code:body:)` with a truncated body (never the
key).

## Provided adapters

- **`OpenAIChatModel`** — `POST /v1/chat/completions`. Structured message
  array; legacy `tool_calls` representation. Port this style first.
- **`OpenAIResponsesModel`** — `POST /v1/responses`. Initial `input` is the
  live records flattened to a newline-delimited string; tool-call continuation
  sends `function_call_output` items + `previous_response_id` (server carries
  prior state instead of re-sending history).
