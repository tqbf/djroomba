import Foundation

/// A model specialized for compaction.
///
/// A `Summarizer` *is a* ``Model`` — the same `call([Record])` boundary — so any
/// model can act as one. ``ContextWindow/summarizeLiveContext()`` prepends a
/// summarizer prompt to the live records, calls the summarizer, and treats the
/// **last** returned event as the summary.
public protocol Summarizer: Model {}

/// The proposed compaction of a context's live records.
///
/// `summarizeLiveContext()` produces this without mutating storage; the caller
/// then either ``ContextWindow/acceptSummary(_:)`` (deaden `replaced` + insert
/// `summary` as a live model response, transactionally) or
/// ``ContextWindow/rejectSummary(_:)`` (no-op on storage).
public struct SummaryResult: Sendable, Equatable {
    /// The summary text (content of the summarizer's last emitted event).
    public var summary: String
    /// The live records this summary would replace (the ones that would be
    /// deadened on accept), timestamp ascending.
    public var replaced: [Record]
    /// Sum of `estimatedTokens` over `replaced`.
    public var originalTokenCount: Int
    /// Tokens reported by the summarizer call.
    public var summaryTokenCount: Int

    public init(
        summary: String,
        replaced: [Record],
        originalTokenCount: Int,
        summaryTokenCount: Int
    ) {
        self.summary = summary
        self.replaced = replaced
        self.originalTokenCount = originalTokenCount
        self.summaryTokenCount = summaryTokenCount
    }
}

/// The default instruction prepended (as a synthetic system-prompt record) to
/// the live records before the summarizer is called. Kept terse and provider
/// neutral; adapters never see this as anything but a record.
public enum SummarizerPrompt {
    public static let `default` = """
        Summarize the conversation so far into a single concise message that \
        preserves all facts, decisions, open questions, and tool results needed \
        to continue. Omit pleasantries. Output only the summary.
        """
}
