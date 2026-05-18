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

  /// True when this is a **synthetic genre collection** (the genre-graph
  /// navigation), not a backing playlist: no Apple/app playlist behind it,
  /// so it's not editable, not favoritable, and is NEVER recorded into
  /// `recent_playlist` (its `id` is a `"genre:<name>"` sentinel that must
  /// not leak into recents). Playback still works — it goes through the
  /// per-song app-owned resolver path. Defaulted ⇒ every existing
  /// initializer keeps compiling unchanged.
  var isGenre = false

  /// The distinct genres of this detail's tracks, most-represented first
  /// (see `genreTally`). Surfaced as the header's quiet, tappable genre
  /// strip. **Empty for a genre detail** (`isGenre`) — a genre view doesn't
  /// show its own genre chips — and empty when no track carries a genre.
  /// Defaulted ⇒ every existing initializer / call site keeps compiling
  /// (non-breaking).
  var genres = [String]()

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

  /// The distinct genres across `songs`, ordered by how much of the
  /// playlist each one represents.
  ///
  /// Each genre name is `.trimmingCharacters(in: .whitespacesAndNewlines)`
  /// before counting; empty/whitespace-only entries are dropped. A genre is
  /// counted **once per song** even if a song lists it more than once
  /// (deduped within the song), so the count is "how many songs carry this
  /// genre". The result is sorted by **count descending, then localized
  /// case-insensitive name ascending** (`localizedCaseInsensitiveCompare`),
  /// which is fully deterministic.
  ///
  /// Frequency-ordered (not alphabetical) on purpose: the dominant genres
  /// read first, so the strip — and any cap on it — shows what the playlist
  /// is *mostly* about rather than an arbitrary alphabetical slice.
  static func genreTally(_ songs: [Song]) -> [String] {
    var counts = [String: Int]()
    for song in songs {
      var seen = Set<String>()
      for raw in song.genreNames {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, seen.insert(name).inserted else { continue }
        counts[name, default: 0] += 1
      }
    }
    return counts
      .sorted { lhs, rhs in
        if lhs.value != rhs.value { return lhs.value > rhs.value }
        return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
      }
      .map(\.key)
  }
}
