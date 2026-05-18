import Foundation

/// Pure force accumulation for one simulation step.
///
/// `Forces` owns no state — it reads flat position/mass arrays and the
/// precomputed spring list, and writes into a caller-owned force buffer. This
/// keeps a step pure given `(state, parameters)` so energy/convergence are
/// unit-testable, and keeps the hot path allocation-free (the quadtree and the
/// traversal stack are reused buffers passed in).
///
/// Forces, per `plans/layout-engine.md`:
/// 1. Repulsion — Barnes–Hut, `F ∝ -k_r / d²`, min-distance clamped.
/// 2. Springs — Hooke toward rest length, stiffness scaled by `edge.weight`.
/// 3. Centering / gravity — weak pull of every node toward the layout centre.
enum Forces {
    /// One spring: indices into the flat node arrays plus its weight.
    struct Spring: Sendable {
        let a: Int
        let b: Int
        let weight: Double
    }

    /// Accumulate all forces into `forces` (which is zeroed first).
    ///
    /// - Parameters:
    ///   - centers: per-node gravity centre (model space) — each node's
    ///     connected-component anchor, so disconnected components settle as
    ///     separated islands rather than collapsing onto one point.
    ///   - tree: a quadtree already `rebuild`-ed over `positions`/`masses`.
    ///   - stack: reusable traversal buffer (allocation-free across steps).
    static func accumulate(
        positions: [Vector2],
        masses: [Double],
        springs: [Spring],
        parameters p: ForceParameters,
        centers: [Vector2],
        tree: Quadtree,
        forces: inout [Vector2],
        stack: inout [Int]
    ) {
        let n = positions.count
        guard n > 0 else { return }

        // 1 + 3. Repulsion (Barnes–Hut) and per-component gravity, per node.
        for i in 0..<n {
            var f = Vector2.zero
            tree.repulsion(
                on: i,
                at: positions[i],
                repulsion: p.repulsion,
                theta: p.theta,
                minDist: p.minDistance,
                into: &f,
                stack: &stack
            )
            // Pull toward this node's component anchor so components stay
            // compact and separated (no single global collapse).
            let toCenter = centers[i] - positions[i]
            f += toCenter * p.gravity
            forces[i] = f
        }

        // 2. Springs: Hooke toward rest length, stiffness × edge weight.
        for s in springs {
            let pa = positions[s.a]
            let pb = positions[s.b]
            let delta = pb - pa
            let dist = delta.length
            guard dist > 1e-9 else { continue }
            let dir = delta / dist
            // F = -k_s · weight · (d - L) ; positive ⇒ pull together.
            let magnitude = p.springStiffness * s.weight * (dist - p.restLength)
            let force = dir * magnitude
            forces[s.a] += force
            forces[s.b] -= force
        }
    }
}
