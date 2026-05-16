import Foundation
import Observation

/// Loads the user's **"Recently Played"** browse list — distinct songs
/// ordered by each song's most-recent play, newest first — from the local
/// SQLite store (NOT live MusicKit — local-first pivot), normalizes to
/// `TrackRow`, and pages it in lazily with a keyset cursor as the user
/// scrolls. The landing surface when no playlist is selected.
///
/// Mirrors `PlaylistDetailService`'s shape/concurrency: `@MainActor
/// @Observable`; `await`s the `Sendable`, off-main `LibraryStore` and
/// republishes results as observable state. `rows` changes ONLY on an
/// explicit load / scroll-trigger / seed / reload — never on the 0.5 s
/// now-playing tick — so the view is not coupled to playback state
/// (swiftui-pro). The keyset cursor and paging internals are
/// `@ObservationIgnored` (not view state).
@MainActor
@Observable
final class RecentlyPlayedService {

  // MARK: Lifecycle

  init(store: LibraryStore) {
    self.store = store
  }

  // MARK: Internal

  private(set) var rows = [TrackRow]()
  private(set) var isLoading = false
  private(set) var loadError: String?
  /// False once a page comes back short of `pageSize` (or empty) — the
  /// list has reached the end and `loadMoreIfNeeded` becomes a no-op.
  private(set) var hasMore = true

  /// Load (or reload) the first page. Idempotent-ish: a load already in
  /// flight is cancelled and replaced, the state is reset, and page 1 is
  /// fetched from the head of the history (no cursor). Safe to call from a
  /// view `.task` on first appearance.
  func loadFirstPage() {
    loadTask?.cancel()
    loadGeneration += 1
    let generation = loadGeneration
    cursor = nil
    hasMore = true
    loadError = nil
    rows = []
    loadTask = Task { [weak self] in
      await self?.loadNextPage(replacing: true, generation: generation)
    }
  }

  /// Lazy pagination hook: the view calls this from a row's `.onAppear`
  /// with that row's id. When the appearing row is within `prefetchDistance`
  /// of the end of what's loaded — and there's more to load and nothing is
  /// already loading — fetch the next keyset page and APPEND it. Out-of-band
  /// (early-row) appearances are cheap no-ops.
  func loadMoreIfNeeded(currentRowID: TrackRow.ID) {
    guard hasMore, !isLoading, loadTask == nil else { return }
    // O(prefetchDistance), NOT O(rows): only an appearance among the last
    // `prefetchDistance` loaded rows triggers the next page. `onAppear`
    // fires for every row scrolled past, so a full-array `firstIndex` scan
    // here would be O(n²) over a scroll of a large history; bounding the
    // check to the tail keeps each appearance O(constant).
    guard rows.suffix(prefetchDistance).contains(where: { $0.id == currentRowID })
    else { return }
    loadGeneration += 1
    let generation = loadGeneration
    loadTask = Task { [weak self] in
      await self?.loadNextPage(replacing: false, generation: generation)
    }
  }

  /// Re-show from the top: used after a debug seed or when the surface is
  /// re-displayed (a play may have been recorded while it was off screen).
  /// Same effect as `loadFirstPage()` — kept as a distinct intent-named
  /// entry point so call sites read clearly (mirrors
  /// `PlaylistDetailService.select` vs `refreshStats`).
  func reload() {
    loadFirstPage()
  }

  // MARK: Private

  @ObservationIgnored private let store: LibraryStore
  /// Keyset cursor: the `lastSeq` of the last row of the most recent page.
  /// `nil` ⇒ load from the head (first page). Paging internal, never view
  /// state — `@ObservationIgnored` so a render never tracks it.
  @ObservationIgnored private var cursor: Int64?
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  /// Monotonic load token. Each `loadFirstPage`/`loadMoreIfNeeded`
  /// increments it and the spawned task carries its value; a task only
  /// applies its result / tears down `loadTask`+`isLoading` if it's still
  /// the current generation. This is what makes cancel-and-replace safe:
  /// a superseded in-flight page can't clobber the replacement's handle
  /// and let a concurrent load start a second racing page (mirrors
  /// `PlaylistDetailService`'s monotonic `revisionCounter` idiom).
  @ObservationIgnored private var loadGeneration = 0
  /// One screenful-ish per keyset page. Large enough that a page fills the
  /// detail pane, small enough that scrolling stays incremental.
  @ObservationIgnored private let pageSize = 50
  /// Begin prefetching the next page when an appearing row is within this
  /// many rows of the end, so the next slice is ready before the user hits
  /// the bottom (no visible stall).
  @ObservationIgnored private let prefetchDistance = 10

  private func loadNextPage(replacing: Bool, generation: Int) async {
    isLoading = true
    loadError = nil
    defer {
      // Only tear down if not superseded: a `loadFirstPage()`/`reload()`
      // during this in-flight page cancels & replaces `loadTask` and
      // bumps the generation. Without this guard the cancelled task's
      // `defer` would null out the *replacement's* handle and reset
      // `isLoading`, letting a concurrent `loadMoreIfNeeded` slip past
      // its guard and start a second racing page.
      if generation == loadGeneration {
        isLoading = false
        loadTask = nil
      }
    }
    do {
      let page = try await store.recentlyPlayedPage(
        beforeSeq: cursor,
        limit: pageSize,
      )
      if Task.isCancelled || generation != loadGeneration { return }
      // Position is a running 1-based index across all loaded pages, so
      // the first column reads like the track table (#1, #2, …) and row
      // ids stay unique even when the same song recurs in history.
      let base = replacing ? 0 : rows.count
      let mapped = page.enumerated().map { offset, entry in
        TrackRow(
          song: entry.song,
          position: base + offset + 1,
          playCount: entry.playCount,
          lastPlayedAt: entry.lastPlayedAt,
        )
      }
      if replacing {
        rows = mapped
      } else {
        rows.append(contentsOf: mapped)
      }
      // Advance the keyset cursor to the last row's most-recent-play seq;
      // a short/empty page is the end of the history.
      cursor = page.last?.lastSeq ?? cursor
      hasMore = page.count == pageSize
    } catch {
      if Task.isCancelled || generation != loadGeneration { return }
      loadError = error.localizedDescription
    }
  }
}
