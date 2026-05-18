import Foundation

/// The force layout simulation: owns positions/velocities and advances them at
/// a fixed timestep with alpha cooling, Barnes–Hut repulsion, weighted springs
/// and **per-component gravity**.
///
/// Real corpora are sparse and disconnected (hundreds of components, many
/// isolated singletons). A single global gravity centre would collapse every
/// component onto the same point — one illegible overlapping pile with tens of
/// thousands of spurious edge crossings. Instead each connected component is
/// packed to its **own anchor** and gravity pulls each node toward its
/// component's anchor, so the graph settles into separated, legible islands.
///
/// Single-writer by construction: `GraphEngine` is the only thing that holds
/// and mutates a `Simulation`, on the main actor. `step()` is allocation-free
/// in steady state (the quadtree, traversal stack and the per-node gravity
/// centres are reused buffers) and **idles when settled** — once
/// `alpha < parameters.alphaMin` it returns immediately doing zero work.
///
/// It is a `Sendable` value type holding only value state, so a step can be
/// performed off the main actor on a copy and the result published back.
struct Simulation: Sendable {
    private(set) var positions: [Vector2]
    private(set) var velocities: [Vector2]
    private let masses: [Double]
    private let springs: [Forces.Spring]
    private var forces: [Vector2]
    private var tree: Quadtree
    private var stack: [Int]

    /// Connected-component id per node, and the packed anchor each node's
    /// component gravitates toward. Fixed for the life of the simulation.
    private let componentOf: [Int]
    private let nodeAnchor: [Vector2]
    /// Reused per-step buffer: effective gravity centre per node (= the node's
    /// component anchor, or the pin for the focused node's component).
    private var centers: [Vector2]

    /// Layout heat. `1` = fully reheated, decays toward `alphaTarget`.
    private(set) var alpha: Double = 1
    private var alphaTarget: Double = 0

    /// Index of the pinned (focal) node and where it is held, model space.
    private(set) var pinnedIndex: Int?
    private var pinnedTarget: Vector2 = .zero

    var parameters: ForceParameters

    /// True once the layout has cooled below `alphaMin`: the engine should
    /// stop stepping (idle ⇒ no CPU) until something reheats it.
    var isSettled: Bool { alpha < parameters.alphaMin }

    // MARK: - Init

    /// Build from the immutable graph. Node arrays are parallel to
    /// `graph.nodes`. `seedPositions` is ignored for placement — nodes are
    /// seeded around their packed component anchor so components start (and
    /// stay) separated, which is both faster to settle and far more legible.
    init<Value>(
        graph: Graph<Value>,
        seedPositions: [Vector2] = [],
        parameters: ForceParameters = .default
    ) {
        let n = graph.nodes.count
        self.parameters = parameters
        self.velocities = [Vector2](repeating: .zero, count: n)
        self.forces = [Vector2](repeating: .zero, count: n)

        let degrees = (0..<n).map { graph.adjacency[$0].count }
        self.masses = Integrator.masses(degrees: degrees, massScale: parameters.massScale)

        var springs: [Forces.Spring] = []
        springs.reserveCapacity(graph.edges.count)
        for e in graph.edges {
            guard let ia = graph.indexByID[e.a], let ib = graph.indexByID[e.b] else { continue }
            springs.append(Forces.Spring(a: ia, b: ib, weight: max(e.weight, 0.05)))
        }
        self.springs = springs

        // Connected components via union-find over the spring graph.
        let (compOf, anchorByNode, seeded) = Self.packComponents(
            nodeCount: n,
            springs: springs,
            spread: parameters.restLength
        )
        self.componentOf = compOf
        self.nodeAnchor = anchorByNode
        self.positions = seeded
        self.centers = anchorByNode

        self.tree = Quadtree(capacity: max(n, 1))
        self.stack = []
        self.stack.reserveCapacity(256)
    }

    /// Union-find the components, pack their anchors on a phyllotaxis spiral
    /// (big components first, radius ∝ √size so each gets room), and seed every
    /// node near its anchor. Deterministic given `(nodeCount, springs)`.
    private static func packComponents(
        nodeCount n: Int,
        springs: [Forces.Spring],
        spread: Double
    ) -> (componentOf: [Int], nodeAnchor: [Vector2], seed: [Vector2]) {
        guard n > 0 else { return ([], [], []) }

        var parent = Array(0..<n)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { r = parent[r] }
            var c = x
            while parent[c] != c { let next = parent[c]; parent[c] = r; c = next }
            return r
        }
        for s in springs {
            let ra = find(s.a), rb = find(s.b)
            if ra != rb { parent[ra] = rb }
        }

        // Group node indices by component root.
        var members: [Int: [Int]] = [:]
        for i in 0..<n { members[find(i), default: []].append(i) }

        // Largest components first so the giant component sits near the centre
        // and the long tail of singletons haloes around it.
        let groups = members.values.sorted { $0.count > $1.count }

        let goldenAngle = .pi * (3.0 - (5.0 as Double).squareRoot())
        var componentOf = [Int](repeating: 0, count: n)
        var nodeAnchor = [Vector2](repeating: .zero, count: n)
        var seed = [Vector2](repeating: .zero, count: n)

        // Walk a spiral, stepping out by each component's radius so discs do
        // not overlap. `gap` keeps a little air between islands.
        var running = 0.0
        let gap = spread * 0.6
        for (cid, group) in groups.enumerated() {
            let radius = max(spread * 0.4, spread * 0.6 * Double(group.count).squareRoot())
            running += radius
            let theta = Double(cid) * goldenAngle
            let anchor = Vector2(running * cos(theta), running * sin(theta))
            running += radius + gap

            for (rank, node) in group.enumerated() {
                componentOf[node] = cid
                nodeAnchor[node] = anchor
                // Seed on a small inner spiral around the anchor so the
                // component starts compact but not coincident (lets repulsion
                // open it cleanly); deterministic per (rank).
                let jr = radius * 0.6 * (Double(rank) / Double(max(group.count, 1))).squareRoot()
                let jt = Double(rank) * goldenAngle
                seed[node] = anchor + Vector2(jr * cos(jt), jr * sin(jt))
            }
        }
        return (componentOf, nodeAnchor, seed)
    }

    // MARK: - Reheat / pin

    /// Reheat the layout: `alpha = 1`, cooling toward `0`. Called on load,
    /// selection, drag and resize per the layout-engine spec.
    mutating func reheat(to value: Double = 1) {
        alpha = value
        alphaTarget = 0
    }

    /// Pin `index` at `target` (model space) and reheat. The pinned node is
    /// held exactly there each step but still repels / anchors springs. Its
    /// whole component re-gravitates to `target` so the focal neighbourhood
    /// gathers around it; other components stay at their anchors.
    mutating func pin(index: Int, at target: Vector2, neighbors: [Int]) {
        pinnedIndex = index
        pinnedTarget = target
        positions[index] = target
        velocities[index] = .zero
        let impulse = parameters.neighborImpulse
        if impulse > 0 {
            for j in neighbors where j != index {
                let dir = (positions[j] - target).normalized
                let kick = dir == .zero
                    ? Vector2(Double(j % 7) - 3, Double(j % 5) - 2).normalized
                    : dir
                velocities[j] += kick * impulse
            }
        }
        reheat()
    }

    /// Move the pin (e.g. the viewport centre changed) without re-impulsing.
    mutating func movePin(to target: Vector2) {
        guard let idx = pinnedIndex else { return }
        pinnedTarget = target
        positions[idx] = target
        velocities[idx] = .zero
    }

    /// Clear any pin and reheat (click on empty space).
    mutating func unpin() {
        pinnedIndex = nil
        reheat()
    }

    // MARK: - Step

    /// Advance one fixed-dt step. No-ops (returns `false`) when already
    /// settled so an idle graph performs zero work. Returns whether positions
    /// changed (⇒ the engine should invalidate its snapshot).
    @discardableResult
    mutating func step() -> Bool {
        guard !isSettled else { return false }

        tree.rebuild(positions: positions, masses: masses)

        // Per-node gravity centre = its component's packed anchor, so the many
        // disconnected components settle as separated islands instead of one
        // pile. When a node is focused, its whole component re-gravitates to
        // the pin so the focal neighbourhood gathers around it.
        let pinnedComponent = pinnedIndex.map { componentOf[$0] }
        for i in 0..<centers.count {
            if let pc = pinnedComponent, componentOf[i] == pc {
                centers[i] = pinnedTarget
            } else {
                centers[i] = nodeAnchor[i]
            }
        }

        Forces.accumulate(
            positions: positions,
            masses: masses,
            springs: springs,
            parameters: parameters,
            centers: centers,
            tree: tree,
            forces: &forces,
            stack: &stack
        )
        alpha = Integrator.step(
            positions: &positions,
            velocities: &velocities,
            forces: forces,
            masses: masses,
            parameters: parameters,
            alpha: alpha,
            alphaTarget: alphaTarget,
            pinnedIndex: pinnedIndex,
            pinnedTarget: pinnedTarget
        )
        return true
    }
}
