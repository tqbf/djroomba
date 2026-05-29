import Foundation

/// Actor-safe accumulator for model token usage.
///
/// In Phase 1 nothing calls a model, so this only ever holds zero, but the
/// call loop in Phase 2 adds each `ModelResult.tokensUsed` here. Kept as an
/// actor so it is safe to share across the `ContextWindow` actor boundary.
public actor Metrics {
    private var modelTokensUsed: Int = 0

    public init() {}

    /// Total tokens reported as used by model calls so far.
    public var totalModelTokens: Int {
        modelTokensUsed
    }

    /// Add tokens reported by a single model call.
    public func addModelTokens(_ tokens: Int) {
        modelTokensUsed += tokens
    }

    /// Reset the accumulator (used by tests / context switches).
    public func reset() {
        modelTokensUsed = 0
    }
}
