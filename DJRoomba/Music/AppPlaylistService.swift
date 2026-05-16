import Foundation
import Observation

/// Owns the user's SQLite-only "My Playlists" — listing them for the sidebar
/// and the create / rename / delete / reorder / add / remove CRUD. This is
/// the app-owned half of the local-first model: these playlists are **never**
/// written back to Apple Music (core product decision); every mutation here
/// touches only `app_playlist` / `app_playlist_track` (the store enforces and
/// tests the one-way isolation — imported `apple_playlist*` data is never
/// affected).
///
/// Concurrency: `@MainActor @Observable` like the sibling read services. It
/// `await`s the `Sendable`, off-main `LibraryStore` and republishes results
/// as observable state, then reloads from SQLite (the source of truth) so the
/// sidebar reflects the persisted order/contents (no dual store).
@MainActor
@Observable
final class AppPlaylistService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  /// User playlists in sidebar order (`sort_index`). `isFavorite` is
  /// overlaid by the controller (it owns favorite state), matching how the
  /// imported-playlist summaries work.
  private(set) var summaries = [PlaylistSummary]()
  private(set) var isLoading = false
  private(set) var lastError: String?

  /// Reload the user playlists from SQLite. Track counts come from one
  /// grouped membership query (not N per-playlist fetches) so this stays
  /// cheap even with many playlists.
  func load() async {
    isLoading = true
    lastError = nil
    defer { isLoading = false }
    do {
      let playlists = try await store.appPlaylists()
      let counts = try await store.appPlaylistTrackCounts()
      summaries = playlists.map { playlist in
        PlaylistSummary(
          id: playlist.id,
          name: playlist.name,
          trackCount: counts[playlist.id] ?? 0,
          isEditable: true,
          source: .appPlaylist,
          isFavorite: false,
        )
      }
    } catch {
      lastError = error.localizedDescription
      summaries = []
    }
  }

  /// Create a playlist appended at the end of the sidebar order and return
  /// its new id (so the caller can select it immediately — the native
  /// "create then rename inline" flow).
  @discardableResult
  func create(named name: String) async -> String? {
    do {
      let created = try await store.createAppPlaylist(named: name)
      await load()
      return created.id
    } catch {
      lastError = error.localizedDescription
      return nil
    }
  }

  func rename(_ playlistID: String, to name: String) async {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try await store.renameAppPlaylist(playlistID, to: trimmed)
      await load()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func delete(_ playlistID: String) async {
    do {
      try await store.deleteAppPlaylist(playlistID)
      await load()
    } catch {
      lastError = error.localizedDescription
    }
  }

  func addSongs(_ songIDs: [String], to playlistID: String) async {
    guard !songIDs.isEmpty else { return }
    do {
      try await store.addSongsToAppPlaylist(playlistID, songIDs: songIDs)
      await load()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Remove tracks by their 1-based table position. (Positions, not song
  /// ids, so removing one of a duplicated song removes exactly that row.)
  func removeTracks(at oneBasedPositions: [Int], from playlistID: String) async {
    guard !oneBasedPositions.isEmpty else { return }
    do {
      try await store.removeTracksFromAppPlaylist(
        playlistID,
        positions: oneBasedPositions.map { $0 - 1 },
      )
      await load()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Persist a reordered membership (the full ordered list of song ids).
  func setTracks(_ songIDs: [String], for playlistID: String) async {
    do {
      try await store.setAppPlaylistTracks(playlistID, songIDs: songIDs)
      await load()
    } catch {
      lastError = error.localizedDescription
    }
  }

  /// Persist a new sidebar order for the user playlists.
  func reorder(_ orderedIDs: [String]) async {
    do {
      try await store.reorderAppPlaylists(orderedIDs)
      await load()
    } catch {
      lastError = error.localizedDescription
    }
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore

}
