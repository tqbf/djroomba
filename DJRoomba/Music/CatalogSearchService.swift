import Foundation
import MusicKit
import Observation

/// Catalog **search** surface (Phase 2 of `plans/catalog-playlists.md`). A
/// deliberately subordinate service: the app never *opens* into it —
/// playlists stay primary. Fires `MusicCatalogSearchRequest` paged with the
/// proven M1-style capped loop, tolerates per-page failures like
/// `ImportService`, and surfaces `[MusicKit.Song]` to the view as observable
/// state. The view layer adds the debounce (via `CatalogSearchDebouncer` +
/// `.task(id:)`); this service answers a single committed query.
///
/// **No ingest here.** The service only fetches Apple's search results. Ingest
/// (catalog `MusicKit.Song` → SQLite `song` row) is the controller's call,
/// triggered when the user *acts on* a result (Add to Playlist ▸). That is
/// the Phase-1 seam (`CatalogIngestService.ingest`); this service does not
/// know SQLite exists.
///
/// Concurrency: `@MainActor @Observable` like the sibling MusicKit services
/// (`ImportService`, `MusicSubscriptionService`). The MusicKit
/// request/response types are main-actor-friendly and result volumes are
/// modest (per-page `request.limit = 25`).
///
/// Cancellation: a new `search(_:)` cancels the previous in-flight `Task` via
/// a stored handle (`searchTask`), so a flurry of keystrokes doesn't queue a
/// flurry of races. `loadMore()` is independently cancellable on the same
/// handle. The decider in the view layer also cancels its sleep on each new
/// keystroke (`.task(id:)`'s semantic) — the two checks are complementary,
/// not redundant: the sleep cancels *before* a request is even issued; the
/// stored handle cancels one already in flight.
///
/// **Page size.** `request.limit = 25`. Conservative — Apple's
/// catalog endpoints are rate-limited and we want the first page back fast
/// (the user is staring at an empty sheet). 25 keeps every page small enough
/// to render synchronously on the main run-loop while still being a useful
/// batch; matches the order-of-magnitude `ImportService` uses
/// (`limit = 100` for the bulkier library list path).
///
/// **Page cap.** `maxSearchBatches = 20` — a hard ceiling on how many
/// `nextBatch()` pages one query may pull (≈ 500 results). Same shape as
/// `ImportService.maxPlaylistBatches = 1000` / `maxTrackBatches = 5000`: a
/// loop guard, not a quality target. A search that genuinely runs past 500
/// hits should be re-typed more specifically.
@MainActor
@Observable
final class CatalogSearchService {

  // MARK: Internal

  /// The latest committed query the service is searching for. Distinct from
  /// the live `TextField` binding in the view (which the user types into);
  /// the debouncer commits a value here when it fires. Empty on idle.
  private(set) var query = ""

  /// Accumulated catalog `Song`s across pages for `query`. Cleared when the
  /// view fires a new `search(_:)`; appended to by `loadMore()`. Carrying
  /// the live `MusicKit.Song` (not a UI value type) lets the controller
  /// hand it straight back to `CatalogIngestService.ingest(_:)` with zero
  /// re-fetch when the user adds a result to a playlist.
  private(set) var results = [MusicKit.Song]()

  /// `true` from the moment a `search(_:)` / `loadMore()` task starts until
  /// it returns (success OR error OR cancellation). The view binds this to
  /// an unobtrusive `ProgressView`.
  private(set) var isSearching = false

  /// Per-page error surfaced verbatim. Tolerate-and-surface, mirroring
  /// `ImportService.lastError`: a failure does NOT clear `results` — the
  /// already-loaded pages stay so a transient hiccup mid-paging isn't
  /// destructive. The view shows it as an inline warning row; a new
  /// `search(_:)` clears it.
  private(set) var lastError: String?

  /// Whether a subsequent `loadMore()` could surface more results. Tracks
  /// `MusicItemCollection<Song>.hasNextBatch` of the most recent successful
  /// page, AND falses out once the cap is hit so the view stops offering
  /// "Load more".
  private(set) var hasMore = false

  /// Fire a fresh search. Cancels any previous in-flight task. Clears
  /// `results` + `lastError` before the request goes out (the user
  /// committed a new query — the previous results are stale by intent).
  /// Tolerant of an empty `term` (no-op — the view's debouncer already
  /// returns `.clear` here, but defending the boundary).
  func search(_ term: String) async {
    searchTask?.cancel()
    let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      query = ""
      results = []
      lastError = nil
      hasMore = false
      currentCollection = nil
      pagesFetched = 0
      return
    }
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runSearch(trimmed)
    }
    searchTask = task
    await task.value
  }

  /// Take a result by stable result id (`MusicKit.Song.id.rawValue`), hand
  /// it to `CatalogIngestService` for the catalog→SQLite mapping, and
  /// return the stable `song.id`s the rest of the app keys on (the
  /// app-playlist FK target). One song → one id (or `nil` if the result
  /// has vanished from the in-memory list — e.g. a new search came in
  /// while the user was clicking; defensive, not expected).
  ///
  /// Keeps `MusicKit.Song` strictly inside the catalog services layer —
  /// `MusicController` stays MusicKit-free (the architectural rule: it is
  /// a coordinator, not a MusicKit consumer; the Phase-0 probe path does
  /// the same trick with `firstSong`).
  func ingestResult(
    withCatalogID catalogID: String,
    using ingest: CatalogIngestService,
  ) async throws -> String? {
    guard let song = results.first(where: { $0.id.rawValue == catalogID }) else {
      return nil
    }
    let ids = try await ingest.ingest([song])
    return ids.first
  }

  /// Clear `lastError` without affecting any other state. The search sheet's
  /// inline error row's "Dismiss" wires here — the user explicitly
  /// acknowledged the message, the results stay, the next `search(_:)`
  /// would clear it anyway.
  func dismissError() {
    lastError = nil
  }

  /// Fetch the next page for the current `query`, if `hasMore` and the cap
  /// hasn't been reached. Idempotent if there is nothing to fetch (no-op).
  /// Independently cancellable on the shared `searchTask` handle.
  func loadMore() async {
    guard hasMore, currentCollection != nil, !query.isEmpty else { return }
    searchTask?.cancel()
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runLoadMore()
    }
    searchTask = task
    await task.value
  }

  // MARK: Private

  /// The most recent successful page's `MusicItemCollection<Song>` — the
  /// handle `.nextBatch()` paginates off (the proven M1-style shape from
  /// `ImportService`'s `playlist` page loop). `nil` ⇒ no successful page
  /// yet, so `loadMore()` is a no-op.
  private var currentCollection: MusicItemCollection<MusicKit.Song>?

  /// How many pages this query has already pulled (including the first).
  /// Compared against `maxSearchBatches` to guard runaway paging — same
  /// posture as `ImportService.maxPlaylistBatches`.
  private var pagesFetched = 0

  /// In-flight cancellation handle. A new `search(_:)` / `loadMore()`
  /// cancels the previous task before kicking off its own.
  private var searchTask: Task<Void, Never>?

  /// Conservative per-page result count. See type doc.
  private let pageLimit = 25

  /// Hard ceiling on `nextBatch()` calls per query. See type doc.
  private let maxSearchBatches = 20

  private func runSearch(_ trimmed: String) async {
    query = trimmed
    results = []
    lastError = nil
    hasMore = false
    currentCollection = nil
    pagesFetched = 0
    isSearching = true
    defer { isSearching = false }

    do {
      var request = MusicCatalogSearchRequest(term: trimmed, types: [MusicKit.Song.self])
      request.limit = pageLimit
      let response = try await request.response()
      try Task.checkCancellation()
      let songs = response.songs
      results = Array(songs)
      currentCollection = songs
      pagesFetched = 1
      hasMore = songs.hasNextBatch && pagesFetched < maxSearchBatches
    } catch is CancellationError {
      // A newer keystroke superseded this query — leave state alone for
      // the next `search(_:)` to overwrite. Not an error worth surfacing.
    } catch {
      // Tolerate-and-surface (`ImportService` posture): keep prior results
      // (none here — first page) and expose the message inline.
      lastError = error.localizedDescription
    }
  }

  private func runLoadMore() async {
    guard let collection = currentCollection else { return }
    isSearching = true
    defer { isSearching = false }

    do {
      let nextPage = try await collection.nextBatch()
      try Task.checkCancellation()
      guard let nextPage else {
        // MusicKit returned nil ⇒ no more pages despite a true
        // `hasNextBatch` snapshot at the previous boundary; close out.
        hasMore = false
        return
      }
      results.append(contentsOf: nextPage)
      currentCollection = nextPage
      pagesFetched += 1
      hasMore = nextPage.hasNextBatch && pagesFetched < maxSearchBatches
    } catch is CancellationError {
      // Newer search / loadMore superseded — leave state to be overwritten.
    } catch {
      // Tolerate-and-surface: the already-loaded pages STAY. One bad
      // page doesn't destroy the search.
      lastError = error.localizedDescription
    }
  }

}
