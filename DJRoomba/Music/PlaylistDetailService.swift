import Foundation
import Observation

/// Loads a selected playlist's tracks from the local SQLite store (NOT live
/// MusicKit — local-first pivot), normalizes to `TrackRow`, and caches the
/// result in memory keyed by playlist id. Cache is invalidated on import /
/// manual refresh. Selection changes cancel any in-flight load.
///
/// Concurrency: `@MainActor @Observable`; `await`s the `Sendable`, off-main
/// `LibraryStore` and republishes results as observable state.
@MainActor
@Observable
final class PlaylistDetailService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  private(set) var detail: PlaylistDetail?
  private(set) var isLoading = false
  private(set) var loadError: String?

  func select(_ summary: PlaylistSummary) {
    loadTask?.cancel()

    if let cached = cache[summary.id] {
      // Serve the cached rows immediately (instant, no flash), then
      // refresh the play-count / last-played columns from `song_stat`
      // on this discrete (re)selection event — they may have advanced
      // since the rows were first fetched (a play recorded while the
      // playlist wasn't on screen). One `songsWithStats` query, NOT a
      // per-tick re-query (D4).
      detail = cached
      loadError = nil
      isLoading = false
      loadTask = Task { [weak self] in
        await self?.refreshStats(summary)
      }
      return
    }

    detail = nil
    loadError = nil
    loadTask = Task { [weak self] in
      await self?.load(summary)
    }
  }

  /// Re-run the stats-joined read for `playlistID` and, if it's still the
  /// one on screen, splice the fresh `play_count` / `last_played_at` back
  /// into the existing rows (order/membership unchanged — only the stat
  /// columns can have moved). Driven by discrete events only: a play was
  /// just recorded, or the playlist was (re)selected. No refresh loop, no
  /// per-row query — the stats come from the single `songsWithStats` LEFT
  /// JOIN, re-run once per event.
  func refreshStats(for playlistID: String) async {
    guard let summary = summaryForRefresh(playlistID) else { return }
    await refreshStats(summary)
  }

  func clear() {
    loadTask?.cancel()
    detail = nil
    loadError = nil
    isLoading = false
  }

  func invalidate() {
    cache.removeAll()
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore
  @ObservationIgnored private var cache = [String: PlaylistDetail]()
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  /// Caller passes the on-screen summary's identity so the refresh keys the
  /// right `songsWithStats` source (app vs imported). Returns nil when the
  /// playlist isn't currently shown — nothing to refresh.
  private func summaryForRefresh(_ playlistID: String) -> PlaylistSummary? {
    guard let detail, detail.id == playlistID else { return nil }
    return PlaylistSummary(
      id: detail.id,
      name: detail.name,
      trackCount: detail.tracks.count,
      isEditable: detail.isEditable,
      source: detail.source,
      isFavorite: false,
    )
  }

  private func refreshStats(_ summary: PlaylistSummary) async {
    do {
      let withStats = summary.source.isAppOwned
        ? try await store.songsWithStats(inAppPlaylist: summary.id)
        : try await store.songsWithStats(inApplePlaylist: summary.id)
      if Task.isCancelled { return }
      // Only the stat columns can have changed since load; rebuild the
      // rows from the fresh join in the same order.
      let rows = withStats.enumerated().map { index, entry in
        TrackRow(songWithStat: entry, position: index + 1)
      }
      guard
        let current = cache[summary.id] ?? detail,
        current.id == summary.id
      else { return }
      let refreshed = PlaylistDetail(
        id: current.id,
        name: current.name,
        isAppleLibraryPlaylist: current.isAppleLibraryPlaylist,
        source: current.source,
        description: current.description,
        isEditable: current.isEditable,
        tracks: rows,
      )
      cache[summary.id] = refreshed
      if detail?.id == summary.id { detail = refreshed }
    } catch {
      // A stats refresh failing is non-fatal — the (possibly stale)
      // rows stay on screen rather than surfacing an error for what is
      // only a play-count update.
      if Task.isCancelled { return }
    }
  }

  private func load(_ summary: PlaylistSummary) async {
    isLoading = true
    loadError = nil
    defer { isLoading = false }

    do {
      // Stats-joined read so the track table's play-count / last-played
      // columns are populated in one query (no per-song stat fetch).
      // Branch on source: app playlists are SQLite-only user lists;
      // everything else is an imported Apple snapshot.
      let withStats = summary.source.isAppOwned
        ? try await store.songsWithStats(inAppPlaylist: summary.id)
        : try await store.songsWithStats(inApplePlaylist: summary.id)
      if Task.isCancelled { return }

      let rows = withStats.enumerated().map { index, entry in
        TrackRow(songWithStat: entry, position: index + 1)
      }
      let result = PlaylistDetail(
        id: summary.id,
        name: summary.name,
        isAppleLibraryPlaylist: summary.source == .libraryUserPlaylist,
        source: summary.source,
        description: nil,
        isEditable: summary.source.isAppOwned ? true : summary.isEditable,
        tracks: rows,
      )
      cache[summary.id] = result
      detail = result
    } catch {
      if Task.isCancelled { return }
      loadError = error.localizedDescription
    }
  }
}
