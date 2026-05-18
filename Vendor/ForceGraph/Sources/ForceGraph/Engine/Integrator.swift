import Foundation

/// Velocity-Verlet integration with alpha cooling.
///
/// Pure given `(positions, velocities, forces, masses, parameters, alpha)` —
/// it mutates the position/velocity buffers in place and returns the new
/// `alpha`. The pinned node (if any) is held exactly at its target and its
/// velocity zeroed; forces are still computed *from* it onto others (it stays
/// a repeller / spring anchor), so only the integration of the pin itself is
/// suppressed here.
///
/// Per `plans/layout-engine.md`:
/// ```
/// a    = F[i] / mass            # mass = 1 + degree·massScale
/// v[i] = (v[i] + a·dt) · velocityDecay
/// p[i] += v[i] · alpha          # alpha scales displacement (cooling)
/// alpha += (alphaTarget - alpha) · alphaDecay
/// ```
enum Integrator {
    /// Integrate one fixed `dt` step. Returns the cooled `alpha`.
    ///
    /// - Parameters:
    ///   - pinnedIndex: node held fixed at `pinnedTarget` (nil ⇒ none).
    ///   - alpha: current heat; `alphaTarget` is the value it decays toward.
    @discardableResult
    static func step(
        positions: inout [Vector2],
        velocities: inout [Vector2],
        forces: [Vector2],
        masses: [Double],
        parameters p: ForceParameters,
        alpha: Double,
        alphaTarget: Double,
        pinnedIndex: Int?,
        pinnedTarget: Vector2
    ) -> Double {
        let n = positions.count
        let dt = p.timestep
        let decay = p.velocityDecay

        for i in 0..<n {
            if i == pinnedIndex {
                // Pinned: snap to target, kill momentum. Forces from it onto
                // others were already accumulated by `Forces`.
                positions[i] = pinnedTarget
                velocities[i] = .zero
                continue
            }
            let invMass = 1.0 / masses[i]
            let accel = forces[i] * invMass
            var v = (velocities[i] + accel * dt) * decay
            // Clamp per-step displacement so a stiff spring or a close
            // repulsion pair can't fling a node across the plane in one step.
            let step = v * alpha
            let stepLenSq = step.lengthSquared
            let maxStep = 120.0
            if stepLenSq > maxStep * maxStep {
                let scale = maxStep / stepLenSq.squareRoot()
                positions[i] += step * scale
                v = v * scale
            } else {
                positions[i] += step
            }
            velocities[i] = v
        }

        return alpha + (alphaTarget - alpha) * p.alphaDecay
    }

    /// Per-node mass = `1 + degree · massScale` (hubs heavier, move less).
    static func masses(degrees: [Int], massScale: Double) -> [Double] {
        degrees.map { 1.0 + Double($0) * massScale }
    }
}
