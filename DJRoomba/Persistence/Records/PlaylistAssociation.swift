import Foundation

/// One playlist associated with a focused genre (or, during neighbour-walk,
/// with a genre **edge**) — a query result, **not** a table row, so it's a
/// plain `Sendable` value, not a GRDB record.
///
/// `strength` is how strongly the playlist ties to the focus: for a single
/// genre it's the number of distinct tracks of that genre in the playlist;
/// for an edge it's the pair co-strength `min(tracks of A, tracks of B)`
/// (the same metric the analysis ranks by). The associations card sorts by
/// it, descending.
struct PlaylistAssociation: Sendable, Hashable, Identifiable {

  let playlistID: String
  let name: String
  let strength: Int
  let isAppOwned: Bool

  // MARK: Internal

  /// Stable across apple/app id spaces (a UUID can't collide with an Apple
  /// `MusicItemID`, but the source prefix makes intent explicit and the
  /// `Identifiable` conformance collision-proof for `ForEach`).
  var id: String {
    "\(isAppOwned ? "app" : "apple"):\(playlistID)"
  }

}
