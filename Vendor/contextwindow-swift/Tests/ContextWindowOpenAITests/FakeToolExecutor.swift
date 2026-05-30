import Foundation
import ContextWindow

/// A network-free ``ToolExecutor`` test double.
///
/// Returns a scripted output per tool name and captures the `(name, args)` it
/// was asked to execute, so the Chat/Responses tool-loop tests can assert the
/// adapter drove it correctly — all offline.
final class FakeToolExecutor: ToolExecutor, @unchecked Sendable {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var executed: [(name: String, args: String)] = []
    }

    private let box = Box()
    private let outputs: [String: String]
    private let tools: [ToolDefinition]

    init(outputs: [String: String], tools: [ToolDefinition] = []) {
        self.outputs = outputs
        self.tools = tools
    }

    func executeTool(name: String, args: Data) async throws -> String {
        box.lock.withLock {
            box.executed.append((name, String(decoding: args, as: UTF8.self)))
        }
        return outputs[name] ?? "no output for \(name)"
    }

    func registeredTools() async -> [ToolDefinition] {
        tools
    }

    var executedCalls: [(name: String, args: String)] {
        box.lock.withLock { box.executed }
    }
}
