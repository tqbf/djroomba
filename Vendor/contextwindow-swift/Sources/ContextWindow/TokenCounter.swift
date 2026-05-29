import Foundation

/// Pluggable token estimator.
///
/// Implementations must be pure and thread-safe (`Sendable`). The result is
/// stored on each ``Record`` at insert time, so the same text must always
/// produce the same count for a given counter instance.
public protocol TokenCounting: Sendable {
    func count(_ text: String) -> Int
}

/// Default token counter: counts whitespace-delimited fields.
///
/// This mirrors the Go fallback (`strings.Fields`) used when a
/// `cl100k_base`/tiktoken tokenizer is unavailable. A real BPE tokenizer is
/// deferred to Phase 3; this whitespace counter is the Phase 1 default and is
/// always correct (never throws, never depends on external resources).
public struct WhitespaceTokenCounter: TokenCounting {
    public init() {}

    public func count(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
