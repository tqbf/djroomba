import CoreGraphics
import Foundation

// MARK: - GenreTreeRadialPlan

/// Pure radial-focus geometry for the trunk-tree
/// (`plans/son-of-genre-map.md` Phase C — "Highlighted state — radial
/// focus"). Given a selected genre + the trunk-tree's existing layout
/// + the underlying multi-channel edge graph, computes the per-genre
/// **target position** + **target opacity** for the focused state.
///
/// The view layer interpolates from the trunk-tree placement to this
/// plan inside a single `withAnimation` block; SwiftUI handles per-
/// frame interpolation on `.position()` + `.opacity()` from the
/// current values to the targets. The plan is computed exactly once
/// per click — no per-frame recompute.
///
/// **Geometry.**
///
/// - The selected genre sits at the **radial centre**. To avoid a
///   visible jump on entry, the centre is set to the selected
///   genre's current trunk-tree position (its world coordinates
///   don't change — only its neighbours move around it).
/// - **1-hop neighbours** fan around the centre on a circle of radius
///   `r1`, evenly spaced. Order is deterministic — sorted by edge
///   weight descending then by genre name ascending so re-entry on
///   the same genre lays neighbours out identically.
/// - **2-hop neighbours** sit on the outer ring of radius `r2`,
///   evenly spaced. A genre that's both 1-hop AND 2-hop (a 1-hop
///   neighbour of a 1-hop neighbour) belongs to the **1-hop** set
///   only — the closest ring wins.
/// - Genres that are neither selected nor 1-hop nor 2-hop are
///   classified as *out-of-focus*. Their `targetPosition` stays at
///   their **existing trunk-tree layout position** (so the layout
///   doesn't shuffle invisibly), but `targetOpacity` drops to
///   `outOfFocusOpacity`.
///
/// **Opacity targets.** Defaults match the plan's "non-neighbours
/// fade to ~6 %" guidance, plus a slightly dimmer 2-hop ring so the
/// closest neighbours read first:
///
/// - selected: `1.0` (fully present, anchors the focus)
/// - 1-hop neighbour: `1.0` (the answer to "what's adjacent to this")
/// - 2-hop neighbour: `0.55` (visible but subordinate — the third
///   tier of legibility)
/// - out-of-focus: `0.06` (the back-edge band; the eye knows there's
///   more here without being distracted)
///
/// **Neighbours from `genre_edge_evidence`, not the MST.** The MST
/// has only n-1 edges. The user's question "what's adjacent to this"
/// reads off the FULL multi-channel graph — including the cross-
/// community bridges Phase A's MST dropped (which Phase B renders as
/// faint back-edges). The radial focus surfaces every edge to the
/// selected genre, not just the tree edges.
///
/// **Position clamping.** Computed positions are clamped to the
/// canvas's `worldBounds` (with a small padding inset) so even a
/// genre at the canvas edge with neighbours on `r2` doesn't fan
/// outside the renderable world.
///
/// Everything `nonisolated static`, deterministic, fixture-testable
/// without SwiftUI / GRDB / MusicKit.
enum GenreTreeRadialPlan {

  // MARK: Internal

  /// Knob-laden configuration. Defaults match the plan's "300 ms
  /// easeInOut, r1 ≈ 280, r2 ≈ 520" starting point — radii roughly
  /// half + full of Phase B's `depth1Radius = 520`. The view layer
  /// surfaces the animation duration through a Debug-menu toggle;
  /// the radii stay fixed for Phase C ship (revisit after live A/B).
  struct Configuration: Sendable {

    // MARK: Lifecycle

    init(
      r1: CGFloat = 420,
      r2: CGFloat = 820,
      outOfFocusOpacity: Double = 0.06,
      twoHopOpacity: Double = 0.55,
      oneHopOpacity: Double = 1.0,
      selectedOpacity: Double = 1.0,
      canvasInset: CGFloat = 40,
      startingAngleRadians: Double = -.pi / 2.0,
      horizontalStretch: CGFloat = 1.0,
    ) {
      self.r1 = r1
      self.r2 = r2
      self.outOfFocusOpacity = outOfFocusOpacity
      self.twoHopOpacity = twoHopOpacity
      self.oneHopOpacity = oneHopOpacity
      self.selectedOpacity = selectedOpacity
      self.canvasInset = canvasInset
      self.startingAngleRadians = startingAngleRadians
      self.horizontalStretch = horizontalStretch
    }

    // MARK: Internal

    /// Inner-ring radius — distance from the selected genre to its
    /// 1-hop neighbours.
    var r1: CGFloat
    /// Outer-ring radius — distance from the selected genre to its
    /// 2-hop neighbours.
    var r2: CGFloat
    /// Opacity for genres that are neither selected nor in either
    /// neighbour ring. Defaults to `0.06` (the back-edge band).
    var outOfFocusOpacity: Double
    /// Opacity for the outer ring (2-hop neighbours).
    var twoHopOpacity: Double
    /// Opacity for the inner ring (1-hop neighbours).
    var oneHopOpacity: Double
    /// Opacity for the selected genre itself.
    var selectedOpacity: Double
    /// Padding inset from `worldBounds` — clamped positions are kept
    /// at least this far from the canvas edge.
    var canvasInset: CGFloat
    /// Where the first slot on each ring lives, in radians. `-π/2`
    /// puts the first slot at the top (12 o'clock); subsequent slots
    /// distribute clockwise.
    var startingAngleRadians: Double
    /// Horizontal stretch turning the focus rings from circles into
    /// **wide ellipses** — the same treatment the trunk-tree layout
    /// gets (`GenreTreeLayout.Configuration.horizontalStretch`), for the
    /// same reason: the docked pane is wide and short, so a circular
    /// ring crowds and a wide ellipse fills the room. `1.0` keeps the
    /// rings circular (the geometry tests describe circles); the panel
    /// passes the live wide value.
    var horizontalStretch: CGFloat
  }

  /// Per-genre placement target. The view layer reads `position` for
  /// `.position()` and `opacity` for `.opacity()`; both are
  /// interpolated by SwiftUI inside the `withAnimation` block.
  struct Target: Equatable, Sendable {
    var genre: String
    var position: CGPoint
    var opacity: Double
    var ring: Ring
  }

  /// Which ring a genre lands on. The view layer uses this for
  /// ancillary effects (e.g. edge visibility — 1-hop edges stay
  /// fully visible, 2-hop edges dim, out-of-focus edges hide).
  enum Ring: Equatable, Sendable {
    case selected
    case oneHop
    case twoHop
    case outOfFocus
  }

  /// Computed plan: the per-genre targets indexed by genre name.
  /// Includes every genre in the layout — the view layer can read
  /// targets without filtering.
  struct Plan: Equatable, Sendable {
    var targetsByGenre: [String: Target]
    var centre: CGPoint
    var selectedGenre: String
  }

  /// Compute a radial-focus plan for `selectedGenre`. Pure,
  /// deterministic.
  ///
  /// - Parameter selectedGenre: the genre at the radial centre.
  /// - Parameter layout: the trunk-tree layout output (consumed for
  ///   each genre's current world position + canvas bounds).
  /// - Parameter evidence: every multi-channel edge — both kept and
  ///   dropped by the MST. Used to enumerate 1-hop and 2-hop
  ///   neighbourhoods.
  /// - Parameter configuration: knobs (see `Configuration`).
  ///
  /// Returns `nil` when `selectedGenre` isn't in the layout (the
  /// view layer treats that as "stay in trunk-tree mode").
  static func plan(
    selectedGenre: String,
    layout: GenreTreeLayout.Output,
    evidence: [GenreEdgeEvidence],
    configuration: Configuration = Configuration(),
  ) -> Plan? {
    let placedByGenre = Dictionary(
      uniqueKeysWithValues: layout.placedNodes.map { ($0.genre.name, $0) }
    )
    guard let selectedPlaced = placedByGenre[selectedGenre] else { return nil }
    let centre = selectedPlaced.position

    // Adjacency from `genre_edge_evidence`. Weight is the composite
    // total_weight — used to rank 1-hop and 2-hop slots so the
    // strongest neighbour sits at the top (`startingAngleRadians`).
    let adjacency = adjacencyMap(from: evidence)

    let oneHop = orderedNeighbours(
      of: selectedGenre,
      adjacency: adjacency,
    )
    // 2-hop = neighbours of neighbours, MINUS the 1-hop set, MINUS
    // the selected genre. Deduped + ordered by max single-step
    // composite weight desc then name asc.
    let twoHopRaw = twoHopNeighbours(
      of: selectedGenre,
      adjacency: adjacency,
      oneHop: Set(oneHop.map(\.genre)),
    )

    var targets = [String: Target]()
    targets.reserveCapacity(layout.placedNodes.count)

    // Selected genre — sits at the centre at full opacity.
    targets[selectedGenre] = Target(
      genre: selectedGenre,
      position: centre,
      opacity: configuration.selectedOpacity,
      ring: .selected,
    )

    // Ring 1 — 1-hop neighbours evenly spaced. Heaviest edge at the
    // starting angle (12 o'clock by default), subsequent slots
    // distributed clockwise so the eye reads strength → periphery.
    let ring1Positions = ringPositions(
      centre: centre,
      radius: configuration.r1,
      count: oneHop.count,
      startingAngle: configuration.startingAngleRadians,
      horizontalStretch: configuration.horizontalStretch,
    )
    for (index, neighbour) in oneHop.enumerated() {
      let clamped = clamp(
        position: ring1Positions[index],
        bounds: layout.worldBounds,
        inset: configuration.canvasInset,
      )
      targets[neighbour.genre] = Target(
        genre: neighbour.genre,
        position: clamped,
        opacity: configuration.oneHopOpacity,
        ring: .oneHop,
      )
    }

    // Ring 2 — 2-hop neighbours evenly spaced on the outer circle.
    let ring2Positions = ringPositions(
      centre: centre,
      radius: configuration.r2,
      count: twoHopRaw.count,
      startingAngle: configuration.startingAngleRadians,
      horizontalStretch: configuration.horizontalStretch,
    )
    for (index, neighbour) in twoHopRaw.enumerated() {
      let clamped = clamp(
        position: ring2Positions[index],
        bounds: layout.worldBounds,
        inset: configuration.canvasInset,
      )
      targets[neighbour] = Target(
        genre: neighbour,
        position: clamped,
        opacity: configuration.twoHopOpacity,
        ring: .twoHop,
      )
    }

    // Out-of-focus — every other placed genre stays at its
    // existing trunk-tree position; only opacity changes. Keeps the
    // back-edge web underneath in registration without animating
    // hundreds of pills sideways.
    for placed in layout.placedNodes {
      if targets[placed.genre.name] != nil { continue }
      targets[placed.genre.name] = Target(
        genre: placed.genre.name,
        position: placed.position,
        opacity: configuration.outOfFocusOpacity,
        ring: .outOfFocus,
      )
    }

    return Plan(
      targetsByGenre: targets,
      centre: centre,
      selectedGenre: selectedGenre,
    )
  }

  /// Evenly-spaced points on a circle of `radius` around `centre`,
  /// starting at `startingAngle` (radians). `count == 0` returns an
  /// empty array; `count == 1` returns a single point at
  /// `startingAngle`.
  ///
  /// `internal` (not `private`) so tests can pin the geometry.
  static func ringPositions(
    centre: CGPoint,
    radius: CGFloat,
    count: Int,
    startingAngle: Double,
    horizontalStretch: CGFloat = 1.0,
  ) -> [CGPoint] {
    guard count > 0 else { return [] }
    /// Elliptical ring: the x half-axis is stretched, the y half-axis is
    /// the plain radius (a circle when `horizontalStretch == 1`).
    func point(at angle: Double) -> CGPoint {
      CGPoint(
        x: centre.x + radius * horizontalStretch * CGFloat(cos(angle)),
        y: centre.y + radius * CGFloat(sin(angle)),
      )
    }
    if count == 1 {
      return [point(at: startingAngle)]
    }
    let step = (2.0 * .pi) / Double(count)
    return (0 ..< count).map { index in
      point(at: startingAngle + Double(index) * step)
    }
  }

  // MARK: Private

  /// Adjacency map `genre → [(other, weight)]` over the canonical-
  /// half edge list. Each neighbour list is sorted by weight desc
  /// then name asc for deterministic ordering.
  private static func adjacencyMap(
    from evidence: [GenreEdgeEvidence]
  ) -> [String: [(other: String, weight: Double)]] {
    var adjacency = [String: [(other: String, weight: Double)]]()
    for row in evidence {
      adjacency[row.genreA, default: []].append((row.genreB, row.totalWeight))
      adjacency[row.genreB, default: []].append((row.genreA, row.totalWeight))
    }
    for key in adjacency.keys {
      adjacency[key]?.sort { lhs, rhs in
        if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
        return lhs.other < rhs.other
      }
    }
    return adjacency
  }

  /// 1-hop neighbours of `genre`, sorted by edge weight descending
  /// then by neighbour name ascending. Returned as
  /// `(genre, weight)` so the caller can reuse the weight for
  /// downstream ordering.
  private static func orderedNeighbours(
    of genre: String,
    adjacency: [String: [(other: String, weight: Double)]],
  ) -> [(genre: String, weight: Double)] {
    (adjacency[genre] ?? []).map { (genre: $0.other, weight: $0.weight) }
  }

  /// 2-hop neighbours: every neighbour-of-a-neighbour that isn't the
  /// selected genre and isn't itself a 1-hop neighbour. Each 2-hop
  /// genre's rank-key is the strongest single-step composite weight
  /// observed in any path reaching it (max over all 1-hop
  /// intermediates). Sorted by that key desc then name asc.
  private static func twoHopNeighbours(
    of selected: String,
    adjacency: [String: [(other: String, weight: Double)]],
    oneHop: Set<String>,
  ) -> [String] {
    var bestWeight = [String: Double]()
    for hop1 in oneHop {
      for (other, weight) in adjacency[hop1] ?? [] {
        if other == selected || oneHop.contains(other) { continue }
        let previous = bestWeight[other] ?? -.infinity
        if weight > previous {
          bestWeight[other] = weight
        }
      }
    }
    return bestWeight.keys.sorted { lhs, rhs in
      let lhsWeight = bestWeight[lhs] ?? 0
      let rhsWeight = bestWeight[rhs] ?? 0
      if lhsWeight != rhsWeight { return lhsWeight > rhsWeight }
      return lhs < rhs
    }
  }

  /// Clamp a candidate position inside `bounds`, with a `inset`
  /// padding on every edge.
  private static func clamp(
    position: CGPoint,
    bounds: CGRect,
    inset: CGFloat,
  ) -> CGPoint {
    let minX = bounds.minX + inset
    let maxX = bounds.maxX - inset
    let minY = bounds.minY + inset
    let maxY = bounds.maxY - inset
    return CGPoint(
      x: min(max(position.x, minX), maxX),
      y: min(max(position.y, minY), maxY),
    )
  }
}
