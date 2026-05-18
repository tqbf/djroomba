import Foundation

/// An immutable, validated graph: nodes + edges + a precomputed adjacency list.
///
/// Construction normalises the input once:
/// - duplicate node ids keep the first occurrence,
/// - edges referencing unknown nodes are dropped,
/// - self-loops are dropped,
/// - parallel edges are merged keeping the maximum weight (edges are
///   undirected, so `a~b` and `b~a` collapse).
///
/// `Graph` is a value type and `Sendable` so it can be snapshotted across the
/// main actor / background `Task` boundary in later phases.
public struct Graph<Value: Sendable>: Sendable {
    /// The normalised nodes (duplicates removed, first occurrence kept).
    public let nodes: [GraphNode<Value>]
    /// The normalised, de-duplicated, undirected edges.
    public let edges: [GraphEdge]

    /// node id -> index into `nodes`.
    public let indexByID: [NodeID: Int]

    /// Per-node neighbour ids (parallel to `nodes`). Order is deterministic
    /// (first-seen during edge normalisation).
    public let adjacency: [[NodeID]]

    public init(nodes rawNodes: [GraphNode<Value>], edges rawEdges: [GraphEdge]) {
        var nodes: [GraphNode<Value>] = []
        var indexByID: [NodeID: Int] = [:]
        nodes.reserveCapacity(rawNodes.count)
        indexByID.reserveCapacity(rawNodes.count)

        for node in rawNodes where indexByID[node.id] == nil {
            indexByID[node.id] = nodes.count
            nodes.append(node)
        }

        // Merge undirected, de-duplicated edges keeping max weight.
        var mergedWeight: [EdgeKey: Double] = [:]
        var order: [EdgeKey] = []
        for edge in rawEdges {
            guard
                edge.a != edge.b,
                indexByID[edge.a] != nil,
                indexByID[edge.b] != nil
            else { continue }

            let key = EdgeKey(edge.a, edge.b)
            if let existing = mergedWeight[key] {
                mergedWeight[key] = max(existing, edge.weight)
            } else {
                mergedWeight[key] = edge.weight
                order.append(key)
            }
        }

        var edges: [GraphEdge] = []
        edges.reserveCapacity(order.count)
        var adjacency = [[NodeID]](repeating: [], count: nodes.count)
        for key in order {
            let weight = mergedWeight[key] ?? 1
            edges.append(GraphEdge(a: key.low, b: key.high, weight: weight))
            if let i = indexByID[key.low] { adjacency[i].append(key.high) }
            if let j = indexByID[key.high] { adjacency[j].append(key.low) }
        }

        self.nodes = nodes
        self.edges = edges
        self.indexByID = indexByID
        self.adjacency = adjacency
    }

    /// Number of (de-duplicated) nodes.
    public var nodeCount: Int { nodes.count }
    /// Number of (de-duplicated) edges.
    public var edgeCount: Int { edges.count }

    /// Index of `id` in `nodes`, or `nil` if unknown.
    public func index(of id: NodeID) -> Int? {
        indexByID[id]
    }

    /// The node for `id`, or `nil` if unknown.
    public func node(_ id: NodeID) -> GraphNode<Value>? {
        guard let i = indexByID[id] else { return nil }
        return nodes[i]
    }

    /// Degree (number of distinct neighbours) of a node.
    public func degree(of id: NodeID) -> Int {
        guard let i = indexByID[id] else { return 0 }
        return adjacency[i].count
    }

    /// Unweighted shortest-path hop count from `source` to `target`.
    /// `0` for the source itself, `nil` if unreachable or either id unknown.
    public func distance(from source: NodeID, to target: NodeID) -> Int? {
        guard indexByID[source] != nil, indexByID[target] != nil else { return nil }
        if source == target { return 0 }
        let distances = distances(from: source)
        return distances[target]
    }

    /// BFS hop counts from `source` to every reachable node (including the
    /// source at distance `0`). Unreachable nodes are absent from the result.
    public func distances(from source: NodeID) -> [NodeID: Int] {
        guard let start = indexByID[source] else { return [:] }
        var depthByIndex = [Int](repeating: -1, count: nodes.count)
        depthByIndex[start] = 0
        var frontier = [start]
        var result: [NodeID: Int] = [source: 0]

        while !frontier.isEmpty {
            var next: [Int] = []
            for i in frontier {
                let depth = depthByIndex[i]
                for neighbour in adjacency[i] {
                    guard let j = indexByID[neighbour], depthByIndex[j] == -1 else { continue }
                    depthByIndex[j] = depth + 1
                    result[neighbour] = depth + 1
                    next.append(j)
                }
            }
            frontier = next
        }
        return result
    }
}

/// Canonical undirected edge key (orders endpoints so `a~b == b~a`).
private struct EdgeKey: Hashable {
    let low: NodeID
    let high: NodeID

    init(_ x: NodeID, _ y: NodeID) {
        if x <= y {
            low = x
            high = y
        } else {
            low = y
            high = x
        }
    }
}
