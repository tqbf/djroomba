import Foundation
import Observation

/// Library snapshot export / import (`plans/snapshot-export-import.md`).
///
/// Mirrors `ImportService`'s architecture exactly: `@MainActor @Observable`,
/// holds the `Sendable` off-main `LibraryStore`, `await`s it, and publishes
/// observable status. **Not** an Apple import — this is local SQLite + file
/// IO + the pure `MetadataMatcher`, so it is fully build- and
/// test-verifiable without a signed MusicKit run. It performs no UI reload
/// itself; `MusicController` owns the post-op reload + genre reanalyze
/// (the same split as `ImportService` ↔ `runImport`).
///
/// Heavy work never runs on the main actor: `LibraryStore` (vacuum /
/// online-backup / batched apply) hops to GRDB's queue, and `SnapshotCodec`
/// is `nonisolated async` so compression runs on the cooperative pool.
@MainActor
@Observable
final class SnapshotService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
    canRevert = Self.backupURL.map {
      FileManager.default.fileExists(atPath: $0.path)
    } ?? false
  }

  // MARK: Internal

  /// The quiet pre-import backup of the live DB. One slot, overwritten
  /// each import — "Revert" undoes the *last* import; a backup history is
  /// out of scope. A plain uncompressed sqlite (never leaves the machine;
  /// speed over size).
  static var backupURL: URL? {
    try? AppDatabase.defaultURL()
      .deletingLastPathComponent()
      .appending(path: "Backups", directoryHint: .isDirectory)
      .appending(path: "pre-import.djroomba-backup", directoryHint: .notDirectory)
  }

  private(set) var isExporting = false
  private(set) var isImporting = false
  /// A failure from the last export/import/revert, surfaced inline (never
  /// modal — the codebase's error convention). `nil` when the last op was
  /// fine.
  private(set) var lastError: String?
  /// The merge tally of the last successful import, for the dismissible
  /// "Updated N — Revert" chip. `nil` once dismissed / before any import.
  private(set) var lastResult: SnapshotMergeSummary?
  /// Whether a pre-import backup exists to revert to. True after a merge
  /// that wrote rows; reflects the backup file's existence at launch so
  /// the File-menu "Revert" item is correctly enabled across relaunches.
  private(set) var canRevert: Bool

  func dismissResult() {
    lastResult = nil
  }

  /// Surface a picker-side failure (`.fileExporter`/`.fileImporter`
  /// completion) that happens outside `prepareExport` / `apply`. User
  /// cancellation is handled by the caller and never reaches here.
  func noteFailure(_ message: String) {
    lastError = message
  }

  /// Build the compressed `.djroomba` bytes OFF-main (`VACUUM INTO` a temp
  /// file → `SnapshotCodec.encode`), returning the document to hand to
  /// `.fileExporter`. Returns `nil` and sets `lastError` on failure. The
  /// work is done here, before the exporter is presented, so SwiftUI's
  /// background `fileWrapper` is a trivial byte copy.
  func prepareExport() async -> SnapshotDocument? {
    guard !isExporting else { return nil }
    isExporting = true
    lastError = nil
    defer { isExporting = false }

    let tempURL = Self.uniqueTempSQLiteURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }
    do {
      try await store.snapshot(to: tempURL)
      let data = try await SnapshotCodec.encode(sqliteAt: tempURL)
      return SnapshotDocument(data: data)
    } catch {
      lastError = "Could not export the library: \(error.localizedDescription)"
      return nil
    }
  }

  /// Merge the metadata from the `.djroomba` at `url` onto the current
  /// library by content matching (the pure tiered `MetadataMatcher`).
  /// Makes a quiet pre-import backup **only when there is something to
  /// write**. Returns the summary on success (caller reloads UI +
  /// reanalyzes genres), `nil` on failure (`lastError` set; nothing
  /// mutated). The library's playlists/history/stats are never touched —
  /// only `song` metadata of matched rows.
  func apply(snapshotAt url: URL) async -> SnapshotMergeSummary? {
    guard !isImporting else { return nil }
    isImporting = true
    lastError = nil
    defer { isImporting = false }

    // `.fileImporter` hands back a security-scoped URL (sandbox); access
    // must be started before reading and stopped after.
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }

    let tempURL = Self.uniqueTempSQLiteURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    do {
      let container = try Data(contentsOf: url, options: .mappedIfSafe)
      try await SnapshotCodec.decode(container, toSQLiteAt: tempURL)

      // Open the decompressed copy — this RUNS THE MIGRATOR on it, so an
      // older-schema `.djroomba` is upgraded to the current schema before
      // we read columns (forward-compat for free). A *newer*-schema file
      // throws here (GRDB won't downgrade) and nothing is mutated.
      let sourceStore = LibraryStore(database: try AppDatabase(path: tempURL.path))
      let source = try await sourceStore.allSongs()
      let target = try await store.allSongs()

      let (updates, summary) = MetadataMatcher.plan(source: source, target: target)

      if updates.isEmpty {
        // Nothing to write → no backup, no revert state change. Honest
        // zero result (the chip will say "Updated 0").
        lastResult = summary
        return summary
      }

      try await makeBackup()
      let changed = try await store.applyImportedMetadata(updates)
      var finalSummary = summary
      finalSummary.updated = changed
      lastResult = finalSummary
      canRevert = true
      return finalSummary
    } catch let error as SnapshotCodec.DecodeError {
      lastError = Self.message(for: error)
      return nil
    } catch {
      lastError = "Could not import the snapshot: \(error.localizedDescription)"
      return nil
    }
  }

  /// Swap the pre-import backup database back in (the user's "revert IS
  /// just swapping the SQLite databases", done via SQLite's Online Backup
  /// API into the live connection — see `LibraryStore.restore`). Returns
  /// whether it succeeded; caller reloads UI.
  func revert() async -> Bool {
    guard !isImporting, let backupURL = Self.backupURL else { return false }
    guard FileManager.default.fileExists(atPath: backupURL.path) else {
      lastError = "There is no snapshot import to revert."
      return false
    }
    isImporting = true
    lastError = nil
    defer { isImporting = false }
    do {
      try await store.restore(from: backupURL)
      lastResult = nil
      return true
    } catch {
      lastError = "Could not revert the import: \(error.localizedDescription)"
      return false
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore

  private static func message(for error: SnapshotCodec.DecodeError) -> String {
    switch error {
    case .tooShort,
         .badMagic:
      "That file is not a DJ Roomba library snapshot."

    case .corruptPayload:
      "The snapshot file is corrupt and could not be read."
    }
  }

  private static func uniqueTempSQLiteURL() -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "djroomba-snapshot-\(UUID().uuidString).sqlite")
  }

  /// `VACUUM INTO` refuses to overwrite, so clear any previous backup
  /// first. Ensures the `Backups/` directory exists.
  private func makeBackup() async throws {
    guard let backupURL = Self.backupURL else {
      throw CocoaError(.fileWriteUnknown)
    }
    let directory = backupURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    if FileManager.default.fileExists(atPath: backupURL.path) {
      try FileManager.default.removeItem(at: backupURL)
    }
    try await store.snapshot(to: backupURL)
  }
}
