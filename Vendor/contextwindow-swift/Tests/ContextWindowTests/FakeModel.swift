import Foundation
@testable import ContextWindow

/// A network-free ``Model``/``Summarizer`` test double.
///
/// Captures every `[Record]` it is called with (so tests can assert the call
/// loop hands it *exactly* the live set, in order) and returns a scripted
/// ``ModelResult``. `Sendable` via an internal lock-box so tests can inspect
/// captures across the actor boundary.
final class FakeModel: Summarizer, @unchecked Sendable {
    /// Box guarding mutable capture state.
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var calls: [[Record]] = []
    }

    private let box = Box()
    private let result: ModelResult

    /// - Parameter result: the scripted result every `call` returns.
    init(result: ModelResult) {
        self.result = result
    }

    /// Convenience: a single model-response event.
    convenience init(reply: String, tokensUsed: Int = 0) {
        self.init(result: ModelResult(
            events: [RecordEvent(source: .modelResponse, content: reply)],
            tokensUsed: tokensUsed
        ))
    }

    func call(_ records: [Record]) async throws -> ModelResult {
        box.lock.withLock { box.calls.append(records) }
        return result
    }

    /// Records passed to the most recent `call`, or `nil` if never called.
    var lastCall: [Record]? {
        box.lock.withLock { box.calls.last }
    }

    /// Number of times `call` was invoked.
    var callCount: Int {
        box.lock.withLock { box.calls.count }
    }
}
