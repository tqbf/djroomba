import GRDB

/// The single source of truth for the SQLite schema.
///
/// ┌─────────────────────────────────────────────────────────────────────┐
/// │ MIGRATION RULES — read before changing anything in here.            │
/// │                                                                     │
/// │ 1. NEVER edit a migration that has shipped. Once `v1.initialSchema` │
/// │    (or any later one) has run on a real user's DB, its closure is   │
/// │    frozen forever. Schema changes are ALWAYS a NEW registration     │
/// │    (e.g. `migrator.registerMigration("v2.addSongRating") { ... }`). │
/// │    Editing a shipped migration silently diverges installed DBs.     │
/// │                                                                     │
/// │ 2. `eraseDatabaseOnSchemaChange` MUST stay false. The DB is the     │
/// │    source of truth (local-first pivot) — never auto-wipe user data. │
/// │                                                                     │
/// │ 3. Migrations run in registration order, each exactly once, inside  │
/// │    a transaction. Re-running the migrator on an up-to-date DB is a  │
/// │    no-op (idempotent) — a tested guarantee.                         │
/// │                                                                     │
/// │ 4. Foreign keys are enforced (see AppDatabase). Ownership cascades  │
/// │    are deliberate (documented per table below). Deleting a `song`   │
/// │    is RESTRICTed while play history / playlist membership exists —  │
/// │    listening history must never be silently destroyed. As of `v3`   │
/// │    `play_history` (FK on `song(local_id)` ON DELETE RESTRICT) is    │
/// │    the only history of record; `play_event` was dropped (it had no  │
/// │    consumer and was the last unbounded table). The                  │
/// │    delete-RESTRICT-protects-history invariant is preserved by       │
/// │    `play_history`'s FK.                                              │
/// │                                                                     │
/// │ 5. This is a standalone static value with no app/MusicKit deps so   │
/// │    migration tests don't need the app to run.                       │
/// └─────────────────────────────────────────────────────────────────────┘
///
/// Future-extension shape (tags, ratings, smart playlists, multi-source
/// sync state, artwork variants, artist/album entities, soft-delete): each
/// is its own `vN.<change>` migration appended below `v1`. Adding a
/// nullable column or a new table is then a localized change (new migration
/// + record file + store method) — not a refactor of existing code.
enum LibraryMigrator {
  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    // RULE 2: the DB owns the truth. Never auto-wipe.
    migrator.eraseDatabaseOnSchemaChange = false

    migrator.registerMigration("v1.initialSchema") { db in
      // ── song ────────────────────────────────────────────────────
      // App-stable `id` (UUID) is the PK so FKs survive Apple
      // re-issuing MusicItemIDs. UNIQUE(music_item_id, id_namespace)
      // is the import dedupe key — library/catalog id spaces are not
      // interchangeable, so the namespace is part of identity.
      try db.create(table: "song") { t in
        t.primaryKey("id", .text)
        t.column("music_item_id", .text).notNull()
        t.column("id_namespace", .text).notNull()
        t.column("title", .text).notNull()
        t.column("artist_name", .text).notNull()
        t.column("album_title", .text)
        t.column("duration", .double)
        t.column("is_explicit", .boolean).notNull().defaults(to: false)
        t.column("artwork_url", .text)
        t.column("imported_at", .datetime).notNull()
        t.uniqueKey(["music_item_id", "id_namespace"])
      }

      // ── apple_playlist ──────────────────────────────────────────
      // Read-only snapshot. `id` is Apple's library MusicItemID.
      try db.create(table: "apple_playlist") { t in
        t.primaryKey("id", .text)
        t.column("name", .text).notNull()
        t.column("artwork_url", .text)
        t.column("curator", .text)
        t.column("last_imported_at", .datetime).notNull()
      }

      // ── apple_playlist_track ────────────────────────────────────
      // Ordered membership. Parent cascade: deleting the snapshot
      // playlist drops its membership (it owns it). song_id RESTRICT:
      // a song can't be deleted while still referenced — protects
      // history & avoids dangling rows. PK (playlist, position).
      try db.create(table: "apple_playlist_track") { t in
        t.column("apple_playlist_id", .text).notNull()
          .references("apple_playlist", onDelete: .cascade)
        t.column("song_id", .text).notNull()
          .references("song", onDelete: .restrict)
        t.column("position", .integer).notNull()
        t.primaryKey(["apple_playlist_id", "position"])
      }
      // Lookup: "which Apple playlists contain this song", and the
      // membership scan when replacing a snapshot.
      try db.create(
        index: "idx_apple_playlist_track_song",
        on: "apple_playlist_track",
        columns: ["song_id"],
      )

      // ── app_playlist ────────────────────────────────────────────
      // User-owned, SQLite-only. Never written back to Apple.
      try db.create(table: "app_playlist") { t in
        t.primaryKey("id", .text)
        t.column("name", .text).notNull()
        t.column("created_at", .datetime).notNull()
        t.column("updated_at", .datetime).notNull()
        t.column("sort_index", .integer).notNull()
      }
      // Sidebar is ordered by sort_index.
      try db.create(
        index: "idx_app_playlist_sort_index",
        on: "app_playlist",
        columns: ["sort_index"],
      )

      // ── app_playlist_track ──────────────────────────────────────
      // Same ownership model as apple_playlist_track.
      try db.create(table: "app_playlist_track") { t in
        t.column("app_playlist_id", .text).notNull()
          .references("app_playlist", onDelete: .cascade)
        t.column("song_id", .text).notNull()
          .references("song", onDelete: .restrict)
        t.column("position", .integer).notNull()
        t.primaryKey(["app_playlist_id", "position"])
      }
      try db.create(
        index: "idx_app_playlist_track_song",
        on: "app_playlist_track",
        columns: ["song_id"],
      )

      // ── play_event ──────────────────────────────────────────────
      // Append-only history, one row per play. song_id RESTRICT so a
      // song's history is never silently destroyed by deleting the
      // song; pruning history is an explicit, separate operation.
      try db.create(table: "play_event") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("song_id", .text).notNull()
          .references("song", onDelete: .restrict)
        t.column("played_at", .datetime).notNull()
      }
      // The headline query: a song's plays, newest first.
      try db.create(
        index: "idx_play_event_song_played_at",
        on: "play_event",
        columns: ["song_id", "played_at"],
      )

      // ── song_stat ───────────────────────────────────────────────
      // Denormalized rollup of play_event for cheap sort/UI. Cascade
      // with its song (the stat has no meaning without the song).
      try db.create(table: "song_stat") { t in
        t.primaryKey("song_id", .text)
          .references("song", onDelete: .cascade)
        t.column("play_count", .integer).notNull().defaults(to: 0)
        t.column("last_played_at", .datetime)
      }
      // Sort the track table by recency / popularity.
      try db.create(
        index: "idx_song_stat_last_played_at",
        on: "song_stat",
        columns: ["last_played_at"],
      )
      try db.create(
        index: "idx_song_stat_play_count",
        on: "song_stat",
        columns: ["play_count"],
      )

      // ── favorite_playlist ───────────────────────────────────────
      // Replaces UserDefaults FavoritesStore. No FK: referent table
      // depends on `source` (apple_playlist | app_playlist).
      try db.create(table: "favorite_playlist") { t in
        t.primaryKey("playlist_id", .text)
        t.column("source", .text).notNull()
      }

      // ── recent_playlist ─────────────────────────────────────────
      // Replaces UserDefaults RecentlyPlayedStore. One row/playlist;
      // ordered + capped at read time. No FK (same reason as above).
      try db.create(table: "recent_playlist") { t in
        t.primaryKey("playlist_id", .text)
        t.column("source", .text).notNull()
        t.column("played_at", .datetime).notNull()
      }
      try db.create(
        index: "idx_recent_playlist_played_at",
        on: "recent_playlist",
        columns: ["played_at"],
      )
    }

    // ── v2+ migrations go BELOW this line. Never touch v1. ──────────

    // v2: a per-playlist change token for incremental import. Nullable
    // INTEGER = `Int(Playlist.lastModifiedDate.timeIntervalSince1970)` from
    // the cheap library-list fetch (NOT the expensive per-playlist track
    // fetch). Append-only nullable column: existing rows get NULL, which
    // the import decision treats as "no comparable signal → re-fetch", so
    // the change is non-destructive and degrades safely. Stored as an
    // opaque Int token (not a `.datetime`) on purpose: GRDB round-trips
    // dates at millisecond precision, which would break exact equality;
    // an integer second-token compares exactly.
    migrator.registerMigration("v2.applePlaylistChangeToken") { db in
      try db.alter(table: "apple_playlist") { t in
        t.add(column: "change_token", .integer)
      }
    }

    // v3: play statistics — a canonical numeric song id, a bounded
    // newest-first play history, skip/replay counters, and the removal of
    // the consumer-less unbounded `play_event` log. Four coordinated
    // changes (see plans/play-statistics.md "migration v3"); each is
    // defaulted/backfilled so an existing v2 DB migrates non-destructively.
    migrator.registerMigration("v3.playStatistics") { db in
      // (a) song.local_id — a first-class canonical numeric song id
      // (assigned at import, monotonic, never recycled, stable across
      // re-import, never the rowid / an Apple id). Added nullable: SQLite
      // can't ADD a NOT NULL column without a constant default, and
      // local_id is per-row, not constant. Existing rows are then
      // backfilled with a dense 1-based id in the deterministic
      // (imported_at, id) order before the UNIQUE index is created.
      try db.alter(table: "song") { t in
        t.add(column: "local_id", .integer)
      }
      try db.execute(sql: """
        UPDATE song SET local_id = ordered.rn
        FROM (
          SELECT id, ROW_NUMBER() OVER (ORDER BY imported_at, id) AS rn
          FROM song
        ) AS ordered
        WHERE song.id = ordered.id
        """)
      // UNIQUE so play_history.song_local_id can FK-reference it. (A
      // SQLite UNIQUE index permits multiple NULLs; app logic guarantees
      // no NULL local_id persists past an upsert.)
      try db.create(
        index: "idx_song_local_id",
        on: "song",
        columns: ["local_id"],
        unique: true,
      )
      // Partial index over only the transiently-unassigned rows (normally
      // none — a freshly inserted song carries local_id NULL only until
      // the same upsert transaction's allocator runs). It makes
      // `upsertSongs`' "are there new rows?" probe and the allocator's
      // `WHERE local_id IS NULL` an O(1) empty-index scan, so a no-op
      // incremental re-import does no allocator work at all.
      try db.execute(sql: """
        CREATE INDEX idx_song_unassigned_local_id
        ON song(id) WHERE local_id IS NULL
        """)

      // (b) play_history — the user's "vector": a bounded, newest-first
      // sequence of the numeric song id. `seq` is AUTOINCREMENT so it is
      // strictly monotonic and never reused (the cap-prune keyset
      // `DELETE WHERE seq <= MAX(seq) - :cap` depends on that). FK on
      // song(local_id) ON DELETE RESTRICT preserves the "history is never
      // silently destroyed" invariant the dropped play_event carried.
      // Written via raw SQL because the FK target is a non-PK UNIQUE
      // column, which GRDB's `references` doesn't model cleanly.
      try db.execute(sql: """
        CREATE TABLE play_history (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          song_local_id INTEGER NOT NULL
            REFERENCES song(local_id) ON DELETE RESTRICT
        )
        """)

      // (c) song_stat — the per-song rollup also carries skip/replay
      // counts now (maintained in-app in the same write as the play, like
      // play_count; not derived from any event log).
      try db.alter(table: "song_stat") { t in
        t.add(column: "skip_count", .integer).notNull().defaults(to: 0)
        t.add(column: "replay_count", .integer).notNull().defaults(to: 0)
      }

      // (d) DROP play_event — verified consumer-less (read only by
      // `playEventCount`, which had zero app callers). `song_stat` was
      // always maintained independently, never derived from play_event,
      // so removing it changes no behaviour; `play_history` is now the
      // only history of record. Dropping the table drops its index.
      try db.drop(table: "play_event")
    }

    return migrator
  }
}
