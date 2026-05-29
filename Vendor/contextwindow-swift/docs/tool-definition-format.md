# Tool definition format

Tools are described with a **neutral, provider-independent** schema so no
provider `Any`/SDK type leaks into core. Provider adapters translate from this
form.

## Types

```swift
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue])
    case string(String), number(Double), bool(Bool), null
}

public struct JSONSchemaToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue   // typically a `.object` JSON Schema
    public var strict: Bool
}

public struct ToolDefinition: Sendable {
    public var schema: JSONSchemaToolDefinition  // persisted
    public var runner: ToolRunner                // behavior, not persisted
}

public protocol ToolRunner: Sendable {
    func run(args: Data) async throws -> String
}
```

`JSONValue` is a fully recursive `Codable` JSON value, so any JSON Schema can be
expressed without dynamic typing.

## Registering a tool

```swift
try await cw.registerTool(
    schema: JSONSchemaToolDefinition(
        name: "search",
        description: "Search the web",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "q": .object(["type": .string("string")])
            ]),
            "required": .array([.string("q")])
        ]),
        strict: true
    ),
    runner: ClosureToolRunner { argsData in
        // argsData is the raw JSON arguments blob the provider delivered.
        return "…tool result string…"
    }
)
```

`registerTool` does two things:

1. Stores the `runner` in the window's in-memory `[name: ToolDefinition]` map
   (last registration of a name wins).
2. Persists the JSON-encoded `JSONSchemaToolDefinition` (sorted keys) into the
   `context_tools` table as the durable **hint** for that context, via an
   upsert.

`registerToolHint(name:definition:)` persists a raw hint string only (no
runner) for callers that just want the durable record.

## How adapters serialize it

- **Chat Completions:** `{"type":"function","function":{name, description,
  parameters, strict?}}`.
- **Responses:** `{"type":"function", name, description, parameters,
  strict?}`.

`strict` is emitted only when `true`. `parameters` is passed through verbatim
as the JSON Schema object.

## Execution

The adapter calls `ToolExecutor.executeTool(name:, args: Data)`. `args` is the
raw JSON arguments string from the provider, as `Data` — the runner decodes it
however it likes. The returned `String` becomes a `.toolOutput` record.

## Durable shape

The `context_tools` table is `(context_id TEXT, tool_name TEXT, definition
TEXT, PRIMARY KEY (context_id, tool_name))`. `definition` is the
sorted-key-encoded `JSONSchemaToolDefinition`. This shape is locked by the
schema-shape compatibility test.
