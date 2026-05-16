import Foundation
import GRDB

/// The app's data API over SQLite. Async read/write only; all DB work runs
/// off the main actor inside GRDB's serialized `DatabaseQueue`.
///
/// Concurrency contract:
/// - `Sendable` and intentionally NOT `@MainActor`. The single stored
///   property is an immutable `AppDatabase` whose `DatabaseQueue` is itself
///   `Sendable` and serialized, so this type is free of shared mutable
///   state. `MusicController` (`@MainActor @Observable`) `await`s these
///   methods and republishes results as observable state.
/// - `read` = snapshot reads; `write` = a single transaction (GRDB commits
///   on success, rolls back on throw). Multi-step invariants (snapshot
///   replace, play accounting) are done inside ONE `write` so they are
///   atomic.
///
/// Extensibility: methods are coarse, intent-named operations ("upsert
/// these songs", "replace this snapshot"), not generic CRUD, so adding a
/// column or table later is a localized change here — callers and the
/// `MusicController` boundary don't move.
struct LibraryStore: Sendable {

  // MARK: Lifecycle

  init(database: AppDatabase) {
    self.database = database
  }

  /// Convenience: open + migrate the production DB. Throws if the store
  /// can't be created (caller decides how to surface it).
  init() throws {
    self.init(database: try AppDatabase.live())
  }

  // MARK: Internal

  /// Recording a play for a song that isn't in the library is a caller
  /// bug (the canonical `local_id` can't be resolved); it aborts the whole
  /// `recordPlay` transaction so `song_stat` stays unchanged.
  enum RecordPlayError: Error, Equatable {
    case unknownSong(String)
  }

  /// Import key, mirrors the DB's `UNIQUE(music_item_id, id_namespace)`.
  struct SongKey: Hashable, Sendable {
    let musicItemID: String
    let namespace: Song.IDNamespace
  }

  /// A song row joined with its `song_stat` rollup, in playlist order. One
  /// indexed LEFT JOIN query (no per-song stat fetch) so the track table
  /// stays fast for large playlists. A song never played has
  /// `playCount == 0` / `lastPlayedAt == nil`.
  struct SongWithStat: Sendable {
    var song: Song
    var playCount: Int
    var lastPlayedAt: Date?
  }

  /// One **distinct** song in the "Recently Played" browse list (NOT a raw
  /// `play_history` row): the song plus the `play_history.seq` of its
  /// **most recent** play and its lifetime `song_stat` rollup. `lastSeq` is
  /// the keyset cursor — pass the last row's `lastSeq` as the next page's
  /// `beforeSeq` (see `recentlyPlayedPage`). A song played three times
  /// appears once, positioned by its newest play.
  struct RecentlyPlayedSong: Sendable {
    var song: Song
    /// `MAX(play_history.seq)` for this song — its most-recent play and the
    /// keyset pagination cursor (strictly monotonic, never reused).
    var lastSeq: Int64
    var playCount: Int
    var lastPlayedAt: Date?
  }

  /// The bounded "last N played" cap (Decision R9, `v3`): `play_history`
  /// keeps at most this many newest rows; `recordPlay` prunes the rest in
  /// the same transaction. It IS the user's original "remember the last
  /// 50,000 songs played" — a single tunable constant (changing N is one
  /// line). Lifetime `song_stat.play_count` is an independent rollup, so
  /// capping history never corrupts true play counts (Decision R5).
  static let playHistoryCap = 50_000

  /// Insert-or-update songs in a SINGLE transaction using a real SQLite
  /// UPSERT, deduped on `(music_item_id, id_namespace)`.
  ///
  /// MusicKit ids are the natural import key, but `song.id` (our UUID) is
  /// the FK target, so the UPSERT's `DO UPDATE` deliberately **does not
  /// touch `id`**: an existing row keeps its stable `id` (and therefore all
  /// playlist/history FK references) while its mutable metadata is
  /// refreshed from the new import. Only a genuinely new key inserts a new
  /// row. This is what makes re-import non-destructive — proven by test.
  ///
  /// Batch idiom (user-flagged perf fix): one chunked multi-row
  /// `INSERT … VALUES (…),(…),… ON CONFLICT(music_item_id, id_namespace)
  /// DO UPDATE SET col = excluded.col …`, all inside one `write`
  /// transaction. No per-row `SELECT`+`update`/`insert`.
  ///
  /// `v3` canonical numeric id: the UPSERT omits `local_id`, so an
  /// existing row keeps its assigned id (same non-destructive re-import
  /// guarantee as the stable `id`); genuinely-new rows are assigned after
  /// the chunk loop (see the inline allocator comment).
  func upsertSongs(_ songs: [Song]) async throws {
    guard !songs.isEmpty else { return }
    // 10 columns/row → keep chunks comfortably under the 999-variable cap.
    let columnsPerRow = 10
    let maxRowsPerChunk = Self.sqliteVariableLimit / columnsPerRow
    try await database.dbQueue.write { db in
      for chunk in songs.chunked(into: maxRowsPerChunk) {
        let placeholders = Array(
          repeating: "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          count: chunk.count,
        ).joined(separator: ", ")
        let sql = """
          INSERT INTO song
            (id, music_item_id, id_namespace, title, artist_name,
             album_title, duration, is_explicit, artwork_url,
             imported_at)
          VALUES \(placeholders)
          ON CONFLICT(music_item_id, id_namespace) DO UPDATE SET
            title       = excluded.title,
            artist_name = excluded.artist_name,
            album_title = excluded.album_title,
            duration    = excluded.duration,
            is_explicit = excluded.is_explicit,
            artwork_url = excluded.artwork_url,
            imported_at = excluded.imported_at
          """
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * columnsPerRow)
        for song in chunk {
          arguments.append(song.id)
          arguments.append(song.musicItemID)
          arguments.append(song.idNamespace.rawValue)
          arguments.append(song.title)
          arguments.append(song.artistName)
          arguments.append(song.albumTitle)
          arguments.append(song.duration)
          arguments.append(song.isExplicit)
          arguments.append(song.artworkURL)
          arguments.append(song.importedAt)
        }
        try db.execute(sql: sql, arguments: StatementArguments(arguments))
      }

      // Assign local_id to genuinely-new rows only. Existing rows keep
      // theirs (the UPSERT never wrote local_id). Skip the allocator
      // entirely on a no-op / fully-incremental re-import that added no
      // new rows — the idx_song_unassigned_local_id partial index makes
      // this probe an O(1) empty-index scan, so the common Refresh case
      // does zero allocator work (mirrors pruneApplePlaylists' early-out).
      let hasNewRows = try Bool.fetchOne(
        db,
        sql: "SELECT EXISTS(SELECT 1 FROM song WHERE local_id IS NULL)",
      ) ?? false
      guard hasNewRows else { return }
      // Dense MAX+1, +2, … in (imported_at, id) order — deterministic
      // and, being in this single serialized write transaction, race-free
      // (same idiom as app_playlist.sort_index's MAX+1).
      try db.execute(sql: """
        UPDATE song SET local_id = base.m + sub.rn
        FROM (SELECT IFNULL(MAX(local_id), 0) AS m FROM song) AS base,
             (SELECT id, ROW_NUMBER() OVER (ORDER BY imported_at, id) AS rn
              FROM song WHERE local_id IS NULL) AS sub
        WHERE song.id = sub.id
        """)
    }
  }

  /// One batched lookup mapping each `(music_item_id, id_namespace)` key to
  /// the stored stable `song.id`. Replaces the per-song N-await re-read
  /// loop in `ImportService` with a single chunked
  /// `WHERE (music_item_id, id_namespace) IN (VALUES …)` query.
  func songIDsByKey(
    _ keys: [(musicItemID: String, namespace: Song.IDNamespace)]
  ) async throws -> [SongKey: String] {
    guard !keys.isEmpty else { return [:] }
    // 2 variables per key → chunk under the 999-variable cap.
    let maxKeysPerChunk = Self.sqliteVariableLimit / 2
    return try await database.dbQueue.read { db in
      var result = [SongKey: String]()
      for chunk in keys.chunked(into: maxKeysPerChunk) {
        let tuples = Array(
          repeating: "(?, ?)",
          count: chunk.count,
        ).joined(separator: ", ")
        let sql = """
          SELECT id, music_item_id, id_namespace
          FROM song
          WHERE (music_item_id, id_namespace) IN (VALUES \(tuples))
          """
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * 2)
        for key in chunk {
          arguments.append(key.musicItemID)
          arguments.append(key.namespace.rawValue)
        }
        let rows = try Row.fetchAll(
          db,
          sql: sql,
          arguments: StatementArguments(arguments),
        )
        for row in rows {
          let id: String = row["id"]
          let mid: String = row["music_item_id"]
          let nsRaw: String = row["id_namespace"]
          if let ns = Song.IDNamespace(rawValue: nsRaw) {
            result[SongKey(musicItemID: mid, namespace: ns)] = id
          }
        }
      }
      return result
    }
  }

  func song(id: String) async throws -> Song? {
    try await database.dbQueue.read { db in
      try Song.fetchOne(db, key: id)
    }
  }

  func song(musicItemID: String, namespace: Song.IDNamespace) async throws -> Song? {
    try await database.dbQueue.read { db in
      try Song
        .filter(Song.Columns.musicItemID == musicItemID)
        .filter(Song.Columns.idNamespace == namespace.rawValue)
        .fetchOne(db)
    }
  }

  /// Every song in the library, materialized into `[Song]`.
  ///
  /// ⚠️ **Residency footgun (Phase B — `plans/memory-and-laziness.md`).**
  /// This loads the entire `song` table into memory and is deliberately
  /// **not** used by any view — the app reads one playlist at a time. Do
  /// **not** back an "All Songs" / catalog list with this: that would
  /// resurrect exactly the "whole library in memory" problem the residency
  /// plan removes. A flat song browser must be windowed at the SQL layer
  /// (keyset / `LIMIT`+`OFFSET`, the deferred Phase D), never this. Kept
  /// only as a store primitive for tests / small bounded callers.
  func allSongs() async throws -> [Song] {
    try await database.dbQueue.read { db in
      try Song.order(Song.Columns.title).fetchAll(db)
    }
  }

  func songCount() async throws -> Int {
    try await database.dbQueue.read { db in
      try Song.fetchCount(db)
    }
  }

  /// Atomically replace one imported Apple playlist's snapshot: upsert the
  /// playlist row, delete its old membership, insert the new ordered
  /// membership — all in a single transaction. `songIDs` must already
  /// exist (call `upsertSongs` first in the SAME import flow).
  ///
  /// Guaranteed NOT to touch `app_playlist*`, `song_stat`, `play_history`,
  /// favorites or recents: this only writes `apple_playlist` and
  /// `apple_playlist_track`. (Verified by test.)
  func replaceApplePlaylistSnapshot(
    _ playlist: ApplePlaylist,
    songIDs: [String],
  ) async throws {
    try await database.dbQueue.write { db in
      var playlist = playlist
      try playlist.save(db)

      try ApplePlaylistTrack
        .filter(ApplePlaylistTrack.Columns.applePlaylistID == playlist.id)
        .deleteAll(db)

      // Chunked multi-row INSERT (3 vars/row) instead of N single-row
      // inserts. A bad song_id still trips FK RESTRICT inside this one
      // transaction, so the whole replace rolls back atomically to the
      // prior snapshot (tested).
      let maxRowsPerChunk = Self.sqliteVariableLimit / 3
      let positioned = Array(songIDs.enumerated())
      for chunk in positioned.chunked(into: maxRowsPerChunk) {
        let placeholders = Array(
          repeating: "(?, ?, ?)",
          count: chunk.count,
        ).joined(separator: ", ")
        let sql = """
          INSERT INTO apple_playlist_track
            (apple_playlist_id, song_id, position)
          VALUES \(placeholders)
          """
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * 3)
        for (position, songID) in chunk {
          arguments.append(playlist.id)
          arguments.append(songID)
          arguments.append(position)
        }
        try db.execute(sql: sql, arguments: StatementArguments(arguments))
      }
    }
  }

  func applePlaylists() async throws -> [ApplePlaylist] {
    try await database.dbQueue.read { db in
      try ApplePlaylist.order(ApplePlaylist.Columns.name).fetchAll(db)
    }
  }

  /// Cheap snapshot state for the incremental-import decision: every
  /// existing Apple-playlist `id` → its stored `change_token` (which may
  /// be `nil`). Key present ⇒ a snapshot exists for that id. Reads only
  /// `apple_playlist` (no track scan), so it stays trivial at library
  /// scale. See `ImportService.importDecision`.
  func applePlaylistChangeTokens() async throws -> [String: Int?] {
    try await database.dbQueue.read { db in
      var result = [String: Int?]()
      let rows = try Row.fetchCursor(
        db,
        sql: "SELECT id, change_token FROM apple_playlist",
      )
      while let row = try rows.next() {
        result[row["id"]] = row["change_token"] as Int?
      }
      return result
    }
  }

  /// Mark an Apple playlist as seen by the current import without
  /// rewriting its (unchanged) membership — the incremental fast path.
  /// Touches only `apple_playlist.last_imported_at`; never the snapshot
  /// tracks, app data, stats, favorites or recents.
  func touchApplePlaylistImportDate(_ id: String, to date: Date) async throws {
    try await database.dbQueue.write { db in
      try db.execute(
        sql: "UPDATE apple_playlist SET last_imported_at = ? WHERE id = ?",
        arguments: [date, id],
      )
    }
  }

  /// Delete Apple-playlist snapshots whose upstream playlist no longer
  /// exists (gone from the library since the last import). FK cascade
  /// drops only their `apple_playlist_track` membership; by schema this
  /// can never touch `app_playlist*`, `song`, `song_stat`, `play_history`,
  /// favorites or recents — the one-way isolation invariant holds. A
  /// no-op when nothing vanished.
  func pruneApplePlaylists(keeping liveIDs: Set<String>) async throws {
    try await database.dbQueue.write { db in
      let storedIDs = try String.fetchSet(
        db,
        sql: "SELECT id FROM apple_playlist",
      )
      let stale = Array(storedIDs.subtracting(liveIDs))
      guard !stale.isEmpty else { return }
      for chunk in stale.chunked(into: Self.sqliteVariableLimit) {
        let placeholders = Array(repeating: "?", count: chunk.count)
          .joined(separator: ", ")
        try db.execute(
          sql: "DELETE FROM apple_playlist WHERE id IN (\(placeholders))",
          arguments: StatementArguments(chunk),
        )
      }
    }
  }

  /// Songs of an imported playlist, in stored playlist order.
  func songs(inApplePlaylist playlistID: String) async throws -> [Song] {
    try await database.dbQueue.read { db in
      let sql = """
        SELECT song.*
        FROM song
        JOIN apple_playlist_track
          ON apple_playlist_track.song_id = song.id
        WHERE apple_playlist_track.apple_playlist_id = ?
        ORDER BY apple_playlist_track.position
        """
      return try Song.fetchAll(db, sql: sql, arguments: [playlistID])
    }
  }

  /// Create a new user-owned playlist. `sortIndex` defaults to "after every
  /// existing app playlist" (computed in the same transaction so two quick
  /// creations don't collide) when not pre-assigned by the caller.
  func createAppPlaylist(_ playlist: AppPlaylist) async throws {
    try await database.dbQueue.write { db in
      var playlist = playlist
      try playlist.insert(db)
    }
  }

  /// Create a playlist named `name`, appended at the end of the sidebar
  /// order, and return the stored record. The `sort_index` is `MAX(...)+1`
  /// computed inside the write so it can't race a concurrent create.
  func createAppPlaylist(named name: String, at createdAt: Date = .now) async throws -> AppPlaylist {
    try await database.dbQueue.write { db in
      let maxSort = try Int.fetchOne(
        db,
        sql: "SELECT MAX(sort_index) FROM app_playlist",
      ) ?? -1
      var playlist = AppPlaylist(
        id: UUID().uuidString,
        name: name,
        createdAt: createdAt,
        updatedAt: createdAt,
        sortIndex: maxSort + 1,
      )
      try playlist.insert(db)
      return playlist
    }
  }

  func appPlaylists() async throws -> [AppPlaylist] {
    try await database.dbQueue.read { db in
      try AppPlaylist.order(AppPlaylist.Columns.sortIndex).fetchAll(db)
    }
  }

  /// Track count per app playlist in ONE grouped query (the sidebar shows a
  /// count; this avoids N per-playlist fetches). Playlists with no tracks
  /// are absent from the map → callers default to 0.
  func appPlaylistTrackCounts() async throws -> [String: Int] {
    try await database.dbQueue.read { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
          SELECT app_playlist_id, COUNT(*) AS n
          FROM app_playlist_track
          GROUP BY app_playlist_id
          """,
      )
      var result = [String: Int]()
      for row in rows {
        let id: String = row["app_playlist_id"]
        result[id] = row["n"] ?? 0
      }
      return result
    }
  }

  /// Rename a user-owned playlist and stamp `updated_at`. One UPDATE; never
  /// touches `apple_playlist*` (a different table entirely).
  func renameAppPlaylist(
    _ playlistID: String,
    to name: String,
    at updatedAt: Date = .now,
  ) async throws {
    try await database.dbQueue.write { db in
      try db.execute(
        sql: """
          UPDATE app_playlist
          SET name = ?, updated_at = ?
          WHERE id = ?
          """,
        arguments: [name, updatedAt, playlistID],
      )
    }
  }

  /// Delete a user-owned playlist. Its `app_playlist_track` membership
  /// cascades (v1 schema FK `ON DELETE CASCADE`); `song`/`song_stat`/
  /// `play_history` are untouched (a song outlives playlist membership).
  func deleteAppPlaylist(_ playlistID: String) async throws {
    try await database.dbQueue.write { db in
      _ = try AppPlaylist.deleteOne(db, key: playlistID)
    }
  }

  /// Append `songIDs` to the end of an app playlist (duplicates allowed —
  /// a song can appear in a playlist more than once). Batch idiom: one
  /// chunked multi-row INSERT in a single transaction, with the starting
  /// position read once inside that transaction so positions stay dense and
  /// can't race a concurrent add. `updated_at` is stamped in the same write.
  func addSongsToAppPlaylist(
    _ playlistID: String,
    songIDs: [String],
    at updatedAt: Date = .now,
  ) async throws {
    guard !songIDs.isEmpty else { return }
    // 3 vars/row → chunk under the 999-variable cap.
    let maxRowsPerChunk = Self.sqliteVariableLimit / 3
    try await database.dbQueue.write { db in
      let nextPosition = try Int.fetchOne(
        db,
        sql: """
          SELECT MAX(position) FROM app_playlist_track
          WHERE app_playlist_id = ?
          """,
        arguments: [playlistID],
      ).map { $0 + 1 } ?? 0

      let positioned = songIDs.enumerated().map {
        (position: nextPosition + $0.offset, songID: $0.element)
      }
      for chunk in positioned.chunked(into: maxRowsPerChunk) {
        let placeholders = Array(
          repeating: "(?, ?, ?)",
          count: chunk.count,
        ).joined(separator: ", ")
        let sql = """
          INSERT INTO app_playlist_track
            (app_playlist_id, song_id, position)
          VALUES \(placeholders)
          """
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * 3)
        for entry in chunk {
          arguments.append(playlistID)
          arguments.append(entry.songID)
          arguments.append(entry.position)
        }
        try db.execute(sql: sql, arguments: StatementArguments(arguments))
      }
      try Self.touchAppPlaylist(db, playlistID, at: updatedAt)
    }
  }

  /// Remove specific rows (by their playlist `position`) from an app
  /// playlist, then renumber the survivors so positions stay dense (the
  /// composite PK is `(app_playlist_id, position)`). Batch idiom: ONE
  /// chunked `IN` delete, then a single ordered re-read + chunked multi-row
  /// re-insert — all inside one transaction (atomic).
  func removeTracksFromAppPlaylist(
    _ playlistID: String,
    positions: [Int],
    at updatedAt: Date = .now,
  ) async throws {
    guard !positions.isEmpty else { return }
    try await database.dbQueue.write { db in
      // Delete the targeted positions (chunked IN — 1 var per position
      // plus the playlist id).
      let maxPerChunk = Self.sqliteVariableLimit - 1
      for chunk in positions.chunked(into: maxPerChunk) {
        let inList = Array(repeating: "?", count: chunk.count)
          .joined(separator: ", ")
        var arguments: [(any DatabaseValueConvertible)?] = [playlistID]
        arguments.append(contentsOf: chunk.map { $0 })
        try db.execute(
          sql: """
            DELETE FROM app_playlist_track
            WHERE app_playlist_id = ?
              AND position IN (\(inList))
            """,
          arguments: StatementArguments(arguments),
        )
      }
      try Self.renumberAppPlaylist(db, playlistID)
      try Self.touchAppPlaylist(db, playlistID, at: updatedAt)
    }
  }

  /// Replace an app playlist's ordered membership in one transaction. Used
  /// both to set the whole list and to reorder it (the new order is the
  /// authoritative full membership). Batch idiom: ONE chunked multi-row
  /// INSERT after a single bulk DELETE — no per-row insert loop.
  func setAppPlaylistTracks(
    _ playlistID: String,
    songIDs: [String],
    at updatedAt: Date = .now,
  ) async throws {
    let maxRowsPerChunk = Self.sqliteVariableLimit / 3
    try await database.dbQueue.write { db in
      try AppPlaylistTrack
        .filter(AppPlaylistTrack.Columns.appPlaylistID == playlistID)
        .deleteAll(db)

      let positioned = Array(songIDs.enumerated())
      for chunk in positioned.chunked(into: maxRowsPerChunk) {
        let placeholders = Array(
          repeating: "(?, ?, ?)",
          count: chunk.count,
        ).joined(separator: ", ")
        let sql = """
          INSERT INTO app_playlist_track
            (app_playlist_id, song_id, position)
          VALUES \(placeholders)
          """
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * 3)
        for (position, songID) in chunk {
          arguments.append(playlistID)
          arguments.append(songID)
          arguments.append(position)
        }
        try db.execute(sql: sql, arguments: StatementArguments(arguments))
      }
      try Self.touchAppPlaylist(db, playlistID, at: updatedAt)
    }
  }

  /// Persist a new sidebar order for the user-owned playlists. `orderedIDs`
  /// is the full list of app-playlist ids in display order; each row's
  /// `sort_index` becomes its index. Batch idiom: one chunked
  /// `CASE`-driven UPDATE per chunk inside a single transaction — never an
  /// N-statement per-row loop.
  func reorderAppPlaylists(_ orderedIDs: [String]) async throws {
    guard !orderedIDs.isEmpty else { return }
    // Each id contributes 2 bind vars to the CASE (WHEN id THEN index)
    // plus 1 to the IN list → ~3/id; chunk well under the cap.
    let maxPerChunk = Self.sqliteVariableLimit / 3
    try await database.dbQueue.write { db in
      for chunk in Array(orderedIDs.enumerated()).chunked(into: maxPerChunk) {
        let whenClauses = chunk
          .map { _ in "WHEN ? THEN ?" }
          .joined(separator: " ")
        let inList = Array(repeating: "?", count: chunk.count)
          .joined(separator: ", ")
        var arguments = [(any DatabaseValueConvertible)?]()
        for (index, id) in chunk {
          arguments.append(id)
          arguments.append(index)
        }
        arguments.append(contentsOf: chunk.map { $0.element })
        try db.execute(
          sql: """
            UPDATE app_playlist
            SET sort_index = CASE id \(whenClauses) END
            WHERE id IN (\(inList))
            """,
          arguments: StatementArguments(arguments),
        )
      }
    }
  }

  func songs(inAppPlaylist playlistID: String) async throws -> [Song] {
    try await database.dbQueue.read { db in
      let sql = """
        SELECT song.*
        FROM song
        JOIN app_playlist_track
          ON app_playlist_track.song_id = song.id
        WHERE app_playlist_track.app_playlist_id = ?
        ORDER BY app_playlist_track.position
        """
      return try Song.fetchAll(db, sql: sql, arguments: [playlistID])
    }
  }

  func songsWithStats(inApplePlaylist playlistID: String) async throws -> [SongWithStat] {
    try await songsWithStats(joining: "apple_playlist_track", playlistColumn: "apple_playlist_id", playlistID)
  }

  func songsWithStats(inAppPlaylist playlistID: String) async throws -> [SongWithStat] {
    try await songsWithStats(joining: "app_playlist_track", playlistColumn: "app_playlist_id", playlistID)
  }

  /// Record that `songID` started playing at `playedAt`. ONE transaction:
  /// resolve the song's canonical `local_id`, roll `song_stat` forward,
  /// append a `play_history` row, then prune history beyond
  /// `playHistoryCap`.
  ///
  /// A play for a song not in the library aborts the whole transaction
  /// (the `local_id` lookup throws), so `song_stat` stays unchanged —
  /// preserving the "play for a missing song is rejected and stat
  /// unchanged" guarantee the old `play_event` FK RESTRICT gave.
  /// `song_stat` is upserted (created at count 1 on the first play,
  /// incremented thereafter); `last_played_at` only advances (a backfilled
  /// older play won't move it backwards). `play_history` is the bounded
  /// "last N played"; pruning is a cheap keyset
  /// (`DELETE WHERE seq <= MAX(seq) - cap`) in the same write, so history
  /// can never grow past the cap while `song_stat.play_count` keeps the
  /// true lifetime count (the two are independent — Decision R5).
  func recordPlay(songID: String, at playedAt: Date = .now) async throws {
    try await database.dbQueue.write { db in
      guard
        let localID = try Int.fetchOne(
          db,
          sql: "SELECT local_id FROM song WHERE id = ?",
          arguments: [songID],
        )
      else {
        throw RecordPlayError.unknownSong(songID)
      }

      if var stat = try SongStat.fetchOne(db, key: songID) {
        stat.playCount += 1
        if let last = stat.lastPlayedAt {
          stat.lastPlayedAt = max(last, playedAt)
        } else {
          stat.lastPlayedAt = playedAt
        }
        try stat.update(db)
      } else {
        var stat = SongStat(
          songID: songID,
          playCount: 1,
          lastPlayedAt: playedAt,
        )
        try stat.insert(db)
      }

      var entry = PlayHistoryEntry(seq: nil, songLocalID: localID)
      try entry.insert(db)

      try db.execute(
        sql: """
          DELETE FROM play_history
          WHERE seq <= (SELECT MAX(seq) FROM play_history) - ?
          """,
        arguments: [Self.playHistoryCap],
      )
    }
  }

  /// Increment `song_stat.skip_count` for `songID` ("next" pressed before
  /// halfway). Upsert-or-insert (new row → `skip_count 1`, everything else
  /// at its default). **Never touches `play_history`** — a skip is not a
  /// play (Decision R4).
  ///
  /// A skip for a song not in the library throws: the `song_stat`→`song`
  /// FK trips on the insert (a raw GRDB `DatabaseError`, *not*
  /// `RecordPlayError`). This deliberately differs from `recordPlay`,
  /// which must resolve `local_id` for the history append anyway and so
  /// can raise a typed error for free — the counter-only paths skip that
  /// lookup and let the FK enforce the identical precondition.
  func recordSkip(songID: String) async throws {
    try await database.dbQueue.write { db in
      try Self.bumpStatCounter(db, songID: songID, \.skipCount)
    }
  }

  /// Increment `song_stat.replay_count` for `songID` ("back" pressed after
  /// halfway). Upsert-or-insert (new row → `replay_count 1`, everything
  /// else at its default). **Never touches `play_history`** — a replay is
  /// not a new history entry (Decision R4). Unknown-song behavior is the
  /// same FK-enforced `DatabaseError` as `recordSkip`.
  func recordReplay(songID: String) async throws {
    try await database.dbQueue.write { db in
      try Self.bumpStatCounter(db, songID: songID, \.replayCount)
    }
  }

  func songStat(songID: String) async throws -> SongStat? {
    try await database.dbQueue.read { db in
      try SongStat.fetchOne(db, key: songID)
    }
  }

  /// The bounded play history as the user's compact numeric vector:
  /// `song.local_id`s, newest first, duplicates preserved. Defaults to the
  /// whole capped history.
  func recentlyPlayedSongLocalIDs(limit: Int = playHistoryCap) async throws -> [Int] {
    try await database.dbQueue.read { db in
      try Int.fetchAll(
        db,
        sql: """
          SELECT song_local_id FROM play_history
          ORDER BY seq DESC LIMIT ?
          """,
        arguments: [limit],
      )
    }
  }

  /// Convenience for callers that need the relational `song.id`: the same
  /// newest-first history joined to `song`, duplicates and order preserved.
  func recentlyPlayedSongIDs(limit: Int = playHistoryCap) async throws -> [String] {
    try await database.dbQueue.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT s.id
          FROM play_history h
          JOIN song s ON s.local_id = h.song_local_id
          ORDER BY h.seq DESC
          LIMIT ?
          """,
        arguments: [limit],
      )
    }
  }

  /// One page of the **"Recently Played" browse list**: *distinct* songs,
  /// each at its **most-recent** play, newest first (NOT the raw repeated
  /// `play_history` — a song played many times appears once, at its latest
  /// position). The list is keyset-paginated as the user scrolls.
  ///
  /// `beforeSeq == nil` → the first page. To fetch the next page, pass the
  /// `lastSeq` of the **last** row of the page just shown as `beforeSeq`;
  /// the `HAVING MAX(h.seq) < :beforeSeq` then returns the slice strictly
  /// older than that cursor. A short / empty page means the end.
  ///
  /// Keyset, not `LIMIT … OFFSET`: `seq` is the `play_history` PK
  /// (AUTOINCREMENT, strictly monotonic, never reused), so the per-song
  /// `MAX(seq)` cursor is stable for the unchanged history — no dup, no
  /// gap in the distinct set, whereas OFFSET would shift every prior row
  /// under it. A new play only mints a *higher* seq (above any cursor
  /// already handed out), so a brand-new song never disturbs later pages.
  /// One eventual-consistency nuance, by design (not a gap): if a song
  /// that was *already* paginated is replayed mid-scroll, its `MAX(seq)`
  /// floats above the live cursor, so it is not re-emitted in a later
  /// page and its already-rendered row stays at its older position until
  /// a `reload()` re-floats it to the top. The `GROUP BY` is
  /// over at most `playHistoryCap` (50k) rows and `seq` is the integer PK,
  /// so the grouped scan + `MAX(seq)` stays cheap at library scale (no
  /// per-song subquery, one pass).
  func recentlyPlayedPage(
    beforeSeq: Int64?,
    limit: Int,
  ) async throws -> [RecentlyPlayedSong] {
    try await database.dbQueue.read { db in
      // The keyset predicate is applied only on subsequent pages
      // (`beforeSeq != nil`); the first page has no cursor. Interpolating a
      // fixed clause (never user input) keeps the two shapes one query.
      let havingClause = beforeSeq == nil ? "" : "HAVING MAX(h.seq) < ?"
      let sql = """
        SELECT s.*, MAX(h.seq) AS last_seq,
               COALESCE(st.play_count, 0) AS pc,
               st.last_played_at AS lpa
        FROM play_history h
        JOIN song s  ON s.local_id = h.song_local_id
        LEFT JOIN song_stat st ON st.song_id = s.id
        GROUP BY h.song_local_id
        \(havingClause)
        ORDER BY last_seq DESC
        LIMIT ?
        """
      var arguments = [(any DatabaseValueConvertible)?]()
      if let beforeSeq { arguments.append(beforeSeq) }
      arguments.append(limit)
      let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
      return try rows.map { row in
        RecentlyPlayedSong(
          song: try Song(row: row),
          lastSeq: row["last_seq"],
          playCount: row["pc"] ?? 0,
          lastPlayedAt: row["lpa"],
        )
      }
    }
  }

  /// Debug-only: seed up to `count` synthetic plays drawn at random from
  /// songs that are a member of *some* playlist (Apple or app), so the
  /// "Recently Played" surface is testable without listening to hundreds of
  /// songs. Mirrors `recordPlay`'s per-row work for each picked song
  /// (resolve `local_id`; upsert `song_stat` play_count/last_played_at;
  /// append a `play_history` row) **in one write transaction**, pruning
  /// beyond `playHistoryCap` **once** at the end (snappy debug action — not
  /// 500 separate transactions). Returns the number actually seeded (`0`
  /// when the library has no playlist-member songs yet). `last_played_at`
  /// is staggered slightly per song so the column isn't all-identical.
  @discardableResult
  func seedRandomPlayHistory(count: Int) async throws -> Int {
    guard count > 0 else { return 0 }
    return try await database.dbQueue.write { db in
      let songIDs = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM song
          WHERE id IN (
            SELECT song_id FROM apple_playlist_track
            UNION
            SELECT song_id FROM app_playlist_track
          )
          ORDER BY RANDOM()
          LIMIT ?
          """,
        arguments: [count],
      )
      guard !songIDs.isEmpty else { return 0 }
      let now = Date.now
      for (index, songID) in songIDs.enumerated() {
        // Resolve canonical local_id — the membership query already
        // guarantees the row exists, so this is always non-nil here.
        guard
          let localID = try Int.fetchOne(
            db,
            sql: "SELECT local_id FROM song WHERE id = ?",
            arguments: [songID],
          )
        else { continue }
        // Minor realism: stagger the timestamp a few seconds per song so
        // `last_played_at` isn't a single identical value across the seed.
        let playedAt = now.addingTimeInterval(-Double(index) * 3)
        if var stat = try SongStat.fetchOne(db, key: songID) {
          stat.playCount += 1
          if let last = stat.lastPlayedAt {
            stat.lastPlayedAt = max(last, playedAt)
          } else {
            stat.lastPlayedAt = playedAt
          }
          try stat.update(db)
        } else {
          var stat = SongStat(songID: songID, playCount: 1, lastPlayedAt: playedAt)
          try stat.insert(db)
        }
        var entry = PlayHistoryEntry(seq: nil, songLocalID: localID)
        try entry.insert(db)
      }
      // Prune ONCE at the end (not per row), same keyset as `recordPlay`.
      try db.execute(
        sql: """
          DELETE FROM play_history
          WHERE seq <= (SELECT MAX(seq) FROM play_history) - ?
          """,
        arguments: [Self.playHistoryCap],
      )
      return songIDs.count
    }
  }

  func setFavorite(_ isFavorite: Bool, playlistID: String, source: PlaylistSourceKind) async throws {
    try await database.dbQueue.write { db in
      if isFavorite {
        var row = FavoritePlaylist(playlistID: playlistID, source: source)
        try row.save(db)
      } else {
        _ = try FavoritePlaylist.deleteOne(db, key: playlistID)
      }
    }
  }

  func isFavorite(playlistID: String) async throws -> Bool {
    try await database.dbQueue.read { db in
      try FavoritePlaylist.fetchOne(db, key: playlistID) != nil
    }
  }

  func favorites() async throws -> [FavoritePlaylist] {
    try await database.dbQueue.read { db in
      try FavoritePlaylist.fetchAll(db)
    }
  }

  /// Bump (or create) the recent entry for a playlist. The "recents list"
  /// is this table read back ordered by `played_at DESC` and capped, so
  /// re-playing just advances the timestamp (no duplicate rows).
  func recordRecent(playlistID: String, source: PlaylistSourceKind, at playedAt: Date = .now) async throws {
    try await database.dbQueue.write { db in
      var row = RecentPlaylist(playlistID: playlistID, source: source, playedAt: playedAt)
      try row.save(db)
    }
  }

  func recentPlaylists(limit: Int = 12) async throws -> [RecentPlaylist] {
    try await database.dbQueue.read { db in
      try RecentPlaylist
        .order(RecentPlaylist.Columns.playedAt.desc)
        .limit(limit)
        .fetchAll(db)
    }
  }

  // MARK: Private

  /// SQLite hard-limits a statement to 999 bound parameters (the historical
  /// `SQLITE_MAX_VARIABLE_NUMBER`). Every batched multi-row statement here
  /// chunks its rows so the bound-parameter count stays well under that
  /// ceiling regardless of import size.
  private static let sqliteVariableLimit = 999

  private let database: AppDatabase

  /// Upsert-or-insert `song_stat` for `songID`, incrementing the single
  /// `Int` column at `counter` by one (a new row starts that counter at 1,
  /// every other column at its struct default). The mechanically-identical
  /// bump behind `recordSkip` / `recordReplay` — only the key path
  /// differs, so they stay one-liners instead of duplicated blocks. Runs
  /// in the caller's write transaction; never touches `play_history` (R4).
  private static func bumpStatCounter(
    _ db: Database,
    songID: String,
    _ counter: WritableKeyPath<SongStat, Int>,
  ) throws {
    if var stat = try SongStat.fetchOne(db, key: songID) {
      stat[keyPath: counter] += 1
      try stat.update(db)
    } else {
      var stat = SongStat(songID: songID, playCount: 0, lastPlayedAt: nil)
      stat[keyPath: counter] = 1
      try stat.insert(db)
    }
  }

  /// Compact an app playlist's positions to 0..<count in current order.
  /// Called after a delete so the composite PK never has gaps. Reads the
  /// survivors once, deletes all, re-inserts in order — all within the
  /// caller's transaction.
  private static func renumberAppPlaylist(
    _ db: Database,
    _ playlistID: String,
  ) throws {
    let songIDs = try String.fetchAll(
      db,
      sql: """
        SELECT song_id FROM app_playlist_track
        WHERE app_playlist_id = ?
        ORDER BY position
        """,
      arguments: [playlistID],
    )
    try AppPlaylistTrack
      .filter(AppPlaylistTrack.Columns.appPlaylistID == playlistID)
      .deleteAll(db)
    let maxRowsPerChunk = sqliteVariableLimit / 3
    for chunk in Array(songIDs.enumerated()).chunked(into: maxRowsPerChunk) {
      let placeholders = Array(
        repeating: "(?, ?, ?)",
        count: chunk.count,
      ).joined(separator: ", ")
      var arguments = [(any DatabaseValueConvertible)?]()
      for (position, songID) in chunk {
        arguments.append(playlistID)
        arguments.append(songID)
        arguments.append(position)
      }
      try db.execute(
        sql: """
          INSERT INTO app_playlist_track
            (app_playlist_id, song_id, position)
          VALUES \(placeholders)
          """,
        arguments: StatementArguments(arguments),
      )
    }
  }

  private static func touchAppPlaylist(
    _ db: Database,
    _ playlistID: String,
    at updatedAt: Date,
  ) throws {
    try db.execute(
      sql: "UPDATE app_playlist SET updated_at = ? WHERE id = ?",
      arguments: [updatedAt, playlistID],
    )
  }

  /// Shared body: ordered membership LEFT JOIN `song_stat`. The membership
  /// table / column are interpolated from a fixed allow-listed set (never
  /// user input), so this is not an injection surface.
  private func songsWithStats(
    joining membershipTable: String,
    playlistColumn: String,
    _ playlistID: String,
  ) async throws -> [SongWithStat] {
    try await database.dbQueue.read { db in
      let sql = """
        SELECT
          song.*,
          COALESCE(song_stat.play_count, 0)  AS stat_play_count,
          song_stat.last_played_at           AS stat_last_played_at
        FROM song
        JOIN \(membershipTable)
          ON \(membershipTable).song_id = song.id
        LEFT JOIN song_stat
          ON song_stat.song_id = song.id
        WHERE \(membershipTable).\(playlistColumn) = ?
        ORDER BY \(membershipTable).position
        """
      let rows = try Row.fetchAll(db, sql: sql, arguments: [playlistID])
      return try rows.map { row in
        SongWithStat(
          song: try Song(row: row),
          playCount: row["stat_play_count"] ?? 0,
          lastPlayedAt: row["stat_last_played_at"],
        )
      }
    }
  }

}
