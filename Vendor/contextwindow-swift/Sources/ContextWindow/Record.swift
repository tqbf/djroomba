import Foundation

/// The kind of a stored ``Record``.
///
/// Raw values are persisted in the `records.source` column and are part of the
/// durable on-disk format — do not renumber.
public enum RecordType: Int, Codable, Sendable, CaseIterable {
    case prompt = 0
    case modelResponse = 1
    case toolCall = 2
    case toolOutput = 3
    case systemPrompt = 4
}

/// An append-only entry in a context.
///
/// `estimatedTokens` is computed at insert time via the active
/// ``TokenCounting`` implementation and stored alongside the record so the
/// token accounting never depends on re-tokenizing historical content.
public struct Record: Codable, Identifiable, Sendable, Equatable {
    public let id: Int64
    public let timestamp: Date
    public let source: RecordType
    public let content: String
    public let live: Bool
    public let estimatedTokens: Int
    public let contextID: UUID

    public init(
        id: Int64,
        timestamp: Date,
        source: RecordType,
        content: String,
        live: Bool,
        estimatedTokens: Int,
        contextID: UUID
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.content = content
        self.live = live
        self.estimatedTokens = estimatedTokens
        self.contextID = contextID
    }
}

/// A named context: the unit of conversation/state that records belong to.
public struct Context: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let startTime: Date

    public init(id: UUID, name: String, startTime: Date) {
        self.id = id
        self.name = name
        self.startTime = startTime
    }
}

/// A tool definition/hint persisted against a context in `context_tools`.
public struct ContextTool: Codable, Sendable, Equatable {
    public let contextID: UUID
    public let toolName: String
    public let definition: String

    public init(contextID: UUID, toolName: String, definition: String) {
        self.contextID = contextID
        self.toolName = toolName
        self.definition = definition
    }
}

/// A full, self-contained export of a context: its metadata, every record
/// (live and dead) in timestamp order, and any registered tool hints.
public struct ContextExport: Codable, Sendable, Equatable {
    public let context: Context
    public let records: [Record]
    public let tools: [ContextTool]

    public init(context: Context, records: [Record], tools: [ContextTool]) {
        self.context = context
        self.records = records
        self.tools = tools
    }
}

/// Aggregate token accounting for a context, returned by token-usage queries.
public struct TokenUsage: Codable, Sendable, Equatable {
    /// Sum of `estimatedTokens` over the context's live records.
    public let liveTokens: Int

    public init(liveTokens: Int) {
        self.liveTokens = liveTokens
    }
}

/// Errors surfaced by the context store / window.
public enum ContextWindowError: Error, Sendable, Equatable {
    /// A context with the requested name already exists (unique-name violation).
    case contextNameAlreadyExists(String)
    /// No context exists with the requested name.
    case contextNotFound(String)
}

extension ContextWindowError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .contextNameAlreadyExists(let name):
            return "a context named \"\(name)\" already exists"
        case .contextNotFound(let name):
            return "no context named \"\(name)\" was found"
        }
    }
}
