import Foundation

// MARK: - TrackRow

/// UI-focused representation of a single playlist entry, read from the local
/// store (NOT a live MusicKit `Track` — local-first pivot). `id` is composed
/// from the row position so a playlist containing the same song twice still
/// has unique, stable row identity. The MusicKit id + namespace travel with
/// the row so `PlaybackResolver` can re-fetch a playable item at play time
/// (the two id spaces are NOT interchangeable — the namespace is required).
struct TrackRow: Identifiable, Hashable, Sendable {
  /// Unique within a playlist: "<position>-<songID>".
  let id: String
  /// 1-based position in the playlist (the boring table's first column).
  let position: Int
  /// `song.id` (app-stable UUID) — the FK target for play recording.
  let songID: String
  /// `MusicItemID.rawValue` as imported.
  let musicItemID: String
  /// Which MusicKit id space `musicItemID` belongs to.
  let namespace: Song.IDNamespace
  let title: String
  let artistName: String
  let albumTitle: String?
  let duration: TimeInterval?
  let isExplicit: Bool
  /// Play rollup from `song_stat` (Phase 4). 0 / nil for a never-played
  /// song. Surfaced as sortable track-table columns.
  let playCount: Int
  let lastPlayedAt: Date?

  /// Re-resolvable artwork (D2): the row already carries the stored song
  /// `MusicItemID` + namespace, which is exactly what `ArtworkProvider`
  /// needs to re-fetch the live `Artwork`.
  var artworkRef: ArtworkRef {
    .song(musicItemID, namespace: namespace)
  }

  //
  // `KeyPathComparator` over an optional sorts unpredictably; these expose
  // stable, non-optional keys so the native column-header sort is
  // well-defined. Missing values sort last under ascending order (empty
  // string / 0 duration / distantPast), matching the "—" placeholder.

  var albumSortKey: String {
    albumTitle ?? ""
  }

  var durationSortKey: TimeInterval {
    duration ?? 0
  }

  /// Never-played → `.distantPast` so ascending puts them first and the
  /// most-recently-played sit at the end (descending = most recent first).
  var lastPlayedSortKey: Date {
    lastPlayedAt ?? .distantPast
  }

  static func ==(lhs: TrackRow, rhs: TrackRow) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

extension TrackRow {
  /// Build a row from a stored `Song` at a 1-based playlist position. Stats
  /// default to "never played" — use `init(songWithStat:position:)` to carry
  /// the joined `song_stat` rollup into the table.
  init(song: Song, position: Int, playCount: Int = 0, lastPlayedAt: Date? = nil) {
    id = "\(position)-\(song.id)"
    self.position = position
    songID = song.id
    musicItemID = song.musicItemID
    namespace = song.idNamespace
    title = song.title
    artistName = song.artistName
    albumTitle = song.albumTitle
    duration = song.duration
    isExplicit = song.isExplicit
    self.playCount = playCount
    self.lastPlayedAt = lastPlayedAt
  }

  /// Build a row from a `song_stat`-joined fetch (the track table's
  /// sortable play-count / last-played columns).
  init(songWithStat row: LibraryStore.SongWithStat, position: Int) {
    self.init(
      song: row.song,
      position: position,
      playCount: row.playCount,
      lastPlayedAt: row.lastPlayedAt,
    )
  }
}
