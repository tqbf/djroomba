import Foundation

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
  /// pre-zoom). The panel uses it to fit-to-view on first appearance.
  var worldBounds: CGRect
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

  var id: String {
    genre
  }
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
