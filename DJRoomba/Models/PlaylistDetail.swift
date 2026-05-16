import Foundation

/// Loaded lazily when a playlist is selected, read from the local store (NOT
/// a live MusicKit `Playlist` — local-first pivot). The track rows carry the
/// MusicKit ids `PlaybackResolver` needs to build a queue at play time.
struct PlaylistDetail: Identifiable, Sendable {
  /// Apple library `MusicItemID` raw value, or an app playlist UUID.
  let id: String
  let name: String
  /// Whether this detail's playlist is an imported Apple library playlist
  /// (its `id` is then a library `MusicItemID` we can re-resolve artwork
  /// from — D2). App playlists have no Apple artwork.
  let isAppleLibraryPlaylist: Bool
  /// Where the playlist came from — drives playback resolution (imported
  /// Apple = playlist-granularity; app = per-song) and editability.
  let source: PlaylistSource
  let description: String?
  let isEditable: Bool?
  let tracks: [TrackRow]
  /// Monotonic content token, minted by `PlaylistDetailService` every time
  /// it produces a value (load, reorder, stats refresh). The track table
  /// keys its sorted/filtered recompute off this so it re-derives exactly
  /// when the content changed — including a same-`id` stats refresh — and
  /// never per `body`. `TrackRow`'s `==` is id-only, so comparing
  /// `tracks` arrays would miss a stats-only change; this token doesn't.
  var revision = 0

  var isEmpty: Bool {
    tracks.isEmpty
  }

  /// A user-owned playlist (Phase 4) the app can edit in place. App
  /// playlists are the only editable lists; imported snapshots are
  /// read-only (one-way import).
  var isAppOwned: Bool {
    source.isAppOwned
  }

  /// Re-resolvable header artwork (D2). Nil → native placeholder.
  var artworkRef: ArtworkRef? {
    isAppleLibraryPlaylist ? .playlist(id) : nil
  }
}
