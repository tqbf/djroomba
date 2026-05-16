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
    ])
    #expect(appliedAfterSecond == appliedAfterFirst)
    #expect(songExists)
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
  ]

}
