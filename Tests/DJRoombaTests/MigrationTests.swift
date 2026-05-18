import Foundation
import GRDB
import Testing
@testable import DJRoomba

/// Schema/migration guarantees: a fresh DB gets the full schema, and
/// re-running the migrator is a no-op.
struct MigrationTests {

  // MARK: Internal

  @Test
  func `fresh database applies all migrations`() throws {
    let db = try AppDatabase()
    let present = try db.dbQueue.read { db in
      Set(try Self.expectedTables.filter { try db.tableExists($0) })
    }
    #expect(present == Self.expectedTables)
  }

  @Test
  func `migrator registers migrations in order`() {
    let applied = LibraryMigrator.migrator.migrations
    #expect(applied == [
      "v1.initialSchema",
      "v2.applePlaylistChangeToken",
      "v3.playStatistics",
      "v4.songMetadata",
      // No "v5.*" — the v5 genre import was data-only (reused the v4
      // column, no schema). The next schema change is v6.
      "v6.genreGraph",
    ])
  }

  @Test
  func `V 2 adds the apple playlist change token column`() throws {
    let db = try AppDatabase()
    let hasColumn = try db.dbQueue.read { db in
      try db.columns(in: "apple_playlist").contains { $0.name == "change_token" }
    }
    #expect(hasColumn, "v2 must add apple_playlist.change_token")
  }

  @Test
  func `V 4 adds every free metadata column to song`() throws {
    let db = try AppDatabase()
    let columns = try db.dbQueue.read { db in
      Set(try db.columns(in: "song").map { $0.name })
    }
    #expect(Self.v4SongColumns.isSubset(of: columns), "v4 must add all nine metadata columns")
  }

  /// v4 is non-destructive on a real v2/v3 DB: a `song` row written before
  /// v4 survives the migration unchanged, and each new column reads NULL
  /// (mirrors the Phase-1 `PlayStatisticsTests` v3-backfill pattern).
  @Test
  func `V 4 is non destructive on a v3 db existing rows preserved new columns null`() async throws {
    let dbQueue = try DatabaseQueue()
    // Migrate up to and including v3 only — none of the v4 columns exist.
    try LibraryMigrator.migrator.migrate(dbQueue, upTo: "v3.playStatistics")
    try await dbQueue.write { db in
      try db.execute(sql: """
        INSERT INTO song
          (id, music_item_id, id_namespace, title, artist_name,
           is_explicit, imported_at, local_id)
        VALUES
          ('idA', 'mA', 'library', 'A', 'Artist', 0,
           '2026-01-01 00:00:00.000', 1)
        """)
    }

    // Apply the rest of the migrator (v4).
    try LibraryMigrator.migrator.migrate(dbQueue)

    let applied = try await dbQueue.read { db in
      try LibraryMigrator.migrator.appliedMigrations(db)
    }
    #expect(applied.contains("v4.songMetadata"))

    let row = try await dbQueue.read { db in
      try Row.fetchOne(db, sql: "SELECT * FROM song WHERE id = 'idA'")
    }
    let unwrapped = try #require(row)
    // Existing data intact.
    #expect(unwrapped["title"] as String == "A")
    #expect(unwrapped["artist_name"] as String == "Artist")
    #expect(unwrapped["local_id"] as Int == 1)
    // Every new column present and NULL on the pre-existing row.
    for column in Self.v4SongColumns {
      #expect(
        unwrapped[column] == nil,
        "pre-v4 row must read NULL for \(column)",
      )
    }
    // No new table was added by v4.
    let tables = try await dbQueue.read { db in
      Set(try Self.expectedTables.filter { try db.tableExists($0) })
    }
    #expect(tables == Self.expectedTables)
  }

  @Test
  func `rerunning migrator is idempotent`() throws {
    // Migrate a file-backed DB, then construct a second AppDatabase on
    // the SAME file — its init runs the migrator again. It must not
    // throw and must not change applied state.
    let dir = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = dir.appending(path: "library.sqlite").path

    let first = try AppDatabase(path: path)
    let appliedAfterFirst = try first.dbQueue.read { db in
      try LibraryMigrator.migrator.appliedMigrations(db)
    }

    let second = try AppDatabase(path: path) // re-runs migrate()
    let appliedAfterSecond = try second.dbQueue.read { db in
      try LibraryMigrator.migrator.appliedMigrations(db)
    }

    let songExists = try second.dbQueue.read { db in
      try db.tableExists("song")
    }
    #expect(appliedAfterFirst == [
      "v1.initialSchema",
      "v2.applePlaylistChangeToken",
      "v3.playStatistics",
      "v4.songMetadata",
      "v6.genreGraph",
    ])
    #expect(appliedAfterSecond == appliedAfterFirst)
    #expect(songExists)
  }

  @Test
  func `V 6 adds the genre edge adjacency table with the composite key`() throws {
    let db = try AppDatabase()
    try db.dbQueue.read { db in
      #expect(try db.tableExists("genre_edge"))
      // The composite PK (genre_a, genre_b) IS the adjacency index — its
      // leftmost prefix covers the `WHERE genre_a = ?` neighbour lookup.
      let hasCompositePK = try db.indexes(on: "genre_edge").contains { index in
        index.isUnique && index.columns == ["genre_a", "genre_b"]
      }
      #expect(hasCompositePK, "genre_edge must be PK'd on (genre_a, genre_b)")
    }
  }

  @Test
  func `erase on schema change is disabled`() {
    // Data must survive — never auto-wipe (local-first invariant).
    #expect(LibraryMigrator.migrator.eraseDatabaseOnSchemaChange == false)
  }

  @Test
  func `foreign keys are enforced`() throws {
    let db = try AppDatabase()
    let fk = try db.dbQueue.read { db in
      try Bool.fetchOne(db, sql: "PRAGMA foreign_keys")
    }
    #expect(fk == true)
  }

  @Test
  func `song has unique music item id namespace constraint`() throws {
    let db = try AppDatabase()
    let hasUnique = try db.dbQueue.read { db in
      try db.indexes(on: "song").contains { index in
        index.isUnique && Set(index.columns) == ["music_item_id", "id_namespace"]
      }
    }
    #expect(hasUnique, "song must have UNIQUE(music_item_id, id_namespace)")
  }

  // MARK: Private

  private static let expectedTables: Set = [
    "song",
    "apple_playlist",
    "apple_playlist_track",
    "app_playlist",
    "app_playlist_track",
    "play_history",
    "song_stat",
    "favorite_playlist",
    "recent_playlist",
    "genre_edge",
  ]

  /// The nine nullable "free" Apple-library metadata columns v4 adds to
  /// `song` (no new table, no new index).
  private static let v4SongColumns: Set = [
    "track_number",
    "disc_number",
    "genre_names",
    "release_date",
    "composer_name",
    "isrc",
    "has_lyrics",
    "work_name",
    "movement_name",
  ]

}
