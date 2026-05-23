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

  /// `internal` (not `private`) so cross-file `LibraryStore+…` extensions
  /// can drive the same `DatabaseQueue` (e.g. `LibraryStore+GenreMap`).
  /// Otherwise unchanged — the queue itself is immutable + serialized, so
  /// widening access doesn't widen the concurrency surface.
  let database: AppDatabase

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
    // 10 base + 9 "free" v4 metadata columns/row = 19 → 999 / 19 = 52 rows
    // per chunk, ~988 bound vars: still comfortably under the 999 cap.
    let columnsPerRow = 19
    let maxRowsPerChunk = Self.sqliteVariableLimit / columnsPerRow
    try await database.dbQueue.write { db in
      for chunk in songs.chunked(into: maxRowsPerChunk) {
        let placeholders = Array(
          repeating: "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, "
            + "?, ?, ?, ?, ?, ?, ?, ?, ?)",
          count: chunk.count,
        ).joined(separator: ", ")
        let sql = """
          INSERT INTO song
            (id, music_item_id, id_namespace, title, artist_name,
             album_title, duration, is_explicit, artwork_url,
             imported_at,
             track_number, disc_number, genre_names, release_date,
             composer_name, isrc, has_lyrics, work_name, movement_name)
          VALUES \(placeholders)
          ON CONFLICT(music_item_id, id_namespace) DO UPDATE SET
            title         = excluded.title,
            artist_name   = excluded.artist_name,
            album_title   = excluded.album_title,
            duration      = excluded.duration,
            is_explicit   = excluded.is_explicit,
            artwork_url   = excluded.artwork_url,
            imported_at   = excluded.imported_at,
            track_number  = excluded.track_number,
            disc_number   = excluded.disc_number,
            genre_names   = excluded.genre_names,
            release_date  = excluded.release_date,
            composer_name = excluded.composer_name,
            isrc          = excluded.isrc,
            has_lyrics    = excluded.has_lyrics,
            work_name     = excluded.work_name,
            movement_name = excluded.movement_name
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
          // "Free" v4 metadata. genre_names is the JSON-array string (nil
          // when empty); has_lyrics Bool? → 0/1/NULL via DatabaseValue;
          // release_date is a Date? passed exactly like imported_at.
          arguments.append(song.trackNumber)
          arguments.append(song.discNumber)
          arguments.append(Song.encodeGenreNames(song.genreNames))
          arguments.append(song.releaseDate)
          arguments.append(song.composerName)
          arguments.append(song.isrc)
          arguments.append(song.hasLyrics)
          arguments.append(song.workName)
          arguments.append(song.movementName)
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

  /// Apply album-derived genres onto the matching library `song` rows in
  /// ONE write transaction.
  ///
  /// Input is keyed by the track's library `music_item_id` — NOT `song.id`
  /// — because that is the only id the caller has: `GenreImportService`
  /// walks `MusicLibraryRequest<Album>` → `album.with([.tracks])` and
  /// unwraps each `Track` to its underlying-item id exactly the way
  /// `ImportService.song(from:)` does (the durable id we already store as
  /// `song.music_item_id`). It never sees our minted `song.id`. There is no
  /// album entity/table — genre lives on the track rows, where the v4
  /// `genre_names` column already is; this only writes that one column.
  ///
  /// Batch idiom: the same chunked `CASE`-driven UPDATE as
  /// `reorderAppPlaylists` — one `UPDATE song SET genre_names =
  /// CASE music_item_id WHEN ? THEN ? … END WHERE music_item_id IN (…) AND
  /// id_namespace = ?` per chunk, never an N-statement per-row loop and
  /// never an UPSERT (these rows already exist — import wrote them; genre
  /// is a refinement, not an insert). The JSON form goes through
  /// `Song.encodeGenreNames` so it round-trips identically to the
  /// `upsertSongs` path; callers don't pass empty lists (an empty album
  /// genre is skipped upstream), so the `[]`→NULL branch is not exercised
  /// here. Library namespace only — every imported track is `.library` by
  /// provenance (the D1 corrective), so a catalog row that happens to share
  /// a `music_item_id` is deliberately untouched.
  ///
  /// Returns the accumulated `db.changesCount` (rows updated) so the caller
  /// can surface coarse progress / verify the pass did work.
  @discardableResult
  func applyAlbumGenres(_ genreByMusicItemID: [String: [String]]) async throws -> Int {
    guard !genreByMusicItemID.isEmpty else { return 0 }
    // Each entry contributes 2 bind vars to the CASE (WHEN id THEN json)
    // plus 1 to the IN list → 3/entry; the namespace adds one fixed var
    // per statement. The `-1` reserves that trailing namespace bind so the
    // worst-case chunk is 3·332+1 = 997 ≤ the 999-variable budget (unlike
    // `reorderAppPlaylists`, which has no trailing bind and lands at 999).
    let maxPerChunk = (Self.sqliteVariableLimit - 1) / 3
    let entries = Array(genreByMusicItemID)
    return try await database.dbQueue.write { db in
      var changed = 0
      for chunk in entries.chunked(into: maxPerChunk) {
        let whenClauses = chunk
          .map { _ in "WHEN ? THEN ?" }
          .joined(separator: " ")
        let inList = Array(repeating: "?", count: chunk.count)
          .joined(separator: ", ")
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * 3 + 1)
        for (musicItemID, genreNames) in chunk {
          arguments.append(musicItemID)
          arguments.append(Song.encodeGenreNames(genreNames))
        }
        arguments.append(contentsOf: chunk.map { $0.key })
        arguments.append(Song.IDNamespace.library.rawValue)
        try db.execute(
          sql: """
            UPDATE song
            SET genre_names = CASE music_item_id \(whenClauses) END
            WHERE music_item_id IN (\(inList)) AND id_namespace = ?
            """,
          arguments: StatementArguments(arguments),
        )
        changed += db.changesCount
      }
      return changed
    }
  }

  /// Rebuild the **genre co-occurrence graph** from scratch over the
  /// playlists (Apple imported snapshots + user-owned app playlists) — the
  /// "Analyze" action. Two genres are related when a track of one and a
  /// track of the other appear in the same (eligible) playlist; the edge
  /// weight is the number of **distinct** such playlists.
  ///
  /// **Two analysis thresholds** shape the graph at its source (the
  /// principled place — they affect the persisted graph and every consumer,
  /// and are user-tunable in the Advanced settings pane):
  ///
  /// - `maxPlaylistTracks` — a playlist with more tracks than this is
  ///   excluded entirely. A playlist clique-connects all its genres
  ///   (quadratic), so a few enormous lists ("every track WLIR played for 8
  ///   years") alone push the graph to near-complete. Dropping the giants
  ///   removes the dominant noise source. **NB:** this is documented
  ///   defense-in-depth, NOT the playlist-folder fix — that is
  ///   `PlaylistFolderClassifier` + `LibraryStore.deleteApplePlaylists`
  ///   (folders never become rows / are actively converged). A *small*
  ///   folder still needs the classifier, and a *large real* playlist must
  ///   not be excluded; this threshold is orthogonal to folder correctness.
  /// - `maxPairsPerPlaylist` — each eligible playlist contributes only its
  ///   **top-N genre pairs by intra-playlist co-strength**, where strength =
  ///   `min(distinct tracks of genre A, distinct tracks of genre B)` in that
  ///   playlist. `min` is high only when *both* genres are substantially
  ///   present, so one stray track can't mint a strong pair and one
  ///   dominant genre can't either. This caps the `G·(G−1)/2` quadratic
  ///   per-playlist blow-up to its strongest, most meaningful links.
  ///
  /// One `DELETE` + one CTE-driven `INSERT … SELECT … UNION ALL`, in a
  /// SINGLE write transaction. Wholesale (never row-by-row) so the table is
  /// consistent by construction — including the two mirrored directions of
  /// every undirected edge (see `genre_edge` / `LibraryMigrator` `v6`).
  /// Idempotent for fixed inputs + thresholds.
  ///
  /// All the graph mess stays in CTEs:
  /// - `membership` — every `(playlist, song)` across BOTH libraries, under
  ///   a source-prefixed composite playlist key so an Apple and an app
  ///   playlist can't collide.
  /// - `eligible` — playlists whose `COUNT(*)` membership is
  ///   `<= maxPlaylistTracks` (threshold a). Everything downstream joins
  ///   through this, so oversized playlists never enter the graph.
  /// - `playlist_genre` — explode `genre_names` with `json_each` and, per
  ///   `(eligible playlist, genre)`, count the distinct tracks of that
  ///   genre (the strength input). NULL / invalid / blank genre JSON is
  ///   filtered (`json_valid` so a malformed value can't abort the rebuild).
  /// - `pair` — self-join on `a.genre < b.genre` (drops self-pairs *and* the
  ///   mirror), carrying `strength = min(track_ct_a, track_ct_b)`.
  /// - `ranked` — `ROW_NUMBER()` per playlist by strength desc (deterministic
  ///   name tiebreak); `kept` keeps `rn <= maxPairsPerPlaylist` (threshold b).
  /// - `edge` — `COUNT(DISTINCT playlist_key)` over the kept per-playlist
  ///   pairs = the weight.
  ///
  /// The final `SELECT … UNION ALL SELECT (swapped)` materializes BOTH
  /// directed half-edges; the two halves can't collide on the
  /// `(genre_a, genre_b)` PK (one is `a<b`, the other `a>b`), and an empty
  /// library inserts nothing. The two `?` binds are, in textual order,
  /// `maxPlaylistTracks` then `maxPairsPerPlaylist`.
  ///
  /// Touches ONLY `genre_edge` — derived, read-only state; `song`,
  /// `apple_playlist*`, `app_playlist*`, `song_stat`, `play_history`,
  /// favorites and recents are never read-for-write nor mutated (one-way,
  /// test-verified). Returns the rebuilt edge-row count (both directions).
  @discardableResult
  func rebuildGenreGraph(
    maxPlaylistTracks: Int,
    maxPairsPerPlaylist: Int,
  ) async throws -> Int {
    try await database.dbQueue.write { db in
      try db.execute(sql: "DELETE FROM genre_edge")
      try db.execute(
        sql: """
          INSERT INTO genre_edge (genre_a, genre_b, weight)
          WITH
            membership(playlist_key, song_id) AS (
              SELECT 'apple:' || apple_playlist_id, song_id
                FROM apple_playlist_track
              UNION ALL
              SELECT 'app:' || app_playlist_id, song_id
                FROM app_playlist_track
            ),
            eligible(playlist_key) AS (
              SELECT playlist_key
                FROM membership
               GROUP BY playlist_key
              HAVING COUNT(*) <= ?
            ),
            playlist_genre(playlist_key, genre, track_ct) AS (
              SELECT m.playlist_key, TRIM(je.value),
                     COUNT(DISTINCT m.song_id)
                FROM membership m
                JOIN eligible e ON e.playlist_key = m.playlist_key
                JOIN song s ON s.id = m.song_id
                JOIN json_each(s.genre_names) je
               WHERE s.genre_names IS NOT NULL
                 AND json_valid(s.genre_names)
                 AND je.value IS NOT NULL
                 AND TRIM(je.value) <> ''
               GROUP BY m.playlist_key, TRIM(je.value)
            ),
            pair(playlist_key, genre_a, genre_b, strength) AS (
              SELECT a.playlist_key, a.genre, b.genre,
                     MIN(a.track_ct, b.track_ct)
                FROM playlist_genre a
                JOIN playlist_genre b
                  ON a.playlist_key = b.playlist_key
                 AND a.genre < b.genre
            ),
            ranked(playlist_key, genre_a, genre_b, rn) AS (
              SELECT playlist_key, genre_a, genre_b,
                     ROW_NUMBER() OVER (
                       PARTITION BY playlist_key
                       ORDER BY strength DESC, genre_a, genre_b
                     )
                FROM pair
            ),
            kept(playlist_key, genre_a, genre_b) AS (
              SELECT playlist_key, genre_a, genre_b
                FROM ranked
               WHERE rn <= ?
            ),
            edge(genre_a, genre_b, weight) AS (
              SELECT genre_a, genre_b, COUNT(DISTINCT playlist_key)
                FROM kept
               GROUP BY genre_a, genre_b
            )
          SELECT genre_a, genre_b, weight FROM edge
          UNION ALL
          SELECT genre_b, genre_a, weight FROM edge
          """,
        arguments: [maxPlaylistTracks, maxPairsPerPlaylist],
      )
      return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM genre_edge") ?? 0
    }
  }

  /// The genres related to `genre`, strongest first — a direct adjacency
  /// lookup (`WHERE genre_a = ?`, covered by the `genre_edge` PK's leftmost
  /// prefix). `genreB` is the neighbour, `weight` how many playlists they
  /// share. Capped (a node can have a long tail of weak edges).
  func relatedGenres(to genre: String, limit: Int = 50) async throws -> [GenreEdge] {
    try await database.dbQueue.read { db in
      try GenreEdge
        .filter(GenreEdge.Columns.genreA == genre)
        .order(GenreEdge.Columns.weight.desc, GenreEdge.Columns.genreB)
        .limit(limit)
        .fetchAll(db)
    }
  }

  /// The whole genre graph as its directed half-edges (both directions),
  /// strongest first then alphabetical. For export / a future graph view /
  /// tests — not a per-view hot path (the graph is small relative to the
  /// song table; it is one row per related genre pair, twice).
  func genreGraphEdges() async throws -> [GenreEdge] {
    try await database.dbQueue.read { db in
      try GenreEdge
        .order(
          GenreEdge.Columns.weight.desc,
          GenreEdge.Columns.genreA,
          GenreEdge.Columns.genreB,
        )
        .fetchAll(db)
    }
  }

  /// The playlists associated with a focused `genre` — or, when
  /// `neighbor` is given, only the playlists pertinent to the `genre ↔
  /// neighbor` **edge** (where *both* genres co-occur). Sorted by strength
  /// of association descending, then name; capped at `limit` so the corner
  /// card stays sane.
  ///
  /// Strength: for one genre = distinct tracks of that genre in the
  /// playlist; for an edge = `min(tracks of genre, tracks of neighbor)` —
  /// the same pair co-strength `rebuildGenreGraph` ranks by, so the listed
  /// edge playlists line up with what formed the link. A read derived live
  /// from `song.genre_names` + membership (the association isn't persisted;
  /// only `genre_edge` is). The size-eligibility / per-playlist top-N
  /// thresholds are deliberately NOT applied here: this lists *all*
  /// playlists a genre genuinely appears in (the honest "associated"
  /// answer), not the curated edge-contribution subset. Read-only; one
  /// `read`. The two CTE shapes are kept separate (graph SQL is a mess —
  /// readability over cleverness).
  func associatedPlaylists(
    genre: String,
    neighbor: String?,
    limit: Int,
  ) async throws -> [PlaylistAssociation] {
    try await database.dbQueue.read { db in
      let membershipCTE = """
        membership(pkey, source, pid, song_id) AS (
          SELECT 'apple:' || apple_playlist_id, 'apple',
                 apple_playlist_id, song_id
            FROM apple_playlist_track
          UNION ALL
          SELECT 'app:' || app_playlist_id, 'app',
                 app_playlist_id, song_id
            FROM app_playlist_track
        )
        """
      // Name resolution is identical for both shapes: the result CTE
      // yields (pid, source, strength); join to the right name table.
      // `name` is ambiguous (both joined tables have one) and SQLite
      // can't use a SELECT alias in WHERE — so the COALESCE is repeated in
      // WHERE/ORDER and the output column is `pl_name`.
      let project = """
        SELECT r.pid AS pid, r.source AS source, r.strength AS strength,
               COALESCE(ap.name, ua.name) AS pl_name
          FROM result r
          LEFT JOIN apple_playlist ap ON r.source = 'apple' AND ap.id = r.pid
          LEFT JOIN app_playlist  ua ON r.source = 'app'   AND ua.id = r.pid
         WHERE COALESCE(ap.name, ua.name) IS NOT NULL
         ORDER BY r.strength DESC, COALESCE(ap.name, ua.name)
         LIMIT ?
        """
      let sql: String
      let arguments: StatementArguments
      if let neighbor {
        // Edge: per-playlist count of each of the two genres, then the
        // pair co-strength = MIN over playlists having BOTH.
        sql = """
          WITH
            \(membershipCTE),
            genre_count(pkey, source, pid, genre, n) AS (
              SELECT m.pkey, m.source, m.pid, TRIM(je.value),
                     COUNT(DISTINCT m.song_id)
                FROM membership m
                JOIN song s ON s.id = m.song_id
                JOIN json_each(s.genre_names) je
               WHERE s.genre_names IS NOT NULL
                 AND json_valid(s.genre_names)
                 AND TRIM(je.value) IN (?, ?)
               GROUP BY m.pkey, TRIM(je.value)
            ),
            result(pid, source, strength) AS (
              SELECT a.pid, a.source, MIN(a.n, b.n)
                FROM genre_count a
                JOIN genre_count b
                  ON a.pkey = b.pkey AND a.genre = ? AND b.genre = ?
            )
          \(project)
          """
        arguments = [genre, neighbor, genre, neighbor, limit]
      } else {
        // Single genre: distinct tracks of that genre per playlist.
        sql = """
          WITH
            \(membershipCTE),
            result(pid, source, strength) AS (
              SELECT m.pid, m.source, COUNT(DISTINCT m.song_id)
                FROM membership m
                JOIN song s ON s.id = m.song_id
                JOIN json_each(s.genre_names) je
               WHERE s.genre_names IS NOT NULL
                 AND json_valid(s.genre_names)
                 AND TRIM(je.value) = ?
               GROUP BY m.pkey
            )
          \(project)
          """
        arguments = [genre, limit]
      }
      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      return rows.map { row in
        PlaylistAssociation(
          playlistID: row["pid"],
          name: row["pl_name"],
          strength: row["strength"] ?? 0,
          isAppOwned: (row["source"] as String) == "app",
        )
      }
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

  /// Actively delete the `apple_playlist` snapshots whose `id` is now
  /// classified as a Music.app *folder* (Phase 3 — playlist-folders.md). A
  /// folder's id is still **live** in the MusicKit playlist list, so the
  /// end-of-import `pruneApplePlaylists(keeping:)` can't drop a previously
  /// imported stale folder snapshot (its id is in `liveIDs`); this is the
  /// active convergence that removes it. FK cascade
  /// (`apple_playlist_track.apple_playlist_id REFERENCES apple_playlist ON
  /// DELETE CASCADE`) drops only that folder's membership rows; by schema
  /// this can never touch `app_playlist*`, `song` (delete-RESTRICTed),
  /// `song_stat`, `play_history`, favorites or recents — the one-way
  /// isolation invariant holds (test-verified). A no-op when the set is
  /// empty (the iTunesLibrary graceful-degradation case — no exclusion,
  /// today's behavior). Single `write` transaction; chunked under the
  /// SQLite bound-parameter cap exactly like `pruneApplePlaylists`.
  func deleteApplePlaylists(ids folderIDs: Set<String>) async throws {
    guard !folderIDs.isEmpty else { return }
    try await database.dbQueue.write { db in
      for chunk in Array(folderIDs).chunked(into: Self.sqliteVariableLimit) {
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

  /// Append `songIDs` to the end of an app playlist, **deduping** both
  /// within the input batch and against existing playlist membership: a song
  /// appears in any one app playlist at most once. A call that contributes
  /// no new rows (every id was already in the playlist, or the input was
  /// only intra-batch duplicates) is a **true no-op** — no INSERT runs, and
  /// `updated_at` is NOT bumped (the playlist genuinely didn't change). This
  /// dedupe is **scoped strictly to `app_playlist_track`**: the
  /// `play_history` / `song_stat` table and the Recently Played surface are
  /// fed from a different write path and are unaffected — a song still
  /// records every time it plays.
  ///
  /// Batch idiom: one chunked multi-row INSERT in a single transaction,
  /// with the starting position read once inside that transaction so
  /// positions stay dense and can't race a concurrent add. The dedupe
  /// read (`SELECT song_id … WHERE app_playlist_id = ?`) runs inside the
  /// same write transaction, atomic with the membership read it gates.
  /// `updated_at` is stamped in the same write iff at least one row was
  /// inserted. Existing duplicates from before this dedupe was introduced
  /// are NOT removed (no surreptitious data mutation); they persist until
  /// the user explicitly removes them.
  func addSongsToAppPlaylist(
    _ playlistID: String,
    songIDs: [String],
    at updatedAt: Date = .now,
  ) async throws {
    guard !songIDs.isEmpty else { return }
    // 3 vars/row → chunk under the 999-variable cap.
    let maxRowsPerChunk = Self.sqliteVariableLimit / 3
    try await database.dbQueue.write { db in
      // Dedupe phase. Atomic with the position-read + INSERT below — the
      // whole sequence runs inside one write transaction, so a concurrent
      // add can't slip a row between our existing-membership read and
      // our INSERT.
      let existingIDs = try Set(String.fetchAll(
        db,
        sql: "SELECT song_id FROM app_playlist_track WHERE app_playlist_id = ?",
        arguments: [playlistID],
      ))
      var seenInBatch = Set<String>()
      let toInsert = songIDs.filter { id in
        guard !existingIDs.contains(id) else { return false }
        return seenInBatch.insert(id).inserted
      }
      // All-dupes / intra-batch-only-dupes path: nothing to write, no
      // touch. The playlist genuinely did not change.
      guard !toInsert.isEmpty else { return }

      let nextPosition = try Int.fetchOne(
        db,
        sql: """
          SELECT MAX(position) FROM app_playlist_track
          WHERE app_playlist_id = ?
          """,
        arguments: [playlistID],
      ).map { $0 + 1 } ?? 0

      let positioned = toInsert.enumerated().map {
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

  /// Every song tagged with `genre` (one of its `song.genre_names` JSON
  /// array entries, whitespace-trimmed — same `json_each` + `TRIM(je.value)`
  /// idiom as `associatedPlaylists`), joined to its `song_stat` rollup. No
  /// playlist join → each song appears exactly once, ordered title then
  /// artist (case-insensitive). Backs the synthetic "genre detail" the
  /// genre-graph navigation shows in the top pane. One `dbQueue.read`.
  func songsWithStats(matchingGenre genre: String) async throws -> [SongWithStat] {
    try await database.dbQueue.read { db in
      let sql = """
        SELECT
          song.*,
          COALESCE(song_stat.play_count, 0)  AS stat_play_count,
          song_stat.last_played_at           AS stat_last_played_at
        FROM song
        LEFT JOIN song_stat
          ON song_stat.song_id = song.id
        WHERE song.genre_names IS NOT NULL
          AND json_valid(song.genre_names)
          AND EXISTS (
            SELECT 1 FROM json_each(song.genre_names) je
             WHERE TRIM(je.value) = ?
          )
        ORDER BY song.title COLLATE NOCASE, song.artist_name COLLATE NOCASE
        """
      let rows = try Row.fetchAll(db, sql: sql, arguments: [genre])
      return try rows.map { row in
        SongWithStat(
          song: try Song(row: row),
          playCount: row["stat_play_count"] ?? 0,
          lastPlayedAt: row["stat_last_played_at"],
        )
      }
    }
  }

  /// Every distinct genre tag across the library, trimmed, non-empty,
  /// case-insensitively ordered. One read using the same
  /// `json_each` + `json_valid` + `TRIM(value)` idiom as
  /// `songsWithStats(matchingGenre:)` / `associatedPlaylists`, so the list
  /// and the genre-match queries agree exactly. Backs the "Add to Genre ▸"
  /// context submenu.
  func distinctGenres() async throws -> [String] {
    try await database.dbQueue.read { db in
      try String.fetchAll(db, sql: """
        SELECT DISTINCT TRIM(je.value) AS g
          FROM song
          JOIN json_each(song.genre_names) je
         WHERE song.genre_names IS NOT NULL
           AND json_valid(song.genre_names)
           AND TRIM(je.value) <> ''
         ORDER BY g COLLATE NOCASE
        """)
    }
  }

  /// Rename genre `from` → `to` across the whole library. Genres are
  /// literal tags (no entity), so this also **merges**: a song carrying
  /// both ends with a single `to` (the pure `GenreEdit.renaming` rewrites
  /// + de-dupes; only rows that actually change are written). Reads the
  /// songs whose `genre_names` contains `from` (the `EXISTS(json_each …)`
  /// idiom), then one batched write. Touches **only** `song` (one-way
  /// isolation — asserted by test). Returns rows changed.
  @discardableResult
  func renameGenre(from: String, to: String) async throws -> Int {
    try await database.dbQueue.write { db in
      let affected = try Song.fetchAll(db, sql: """
        SELECT * FROM song
         WHERE genre_names IS NOT NULL
           AND json_valid(genre_names)
           AND EXISTS (
             SELECT 1 FROM json_each(song.genre_names) je
              WHERE TRIM(je.value) = ?
           )
        """, arguments: [from])
      let updates = affected.compactMap { song -> (String, [String])? in
        guard
          let rewritten = GenreEdit.renaming(song.genreNames, from: from, to: to)
        else { return nil }
        return (song.id, rewritten)
      }
      return try Self.writeGenreNames(db, updates)
    }
  }

  /// Append `genre` to each of `songIDs` that doesn't already carry it
  /// (idempotent — `GenreEdit.adding` returns nil for a song that already
  /// has it, so it isn't rewritten). Reads those songs by primary key
  /// (chunked `IN`), one batched write. Touches **only** `song`. Returns
  /// rows changed.
  @discardableResult
  func addGenre(_ genre: String, toSongIDs songIDs: [String]) async throws -> Int {
    guard !songIDs.isEmpty else { return 0 }
    return try await database.dbQueue.write { db in
      var updates = [(String, [String])]()
      for chunk in songIDs.chunked(into: Self.sqliteVariableLimit) {
        let songs = try Song.fetchAll(db, keys: chunk)
        for song in songs {
          guard let added = GenreEdit.adding(song.genreNames, genre) else { continue }
          updates.append((song.id, added))
        }
      }
      return try Self.writeGenreNames(db, updates)
    }
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

  /// Write a clean, transactionally-consistent single-file copy of the
  /// whole DB to `fileURL` via `VACUUM INTO`. The live `DatabaseQueue`
  /// stays open the entire time (no fd swap, no app quiesce) and the copy
  /// is defragmented. Used for both the `.djroomba` export payload and the
  /// quiet pre-import backup. `VACUUM INTO` fails if the destination
  /// already exists, so the caller owns ensuring a clean path.
  func snapshot(to fileURL: URL) async throws {
    try await database.dbQueue.vacuum(into: fileURL.path)
  }

  /// Overwrite the **live** database with the contents of the SQLite file
  /// at `backupURL`, using SQLite's Online Backup API. This copies every
  /// page through the already-open live connection on GRDB's writer queue
  /// (off-main) — semantically "swap the SQLite databases" as the user
  /// described, but done via SQLite's own API instead of an unsafe `mv`
  /// under an open fd, so the whole `LibraryStore`/services object graph
  /// stays valid and only the in-memory view caches need a reload.
  ///
  /// The backup was produced by *this* app (a prior `snapshot(to:)`), so
  /// its schema is byte-identical to the live one — GRDB's lazily re-read
  /// schema cache stays correct after the page copy. Caller reloads all
  /// derived UI state afterward.
  func restore(from backupURL: URL) async throws {
    let source = try DatabaseQueue(path: backupURL.path)
    try await database.dbQueue.writeWithoutTransaction { destinationDB in
      try source.read { sourceDB in
        try sourceDB.backup(to: destinationDB)
      }
    }
  }

  /// Apply matched-snapshot metadata onto existing `song` rows in ONE
  /// chunked statement per ≤999-var batch — the `applyAlbumGenres` /
  /// `reorderAppPlaylists` idiom, never a per-row loop. `UPDATE … FROM
  /// (VALUES …)` keyed on the stable `song.id`: identity/relations
  /// (`id`, `local_id`, `music_item_id`, `id_namespace`, `imported_at`)
  /// and **every other table** are untouched, so all playlist/history FKs
  /// stay intact (the one-way-isolation invariant — asserted by test, like
  /// every other store mutation). Returns rows changed.
  ///
  /// 15 binds/row (id + 14 columns) ⇒ 999/15 = 66 rows/chunk. `genre_names`
  /// goes through `Song.encodeGenreNames` so it round-trips identically to
  /// the `upsertSongs` path; `release_date` binds a `Date` exactly as the
  /// upsert does (GRDB `.datetime`).
  @discardableResult
  func applyImportedMetadata(_ updates: [MetadataUpdate]) async throws -> Int {
    guard !updates.isEmpty else { return 0 }
    let columnsPerRow = 15
    let maxRowsPerChunk = Self.sqliteVariableLimit / columnsPerRow
    return try await database.dbQueue.write { db in
      var changed = 0
      for chunk in updates.chunked(into: maxRowsPerChunk) {
        let rowPlaceholder = "(" + Array(repeating: "?", count: columnsPerRow)
          .joined(separator: ", ") + ")"
        let valuesClause = Array(repeating: rowPlaceholder, count: chunk.count)
          .joined(separator: ", ")
        var arguments = [(any DatabaseValueConvertible)?]()
        arguments.reserveCapacity(chunk.count * columnsPerRow)
        for update in chunk {
          arguments.append(update.targetSongID)
          arguments.append(update.title)
          arguments.append(update.artistName)
          arguments.append(update.albumTitle)
          arguments.append(update.duration)
          arguments.append(update.isExplicit)
          arguments.append(update.trackNumber)
          arguments.append(update.discNumber)
          arguments.append(Song.encodeGenreNames(update.genreNames))
          arguments.append(update.releaseDate)
          arguments.append(update.composerName)
          arguments.append(update.isrc)
          arguments.append(update.hasLyrics)
          arguments.append(update.workName)
          arguments.append(update.movementName)
        }
        // A column-named CTE (`WITH v(col,…) AS (VALUES …)`) is the SQLite
        // form — SQLite does not accept the `AS alias(col,…)` column list
        // on a `(VALUES …)` subquery (that is Postgres syntax). `UPDATE …
        // FROM cte` is supported (SQLite ≥ 3.33; the system SQLite on
        // macOS 14 is well past that).
        try db.execute(
          sql: """
            WITH v(
              id, title, artist_name, album_title, duration, is_explicit,
              track_number, disc_number, genre_names, release_date,
              composer_name, isrc, has_lyrics, work_name, movement_name
            ) AS (VALUES \(valuesClause))
            UPDATE song SET
              title = v.title,
              artist_name = v.artist_name,
              album_title = v.album_title,
              duration = v.duration,
              is_explicit = v.is_explicit,
              track_number = v.track_number,
              disc_number = v.disc_number,
              genre_names = v.genre_names,
              release_date = v.release_date,
              composer_name = v.composer_name,
              isrc = v.isrc,
              has_lyrics = v.has_lyrics,
              work_name = v.work_name,
              movement_name = v.movement_name
            FROM v
            WHERE song.id = v.id
            """,
          arguments: StatementArguments(arguments),
        )
        changed += db.changesCount
      }
      return changed
    }
  }

  // MARK: Private

  /// SQLite hard-limits a statement to 999 bound parameters (the historical
  /// `SQLITE_MAX_VARIABLE_NUMBER`). Every batched multi-row statement here
  /// chunks its rows so the bound-parameter count stays well under that
  /// ceiling regardless of import size.
  private static let sqliteVariableLimit = 999

  /// The single batched genre-only write both edits funnel through: one
  /// chunked `WITH v(id, genre_names) AS (VALUES …) UPDATE song SET
  /// genre_names = v.genre_names FROM v WHERE song.id = v.id` per ≤999-var
  /// chunk (a **column-named CTE** — SQLite rejects the `AS alias(cols)`
  /// column list on a `(VALUES …)` subquery; `UPDATE … FROM` needs ≥3.33,
  /// fine on macOS 14's system SQLite). `genre_names` goes through
  /// `Song.encodeGenreNames` so it round-trips identically to the
  /// `upsertSongs` path (empty list ⇒ NULL — never produced here:
  /// rename's `to` and add's `genre` are non-empty). 2 binds/row ⇒
  /// 999/2 = 499 rows/chunk. Runs in the caller's write transaction;
  /// never touches any table but `song`. Returns rows changed.
  private static func writeGenreNames(
    _ db: Database,
    _ updates: [(id: String, names: [String])],
  ) throws -> Int {
    guard !updates.isEmpty else { return 0 }
    let maxRowsPerChunk = sqliteVariableLimit / 2
    var changed = 0
    for chunk in updates.chunked(into: maxRowsPerChunk) {
      let valuesClause = Array(repeating: "(?, ?)", count: chunk.count)
        .joined(separator: ", ")
      var arguments = [(any DatabaseValueConvertible)?]()
      arguments.reserveCapacity(chunk.count * 2)
      for (id, names) in chunk {
        arguments.append(id)
        arguments.append(Song.encodeGenreNames(names))
      }
      try db.execute(
        sql: """
          WITH v(id, genre_names) AS (VALUES \(valuesClause))
          UPDATE song SET genre_names = v.genre_names
          FROM v WHERE song.id = v.id
          """,
        arguments: StatementArguments(arguments),
      )
      changed += db.changesCount
    }
    return changed
  }

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
