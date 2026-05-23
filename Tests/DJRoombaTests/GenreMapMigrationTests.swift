import Foundation
import GRDB
import Testing
@testable import DJRoomba

/// Schema/migration guarantees for the `v7.genreMap` substrate
/// (`plans/genre-metro-map.md` Phase 1). Pins: the two new tables exist
/// with the expected PKs; the migration is purely additive (v1–v6 frozen);
/// the rebuild executes against an empty DB without error.
struct GenreMapMigrationTests {

  @Test
  func `v 7 adds genre node and genre edge evidence tables`() throws {
    let db = try AppDatabase()
    try db.dbQueue.read { db in
      #expect(try db.tableExists("genre_node"))
      #expect(try db.tableExists("genre_edge_evidence"))

      let nodeHasPK = try db.indexes(on: "genre_node").contains { index in
        index.isUnique && index.columns == ["genre"]
      }
      #expect(nodeHasPK, "genre_node must be PK'd on (genre)")

      let evidenceHasPK = try db.indexes(on: "genre_edge_evidence").contains { index in
        index.isUnique && index.columns == ["genre_a", "genre_b"]
      }
      #expect(
        evidenceHasPK,
        "genre_edge_evidence must be PK'd on (genre_a, genre_b)",
      )
    }
  }

  /// Phase 3 carry-forward: `song_genre` materialised view + the three
  /// indexes are part of v7 (`plans/genre-metro-map.md` Phase 3 step 9).
  /// Pin the schema so a future regression surfaces here, not by a
  /// 6-8 s evidence-on-demand latency in live verification.
  @Test
  func `v 7 adds the song genre materialised view with all three indexes`() throws {
    let db = try AppDatabase()
    try db.dbQueue.read { db in
      #expect(try db.tableExists("song_genre"))
      let indexNames = try db.indexes(on: "song_genre").map(\.name)
      #expect(indexNames.contains("song_genre_genre_song_idx"))
      #expect(indexNames.contains("song_genre_genre_artist_idx"))
      #expect(indexNames.contains("song_genre_genre_album_idx"))
    }
  }

  @Test
  func `migrator ordering ends with v 9 genre map state`() {
    let applied = LibraryMigrator.migrator.migrations
    #expect(applied.last == "v9.genreMapState")
    #expect(applied == [
      "v1.initialSchema",
      "v2.applePlaylistChangeToken",
      "v3.playStatistics",
      "v4.songMetadata",
      "v6.genreGraph",
      "v7.genreMap",
      "v8.songGenreMaterialised",
      "v9.genreMapState",
    ])
  }

  /// Phase 6 (`plans/genre-metro-map.md`): v9 adds the persisted layout
  /// state tables — `genre_map_state` (one row per genre) and
  /// `genre_map_strand` (one row per main strand). Pin the schema so
  /// a future regression surfaces here instead of an "atlas drifted"
  /// live-verification miss.
  @Test
  func `v 9 adds genre map state and strand tables`() throws {
    let db = try AppDatabase()
    try db.dbQueue.read { db in
      #expect(try db.tableExists("genre_map_state"))
      #expect(try db.tableExists("genre_map_strand"))

      let stateHasPK = try db.indexes(on: "genre_map_state").contains { index in
        index.isUnique && index.columns == ["genre"]
      }
      #expect(stateHasPK, "genre_map_state must be PK'd on (genre)")

      let strandHasPK = try db.indexes(on: "genre_map_strand").contains { index in
        index.isUnique && index.columns == ["strand_id"]
      }
      #expect(strandHasPK, "genre_map_strand must be PK'd on (strand_id)")

      let stateColumns = Set(try db.columns(in: "genre_map_state").map(\.name))
      #expect(stateColumns.isSuperset(of: [
        "genre",
        "x",
        "y",
        "community_coarse",
        "community_medium",
        "community_fine",
        "strand_ids",
        "updated_at",
        "revision",
      ]))

      let strandColumns = Set(try db.columns(in: "genre_map_strand").map(\.name))
      #expect(strandColumns.isSuperset(of: [
        "strand_id",
        "colour",
        "label_tokens",
        "revision",
      ]))
    }
  }

  /// Phase 6: v9 is **purely additive**. Migrating up to v8 only, writing
  /// a row, and then applying v9 must leave v1–v8 data intact and add
  /// only the two new tables.
  @Test
  func `v 9 is non destructive over an existing v 8 db`() async throws {
    let dbQueue = try DatabaseQueue()
    try LibraryMigrator.migrator.migrate(dbQueue, upTo: "v8.songGenreMaterialised")
    try await dbQueue.write { db in
      try db.execute(sql: """
        INSERT INTO song
          (id, music_item_id, id_namespace, title, artist_name,
           is_explicit, imported_at, local_id)
        VALUES
          ('s1', 'm1', 'library', 'Hey', 'Artist', 0,
           '2026-01-01 00:00:00.000', 1)
        """)
    }
    try LibraryMigrator.migrator.migrate(dbQueue)
    let applied = try await dbQueue.read { db in
      try LibraryMigrator.migrator.appliedMigrations(db)
    }
    #expect(applied.contains("v9.genreMapState"))
    let title = try await dbQueue.read { db in
      try String.fetchOne(db, sql: "SELECT title FROM song WHERE id = 's1'")
    }
    #expect(title == "Hey")
    let stateCount = try await dbQueue.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM genre_map_state") ?? -1
    }
    #expect(stateCount == 0, "v9 must start the state table empty")
  }

  /// Phase 6 store API: `loadGenreMapState` returns `nil` on an empty DB
  /// (no v9 rows yet); `writeGenreMapState` writes wholesale and a
  /// subsequent read round-trips identically. Pins the one-tx posture
  /// (write twice → second wholly replaces the first).
  @Test
  func `phase 6 state round trips through the store`() async throws {
    let store = try TestSupport.freshStore()

    #expect(try await store.loadGenreMapState() == nil)

    let states = [
      GenreMapStateRow(
        genre: "Alt",
        x: 12.5,
        y: -34.0,
        communityCoarse: "1",
        communityMedium: "2",
        communityFine: "5",
        strandIds: "[1,3]",
        updatedAt: 1_700_000_000,
        revision: 7,
      ),
      GenreMapStateRow(
        genre: "Folk",
        x: -7.0,
        y: 19.0,
        communityCoarse: "1",
        communityMedium: "3",
        communityFine: "8",
        strandIds: "[3]",
        updatedAt: 1_700_000_000,
        revision: 7,
      ),
    ]
    let strands = [
      GenreMapStrandRow(
        strandID: "1",
        colour: 5,
        labelTokens: "[\"Alternative\",\"Britpop\"]",
        revision: 7,
      ),
      GenreMapStrandRow(
        strandID: "3",
        colour: 8,
        labelTokens: "[\"Folk\"]",
        revision: 7,
      ),
    ]
    try await store.writeGenreMapState(states: states, strands: strands)

    let loaded = try await store.loadGenreMapState()
    let unwrapped = try #require(loaded)
    #expect(unwrapped.positions["Alt"]?.x == 12.5)
    #expect(unwrapped.positions["Folk"]?.y == 19.0)
    #expect(unwrapped.communitiesByGenre["Alt"]?.medium == "2")
    #expect(unwrapped.strandIDsByGenre["Alt"] == [1, 3])
    #expect(unwrapped.strandRowByID["1"]?.colour == 5)
    #expect(unwrapped.strandRowByID["1"]?.labelTokens == ["Alternative", "Britpop"])
    #expect(unwrapped.revision == 7)

    // Wholesale: second write replaces the first. Remove "Folk", lower
    // revision to confirm we read back what we wrote (no merging).
    try await store.writeGenreMapState(
      states: [states[0]],
      strands: [strands[0]],
    )
    let secondLoad = try await store.loadGenreMapState()
    #expect(secondLoad?.positions.keys.sorted() == ["Alt"])
    #expect(secondLoad?.strandRowByID.keys.sorted() == ["1"])
  }

  /// SQLite must expose `ln` (the math-functions extension) — the rebuild
  /// SQL uses it for the per-genre weight. If GRDB's SQLite ever loses
  /// that compile flag, the rebuild would fail at runtime; pin it here
  /// so the failure is a single, debuggable test failure.
  @Test
  func `sqlite exposes the ln math function`() async throws {
    let store = try TestSupport.freshStore()
    let v = try await store.database.dbQueue.read { db in
      try Double.fetchOne(db, sql: "SELECT ln(2.718281828)")
    }
    #expect(v != nil)
    #expect((v ?? 0).isFinite)
  }

  /// Empty DB ⇒ rebuild writes nothing and returns 0; idempotent re-run
  /// is also 0. Re-runs against the same DB never throw.
  @Test
  func `rebuild on empty db writes nothing and is idempotent`() async throws {
    let store = try TestSupport.freshStore()
    let first = try await store.rebuildGenreMap()
    let second = try await store.rebuildGenreMap()
    #expect(first == 0)
    #expect(second == 0)
    #expect(try await store.genreMapNodes().isEmpty)
    #expect(try await store.genreMapEvidence().isEmpty)
  }
}
