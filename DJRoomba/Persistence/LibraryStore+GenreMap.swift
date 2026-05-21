import Foundation
import GRDB

/// `v7.genreMap` substrate (`plans/genre-metro-map.md` Phase 1): the
/// **wholesale** rebuild of the per-genre `genre_node` weights + the
/// multi-channel `genre_edge_evidence` model, plus the small read methods
/// the pipeline needs. Mirrors the posture of `rebuildGenreGraph` — one
/// CTE-driven write transaction, no row-by-row loops, no Swift fan-out.
///
/// The v6 `genre_edge` table is unchanged here; the playlist channel of the
/// new model **reads** it (so the existing thresholds still shape the
/// playlist input) but never mutates it. The v6 rebuild and this one are
/// orthogonal: callers run them in sequence (the existing genre rebuild
/// first, then this one) so this one can join `genre_edge.weight` as a
/// numeric channel.
extension LibraryStore {

  /// Replace both `genre_node` + `genre_edge_evidence` rows wholesale from
  /// the live data, in one write transaction. Returns the count of edges
  /// (canonical halves) materialised — the support floor (`shared_* < 2`)
  /// drops weak pairs at write time.
  ///
  /// Touches ONLY `genre_node` + `genre_edge_evidence`. `song`,
  /// `apple_playlist*`, `app_playlist*`, `genre_edge`, `song_stat`,
  /// `play_history`, favourites and recents are never read-for-write nor
  /// mutated — one-way isolated, mirroring `rebuildGenreGraph`.
  ///
  /// Artist / album identity: `song` has only the free-text `artist_name`
  /// + `album_title` (no normalised ids). The map's "shared artist" /
  /// "shared album" counts therefore key on the normalised string —
  /// `TRIM(LOWER(artist_name))` for the artist key, and the artist key
  /// concatenated with `TRIM(LOWER(album_title))` for the album key (so a
  /// "Greatest Hits" by Queen is distinguishable from "Greatest Hits" by
  /// the Beatles). Same-name distinct artists are deliberately folded —
  /// that's accepted noise at this scale, and the support floor + the
  /// 1.2× weighting on the artist channel keep the signal honest.
  @discardableResult
  func rebuildGenreMap() async throws -> Int {
    try await database.dbQueue.write { db in
      try db.execute(sql: "DELETE FROM genre_node")
      try db.execute(sql: "DELETE FROM genre_edge_evidence")

      // 1) Per-(genre, song) explode: one row per (TRIM'd, non-blank,
      // case-folded-for-keys) genre + its underlying song. `LOWER` is only
      // applied to artist/album KEYS — the genre string stays verbatim
      // (so the user's own tagging survives). `song_artist_key` /
      // `song_album_key` are `NULL` when the underlying text is missing
      // (the channel then doesn't contribute to that pair).
      //
      // 2) `genre_card` collapses to one row per genre with the three raw
      // distinct counts + the `log`-shaped raw weight; the normaliser
      // divides by the max raw weight across all rows in the same write.
      try db.execute(sql: """
        INSERT INTO genre_node
          (genre, track_count, album_count, artist_count, weight)
        WITH
          song_genre(song_id, genre, artist_key, album_key) AS (
            SELECT s.id,
                   TRIM(je.value) AS genre,
                   NULLIF(TRIM(LOWER(s.artist_name)), '') AS artist_key,
                   CASE
                     WHEN NULLIF(TRIM(LOWER(s.artist_name)), '') IS NULL
                       OR NULLIF(TRIM(LOWER(s.album_title)), '') IS NULL
                     THEN NULL
                     ELSE TRIM(LOWER(s.artist_name))
                          || '|'
                          || TRIM(LOWER(s.album_title))
                   END AS album_key
              FROM song s
              JOIN json_each(s.genre_names) je
             WHERE s.genre_names IS NOT NULL
               AND json_valid(s.genre_names)
               AND je.value IS NOT NULL
               AND TRIM(je.value) <> ''
          ),
          genre_card(genre, tc, ac, rc, raw) AS (
            SELECT genre,
                   COUNT(DISTINCT song_id),
                   COUNT(DISTINCT album_key),
                   COUNT(DISTINCT artist_key),
                   ln(1.0 + COUNT(DISTINCT song_id))
                   + 0.8 * ln(1.0 + COUNT(DISTINCT album_key))
                   + 1.2 * ln(1.0 + COUNT(DISTINCT artist_key))
              FROM song_genre
             GROUP BY genre
          ),
          norm(max_raw) AS (
            SELECT MAX(raw) FROM genre_card
          )
        SELECT gc.genre, gc.tc, gc.ac, gc.rc,
               CASE
                 WHEN (SELECT max_raw FROM norm) IS NULL
                   OR (SELECT max_raw FROM norm) <= 0
                 THEN 0.0
                 ELSE gc.raw / (SELECT max_raw FROM norm)
               END
          FROM genre_card gc
        """)

      // 3) Multi-channel edges. Three Jaccards (artist / album / track)
      // computed inline; the playlist channel reads `genre_edge.weight`
      // and normalises by the max weight in the same query. The support
      // floor (shared_* < 2) is enforced by `WHERE` — weak rows are never
      // written, keeping the table small and the layout graph sparse.
      try db.execute(sql: """
        INSERT INTO genre_edge_evidence
          (genre_a, genre_b,
           artist_overlap_jaccard, album_overlap_jaccard,
           track_overlap_jaccard, playlist_cooccur_weight,
           shared_artist_count, shared_album_count, shared_track_count,
           total_weight)
        WITH
          song_genre(song_id, genre, artist_key, album_key) AS (
            SELECT s.id,
                   TRIM(je.value),
                   NULLIF(TRIM(LOWER(s.artist_name)), ''),
                   CASE
                     WHEN NULLIF(TRIM(LOWER(s.artist_name)), '') IS NULL
                       OR NULLIF(TRIM(LOWER(s.album_title)), '') IS NULL
                     THEN NULL
                     ELSE TRIM(LOWER(s.artist_name))
                          || '|'
                          || TRIM(LOWER(s.album_title))
                   END
              FROM song s
              JOIN json_each(s.genre_names) je
             WHERE s.genre_names IS NOT NULL
               AND json_valid(s.genre_names)
               AND je.value IS NOT NULL
               AND TRIM(je.value) <> ''
          ),
          -- Per-channel cardinalities per genre (the Jaccard denominators).
          genre_artists(genre, artist_key) AS (
            SELECT DISTINCT genre, artist_key FROM song_genre
             WHERE artist_key IS NOT NULL
          ),
          genre_albums(genre, album_key) AS (
            SELECT DISTINCT genre, album_key FROM song_genre
             WHERE album_key IS NOT NULL
          ),
          genre_tracks(genre, song_id) AS (
            SELECT DISTINCT genre, song_id FROM song_genre
          ),
          card_artist(genre, n) AS (
            SELECT genre, COUNT(*) FROM genre_artists GROUP BY genre
          ),
          card_album(genre, n) AS (
            SELECT genre, COUNT(*) FROM genre_albums GROUP BY genre
          ),
          card_track(genre, n) AS (
            SELECT genre, COUNT(*) FROM genre_tracks GROUP BY genre
          ),
          -- Pairwise intersections per channel, canonical `a < b` half.
          inter_artist(genre_a, genre_b, n) AS (
            SELECT a.genre, b.genre, COUNT(*)
              FROM genre_artists a
              JOIN genre_artists b
                ON a.artist_key = b.artist_key
               AND a.genre < b.genre
             GROUP BY a.genre, b.genre
          ),
          inter_album(genre_a, genre_b, n) AS (
            SELECT a.genre, b.genre, COUNT(*)
              FROM genre_albums a
              JOIN genre_albums b
                ON a.album_key = b.album_key
               AND a.genre < b.genre
             GROUP BY a.genre, b.genre
          ),
          inter_track(genre_a, genre_b, n) AS (
            SELECT a.genre, b.genre, COUNT(*)
              FROM genre_tracks a
              JOIN genre_tracks b
                ON a.song_id = b.song_id
               AND a.genre < b.genre
             GROUP BY a.genre, b.genre
          ),
          -- Union of every canonical pair that has at least one channel.
          pairs(genre_a, genre_b) AS (
            SELECT genre_a, genre_b FROM inter_artist
            UNION
            SELECT genre_a, genre_b FROM inter_album
            UNION
            SELECT genre_a, genre_b FROM inter_track
          ),
          -- v6 playlist channel: canonicalise `genre_edge` to `a < b`, and
          -- normalise its weight to [0,1] by the max in the analysed graph.
          playlist_max(max_w) AS (
            SELECT MAX(weight) FROM genre_edge
          ),
          playlist_canon(genre_a, genre_b, w) AS (
            SELECT genre_a, genre_b, weight FROM genre_edge
             WHERE genre_a < genre_b
          ),
          -- Composite per pair. LEFT JOINs let a pair light up on any
          -- subset of channels (most edges are dominated by 1–2 channels).
          composed(genre_a, genre_b,
                   a_n, b_n, t_n, p_w,
                   a_j, b_j, t_j, pl) AS (
            SELECT p.genre_a, p.genre_b,
                   COALESCE(ia.n, 0),
                   COALESCE(ib.n, 0),
                   COALESCE(it.n, 0),
                   COALESCE(pc.w, 0),
                   CASE
                     WHEN COALESCE(ia.n, 0) = 0 THEN 0.0
                     ELSE 1.0 * ia.n
                          / (ca.n + cb.n - ia.n)
                   END,
                   CASE
                     WHEN COALESCE(ib.n, 0) = 0 THEN 0.0
                     ELSE 1.0 * ib.n
                          / (cab.n + cbb.n - ib.n)
                   END,
                   CASE
                     WHEN COALESCE(it.n, 0) = 0 THEN 0.0
                     ELSE 1.0 * it.n
                          / (cta.n + ctb.n - it.n)
                   END,
                   CASE
                     WHEN (SELECT max_w FROM playlist_max) IS NULL
                       OR (SELECT max_w FROM playlist_max) <= 0
                       OR pc.w IS NULL
                     THEN 0.0
                     ELSE 1.0 * pc.w / (SELECT max_w FROM playlist_max)
                   END
              FROM pairs p
              LEFT JOIN inter_artist ia
                     ON ia.genre_a = p.genre_a AND ia.genre_b = p.genre_b
              LEFT JOIN inter_album ib
                     ON ib.genre_a = p.genre_a AND ib.genre_b = p.genre_b
              LEFT JOIN inter_track it
                     ON it.genre_a = p.genre_a AND it.genre_b = p.genre_b
              LEFT JOIN card_artist ca ON ca.genre = p.genre_a
              LEFT JOIN card_artist cb ON cb.genre = p.genre_b
              LEFT JOIN card_album cab ON cab.genre = p.genre_a
              LEFT JOIN card_album cbb ON cbb.genre = p.genre_b
              LEFT JOIN card_track cta ON cta.genre = p.genre_a
              LEFT JOIN card_track ctb ON ctb.genre = p.genre_b
              LEFT JOIN playlist_canon pc
                     ON pc.genre_a = p.genre_a AND pc.genre_b = p.genre_b
          )
        SELECT genre_a, genre_b,
               a_j, b_j, t_j, pl,
               a_n, b_n, t_n,
               0.45 * a_j + 0.35 * b_j + 0.15 * t_j + 0.05 * pl
          FROM composed
         -- Support floor: drop pairs lacking ≥2 shared things across all
         -- three structural channels combined. Pure noise filter — tiny
         -- genres sharing one stray track no longer mint a fake edge.
         WHERE (a_n + b_n + t_n) >= 2
        """)

      return try Int.fetchOne(
        db,
        sql: "SELECT COUNT(*) FROM genre_edge_evidence",
      ) ?? 0
    }
  }

  /// All `genre_node` rows, sorted by weight desc (biggest genres first)
  /// then name. The pipeline pulls these into memory once — small table
  /// (one row per genre), no per-view hot path.
  func genreMapNodes() async throws -> [GenreNode] {
    try await database.dbQueue.read { db in
      try GenreNode
        .order(GenreNode.Columns.weight.desc, GenreNode.Columns.genre)
        .fetchAll(db)
    }
  }

  /// All `genre_edge_evidence` rows, sorted by total weight desc then by
  /// the canonical name pair. Like `genreGraphEdges()`: full table read,
  /// not a per-view hot path (the table is small relative to the song
  /// table — one row per related-pair, post support-floor).
  func genreMapEvidence() async throws -> [GenreEdgeEvidence] {
    try await database.dbQueue.read { db in
      try GenreEdgeEvidence
        .order(
          GenreEdgeEvidence.Columns.totalWeight.desc,
          GenreEdgeEvidence.Columns.genreA,
          GenreEdgeEvidence.Columns.genreB,
        )
        .fetchAll(db)
    }
  }

}
