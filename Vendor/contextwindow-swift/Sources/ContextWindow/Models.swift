import Foundation

/// The provider-independent model boundary.
///
/// A `Model` is handed the *live* records of a context (timestamp ascending)
/// and returns a typed ``ModelResult``. Core never deals in provider payloads:
/// adapters (Phase 3) translate `[Record]` in and ``RecordEvent`` out.
///
/// Implementations must be `Sendable` so the `ContextWindow` actor can call
/// across the concurrency boundary.
public protocol Model: Sendable {
    /// Run the model against the supplied live records.
    ///
    /// - Parameter records: the context's live records, timestamp ascending —
    ///   exactly what ``ContextWindow/liveRecords()`` would return.
    /// - Returns: the events to persist plus the provider-reported token usage.
    func call(_ records: [Record]) async throws -> ModelResult
}

/// The typed result of a single ``Model/call(_:)``.
///
/// `events` are persisted in order as records; `tokensUsed` is accumulated
/// into ``Metrics``. A model may emit zero or many events (e.g. a tool call
/// followed by an assistant message).
public struct ModelResult: Sendable, Equatable {
    /// Events to persist, in emission order.
    public var events: [RecordEvent]
    /// Provider-reported tokens used by this call.
    public var tokensUsed: Int

    public init(events: [RecordEvent], tokensUsed: Int) {
        self.events = events
        self.tokensUsed = tokensUsed
    }
}

/// A single neutral event emitted by a ``Model``.
///
/// Maps 1:1 onto an inserted ``Record``: `source`/`content`/`live` are
/// preserved verbatim by the call loop.
public struct RecordEvent: Sendable, Equatable {
    public var source: RecordType
    public var content: String
    public var live: Bool

    public init(source: RecordType, content: String, live: Bool = true) {
        self.source = source
        self.content = content
        self.live = live
    }
}

/// Errors surfaced by the Phase 2 model loop / summarization / tools.
public enum ModelError: Error, Sendable, Equatable {
    /// `callModel()` was invoked but no ``Model`` was configured on the window.
    case noModelConfigured
    /// `summarizeLiveContext()` was invoked but no ``Summarizer`` was configured.
    case noSummarizerConfigured
    /// `executeTool` was asked for a tool name that was never registered.
    case toolNotRegistered(String)
    /// A model returned no events (the call loop has no content to return).
    case emptyModelResult
}

extension ModelError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .noModelConfigured:
            return "callModel() requires a Model; none was configured"
        case .noSummarizerConfigured:
            return "summarizeLiveContext() requires a Summarizer; none was configured"
        case .toolNotRegistered(let name):
            return "no tool named \"\(name)\" is registered"
        case .emptyModelResult:
            return "the model returned no events"
        }
    }
}
