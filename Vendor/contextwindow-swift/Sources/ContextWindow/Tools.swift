import Foundation

// MARK: - JSONValue

/// A neutral, recursive JSON value.
///
/// Used so tool parameter schemas can be expressed in core *without* leaking a
/// provider's `Any`/dynamic type into the public surface. Provider adapters
/// (Phase 3) translate this to/from their SDK's representation.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let v = try? container.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? container.decode(Double.self) {
            self = .number(v)
            return
        }
        if let v = try? container.decode(String.self) {
            self = .string(v)
            return
        }
        if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
            return
        }
        if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "unsupported JSON value"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Tool definitions

/// A JSON-Schema-shaped tool definition (the durable/neutral form).
///
/// `parameters` is a ``JSONValue`` (typically a `.object` JSON Schema). This is
/// what gets serialized into the `context_tools` hint and what provider
/// adapters translate from.
public struct JSONSchemaToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?
    public var parameters: JSONValue
    public var strict: Bool

    public init(
        name: String,
        description: String? = nil,
        parameters: JSONValue,
        strict: Bool = false
    ) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.strict = strict
    }
}

/// A registered tool: its neutral schema plus its executable behavior.
///
/// `runner` is not `Codable` (it's behavior); only `schema` is persisted as the
/// `context_tools` hint.
public struct ToolDefinition: Sendable {
    public var schema: JSONSchemaToolDefinition
    public var runner: ToolRunner

    public init(schema: JSONSchemaToolDefinition, runner: ToolRunner) {
        self.schema = schema
        self.runner = runner
    }

    /// Convenience: the tool's name (from its schema).
    public var name: String { schema.name }
}

// MARK: - Tool execution

/// The executable behavior behind a tool.
///
/// `args` is the raw JSON arguments blob (as a provider would deliver it). The
/// returned `String` is persisted as a `toolOutput` record.
public protocol ToolRunner: Sendable {
    func run(args: Data) async throws -> String
}

/// A `ToolRunner` backed by a `Sendable` closure (handy for tests / inline
/// tools).
public struct ClosureToolRunner: ToolRunner {
    private let body: @Sendable (Data) async throws -> String

    public init(_ body: @Sendable @escaping (Data) async throws -> String) {
        self.body = body
    }

    public func run(args: Data) async throws -> String {
        try await body(args)
    }
}

/// The tool-execution surface a provider adapter drives during a tool-call
/// loop.
public protocol ToolExecutor: Sendable {
    /// Execute the registered tool `name` with raw JSON `args`; returns its
    /// string output. Throws ``ModelError/toolNotRegistered(_:)`` if unknown.
    func executeTool(name: String, args: Data) async throws -> String
    /// The currently registered tools.
    func registeredTools() async -> [ToolDefinition]
}

// MARK: - Middleware

/// A neutral event the ``ContextWindow`` reports to ``Middleware`` during tool
/// execution.
public enum MiddlewareEvent: Sendable, Equatable {
    /// A tool is about to run: its name and raw JSON args.
    case toolCall(name: String, args: Data)
    /// A tool finished: its name and string output.
    case toolResult(name: String, output: String)
}

/// Observer hooks fired by the window around tool execution.
///
/// Both callbacks are `async` so observers may do async work; they must not
/// throw (observation must never break the call loop). Implementations are
/// `Sendable`.
public protocol Middleware: Sendable {
    func onToolCall(name: String, args: Data) async
    func onToolResult(name: String, output: String) async
}

/// A `Middleware` built from two `Sendable` closures (handy for tests).
public struct ClosureMiddleware: Middleware {
    private let callHandler: @Sendable (String, Data) async -> Void
    private let resultHandler: @Sendable (String, String) async -> Void

    public init(
        onToolCall: @Sendable @escaping (String, Data) async -> Void = { _, _ in },
        onToolResult: @Sendable @escaping (String, String) async -> Void = { _, _ in }
    ) {
        self.callHandler = onToolCall
        self.resultHandler = onToolResult
    }

    public func onToolCall(name: String, args: Data) async {
        await callHandler(name, args)
    }

    public func onToolResult(name: String, output: String) async {
        await resultHandler(name, output)
    }
}
