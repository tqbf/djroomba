import CoreGraphics
import Foundation

// MARK: - GenreMapBundling

/// Corridor bundling for the metro-strand overlay
/// (`plans/genre-metro-map.md` Phase 4, step 3 + step 4 ordering).
/// Pure Swift; no SwiftUI, no observation; deterministic.
///
/// After `GenreMapRouting.route` lays each strand on its own polyline,
/// bundling identifies **shared corridor segments** — runs of cells
/// where two or more routed strands cover the same A* path. Each
/// participating strand inside a corridor gets a small **perpendicular
/// offset** so they render as parallel rails rather than one stacked
/// line. The classic five-colour case (five strands sharing the same
/// pair of station endpoints) is the visual proof: bundling spreads
/// them across `±k·offsetStep` rails inside the corridor.
///
/// Phase-4 ships the simplest correct shape:
///
/// 1. **Corridor extraction.** Compute the cell-set intersection
///    between every pair of routed strands. Pairs whose intersection
///    is ≥ `minSharedCells` are linked into a corridor (union-find on
///    the strand ids; transitivity is the point — five strands that
///    pairwise share cells form one five-strand corridor).
/// 2. **Offset assignment.** Inside each corridor, assign each strand
///    an offset slot `−k…+k` (centred on zero so the corridor's
///    aggregate centerline stays where A* put it). Slot order is
///    deterministic by `strandID`.
/// 3. **Crossing rank.** Count pairwise crossings between strands in
///    DIFFERENT corridors after the offsets are applied; the caller
///    surfaces the count for instrumentation. Crossings AT a transfer
///    station (shared member-station of both strands) discount toward
///    "intentional" — surfaced separately so the inspector can show
///    "8 crossings, 5 at transfer stations".
enum GenreMapBundling {

  // MARK: Internal

  struct Configuration: Sendable {
    /// Two strands need to share at least this many grid cells to be
    /// considered part of the same corridor. Tuned for 50pt cells over
    /// the live-library: 3 cells ≈ a full pill-to-pill segment, which
    /// is what the eye reads as "these strands are running together".
    var minSharedCells = 3
    /// Per-slot perpendicular displacement at scale 1.0× (world units).
    /// The renderer scales it down at zoom-in / up at zoom-out so the
    /// visual offset stays roughly constant in screen pixels.
    var offsetStep: CGFloat = 6
  }

  /// Output: every routed strand annotated with its corridor id +
  /// per-strand offset slot (the offset to apply when rendering).
  struct BundledStrand: Equatable, Sendable {
    var strandID: Int
    /// Stable corridor identifier (small integer, 0…). Each isolated
    /// (un-bundled) strand still gets its own corridor id; this keeps
    /// downstream code uniform.
    var corridorID: Int
    /// Slot index inside the corridor. Slot 0 ⇒ no offset; ±1, ±2, …
    /// fan out perpendicular to the strand's local direction.
    var slot: Int
    /// World-space polyline (snapped at strand endpoints to the exact
    /// station positions; offset-aware — bundling already shifted
    /// interior points perpendicular to the local direction).
    var polyline: [CGPoint]
    /// `true` if this strand shares its corridor with at least one
    /// other strand (i.e. it's actually bundled). Surfaces a cheap
    /// "this strand is bundled" affordance for the renderer without
    /// requiring a corridor-population lookup at draw time.
    var isBundled: Bool
  }

  /// Result of one bundling pass.
  struct Result: Equatable, Sendable {
    var bundled: [BundledStrand]
    /// Total corridor count (one per equivalence class).
    var corridorCount: Int
    /// Number of corridors that contain ≥ 2 strands (bundled).
    var bundledCorridorCount: Int
    /// Max strands packed into any single corridor (the "5-colour"
    /// benchmark metric).
    var maxStrandsPerCorridor: Int
    /// Total pairwise crossings between strands in different corridors
    /// (cell intersection at non-bundled-pair cells). For instrumentation.
    var crossingCount: Int
    /// Of `crossingCount`, how many fall on a transfer station (a
    /// member-of-both station). Intentional crossings.
    var transferCrossingCount: Int
  }

  /// Compute corridors + offsets for the supplied routed strands.
  /// `memberGenresByStrand` keys must match `routed[*].strandID`. The
  /// caller (the routing actor) builds these from the `Strand`
  /// `memberGenres` set.
  static func bundle(
    routed: [GenreMapRouting.RoutedStrandPath],
    memberGenresByStrand: [Int: Set<String>],
    transferStationCells: Set<GenreMapRouting.GridCell> = [],
    configuration: Configuration = Configuration(),
  ) -> Result {
    guard !routed.isEmpty else {
      return Result(
        bundled: [],
        corridorCount: 0,
        bundledCorridorCount: 0,
        maxStrandsPerCorridor: 0,
        crossingCount: 0,
        transferCrossingCount: 0,
      )
    }
    // Union-find over strand ids — group strands whose cell sets
    // overlap by ≥ minSharedCells.
    var uf = UnionFindInt(elements: routed.map(\.strandID))
    for lhsIndex in 0 ..< routed.count {
      let lhs = routed[lhsIndex]
      for rhsIndex in (lhsIndex + 1) ..< routed.count {
        let rhs = routed[rhsIndex]
        let shared = lhs.occupiedCells.intersection(rhs.occupiedCells)
        if shared.count >= configuration.minSharedCells {
          _ = uf.union(lhs.strandID, rhs.strandID)
        }
      }
    }
    // Bucket strands by corridor id (= union-find root).
    var strandsByCorridor = [Int: [Int]]()
    for path in routed {
      let root = uf.find(path.strandID)
      strandsByCorridor[root, default: []].append(path.strandID)
    }
    // Stable corridor ids: 0… in ascending order of (root id) so
    // identical inputs produce identical numbering.
    let sortedRoots = strandsByCorridor.keys.sorted()
    var corridorIDByRoot = [Int: Int]()
    for (index, root) in sortedRoots.enumerated() {
      corridorIDByRoot[root] = index
    }
    // Assign offset slots inside each corridor — symmetric around 0,
    // deterministic by `strandID`.
    var slotByStrand = [Int: Int]()
    for root in sortedRoots {
      let strands = (strandsByCorridor[root] ?? []).sorted()
      let centre = (strands.count - 1) / 2
      for (index, strandID) in strands.enumerated() {
        slotByStrand[strandID] = index - centre
      }
    }
    // Apply perpendicular offsets per strand. For each interior point
    // of the polyline, derive the local tangent (next − previous) and
    // shift along its perpendicular by `slot · offsetStep`.
    var bundled = [BundledStrand]()
    bundled.reserveCapacity(routed.count)
    var maxStrandsPerCorridor = 0
    var bundledCorridorCount = 0
    let memberByStrand = memberGenresByStrand
    let corridorMembership = strandsByCorridor.mapValues { Set($0) }
    for path in routed {
      let root = uf.find(path.strandID)
      let corridorID = corridorIDByRoot[root] ?? 0
      let slot = slotByStrand[path.strandID] ?? 0
      let corridorStrands = corridorMembership[root] ?? Set([path.strandID])
      let isBundled = corridorStrands.count >= 2
      let offsetPolyline = applyPerpendicularOffset(
        polyline: path.polyline,
        slot: slot,
        offsetStep: configuration.offsetStep,
      )
      bundled.append(BundledStrand(
        strandID: path.strandID,
        corridorID: corridorID,
        slot: slot,
        polyline: offsetPolyline,
        isBundled: isBundled,
      ))
      maxStrandsPerCorridor = max(maxStrandsPerCorridor, corridorStrands.count)
    }
    bundledCorridorCount = strandsByCorridor.values.count(where: { $0.count >= 2 })
    // Crossing inventory — pairs of strands in DIFFERENT corridors
    // whose cell sets intersect. Transfer-station discount: crossings
    // at cells in `transferStationCells` count toward the intentional
    // total too.
    var crossingTotal = 0
    var transferCrossingTotal = 0
    for lhsIndex in 0 ..< routed.count {
      for rhsIndex in (lhsIndex + 1) ..< routed.count {
        let lhs = routed[lhsIndex]
        let rhs = routed[rhsIndex]
        let lhsRoot = uf.find(lhs.strandID)
        let rhsRoot = uf.find(rhs.strandID)
        if lhsRoot == rhsRoot { continue }
        let shared = lhs.occupiedCells.intersection(rhs.occupiedCells)
        if shared.isEmpty { continue }
        crossingTotal += 1
        // Are any of the shared cells transfer stations?
        let bothMembers = (memberByStrand[lhs.strandID] ?? Set())
          .intersection(memberByStrand[rhs.strandID] ?? Set())
        if !bothMembers.isEmpty {
          // The intersection of cells with the transfer-station cell
          // set is the perceptual test — but at this layer we don't
          // know station cells unless the caller passed them. The
          // routing pass owns that knowledge.
          let transferIntersect = shared.intersection(transferStationCells)
          if !transferIntersect.isEmpty {
            transferCrossingTotal += 1
          }
        }
      }
    }
    return Result(
      bundled: bundled,
      corridorCount: sortedRoots.count,
      bundledCorridorCount: bundledCorridorCount,
      maxStrandsPerCorridor: maxStrandsPerCorridor,
      crossingCount: crossingTotal,
      transferCrossingCount: transferCrossingTotal,
    )
  }

  /// Apply a per-strand perpendicular offset to a polyline. Endpoints
  /// stay attached to the stations (slot=0 effectively for the first
  /// and last points so the strand reads as "starts at this pill,
  /// ends at this pill"). Interior points shift by `slot · offsetStep`
  /// along the local-tangent perpendicular.
  static func applyPerpendicularOffset(
    polyline: [CGPoint],
    slot: Int,
    offsetStep: CGFloat,
  ) -> [CGPoint] {
    guard slot != 0, polyline.count >= 3 else { return polyline }
    let displacement = CGFloat(slot) * offsetStep
    var out = polyline
    for index in 1 ..< polyline.count - 1 {
      let previous = polyline[index - 1]
      let next = polyline[index + 1]
      let tangentX = next.x - previous.x
      let tangentY = next.y - previous.y
      let magnitude = sqrt(tangentX * tangentX + tangentY * tangentY)
      guard magnitude > 1.0e-6 else { continue }
      // Perpendicular (rotate 90°: (x, y) → (-y, x)).
      let perpX = -tangentY / magnitude
      let perpY = tangentX / magnitude
      out[index] = CGPoint(
        x: polyline[index].x + perpX * displacement,
        y: polyline[index].y + perpY * displacement,
      )
    }
    return out
  }

  // MARK: Private

  /// Bounded union-find keyed by `Int`. The `UnionFind<String>` used
  /// elsewhere in the GenreMap pipeline is generic on `Hashable`; this
  /// specialised variant skips the dictionary lookup for the tight
  /// strand-id loop.
  private struct UnionFindInt {

    // MARK: Lifecycle

    init(elements: [Int]) {
      parent = Dictionary(uniqueKeysWithValues: elements.map { ($0, $0) })
      rank = Dictionary(uniqueKeysWithValues: elements.map { ($0, 0) })
    }

    // MARK: Internal

    var parent: [Int: Int]
    var rank: [Int: Int]

    mutating func find(_ id: Int) -> Int {
      var current = id
      while parent[current] != current {
        let next = parent[current] ?? current
        parent[current] = parent[next] ?? next
        current = next
      }
      return current
    }

    mutating func union(_ lhs: Int, _ rhs: Int) -> Bool {
      let rootLhs = find(lhs)
      let rootRhs = find(rhs)
      if rootLhs == rootRhs { return false }
      let rankLhs = rank[rootLhs] ?? 0
      let rankRhs = rank[rootRhs] ?? 0
      if rankLhs < rankRhs {
        parent[rootLhs] = rootRhs
      } else if rankLhs > rankRhs {
        parent[rootRhs] = rootLhs
      } else {
        parent[rootRhs] = rootLhs
        rank[rootLhs] = rankLhs + 1
      }
      return true
    }

  }
}
