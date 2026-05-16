import Foundation
import GRDB

/// Owns the GRDB `DatabaseQueue` and applies the schema migrations.
///
/// Pure plumbing: no app/MusicKit knowledge, no business API (that's
/// `LibraryStore`). Lives off the main actor — `DatabaseQueue` is internally
/// serialized and `Sendable`, so this is a `Sendable` value with no
/// `@MainActor` and no external locking. `GRDB.Configuration` turns foreign
/// keys ON (GRDB's default, made explicit here so cascade/restrict behavior
/// is guaranteed regardless of SQLite build).
struct AppDatabase: Sendable {

  // MARK: Lifecycle

  /// Opens a file-backed database at `path` and runs all migrations.
  /// Used by `live()` and, with a temp path, by tests.
  init(path: String) throws {
    dbQueue = try DatabaseQueue(path: path, configuration: Self.configuration)
    try Self.migrate(dbQueue)
  }

  /// Opens an in-memory database and runs all migrations. The fast path
  /// for unit tests — no filesystem, fresh schema every time.
  init(inMemory _: Void = ()) throws {
    dbQueue = try DatabaseQueue(configuration: Self.configuration)
    try Self.migrate(dbQueue)
  }

  // MARK: Internal

  let dbQueue: DatabaseQueue

  /// The on-disk store: `Application Support/DJRoomba/library.sqlite`.
  /// `URL.applicationSupportDirectory` is sandbox-safe; the per-app
  /// subdirectory is created if missing (Application Support is not
  /// guaranteed to exist on a fresh container).
  static func defaultURL() throws -> URL {
    let directory = URL.applicationSupportDirectory
      .appending(path: "DJRoomba", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    return directory.appending(path: "library.sqlite", directoryHint: .notDirectory)
  }

  /// Opens (creating if needed) the production database and migrates it.
  static func live() throws -> AppDatabase {
    try AppDatabase(path: defaultURL().path)
  }

  // MARK: Private

  private static var configuration: Configuration {
    var config = Configuration()
    // Enforce FK constraints (default on, explicit for guarantee):
    // ownership cascades + delete-RESTRICT on song depend on this.
    config.foreignKeysEnabled = true
    return config
  }

  private static func migrate(_ dbQueue: DatabaseQueue) throws {
    try LibraryMigrator.migrator.migrate(dbQueue)
  }
}
