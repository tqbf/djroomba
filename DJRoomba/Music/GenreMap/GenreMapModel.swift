import Foundation

// MARK: - GenreMapNodeKind

/// Topological classification of a genre node (`plans/genre-metro-map.md`
/// Phase 2 + Phase 3). Derived from the composite transferness score on
/// the layout graph; cached on the node so the renderer never
/// re-classifies on its own.
///
/// - `ordinary`: a regular stop — the existing Phase-1 pill.
/// - `junction`: a pill with a `diamond.fill` glyph inside it — modest
///   topological breadth, AND not necessarily a strand member (the
///   classification is layout-graph-derived, not strand-derived).
/// - `transferStation`: a pill that serves 2+ metro strands. From
///   Phase 3 the signal is communicated **purely via the per-strand
///   coloured tick row under the pill** — the Phase-2 neutral multi-
///   strand glyph is removed (it was a placeholder for the strand
///   colours that didn't exist yet).
///
/// Thresholds (composite transferness in `[0, 1]`): `<0.35` ordinary,
/// `<0.65` junction, `≥0.65` transfer station. Pinned in
/// `GenreMapTransfernessTests`; matches the plan's headline values
/// on the back of the Phase-2-gate substrate widening (`interCommunityBridges`).
enum GenreMapNodeKind: Int, Equatable, Sendable, CaseIterable {
  case ordinary = 0
  case junction = 1
  case transferStation = 2
}

// MARK: - GenreMapModel

/// The renderable, layout-ready model the `GenreMapPanel` binds to — the
/// output of `GenreMapBuilder` (`plans/genre-metro-map.md` Phase 1).
///
/// Three pieces:
///
/// - `nodes`: every analysed genre's label, normalised importance, raw
///   counts, and current 2-D position (assigned by the constrained force
///   layout). Phase 1 surfaces only **geography**: pills + community hulls.
/// - `layoutEdges`: the **sparse** subset of edges that the physics sees —
///   per-node mutual-kNN ∪ maximum spanning tree ∪ strongest inter-
///   community bridges. The display knows about more edges (kept on each
///   node for future hover-reveal) but they never enter the force kernel.
/// - `communities`: medium-resolution Louvain partitions (`γ = 1.0`).
///   Phase 1 uses them for centroid gravity + soft background hulls; later
///   phases add coarse + fine resolutions on top.
struct GenreMapModel: Equatable, Sendable {
  var nodes: [GenreMapNode]
  var layoutEdges: [GenreMapEdge]
  /// Medium-resolution communities, keyed by community id. Hulls draw
  /// from these.
  var communities: [GenreMapCommunity]
  /// World-space bounding box of the laid-out nodes (label centres,
  /// pre-zoom). The panel uses it for the **opt-in** Fit toolbar action
  /// (Cmd-9). Default presentation centres on `defaultCentre` at scale
  /// 1.0× — Phase-3-gate "stop compacting" reset (2026-05-20): the map
  /// is a panable / zoomable surface, not a fit-to-viewport overview.
  var worldBounds: CGRect
  /// World-space point the panel uses as the **default viewport
  /// centre** on first appearance (Phase-3-gate 2026-05-20). Computed
  /// as the centroid of the heaviest community — defined as the
  /// community whose summed member `weight` is largest, deterministic
  /// tie-break by community id. A recognisable neighbourhood, not the
  /// world centroid; the user pans / zooms to discover the rest.
  var defaultCentre = CGPoint.zero
  /// Phase 3 (`plans/genre-metro-map.md`): algorithmic metro strands
  /// extracted from the layout graph + community partition (heavy paths
  /// inside communities + cross-community bridge strands). Empty before
  /// Phase 3; in-memory only (Phase 6 persists). Each strand renders as
  /// a faint Catmull-Rom spline over its `pathStations`; the renderer
  /// draws coloured ticks on every station serving a strand and uses
  /// `colourID` to keep the same hue stable across the strand's spline
  /// + station ticks.
  var strands = [GenreMapStrandInference.Strand]()
  /// Phase 4 (`plans/genre-metro-map.md`): obstacle-aware routed
  /// polylines + corridor bundling, keyed by `strand.id`. Populated
  /// by `GenreMapRoutingActor` on a background actor after the layout
  /// settles; empty until the first routing pass completes. The
  /// renderer prefers `routedStrands[id]` when present and falls back
  /// to the Phase-3 naïve Catmull-Rom over `Strand.pathStations` while
  /// routing is in flight (or for the rare disconnected fallback).
  var routedStrands = [Int: GenreMapRoutedStrand]()
  /// Phase 4: monotonically-increasing revision number that bumps on
  /// any geographic mutation (rebuild + node-position movement past
  /// `geographicEpsilon`). Routing keys its cache on
  /// `(strand.id, layoutRevision)`; drag does NOT bump revision until
  /// release (see `GenreMapService.commitDrag`).
  var layoutRevision = 0
}

// MARK: - GenreMapRoutedStrand

/// One Phase-4 routed strand — the obstacle-aware polyline +
/// corridor / offset metadata produced by `GenreMapRouting` +
/// `GenreMapBundling`. The renderer draws this polyline directly (no
/// Catmull-Rom — the polyline has already been smoothed); the
/// corridor id + slot are surfaced so the side panel can say
/// "this strand shares a corridor with 4 others".
struct GenreMapRoutedStrand: Equatable, Sendable {
  var strandID: Int
  /// World-space points; endpoints snap to the exact station
  /// positions, interior points are A*-detoured + offset-shifted.
  var polyline: [CGPoint]
  /// Corridor identifier from `GenreMapBundling`. Singleton strands
  /// still get a unique corridor id (downstream code stays uniform).
  var corridorID: Int
  /// Symmetric offset slot inside the corridor; 0 ⇒ on the corridor
  /// centerline, ±1, ±2, … fan out perpendicular to the local tangent.
  var slot: Int
  /// `true` ⇒ corridor contains ≥ 2 strands.
  var isBundled: Bool
}

// MARK: - GenreMapNode

struct GenreMapNode: Equatable, Sendable, Identifiable {
  var genre: String
  /// Normalised importance from `genre_node.weight` (`[0, 1]`).
  var weight: Double
  var trackCount: Int
  var albumCount: Int
  var artistCount: Int
  /// Algorithmic community id at the medium resolution (`γ = 1.0`). Stable
  /// across rebuilds **within the same `GenreMapModel`**, but not across
  /// rebuilds — community identity persistence is Phase 6.
  var communityID: Int
  /// World-space layout position. Mutated by `GenreMapBuilder.layout` and
  /// the drag interaction; never persisted in Phase 1.
  var position: CGPoint
  /// Cached label rectangle size (world units, including pill padding)
  /// from the `measureLabel` closure the builder consumed at build time.
  /// Carried on the node so the drag-relaxation pass uses the SAME
  /// rectangle the layout pass used — the original Phase-1 ship had
  /// drag re-approximate a different size, which let drag re-overlap
  /// labels the layout had separated.
  var labelSize: CGSize
  /// Composite transferness score in `[0, 1]` (Phase 2). Sum of the
  /// four normalised inputs at their spec weights, dampened for
  /// generic giants. The renderer never recomputes this — it reads.
  var transferness: Double
  /// Cached topological classification (Phase 2). The drag affordance
  /// must NOT change this: kind is purely layout-graph-derived,
  /// not position-derived, so it stays stable while the user moves a
  /// node around.
  var nodeKind: GenreMapNodeKind
  /// Per-input contributions to `transferness`, in `[0, 1]`. Used by
  /// the evidence side panel to explain which inputs landed high/low.
  /// (Stored on the node so the panel never re-derives a number that
  /// disagrees with the classification.)
  var transfernessInputs: GenreMapTransfernessInputs

  var id: String {
    genre
  }
}

// MARK: - GenreMapTransfernessInputs

/// The four normalised inputs to the composite transferness score
/// (`plans/genre-metro-map.md` Phase 2, step 1). All in `[0, 1]` at the
/// node-cache point; the `membershipEntropy` slot is a placeholder until
/// soft community detection lands (deliberately deferred).
///
/// `strandCount` stays at 0 until Phase 3 fills it; the composite reads
/// the spec's 10 % weight on this slot today and it contributes nothing.
struct GenreMapTransfernessInputs: Equatable, Sendable {
  var betweenness: Double
  var neighbourEntropy: Double
  var crossCommunityFraction: Double
  var membershipEntropy: Double
  var strandCount: Double
  /// Multiplicative dampening factor applied to the raw composite (`1.0`
  /// = untouched, `<1.0` = generic-giant dampened). Surfaced so the
  /// evidence panel can say "the score is lower because…".
  var dampening: Double
}

// MARK: - GenreMapEdge

/// One canonical-half edge in the **layout** graph — what the physics sees
/// (the display graph is held inside `GenreMapBuilder` and not yet
/// surfaced to the view in Phase 1).
struct GenreMapEdge: Equatable, Sendable {
  var genreA: String
  var genreB: String
  /// Composite weight from `genre_edge_evidence.totalWeight`, scaled into
  /// the spring kernel by the layout pass.
  var totalWeight: Double
}

// MARK: - GenreMapCommunity

struct GenreMapCommunity: Equatable, Sendable, Identifiable {
  /// Algorithmic id (small integer, stable within this model only).
  var id: Int
  /// Member genre names.
  var members: [String]
  /// World-space centroid of the members.
  var centroid: CGPoint
}
