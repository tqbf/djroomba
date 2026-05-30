import Foundation
import ContextWindow

/// A ``ToolExecutor`` whose backing executor is supplied *after* construction.
///
/// The `ContextWindow` actor *is* the `ToolExecutor`, but an `OpenAIChatModel`
/// needs an executor at init while the window needs the model at init — a
/// chicken-and-egg. This box breaks it: build the model with a
/// `LateBoundToolExecutor`, build the window with the model, then
/// ``bind(_:)`` the window into the box.
///
/// Thread-safe (`Sendable`) via an internal lock. Until bound, tool execution
/// throws ``ModelError/toolNotRegistered(_:)`` and `registeredTools()` is empty.
public final class LateBoundToolExecutor: ToolExecutor, @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var executor: ToolExecutor?
    }
    private let box = Box()

    public init() {}

    /// Supply the real executor (typically the `ContextWindow` actor).
    public func bind(_ executor: ToolExecutor) {
        box.lock.withLock { box.executor = executor }
    }

    private var current: ToolExecutor? {
        box.lock.withLock { box.executor }
    }

    public func executeTool(name: String, args: Data) async throws -> String {
        guard let executor = current else {
            throw ModelError.toolNotRegistered(name)
        }
        return try await executor.executeTool(name: name, args: args)
    }

    public func registeredTools() async -> [ToolDefinition] {
        guard let executor = current else { return [] }
        return await executor.registeredTools()
    }
}
