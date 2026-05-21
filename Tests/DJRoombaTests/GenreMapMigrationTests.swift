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

  @Test
  func `migrator ordering ends with v 7 genre map`() {
    let applied = LibraryMigrator.migrator.migrations
    #expect(applied.last == "v7.genreMap")
    #expect(applied == [
      "v1.initialSchema",
      "v2.applePlaylistChangeToken",
      "v3.playStatistics",
      "v4.songMetadata",
      "v6.genreGraph",
      "v7.genreMap",
    ])
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
