import CoreGraphics
import Foundation

// MARK: - GenreTreeLayout

/// Pure geometric placement for the trunk-tree
/// (`plans/son-of-genre-map.md` Phase B — "Visual grammar" + "Tree
/// construction from trunks"). Consumes a `GenreTreeModel` from
/// `GenreTreeBuilder` and emits world-space coordinates for every node
/// + Bezier control points for every parent → child curve.
///
/// **Why pure geometry, not force-directed.** The metro plan's
/// `GenreMapForceLayout` was a ~30-iteration constrained-physics pass.
/// This plan replaces it with deterministic O(n) trig — no solver, no
/// random reseed, no convergence test. Same canvas, same "scrolling
/// is fine" posture, but the layout is byte-identical across runs and
/// disappears as a perf line item (the routing/bundling cost that
/// dominated Phase 4 evaporates entirely).
///
/// **Trunk placement — even-spaced along the diagonal.** Trunks land
/// on the `(0, 0) → (worldSide, worldSide)` diagonal, *evenly spaced*
/// (not weight-spaced). The plan calls out the simpler readable
/// default; weight-spacing would compress trunks together near the
/// origin (giants cluster, lighter trunks crowd the far end) without
/// improving legibility — and the spacing is what the reader scans, so
/// even spacing reads better. Documented choice; reverse with a config
/// flag if a later screenshot review disagrees.
///
/// **Branch fanning — alternating sides + ~120° default arc.** Per
/// trunk arc bisector aims **perpendicular to the diagonal**,
/// alternating side (trunk 0 → "up-left of the diagonal", trunk 1 →
/// "down-right", trunk 2 → "up-left", …) so ink is balanced across
/// the canvas instead of all branches piling into one quadrant. Each
/// depth-1 branch fans over the full `branchArcWidth` around the
/// trunk; depth-2 branches fan over `branchArcWidth / 2` around their
/// parent; depth-3+ same recursion, each level halving the arc
/// allotment.
///
/// **Heaviest-near-12.** Inside each parent's arc, branches are
/// ordered by per-genre weight desc (the builder already sorts
/// children that way). The heaviest branch lands at the **arc
/// bisector** — the parent's local "12 o'clock" — with siblings
/// fanning symmetrically outward. The eye reads the heaviest sub-genre
/// first; the long tail spreads to the periphery.
///
/// **Branch curves — Catmull-Rom in spirit, cubic Bezier in code.**
/// Each parent → child edge is a single cubic Bezier whose control
/// points project along the parent's outward direction (`c1`) and the
/// child's inward direction (`c2`), at a fraction of the
/// parent–child distance. That matches the Phase-4 spline survivor
/// (`StrandSpline.catmullRomPath` is centripetal Catmull-Rom; a
/// single cubic Bezier per segment is what that decomposes to anyway).
/// The renderer (`BranchEdge`) consumes the raw control points without
/// re-running the spline kernel — keeps the new code self-contained
/// and avoids a hard dependency on the retiring metro renderer.
///
/// Everything is `nonisolated static` + free of mutable globals:
/// deterministic given identical inputs, unit-testable without
/// SwiftUI / GRDB / MusicKit.
enum GenreTreeLayout {

  // MARK: Internal

  /// Knob-laden configuration for the layout pass. Defaults match the
  /// plan + "scrolling is fine" posture; tests instantiate custom
  /// configurations to exercise edge cases (very small canvas, no
  /// alternation, etc.).
  struct Configuration: Sendable {

    // MARK: Lifecycle

    init(
      worldSide: CGFloat = 14000,
      diagonalPadding: CGFloat = 1100,
      branchArcWidthDegrees: Double = 120,
      depthArcShrink: Double = 0.65,
      depth1Radius: CGFloat = 700,
      depthRadiusShrink: CGFloat = 0.65,
      minChildSpacing: CGFloat = 360,
      horizontalStretch: CGFloat = 1.0,
      controlPointFraction: CGFloat = 0.45,
      alternateSides: Bool = true,
    ) {
      self.worldSide = worldSide
      self.diagonalPadding = diagonalPadding
      self.branchArcWidthDegrees = branchArcWidthDegrees
      self.depthArcShrink = depthArcShrink
      self.depth1Radius = depth1Radius
      self.depthRadiusShrink = depthRadiusShrink
      self.minChildSpacing = minChildSpacing
      self.horizontalStretch = horizontalStretch
      self.controlPointFraction = controlPointFraction
      self.alternateSides = alternateSides
    }

    // MARK: Internal

    /// Canvas side length (square). **Deliberately huge** — the map is
    /// larger than any reasonable viewport and the user pans / zooms /
    /// scrolls to discover (the standing "scrolling is fine" directive).
    /// Widened from the metro-era `7000` to `14000` so adjacent trunk
    /// fans get room to breathe instead of colliding near the diagonal.
    var worldSide: CGFloat
    /// Inset from the canvas corners along the diagonal — keeps the
    /// first / last trunks from touching the world edge.
    var diagonalPadding: CGFloat
    /// Depth-1 arc width in degrees (`~120°` per the plan). Depth-2 +
    /// shrink to `branchArcWidthDegrees * depthArcShrink`; depth-3+
    /// continue the recursion.
    var branchArcWidthDegrees: Double
    /// Multiplicative factor applied to the arc width on each recursion
    /// step. Default `0.5` ⇒ depth-1 120°, depth-2 60°, depth-3 30°.
    var depthArcShrink: Double
    /// **Floor** distance from a trunk to its depth-1 branches. The
    /// effective radius is `max(depth1Radius, requiredForSpacing)` —
    /// see `adaptiveRadius`. A bushy parent pushes its fan further out
    /// so the children never crowd; a sparse parent keeps this floor.
    var depth1Radius: CGFloat
    /// Multiplicative factor applied to the radius on each recursion
    /// step. Default `0.7` ⇒ depth-2 children sit at `0.7 × depth1Radius`
    /// from their depth-1 parent. Slight shrink keeps the recursion
    /// from outrunning the canvas while still spreading.
    var depthRadiusShrink: CGFloat
    /// Minimum world-space gap to leave between two adjacent siblings on
    /// a fan. The arc geometry needs the fan radius to grow with the
    /// child count so a 12-child trunk doesn't pack its branches on top
    /// of each other (the "TOO TIGHT" failure mode); `adaptiveRadius`
    /// derives the radius that yields this gap and uses the larger of it
    /// and the depth's base radius. Held **flat across depths** — a deep
    /// genre label is the same kind of long string as a shallow one, so
    /// shrinking the gap with depth (an earlier mistake) collapsed deep
    /// fans back into a pile.
    var minChildSpacing: CGFloat
    /// Horizontal stretch applied to the whole layout as the very last
    /// step. The fan geometry is computed in **circular** space (clean
    /// trig, deterministic, unit-tested), then every x-coordinate is
    /// multiplied by this factor — turning each circular fan into a
    /// **wide ellipse** and the 45° trunk diagonal into a shallow one.
    /// The docked pane is wide and short, so a circle wastes the
    /// horizontal room and overflows vertically (and near-vertical
    /// sibling stacks are exactly what collide); the wide ellipse fills
    /// the space and pulls those stacks apart sideways. Default `1.0`
    /// keeps the pure-geometry layout circular (so the geometry tests
    /// describe un-stretched coordinates); the view-facing
    /// `GenreTreeService` supplies the real wide value, because "how
    /// wide is our canvas" is a presentation concern, not a property of
    /// the tree.
    var horizontalStretch: CGFloat
    /// Cubic-Bezier control-point distance, as a fraction of the
    /// parent → child line length. `0.45` ≈ a soft S-curve that hints
    /// the radial direction at both endpoints without spiking.
    var controlPointFraction: CGFloat
    /// `true` ⇒ alternate which side of the diagonal a trunk's fan
    /// occupies, so ink balances across the canvas. `false` ⇒ every
    /// trunk fans on the "up-left" side (only useful for tests).
    var alternateSides: Bool
  }

  /// One node's laid-out position + the curve that connects it to its
  /// parent (nil on a trunk). World coordinates; the renderer applies
  /// pan / zoom on top.
  struct PlacedNode: Equatable, Sendable {
    var genre: Genre
    var depth: Int
    var position: CGPoint
    /// `nil` ⇒ trunk. Otherwise the parent's placed name (lookup by
    /// `placedByName[parentGenreName]` in the renderer).
    var parentGenre: String?
    /// Cubic-Bezier curve from `parentGenre`'s position to `position`.
    /// `nil` on a trunk.
    var edge: BezierCurve?
  }

  /// A single cubic Bezier segment: `start → control1 → control2 → end`.
  struct BezierCurve: Equatable, Sendable {
    var start: CGPoint
    var control1: CGPoint
    var control2: CGPoint
    var end: CGPoint
  }

  /// Layout output: every placed node + the canvas's world bounding
  /// box (for fit-to-view affordances) + the diagonal endpoints (for
  /// debug overlays / golden-test pinning).
  struct Output: Equatable, Sendable {
    var placedNodes: [PlacedNode]
    var worldBounds: CGRect
    var diagonalStart: CGPoint
    var diagonalEnd: CGPoint
  }

  /// Lay out a `GenreTreeModel` against the configuration. Pure,
  /// deterministic — same input twice ⇒ identical `Output`.
  static func layout(
    model: GenreTreeModel,
    configuration: Configuration = Configuration(),
  ) -> Output {
    let trunks = model.trunks
    let diagonalStart = CGPoint(
      x: configuration.diagonalPadding,
      y: configuration.diagonalPadding,
    )
    let diagonalEnd = CGPoint(
      x: configuration.worldSide - configuration.diagonalPadding,
      y: configuration.worldSide - configuration.diagonalPadding,
    )
    guard !trunks.isEmpty else {
      return Output(
        placedNodes: [],
        worldBounds: CGRect(
          x: 0,
          y: 0,
          width: configuration.worldSide,
          height: configuration.worldSide,
        ),
        diagonalStart: diagonalStart,
        diagonalEnd: diagonalEnd,
      )
    }

    var placed = [PlacedNode]()
    placed.reserveCapacity(64)

    // Even-spaced trunk centres along the diagonal. With k trunks the
    // i-th trunk sits at parameter `(i + 1) / (k + 1)` along the
    // diagonal — endpoints reserved as padding, never touched by a
    // trunk pill (which prevents the first / last pills from cropping
    // against the canvas edge).
    let trunkCount = trunks.count
    let diagonalDx = diagonalEnd.x - diagonalStart.x
    let diagonalDy = diagonalEnd.y - diagonalStart.y
    for (index, trunk) in trunks.enumerated() {
      let parameter = CGFloat(index + 1) / CGFloat(trunkCount + 1)
      let trunkPosition = CGPoint(
        x: diagonalStart.x + diagonalDx * parameter,
        y: diagonalStart.y + diagonalDy * parameter,
      )
      let side: Side = configuration.alternateSides
        ? (index.isMultiple(of: 2) ? .aboveDiagonal : .belowDiagonal)
        : .aboveDiagonal
      placeSubtree(
        node: trunk.root,
        position: trunkPosition,
        parentGenre: nil,
        parentBisector: side.normalAngle,
        depth: 0,
        configuration: configuration,
        into: &placed,
      )
    }

    // Wide-ellipse pass: the fan geometry above is circular; stretch
    // every x-coordinate to fill the wide / short pane (see
    // `Configuration.horizontalStretch`). A horizontal affine scale maps
    // circles to wide ellipses and preserves the Bézier curves, so the
    // edges still meet their (stretched) endpoints. `1.0` is a no-op.
    let stretch = configuration.horizontalStretch
    let stretchedNodes = stretch == 1.0
      ? placed
      : placed.map { node in
        var node = node
        node.position = stretchX(node.position, by: stretch)
        if let edge = node.edge {
          node.edge = BezierCurve(
            start: stretchX(edge.start, by: stretch),
            control1: stretchX(edge.control1, by: stretch),
            control2: stretchX(edge.control2, by: stretch),
            end: stretchX(edge.end, by: stretch),
          )
        }
        return node
      }

    // World bounds = the (stretched) canvas. The renderer pans / zooms
    // over this rect; "scrolling is fine" — we don't try to fit pills
    // tighter.
    let bounds = CGRect(
      x: 0,
      y: 0,
      width: configuration.worldSide * stretch,
      height: configuration.worldSide,
    )
    return Output(
      placedNodes: stretchedNodes,
      worldBounds: bounds,
      diagonalStart: stretchX(diagonalStart, by: stretch),
      diagonalEnd: stretchX(diagonalEnd, by: stretch),
    )
  }

  /// Multiply a point's x by `factor`, leaving y untouched — the
  /// horizontal half of the wide-ellipse affine scale.
  static func stretchX(_ point: CGPoint, by factor: CGFloat) -> CGPoint {
    CGPoint(x: point.x * factor, y: point.y)
  }

  /// Position the `n` children around their parent's local 12 o'clock
  /// over `arcWidthRadians`. The 0-th child (heaviest, per the builder's
  /// child-ordering) lands on the bisector; subsequent children fan
  /// alternately right/left of it at increasing offsets. With four
  /// children the angle sequence relative to the bisector is
  /// `[0, +s, −s, +2s, −2s, …]` where `s = arcWidth / (n − 1)`. The
  /// heaviest branch is most legible (centred); lighter branches fall
  /// off symmetrically into the periphery.
  ///
  /// Single-child case → the child sits exactly on the bisector. Zero
  /// arc-width (very deep recursion) → all children collapse onto the
  /// bisector; pure layout doesn't iterate to separate, in practice
  /// the real library doesn't recurse that deep (the MST is bushy
  /// rather than chain-like).
  static func childPositions(
    parentPosition: CGPoint,
    childCount: Int,
    parentBisector: Double,
    arcWidthRadians: Double,
    radius: CGFloat,
  ) -> [CGPoint] {
    guard childCount > 0 else { return [] }
    if childCount == 1 {
      return [
        CGPoint(
          x: parentPosition.x + radius * CGFloat(cos(parentBisector)),
          y: parentPosition.y + radius * CGFloat(sin(parentBisector)),
        )
      ]
    }
    // Two-step assignment so the heaviest branch is *always* most
    // central (the slot closest to the bisector) regardless of whether
    // `childCount` is odd or even:
    //
    // 1) Compute `n` equally-spaced *angular slots* from `-arc/2` to
    //    `+arc/2`. These are the geometric positions the fan occupies.
    // 2) Re-rank the slots by absolute distance from the bisector
    //    (slot at 0 first, then ±step, then ±2·step, …) so the
    //    heaviest child (input index 0) gets the most-central slot,
    //    the next gets the next-most-central, alternating right/left
    //    of the bisector. This makes the heaviest branch most legible
    //    no matter the child count.
    let step = arcWidthRadians / Double(childCount - 1)
    let halfArc = arcWidthRadians / 2.0
    let slotAngles: [Double] = (0 ..< childCount).map { slotIndex in
      -halfArc + Double(slotIndex) * step
    }
    // Rank slots by absolute offset from the bisector (stable tie-break:
    // right-of-bisector beats left at equal absolute offset, so the
    // heavier of a pair lands on the right consistently across calls).
    let rankedSlots = slotAngles.enumerated().sorted { lhs, rhs in
      let lhsAbs = abs(lhs.element)
      let rhsAbs = abs(rhs.element)
      if lhsAbs != rhsAbs { return lhsAbs < rhsAbs }
      return lhs.element > rhs.element
    }
    var positions = [CGPoint](repeating: .zero, count: childCount)
    for childIndex in 0 ..< childCount {
      let slotAngle = rankedSlots[childIndex].element
      let angle = parentBisector + slotAngle
      positions[childIndex] = CGPoint(
        x: parentPosition.x + radius * CGFloat(cos(angle)),
        y: parentPosition.y + radius * CGFloat(sin(angle)),
      )
    }
    return positions
  }

  /// Cubic-Bezier curve from `start` to `end` with control points
  /// projected outward along the start → end direction. The Bezier
  /// gently leaves `start` toward `end` and gently enters `end` from
  /// the same direction; on a tree-edge segment that reads as a
  /// smooth curve close to a straight line, which is what we want
  /// (the radial geometry already encodes the structure; the curve is
  /// cosmetic).
  static func makeEdge(
    from start: CGPoint,
    to end: CGPoint,
    fraction: CGFloat,
  ) -> BezierCurve {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let control1 = CGPoint(
      x: start.x + dx * fraction,
      y: start.y + dy * fraction,
    )
    let control2 = CGPoint(
      x: end.x - dx * fraction,
      y: end.y - dy * fraction,
    )
    return BezierCurve(start: start, control1: control1, control2: control2, end: end)
  }

  /// Arc width at `depth`. Depth-1 = `branchArcWidthDegrees` (in
  /// radians); each subsequent depth multiplies by `depthArcShrink`.
  /// Depth-0 (the trunk itself) returns its children's arc, which is
  /// depth-1's width.
  static func childArcWidth(
    depth: Int,
    configuration: Configuration,
  ) -> Double {
    let base = configuration.branchArcWidthDegrees * .pi / 180.0
    if depth <= 0 { return base }
    return base * pow(configuration.depthArcShrink, Double(depth))
  }

  /// Radius at `depth`. Depth-0 → trunk → no radius needed (handled
  /// by the diagonal placement). Depth-1 → `depth1Radius`; each level
  /// shrinks by `depthRadiusShrink`.
  static func childRadius(
    depth: Int,
    configuration: Configuration,
  ) -> CGFloat {
    if depth <= 0 { return configuration.depth1Radius }
    return configuration.depth1Radius * pow(configuration.depthRadiusShrink, CGFloat(depth))
  }

  /// The radius a parent at `depth` should fan its `childCount` children
  /// out to. This is the breathing-room fix for the "TOO TIGHT" failure
  /// mode: a fan of `n` children spread over `arcWidth` only has
  /// `arcWidth · radius / (n − 1)` of arc length between neighbours, so a
  /// trunk with a dozen branches packed them on top of each other at the
  /// old fixed radius. We instead solve for the radius that leaves at
  /// least `minChildSpacing` (shrunk per depth, since deeper pills are
  /// smaller) between adjacent siblings, and take the larger of that and
  /// the depth's base radius so sparse fans keep their tidy floor.
  ///
  /// `childCount ≤ 1` ⇒ no spacing constraint, return the base radius
  /// (a lone child sits on the bisector at the floor distance).
  static func adaptiveRadius(
    depth: Int,
    childCount: Int,
    configuration: Configuration,
  ) -> CGFloat {
    let base = childRadius(depth: depth, configuration: configuration)
    guard childCount > 1 else { return base }
    let arcWidth = childArcWidth(depth: depth, configuration: configuration)
    guard arcWidth > 0 else { return base }
    // Flat spacing across depths (see `minChildSpacing`): a deep label
    // is just as long as a shallow one. Required radius = the radius at
    // which `childCount` equally-spaced points on the arc sit
    // `minChildSpacing` apart (small-angle chord ≈ arc length / count).
    let required = configuration.minChildSpacing
      * CGFloat(childCount - 1) / CGFloat(arcWidth)
    return max(base, required)
  }

  // MARK: Private

  /// Which side of the canvas diagonal a trunk's fan occupies. The
  /// canvas diagonal runs from `(0, 0)` (top-left of the canvas, in
  /// screen coordinates) to `(worldSide, worldSide)` (bottom-right);
  /// screen-y increases downward. The two perpendicular sides:
  ///
  /// - `.aboveDiagonal` → branches sit visually **above** the
  ///   diagonal (toward the upper-right of the canvas). Perpendicular
  ///   vector `(+1, -1)`, angle `-π/4`.
  /// - `.belowDiagonal` → branches sit visually **below** the diagonal
  ///   (toward the lower-left). Perpendicular vector `(-1, +1)`, angle
  ///   `+3π/4`.
  ///
  /// Alternating per trunk balances ink across the canvas so neither
  /// the upper-right nor the lower-left ends up empty.
  private enum Side {
    case aboveDiagonal
    case belowDiagonal

    var normalAngle: Double {
      switch self {
      case .aboveDiagonal: -.pi / 4.0
      case .belowDiagonal: 3.0 * .pi / 4.0
      }
    }
  }

  /// Recursive subtree placement. Lays out `node` at `position`, then
  /// fans its children around `parentBisector` over the depth-scaled
  /// arc.
  ///
  /// **Arc bisector inheritance.** A depth-1 branch's *own* fan
  /// bisector points outward from the trunk — same direction as the
  /// edge that brought us here. We pass that as the next recursion's
  /// `parentBisector` so each level's children fan further outward
  /// rather than doubling back over the parent.
  private static func placeSubtree(
    node: GenreTreeNode,
    position: CGPoint,
    parentGenre: String?,
    parentBisector: Double,
    depth: Int,
    configuration: Configuration,
    into placed: inout [PlacedNode],
  ) {
    // The parent → this node edge. `nil` on trunks (parentGenre nil).
    let edge: BezierCurve? = {
      guard let parentGenre, let parentPlaced = placed.first(where: { $0.genre.name == parentGenre }) else {
        return nil
      }
      return makeEdge(
        from: parentPlaced.position,
        to: position,
        fraction: configuration.controlPointFraction,
      )
    }()

    placed.append(PlacedNode(
      genre: node.genre,
      depth: depth,
      position: position,
      parentGenre: parentGenre,
      edge: edge,
    ))

    let children = node.children
    guard !children.isEmpty else { return }

    let arcWidthRadians = childArcWidth(depth: depth, configuration: configuration)
    let positions = childPositions(
      parentPosition: position,
      childCount: children.count,
      parentBisector: parentBisector,
      arcWidthRadians: arcWidthRadians,
      radius: adaptiveRadius(
        depth: depth,
        childCount: children.count,
        configuration: configuration,
      ),
    )
    for (index, child) in children.enumerated() {
      let childPosition = positions[index]
      let dx = childPosition.x - position.x
      let dy = childPosition.y - position.y
      // The child's own outward bisector is the direction from parent
      // to child — that's the "12 o'clock" for the child's grandchildren.
      let childBisector = Double(atan2(dy, dx))
      placeSubtree(
        node: child,
        position: childPosition,
        parentGenre: node.genre.name,
        parentBisector: childBisector,
        depth: depth + 1,
        configuration: configuration,
        into: &placed,
      )
    }
  }

}
