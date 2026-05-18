import Foundation

/// The tunable constants of the force simulation, surfaced live in the Lab
/// inspector so the layout can be tweaked and perfected.
///
/// A plain `Sendable` value type: the engine holds one, callers bind to a copy
/// via `GraphController`, and `Simulation.step()` reads it by value so a step
/// is pure given `(state, parameters)`. Defaults are tuned for the sparse
/// ~1,594-node corpus (avg degree ≈ 4.4) and follow the d3-force conventions
/// cited in `plans/layout-engine.md`.
public struct ForceParameters: Equatable, Sendable {
    /// Repulsion strength `k_r`. Force between two nodes ∝ `-k_r / d²`.
    /// Word-capsule nodes are ~80–200 model units wide, so repulsion must be
    /// strong enough to keep neighbours from overlapping at `restLength`.
    public var repulsion: Double = 45_000

    /// Spring stiffness `k_s`. Hooke pull toward `restLength`, scaled by edge
    /// weight: `F = -k_s · weight · (d - L) · û`. Soft, so strong repulsion can
    /// open clusters out while springs still hold topology.
    public var springStiffness: Double = 0.10

    /// Spring rest length `L` (model units) — wider than a capsule so a
    /// connected pair sits with a clear gap, not overlapping.
    public var restLength: Double = 120

    /// Centering / gravity `k_g`. Each node is pulled toward *its connected
    /// component's* anchor (not one global centre). Deliberately weak: on a
    /// sparse (avg-degree ≈ 2) graph, strong gravity collapses tree-like
    /// components into an illegible ball — springs + repulsion must dominate so
    /// the component sprawls into an airy web. It only needs to be strong
    /// enough to keep isolated singletons near their packed slot.
    public var gravity: Double = 0.006

    /// Barnes–Hut opening criterion `θ`. A cell is treated as one aggregate
    /// mass when `cellSize / distance < θ`. Higher ⇒ faster, less accurate.
    public var theta: Double = 0.9

    /// Per-step velocity damping (d3 `velocityDecay`); higher ⇒ more friction.
    public var velocityDecay: Double = 0.6

    /// Per-step alpha cooling toward `alphaTarget`. Slower than the d3 default
    /// (0.0228) so the tight seeded spiral has time to bloom into spread-out
    /// clusters before the layout freezes.
    public var alphaDecay: Double = 0.015

    /// Extra mass per unit of degree, so hubs are heavier and move less
    /// (`mass = 1 + degree · massScale`).
    public var massScale: Double = 0.5

    /// Below this alpha the layout is considered settled: the simulation
    /// stops stepping entirely so an idle graph uses ~no CPU.
    public var alphaMin: Double = 0.0015

    /// Minimum pair distance used when computing repulsion, to avoid
    /// singular `1/d²` blow-ups (and jitter) when nodes are very close.
    public var minDistance: Double = 4.0

    /// Fixed integration timestep. Sim steps are decoupled from render frames.
    public var timestep: Double = 0.85

    /// Outward impulse given to the selected node's one-ring neighbours on
    /// pin, so they fan around the focus immediately (snappier response).
    public var neighborImpulse: Double = 26

    /// The tuned defaults (good for sparse, ~1,500-node word graphs).
    public static let `default` = ForceParameters()

    /// Create parameters at the tuned defaults; mutate individual fields to
    /// tweak the layout.
    public init() {}
}
