import Foundation

/// An undirected, weighted edge between two nodes.
///
/// `weight` is `0...1` and scales spring stiffness (later phases) and visual
/// emphasis. Edges are treated as undirected: `a~b` and `b~a` are the same
/// relationship; callers should de-duplicate before constructing a `Graph`.
public struct GraphEdge: Identifiable, Sendable, Hashable {
    /// Canonical id `"a~b"`. Edges are undirected, so treat `a~b` and `b~a`
    /// as the same relationship.
    public var id: String { "\(a)~\(b)" }
    /// One endpoint's node id.
    public let a: NodeID
    /// The other endpoint's node id.
    public let b: NodeID
    /// Relationship strength `0...1`: scales spring stiffness and visual
    /// emphasis. On parallel edges the maximum weight is kept.
    public var weight: Double

    /// Create an undirected, weighted edge between two node ids.
    public init(a: NodeID, b: NodeID, weight: Double = 1) {
        self.a = a
        self.b = b
        self.weight = weight
    }
}
