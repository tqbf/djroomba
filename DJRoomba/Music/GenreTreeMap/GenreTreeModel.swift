import Foundation

// MARK: - GenreTreeModel

/// The renderable, layout-ready model the new tree view will bind to
/// (`plans/son-of-genre-map.md` Phase A). Phase A surfaces only the
/// *topology* — Kruskal MST + trunk selection + BFS forest. Geometric
/// layout (diagonal trunk placement, radial branch fanning, Catmull-Rom
/// curves) lands in Phase B and consumes this model unchanged.
///
/// `trunks` is the forest of k ≤ 7 trees; every genre with an MST path
/// to one of the selected trunks appears in exactly one tree.
/// `orphans` is the defensive overflow: genres with no MST path to
/// any selected trunk. On a connected real-library run it's empty;
/// the field exists so the view can surface them in a footer if they
/// ever appear (a flag that the substrate's edge filter has dropped
/// too many candidates, or the library genuinely has disconnected
/// components).
struct GenreTreeModel: Equatable, Sendable {
  var trunks: [GenreTreeTrunk]
  var orphans: [Genre]
}

// MARK: - GenreTreeTrunk

/// One trunk + its claimed subtree. The trunk genre is `root.genre`;
/// `root.children` are its depth-1 branches; `root.depth == 0` by
/// construction.
///
/// `communityID` carries the medium-resolution community id the trunk
/// represents — Phase E will use it to retrieve the persisted trunk
/// colour from `v9.genreMapState`, but Phase A surfaces it raw so
/// the layout pass can group trunks by community for the diagonal
/// arrangement.
struct GenreTreeTrunk: Equatable, Sendable {
  var root: GenreTreeNode
  var communityID: Int
}

// MARK: - GenreTreeNode

/// One node in the trunk tree. Recursive: trunks are depth-0 nodes,
/// branches are depth-1, sub-branches are depth-2+.
///
/// Children are sorted by per-genre weight descending (heavier branches
/// rank first → in Phase B they fan nearest their parent's local "12
/// o'clock") with lex tie-break on genre name for determinism.
struct GenreTreeNode: Equatable, Sendable {
  var genre: Genre
  var depth: Int
  var children: [GenreTreeNode]
}

// MARK: - Genre

/// Lightweight value type — a genre's name + the per-genre `weight` the
/// substrate computed (`[0, 1]`). The renderer reads `weight` to size
/// the pill; the layout reads it to rank branches inside their
/// parent's fan.
///
/// Lives in the `GenreTreeMap` namespace because Phase A's pure-logic
/// flow doesn't need the raw track/album/artist counts the substrate
/// `GenreNode` carries. If a future phase wants them, surface them on
/// `GenreTreeNode` directly rather than widening this type.
struct Genre: Equatable, Hashable, Sendable {
  var name: String
  var weight: Double
}

// MARK: - MSTEdge

/// One edge kept by Kruskal's spanning-tree pass. Mirrors the
/// canonical-half shape of `GenreEdgeEvidence` (`genreA < genreB`),
/// minus the multi-channel jaccards — the trunk-tree pipeline only
/// reads `totalWeight` from the substrate.
///
/// `cost = 1 − totalWeight` is the edge cost the BFS forest minimises
/// when breaking ties between competing trunk claims.
struct MSTEdge: Equatable, Sendable {
  var genreA: String
  var genreB: String
  var totalWeight: Double

  var cost: Double {
    1.0 - totalWeight
  }
}
