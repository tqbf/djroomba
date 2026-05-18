import Foundation

/// Deterministic initial node placement (library-internal).
///
/// Nodes are seeded on a golden-angle (phyllotaxis) spiral so the layout starts
/// evenly spread and reproducible for a given `seed` before the force engine
/// takes over. The same `(graph, seed)` always yields the same positions, which
/// the simulation determinism tests rely on. This is an engine detail, not part
/// of the public API — callers pass `nodes`/`edges` and never touch positions.
enum SeededLayout {
    /// Golden angle in radians (≈137.507°), the phyllotaxis constant.
    private static let goldenAngle = .pi * (3.0 - (5.0 as Double).squareRoot())

    /// Compute positions for every node, ordered to match `graph.nodes`.
    ///
    /// - Parameters:
    ///   - spacing: radial growth factor; larger spreads the spiral out.
    ///   - seed: rotates the whole spiral so re-seeding gives a fresh, still
    ///     deterministic arrangement.
    static func positions<Value>(
        for graph: Graph<Value>,
        spacing: Double = 36,
        seed: UInt64 = 0
    ) -> [Vector2] {
        let count = graph.nodes.count
        guard count > 0 else { return [] }

        // Stable per-seed rotation in [0, 2π).
        let phase = Double(seed % 360) * .pi / 180

        var positions = [Vector2](repeating: .zero, count: count)
        for i in 0..<count {
            let radius = spacing * Double(i).squareRoot()
            let theta = Double(i) * goldenAngle + phase
            positions[i] = Vector2(radius * cos(theta), radius * sin(theta))
        }
        return positions
    }
}
