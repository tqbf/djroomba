import Foundation

// MARK: - GenreMapForceLayout

/// The djroomba-owned constrained force layout for the genre map
/// (`plans/genre-metro-map.md` Phase 1, step 6). Pure — no SwiftUI, no
/// observation, no globals. Takes nodes (weights + label rectangles +
/// community ids) + the layout graph, returns positions and a final KE
/// reading.
///
/// Force terms:
///
/// - **Edge attraction** ∝ `total_weight` over the layout graph (linear
///   spring with a target length scaled by the average label radius).
/// - **Node repulsion** that accounts for the **label rectangle** size —
///   the headline correctness item. Each node is modelled by its label
///   AABB (padded), and an axis-aligned overlap projects a stronger
///   repulsive impulse along whichever axis has the smaller overlap; a
///   weak, decaying separation force kicks in within a margin.
/// - **Community gravity** — soft pull toward the medium-resolution
///   community centroid (the centroid is recomputed each step).
/// - **Macro-region gravity** — derived from the macro positions a
///   coarser layout produced first (Phase 1 does a small recursive
///   layout over the community supernodes; those positions seed the
///   per-community anchors).
///
/// Integration: velocity Verlet with strong damping (~0.85 / step) and a
/// per-step velocity cap. Run until kinetic energy < ε for `settleWindow`
/// consecutive steps OR `maxSteps` reached, whichever comes first.
enum GenreMapForceLayout {

  // MARK: Internal

  struct Configuration: Sendable {
    /// Outer area's nominal world-space side (pre-zoom). Drives the
    /// initial spread + the macro anchor offsets.
    var worldSide: CGFloat = 2000
    /// Edge spring strength. Multiplied by `totalWeight` per edge.
    var edgeAttraction = 0.06
    /// Target edge length (pre-weight). Bigger ⇒ more spread. Tuned up
    /// after the first live verification — the original 220 produced
    /// readable communities but heavy label collisions at the cluster
    /// centres on a real ~120-genre library.
    var idealEdgeLength: Double = 320
    /// Strength of the soft community-centroid pull.
    var communityGravity = 0.008
    /// Strength of the macro-anchor pull (seeded from the coarse pass).
    var macroGravity = 0.020
    /// Strength of label-rectangle repulsion when boxes overlap. Bumped
    /// from 8000 → 14000 after the first live verification; labels
    /// inside dense clusters were still overlapping at 8000.
    var labelRepulsion: Double = 14000
    /// Extra padding (world units) around each label box for spacing.
    var labelPadding: CGFloat = 12
    /// Per-step velocity damping (0…1, smaller = more damping).
    var damping = 0.85
    /// Cap on per-step velocity magnitude (prevents instability).
    var maxStepSpeed: Double = 40
    /// Internal flag — set on the inner (super-node) pass so the kernel
    /// skips the macro-anchor recursion. Public API users never set this.
    var skipMacroAnchors = false
    /// Integration step count cap. Hit by very large graphs / pathological
    /// inputs; settle threshold below ends most runs much earlier.
    var maxSteps = 900
    /// Kinetic-energy threshold: when total KE stays below this for
    /// `settleWindow` consecutive steps, the layout is "settled".
    var settleEpsilon = 0.5
    var settleWindow = 8
    /// Seed for the deterministic initial scatter.
    var rngSeed: UInt64 = 0xD9_C1_57_2A_3C_22_77_77
    /// Post-settle label-collision compaction pass (Phase 2 carry-forward
    /// from the Phase-1 gate's "labels-don't-collide PARTIAL"). After
    /// the main settle the layout has reached a community-gravity vs.
    /// label-repulsion equilibrium that can still leave overlapping
    /// labels in the dense centre. We run a short repulsion-only polish
    /// pass with gravity disabled: labels can slide apart along the
    /// existing geographic axes without the community/macro pulls
    /// fighting them back together. Bounded, deterministic, runs once.
    var compactionIterations = 40
  }

  struct InputNode: Sendable {
    var id: String
    /// Importance in `[0, 1]` (drives target font size + spring weight).
    var weight: Double
    /// Label rectangle size (world units; the panel measures the label
    /// at its target font size and passes that here — so repulsion is
    /// genuinely label-first, not circle-radius-first).
    var labelSize: CGSize
    /// Medium-resolution community id (centroid gravity target).
    var communityID: Int
  }

  struct Output: Sendable {
    var positions: [String: CGPoint]
    var finalKineticEnergy: Double
    var steps: Int
    var settled: Bool
  }

  /// Lay out a graph. `edges` should already be the **layout** graph
  /// (sparse — see `GenreMapLayoutGraph`); throwing the full edge set at
  /// the physics is the failure mode the plan calls out.
  static func layout(
    nodes: [InputNode],
    edges: [GenreMapEdge],
    configuration: Configuration = Configuration(),
  ) -> Output {
    guard !nodes.isEmpty else {
      return Output(positions: [:], finalKineticEnergy: 0, steps: 0, settled: true)
    }

    // Stable index → name table for tight per-node arrays.
    let inputs = nodes.sorted { $0.id < $1.id }
    let n = inputs.count
    var nameByIndex = [String](repeating: "", count: n)
    var indexByName = [String: Int](minimumCapacity: n)
    for (index, node) in inputs.enumerated() {
      nameByIndex[index] = node.id
      indexByName[node.id] = index
    }

    // Edge index list with weights (canonical halves; no duplication).
    var edgeIndexA = [Int]()
    var edgeIndexB = [Int]()
    var edgeWeight = [Double]()
    edgeIndexA.reserveCapacity(edges.count)
    edgeIndexB.reserveCapacity(edges.count)
    edgeWeight.reserveCapacity(edges.count)
    for edge in edges {
      if let lhs = indexByName[edge.genreA], let rhs = indexByName[edge.genreB] {
        edgeIndexA.append(lhs)
        edgeIndexB.append(rhs)
        edgeWeight.append(edge.totalWeight)
      }
    }

    // Compute the macro anchor for each community by running the SAME
    // constrained-force kernel on the supernode graph first (smaller
    // problem; same code path, different inputs). The inner call sets
    // `skipMacroAnchors` to break the obvious recursion.
    let macroAnchorByCommunity: [Int: CGPoint] =
      if configuration.skipMacroAnchors {
        [:]
      } else {
        macroAnchors(
          inputs: inputs,
          edges: edges,
          configuration: configuration,
        )
      }

    // Per-node mutable state.
    var positionX = [Double](repeating: 0, count: n)
    var positionY = [Double](repeating: 0, count: n)
    var velocityX = [Double](repeating: 0, count: n)
    var velocityY = [Double](repeating: 0, count: n)
    var rng = SplitMix64(seed: configuration.rngSeed)

    // Initial scatter inside a circle at the community macro anchor
    // (when known) or the origin. Scaled by `worldSide`.
    let radius = Double(configuration.worldSide) * 0.45
    for index in 0 ..< n {
      let anchor = macroAnchorByCommunity[inputs[index].communityID]
        ?? .zero
      let theta = Double(rng.nextUnitFraction()) * 2 * .pi
      let rho = sqrt(Double(rng.nextUnitFraction())) * radius * 0.12
      positionX[index] = Double(anchor.x) + cos(theta) * rho
      positionY[index] = Double(anchor.y) + sin(theta) * rho
    }

    // Per-step half-box (padded) for repulsion math.
    var halfBoxX = [Double](repeating: 0, count: n)
    var halfBoxY = [Double](repeating: 0, count: n)
    for index in 0 ..< n {
      halfBoxX[index] = Double(inputs[index].labelSize.width) / 2
        + Double(configuration.labelPadding)
      halfBoxY[index] = Double(inputs[index].labelSize.height) / 2
        + Double(configuration.labelPadding)
    }

    // Pre-compute per-node ideal-length adjustment factor (heavier
    // genres get a slightly longer ideal length so big pills don't
    // collapse onto each other).
    let baseIdeal = configuration.idealEdgeLength
    let macroAnchorByIndex = (0 ..< n).map { index in
      macroAnchorByCommunity[inputs[index].communityID] ?? .zero
    }

    // Settle bookkeeping.
    var quietSteps = 0
    var totalSteps = 0
    var settled = false
    var lastKE = 0.0

    let maxStepSpeedSquared = configuration.maxStepSpeed * configuration.maxStepSpeed
    let damping = configuration.damping
    let macroGravity = configuration.macroGravity

    while totalSteps < configuration.maxSteps {
      totalSteps += 1
      var forceX = [Double](repeating: 0, count: n)
      var forceY = [Double](repeating: 0, count: n)

      // 1) Edge attraction (linear spring on |d| − ideal, scaled by w).
      for edgeIndex in 0 ..< edgeIndexA.count {
        let lhs = edgeIndexA[edgeIndex]
        let rhs = edgeIndexB[edgeIndex]
        let weight = edgeWeight[edgeIndex]
        let dx = positionX[rhs] - positionX[lhs]
        let dy = positionY[rhs] - positionY[lhs]
        let distance = max(sqrt(dx * dx + dy * dy), 1.0e-3)
        // Heavier endpoints want a slightly longer ideal length so big
        // labels don't crowd in — read each endpoint's weight off the
        // input array.
        let weightBoost = (inputs[lhs].weight + inputs[rhs].weight) * 0.5
        let ideal = baseIdeal * (1 + 0.45 * weightBoost)
        let stretch = distance - ideal
        let force = configuration.edgeAttraction * weight * stretch
        let unitX = dx / distance
        let unitY = dy / distance
        forceX[lhs] += force * unitX
        forceY[lhs] += force * unitY
        forceX[rhs] -= force * unitX
        forceY[rhs] -= force * unitY
      }

      // 2) Label-rectangle repulsion (O(n²) — n < ~300 in practice).
      // For each pair, compute the AABB overlap with padding; when the
      // boxes intersect, project the repulsive impulse along whichever
      // axis has the *smaller* overlap (so overlapping pills slide
      // sideways the short way, not the long way — the perceptual win).
      for lhs in 0 ..< n {
        for rhs in (lhs + 1) ..< n {
          let dx = positionX[rhs] - positionX[lhs]
          let dy = positionY[rhs] - positionY[lhs]
          let overlapX = (halfBoxX[lhs] + halfBoxX[rhs]) - abs(dx)
          let overlapY = (halfBoxY[lhs] + halfBoxY[rhs]) - abs(dy)
          if overlapX > 0, overlapY > 0 {
            // Inside each other's padded box — strong axis-aligned push.
            let dxSign: Double = dx >= 0 ? 1 : -1
            let dySign: Double = dy >= 0 ? 1 : -1
            if overlapX < overlapY {
              let push = configuration.labelRepulsion * overlapX / max(overlapY, 1)
              forceX[lhs] -= push * dxSign
              forceX[rhs] += push * dxSign
            } else {
              let push = configuration.labelRepulsion * overlapY / max(overlapX, 1)
              forceY[lhs] -= push * dySign
              forceY[rhs] += push * dySign
            }
          } else {
            // Soft inverse-distance falloff once boxes are separated, so
            // labels don't drift right onto each other on the next step.
            let dist = sqrt(dx * dx + dy * dy) + 1.0e-3
            let avgHalf = (halfBoxX[lhs] + halfBoxX[rhs] + halfBoxY[lhs] + halfBoxY[rhs]) * 0.25
            let influence = max(0, 1 - dist / (avgHalf * 2.4))
            if influence > 0 {
              let push = configuration.labelRepulsion * 0.02 * influence
              let invDist = 1 / dist
              forceX[lhs] -= push * dx * invDist
              forceY[lhs] -= push * dy * invDist
              forceX[rhs] += push * dx * invDist
              forceY[rhs] += push * dy * invDist
            }
          }
        }
      }

      // 3) Community centroids (recomputed each step) for centroid pull.
      var centroidSumX = [Int: Double]()
      var centroidSumY = [Int: Double]()
      var centroidCount = [Int: Int]()
      for index in 0 ..< n {
        let community = inputs[index].communityID
        centroidSumX[community, default: 0] += positionX[index]
        centroidSumY[community, default: 0] += positionY[index]
        centroidCount[community, default: 0] += 1
      }
      var communityCentroid = [Int: (x: Double, y: Double)]()
      for (community, count) in centroidCount where count > 0 {
        communityCentroid[community] = (
          (centroidSumX[community] ?? 0) / Double(count),
          (centroidSumY[community] ?? 0) / Double(count),
        )
      }

      // 4) Community gravity + macro anchor pull (both linear).
      for index in 0 ..< n {
        let community = inputs[index].communityID
        if let centroid = communityCentroid[community] {
          forceX[index] -= configuration.communityGravity * (positionX[index] - centroid.x)
          forceY[index] -= configuration.communityGravity * (positionY[index] - centroid.y)
        }
        let anchor = macroAnchorByIndex[index]
        forceX[index] -= macroGravity * (positionX[index] - Double(anchor.x))
        forceY[index] -= macroGravity * (positionY[index] - Double(anchor.y))
      }

      // 5) Integrate (velocity Verlet, strongly damped) + cap velocity.
      var kineticEnergy = 0.0
      for index in 0 ..< n {
        velocityX[index] = (velocityX[index] + forceX[index]) * damping
        velocityY[index] = (velocityY[index] + forceY[index]) * damping
        let speedSquared = velocityX[index] * velocityX[index]
          + velocityY[index] * velocityY[index]
        if speedSquared > maxStepSpeedSquared {
          let scale = configuration.maxStepSpeed / sqrt(speedSquared)
          velocityX[index] *= scale
          velocityY[index] *= scale
        }
        positionX[index] += velocityX[index]
        positionY[index] += velocityY[index]
        kineticEnergy += velocityX[index] * velocityX[index]
          + velocityY[index] * velocityY[index]
      }

      lastKE = kineticEnergy
      if kineticEnergy < configuration.settleEpsilon {
        quietSteps += 1
        if quietSteps >= configuration.settleWindow {
          settled = true
          break
        }
      } else {
        quietSteps = 0
      }
    }

    // Post-settle compaction polish pass (Phase 2 carry-forward).
    // Gravity disabled; only the label-AABB repulsion runs. The settled
    // geography is preserved (each node moves at most by the overlap it
    // needs to clear), but labels that were still touching at the end
    // of the equilibrium step slide apart along the short overlap axis.
    // Inner-pass macro layouts (`skipMacroAnchors = true`) skip this —
    // they're tiny graphs at scaled-up ideal lengths where polish would
    // just churn.
    if !configuration.skipMacroAnchors, configuration.compactionIterations > 0 {
      for _ in 0 ..< configuration.compactionIterations {
        var anyOverlap = false
        for lhs in 0 ..< n {
          for rhs in (lhs + 1) ..< n {
            let dx = positionX[rhs] - positionX[lhs]
            let dy = positionY[rhs] - positionY[lhs]
            let overlapX = (halfBoxX[lhs] + halfBoxX[rhs]) - abs(dx)
            let overlapY = (halfBoxY[lhs] + halfBoxY[rhs]) - abs(dy)
            guard overlapX > 0, overlapY > 0 else { continue }
            anyOverlap = true
            // Slide apart along whichever axis has the smaller overlap
            // (the shorter way out of the collision). Half the overlap
            // goes to each side, so neither gets pushed all the way
            // through the other.
            if overlapX < overlapY {
              let sign: Double = dx >= 0 ? 1 : -1
              let push = overlapX * 0.55
              positionX[lhs] -= push * sign * 0.5
              positionX[rhs] += push * sign * 0.5
            } else {
              let sign: Double = dy >= 0 ? 1 : -1
              let push = overlapY * 0.55
              positionY[lhs] -= push * sign * 0.5
              positionY[rhs] += push * sign * 0.5
            }
          }
        }
        if !anyOverlap { break }
      }
    }

    var positions = [String: CGPoint](minimumCapacity: n)
    for index in 0 ..< n {
      positions[nameByIndex[index]] = CGPoint(
        x: positionX[index],
        y: positionY[index],
      )
    }
    return Output(
      positions: positions,
      finalKineticEnergy: lastKE,
      steps: totalSteps,
      settled: settled,
    )
  }

  /// Drag affordance (`plans/genre-metro-map.md` "drag pins the dragged
  /// node, relaxes its neighbours within radius, leaves the rest
  /// unmoved"). Re-runs a small, cheap, scoped settle pass: only the
  /// `dragged` node's 1-hop layout neighbours can move; everything else
  /// is pinned. Iterations are bounded — this is interactive code, must
  /// stay snappy.
  static func relaxDragNeighbours(
    positions: [String: CGPoint],
    dragged: String,
    layoutEdges: [GenreMapEdge],
    inputs: [InputNode],
    iterations: Int = 6,
  ) -> [String: CGPoint] {
    var neighbourSet = Set<String>()
    for edge in layoutEdges {
      if edge.genreA == dragged { neighbourSet.insert(edge.genreB) }
      else if edge.genreB == dragged { neighbourSet.insert(edge.genreA) }
    }
    guard !neighbourSet.isEmpty else { return positions }

    let inputByID = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, $0) })
    var working = positions
    let dragPosition = positions[dragged] ?? .zero

    // Single very-short tour: pull neighbours back toward each other's
    // ideal edge length from the dragged node + soft de-overlap.
    let ideal = 220.0
    for _ in 0 ..< iterations {
      for neighbour in neighbourSet {
        guard let current = working[neighbour] else { continue }
        let dx = current.x - dragPosition.x
        let dy = current.y - dragPosition.y
        let distance = max(sqrt(dx * dx + dy * dy), 1.0e-3)
        let stretch = distance - ideal
        let factor = 0.18 * stretch / distance
        working[neighbour] = CGPoint(
          x: current.x - factor * dx,
          y: current.y - factor * dy,
        )

        // De-overlap against any *other* moving neighbour (cheap O(k²)).
        guard let input = inputByID[neighbour] else { continue }
        for other in neighbourSet where other != neighbour {
          guard
            let otherPosition = working[other],
            let otherInput = inputByID[other]
          else { continue }
          let ddx = otherPosition.x - working[neighbour]!.x
          let ddy = otherPosition.y - working[neighbour]!.y
          let halfX = (input.labelSize.width + otherInput.labelSize.width) / 2 + 8
          let halfY = (input.labelSize.height + otherInput.labelSize.height) / 2 + 8
          let overlapX = halfX - abs(ddx)
          let overlapY = halfY - abs(ddy)
          if overlapX > 0, overlapY > 0 {
            let signX: CGFloat = ddx >= 0 ? 1 : -1
            let signY: CGFloat = ddy >= 0 ? 1 : -1
            if overlapX < overlapY {
              let push = overlapX * 0.5
              working[neighbour] = CGPoint(
                x: working[neighbour]!.x - push * signX,
                y: working[neighbour]!.y,
              )
            } else {
              let push = overlapY * 0.5
              working[neighbour] = CGPoint(
                x: working[neighbour]!.x,
                y: working[neighbour]!.y - push * signY,
              )
            }
          }
        }
      }
    }
    return working
  }

  // MARK: Private

  private struct SuperEdgeKey: Hashable {
    init(lhs: Int, rhs: Int) {
      if lhs <= rhs { smaller = lhs
        larger = rhs
      } else { smaller = rhs
        larger = lhs
      }
    }

    let smaller: Int
    let larger: Int
  }

  /// Coarse pass: collapse each community into a single super-node, run
  /// the SAME constrained kernel over it, and return the resulting
  /// super-node positions as per-community anchors for the main pass.
  /// The graph is small (one super-node per community), so this finishes
  /// in well under a millisecond at realistic library scale.
  private static func macroAnchors(
    inputs: [InputNode],
    edges: [GenreMapEdge],
    configuration: Configuration,
  ) -> [Int: CGPoint] {
    // Group nodes by community.
    var memberCount = [Int: Int]()
    var weightSum = [Int: Double]()
    var maxLabel = [Int: CGSize]()
    for node in inputs {
      memberCount[node.communityID, default: 0] += 1
      weightSum[node.communityID, default: 0] += max(node.weight, 0.001)
      var size = maxLabel[node.communityID] ?? .zero
      size.width = max(size.width, node.labelSize.width)
      size.height = max(size.height, node.labelSize.height)
      maxLabel[node.communityID] = size
    }
    let communityIDs = memberCount.keys.sorted()
    guard communityIDs.count > 1 else {
      // Single community ⇒ everyone anchors at origin.
      if let only = communityIDs.first { return [only: .zero] }
      return [:]
    }

    // Sum inter-community edge weight ⇒ super-edges.
    var superEdgeWeight = [SuperEdgeKey: Double]()
    for edge in edges {
      guard
        let lhsNode = inputs.first(where: { $0.id == edge.genreA }),
        let rhsNode = inputs.first(where: { $0.id == edge.genreB }),
        lhsNode.communityID != rhsNode.communityID
      else { continue }
      let key = SuperEdgeKey(lhs: lhsNode.communityID, rhs: rhsNode.communityID)
      superEdgeWeight[key, default: 0] += edge.totalWeight
    }

    // Synthetic InputNode per community (label size = scaled member-count
    // proxy so big communities settle apart).
    let superInputs = communityIDs.map { id -> InputNode in
      let count = memberCount[id] ?? 1
      let width = 80 + 6 * CGFloat(count)
      return InputNode(
        id: "__community_\(id)",
        weight: min(1.0, Double(count) / 60.0),
        labelSize: CGSize(width: width, height: 40),
        communityID: id,
      )
    }
    let superEdges = superEdgeWeight.map { entry -> GenreMapEdge in
      GenreMapEdge(
        genreA: "__community_\(entry.key.smaller)",
        genreB: "__community_\(entry.key.larger)",
        totalWeight: entry.value,
      )
    }

    // Recurse with macroGravity disabled (this IS the macro pass) and
    // shorter step count. `skipMacroAnchors` breaks the recursion.
    var inner = configuration
    inner.macroGravity = 0
    inner.maxSteps = 240
    inner.worldSide = configuration.worldSide * 1.4
    inner.idealEdgeLength = configuration.idealEdgeLength * 2.4
    inner.communityGravity = 0
    inner.skipMacroAnchors = true
    let output = layout(nodes: superInputs, edges: superEdges, configuration: inner)
    var anchors = [Int: CGPoint]()
    for id in communityIDs {
      if let point = output.positions["__community_\(id)"] {
        anchors[id] = point
      }
    }
    return anchors
  }

}

// MARK: - SplitMix64

/// Deterministic seeded PRNG so the initial scatter (and therefore the
/// final layout, up to settled-state) is identical across runs given the
/// same inputs. SplitMix64 is the canonical 64-bit splittable generator.
struct SplitMix64 {

  // MARK: Lifecycle

  init(seed: UInt64) {
    state = seed
  }

  // MARK: Internal

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z &>> 31)
    return z
  }

  mutating func nextUnitFraction() -> Double {
    // 53 bits of mantissa precision; everything else is wasted.
    Double(next() &>> 11) / Double(1 << 53)
  }

  // MARK: Private

  private var state: UInt64
}
