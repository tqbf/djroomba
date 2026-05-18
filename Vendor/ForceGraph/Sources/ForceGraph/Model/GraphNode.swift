import Foundation

/// A single word node in the graph.
///
/// The library renders only `label`. `value` is an opaque caller payload the
/// library never inspects; it exists so the caller's `style` callback and
/// `onActivate` hook can carry application behaviour.
public struct GraphNode<Value>: Identifiable, Sendable where Value: Sendable {
    /// Stable node identity (a `String`); referenced by `GraphEdge.a` / `.b`.
    public let id: NodeID
    /// The word rendered for this node (the only thing the library draws).
    public var label: String
    /// Opaque caller payload. The library never inspects it; it exists for the
    /// `style` callback and `onActivate` hook to carry application behaviour.
    public var value: Value

    /// Create a node with a caller payload.
    public init(id: NodeID, label: String, value: Value) {
        self.id = id
        self.label = label
        self.value = value
    }
}

extension GraphNode where Value == Void {
    /// Convenience for graphs that carry no caller payload.
    public init(id: NodeID, label: String) {
        self.init(id: id, label: label, value: ())
    }
}
