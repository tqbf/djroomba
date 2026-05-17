import Foundation
import Observation

/// Top-level coordinator. Owns the service instances and the app-level state
/// the UI binds to. Coordinates startup; delegates fetching/playback to
/// services (it is a coordinator, not a god object).
///
/// Local-first pivot: the app operates **from SQLite**. `LibraryStore` (a
/// `Sendable`, off-main value type) is the source of truth; Apple Music is a
/// one-way import source (`ImportService`) + the playback engine
/// (`PlaybackResolver` → `PlaybackService`). The sidebar/detail read from the
/// store via `LibraryReadService` / `PlaylistDetailService`. The controller
/// stays `@MainActor @Observable`, `await`s the store, and republishes
/// results as observable state.
@MainActor
@Observable
final class MusicController {

  // MARK: Lifecycle

  init() {
    let openedStore = try? LibraryStore()
    store = openedStore
    // Services need a store; if the DB failed to open we still construct
    // them against a throwaway in-memory store so the type is non-optional
    // and the UI degrades to empty states rather than crashing.
    let backing = openedStore ?? (try? LibraryStore(database: AppDatabase()))
    let safeStore = backing ?? Self.unsafeEmptyStore()
    library = LibraryReadService(store: safeStore)
    appPlaylistService = AppPlaylistService(store: safeStore)
    detailService = PlaylistDetailService(store: safeStore)
    recentlyPlayed = RecentlyPlayedService(store: safeStore)
    importService = ImportService(store: safeStore)
    genreImportService = GenreImportService(store: safeStore)
    resolver = PlaybackResolver()
    if openedStore == nil {
      storeError = "The local library database could not be opened."
    }
  }

  // MARK: Internal

  let authorization = MusicAuthorizationService()
  let subscription = MusicSubscriptionService()
  let playback = PlaybackService()

  private(set) var storeError: String?
  let library: LibraryReadService
  let appPlaylistService: AppPlaylistService
  let detailService: PlaylistDetailService
  /// The "Recently Played" landing surface's view-model (shown when no
  /// playlist is selected). Reads the keyset-paginated distinct history.
  let recentlyPlayed: RecentlyPlayedService
  let importService: ImportService
  /// Album→track genre enrichment. Runs **only** on a full import
  /// (Reimport Everything ⇧⌘R) or the empty-DB first import — never on the
  /// fast incremental Refresh; see `runImport(force:firstImport:)`.
  let genreImportService: GenreImportService
  let resolver: PlaybackResolver

  /// Observable mirrors of the persisted app state. SQLite is authoritative;
  /// these are refreshed from it after writes (no dual store).
  private(set) var favoriteIDs = Set<String>()
  private(set) var recentIDs = [String]()

  /// Bumped by the ⌘L / ⌘1 commands; the sidebar observes this to take
  /// keyboard focus (commands are app-scoped, so this bridges to the view).
  private(set) var focusSidebarRequest = 0

  /// Derived summary collections — **stored, input-driven state**, not
  /// per-`body` computed properties (Phase A spry fix; see
  /// `plans/memory-and-laziness.md`). `rebuildDerivedSummaries()` recomputes
  /// these only when an input (`library.summaries`,
  /// `appPlaylistService.summaries`, `favoriteIDs`, `recentIDs`) changes, so
  /// a sidebar render does zero array concatenation and zero O(n·m) scans.
  ///
  /// `allSummaries`: every selectable playlist across both libraries —
  /// imported Apple snapshots + user-owned app playlists, uniform for
  /// selection / restore / detail lookups.
  private(set) var allSummaries = [PlaylistSummary]()

  /// User-owned, SQLite-only playlists ("My Playlists" section, Phase 4),
  /// with `isFavorite` overlaid (the service leaves it false).
  private(set) var appPlaylists = [PlaylistSummary]()

  /// Favorites span both libraries (a user playlist can be a favorite too).
  private(set) var favoritePlaylists = [PlaylistSummary]()

  /// Recently played, in recency order, limited to playlists still present
  /// in either library.
  private(set) var recentPlaylists = [PlaylistSummary]()

  /// O(1) id → summary index over `allSummaries`. Backs `selectedSummary`
  /// and every `…contains(where: id ==)` / `first(where: id ==)` lookup so
  /// they stop being O(n) scans over a freshly concatenated array.
  private(set) var summariesByID = [String: PlaylistSummary]()

  /// Sidebar selection. App-local state — drives lazy detail load and is
  /// persisted so it survives relaunch (if the playlist still exists).
  var selectedPlaylistID: String? {
    didSet {
      guard oldValue != selectedPlaylistID else { return }
      handleSelectionChange()
    }
  }

  /// True while the library is being (re)populated — an Apple import is
  /// running OR the store-backed sidebar is reloading. Drives the sidebar's
  /// existing "Loading playlists…" state so first-launch import doesn't
  /// briefly flash "No Playlists" (same UI, just honest about the import).
  var isLibraryBusy: Bool {
    importService.isImporting || library.isLoading
  }

  /// Coarse import progress for the sidebar's loading affordance (Phase 5):
  /// "Importing N of M playlists…" while a first-launch / Refresh import
  /// runs, falling back to the plain "Loading playlists…" before the total
  /// is known or while only the store reload is in flight. `ImportService`
  /// already tracks these counts; this just surfaces them.
  var libraryLoadingMessage: String {
    if importService.isImporting, importService.totalPlaylistCount > 0 {
      return "Importing \(importService.importedPlaylistCount) of \(importService.totalPlaylistCount) playlists…"
    }
    return "Loading playlists…"
  }

  /// A user-facing problem string for the sidebar's error state: a store
  /// open/migration failure, or an import failure. Library read error is
  /// surfaced separately (it has its own retry).
  var libraryProblem: String? {
    storeError ?? importService.lastError ?? library.loadError
  }

  /// The sidebar's state *with the cause inferred* (Phase 5 smarter empty
  /// states). The view renders the right `ContentUnavailableView` from this;
  /// the decision (and the MusicSubscription cross-check that distinguishes
  /// "not synced" / "needs subscription" / "no playlists") lives in the pure,
  /// unit-tested `LibrarySidebarState.resolve` rather than the view body.
  var sidebarState: LibrarySidebarState {
    LibrarySidebarState.resolve(
      hasAnySummaries: !allSummaries.isEmpty,
      hasImportedPlaylists: !library.summaries.isEmpty,
      isBusy: isLibraryBusy,
      problem: libraryProblem,
      subscriptionLoaded: subscription.hasLoaded,
      canPlayCatalog: subscription.canPlayCatalogContent,
      canBecomeSubscriber: subscription.canBecomeSubscriber,
      cloudLibraryEnabled: subscription.hasCloudLibraryEnabled,
    )
  }

  /// O(1) index lookup (was an O(n) scan over a freshly concatenated
  /// `allSummaries` on every `body`).
  var selectedSummary: PlaylistSummary? {
    guard let id = selectedPlaylistID else { return nil }
    return summariesByID[id]
  }

  /// Imported Apple library playlists ("Library Playlists" section). A bare
  /// passthrough (single observed-property read, no recompute), kept
  /// computed deliberately.
  var libraryPlaylists: [PlaylistSummary] {
    library.summaries
  }

  /// Library browsing always works; catalog playback needs a subscription.
  /// Until subscription info has loaded we optimistically allow playback.
  var canAttemptPlayback: Bool {
    !subscription.hasLoaded || subscription.canPlayCatalogContent
  }

  var playbackUnavailableReason: String? {
    guard subscription.hasLoaded, !subscription.canPlayCatalogContent else {
      return nil
    }
    return "An active Apple Music subscription is required to play this content."
  }

  /// A short, user-facing problem string for a *playback / re-resolve*
  /// failure, surfaced inline (never modal — see `plans/architecture.md`)
  /// so a broken id round trip is visible instead of failing silently
  /// (the D1 corrective: the resolver/player `lastError` previously had no
  /// UI surface). Nil when the last attempt was fine. The subscription
  /// gate has its own dedicated message, so it's excluded here.
  var playbackProblem: String? {
    if let resolverError = resolver.lastError {
      return resolverError
    }
    if !resolver.unresolvedMusicItemIDs.isEmpty {
      let n = resolver.unresolvedMusicItemIDs.count
      return "^[\(n) track](inflect: true) couldn't be matched for playback and \(n == 1 ? "was" : "were") skipped."
    }
    if let playerError = playback.lastError {
      return playerError
    }
    return nil
  }

  var musicContext: MusicContext {
    MusicContext(
      selectedPlaylistID: selectedPlaylistID,
      selectedPlaylistName: selectedSummary?.name,
      selectedSongID: nil,
      nowPlayingSongID: playback.snapshot.nowPlayingItemID,
      nowPlayingTitle: playback.snapshot.title,
      nowPlayingArtist: playback.snapshot.artist,
      queuePlaylistID: playback.snapshot.playlistContextID,
      playbackStatus: playback.snapshot.status,
    )
  }

  /// The stored `song.id` at the player's current **structural queue
  /// position**, or nil if unknown/unattributable. Cheap O(1) derived
  /// read, not view-consumed in Phase 2 (Phases 3–4 read it for
  /// attribution). Position = `snapshot.queueIndex`, or the start-index
  /// seed before the first monitor tick. Only ever indexes **our**
  /// context by an ordinal — no Apple id is a key (plans/play-statistics.md
  /// — "Rejected alternative").
  var currentStoredSongID: String? {
    let index = playback.snapshot.queueIndex
      ?? PlaybackResolver.startIndex(
        in: activePlayContext.songIDs,
        startSongID: activePlayContext.startSongID,
      )
    return PlaybackResolver.storedSongID(in: activePlayContext.songIDs, at: index)
  }

  func requestSidebarFocus() {
    focusSidebarRequest &+= 1
  }

  func bootstrap() async {
    authorization.refresh()
    if authorization.status == .authorized {
      await startAuthorizedSession()
    }
  }

  func requestAuthorization() async {
    await authorization.request()
    if authorization.status == .authorized {
      await startAuthorizedSession()
    }
  }

  /// The Refresh affordance (⌘R / toolbar). **Incremental** one-way
  /// import — unchanged playlists skip the expensive MusicKit track
  /// fetch — then reload the sidebar/detail from SQLite.
  func refreshLibrary() async {
    await runImport()
    reconcileSelectionAfterImport()
  }

  /// "Reimport Everything" (⇧⌘R / menu): **force** a full re-fetch of
  /// every playlist. The recovery path for when the incremental change
  /// signal can't be trusted — e.g. a smart/auto playlist whose contents
  /// changed server-side without bumping `lastModifiedDate`.
  func reimportEverything() async {
    await runImport(force: true)
    reconcileSelectionAfterImport()
  }

  /// Debug menu action: seed `count` synthetic plays drawn at random from
  /// the user's playlist songs, then re-show the Recently Played surface so
  /// the result is immediately visible. Fire-and-forget-safe: a store
  /// failure sets `storeError` (matching the codebase) and never crashes.
  /// No `#if DEBUG` gate — the user's normal `make` build is debug-config
  /// and the button is wanted (it is clearly labelled under "Debug").
  func seedSyntheticHistory(count: Int) async {
    guard let store else { return }
    do {
      try await store.seedRandomPlayHistory(count: count)
      recentlyPlayed.reload()
    } catch {
      storeError = error.localizedDescription
    }
  }

  func isFavorite(_ summary: PlaylistSummary) -> Bool {
    favoriteIDs.contains(summary.id)
  }

  func toggleFavorite(_ summary: PlaylistSummary) {
    guard let store else { return }
    let key = summary.id
    let willFavorite = !favoriteIDs.contains(key)
    // Optimistic local update so the UI responds immediately; SQLite is
    // written async and is authoritative on the next reload.
    if willFavorite {
      favoriteIDs.insert(key)
    } else {
      favoriteIDs.remove(key)
    }
    // `favoriteIDs` is an input to the derived collections (favorites list,
    // the `isFavorite` overlay on app playlists) — re-derive now, off the
    // optimistic mutation, not in `body`.
    rebuildDerivedSummaries()
    let kind: PlaylistSourceKind = summary.source.isAppOwned ? .app : .apple
    Task {
      do {
        try await store.setFavorite(willFavorite, playlistID: key, source: kind)
      } catch {
        storeError = error.localizedDescription
      }
    }
  }

  func playSelectedPlaylist() async {
    guard let detail = detailService.detail, !detail.isEmpty else { return }
    await resolveAndPlay(detail: detail, startRow: nil)
  }

  func play(_ row: TrackRow) async {
    guard let detail = detailService.detail else { return }
    await resolveAndPlay(detail: detail, startRow: row)
  }

  func togglePlayPause() async {
    await playback.togglePlayPause()
  }

  /// "Next" pressed. Before delegating to the transport — which mutates
  /// `queue.currentEntry` and therefore `currentStoredSongID` — capture
  /// the song that *was* playing and the *live* playhead, decide whether
  /// this is a skip (Phase 3, ask #2), then run the unchanged transport.
  func skipNext() async {
    recordTransportStat(button: .next)
    await playback.skipNext()
  }

  /// "Back" pressed. Same capture-before-delegate ordering as
  /// `skipNext()`; a press past halfway counts as a replay (Phase 3,
  /// ask #3). The transport is unchanged — whatever MusicKit then does
  /// (restart vs. previous entry) is irrelevant to the count.
  func skipPrevious() async {
    recordTransportStat(button: .previous)
    await playback.skipPrevious()
  }

  /// Create a new user playlist and select it (the native "new untitled
  /// item, ready to rename" flow). Returns its id so the sidebar can put
  /// the row straight into inline-rename.
  @discardableResult
  func createAppPlaylist(named name: String = "New Playlist") async -> String? {
    let id = await appPlaylistService.create(named: name)
    // Rebuild BEFORE assigning selection: `selectedPlaylistID`'s `didSet`
    // resolves `selectedSummary` via `summariesByID`, which must already
    // contain the new playlist.
    rebuildDerivedSummaries()
    if let id { selectedPlaylistID = id }
    return id
  }

  func renameAppPlaylist(_ playlistID: String, to name: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.rename(playlistID, to: name)
    }
  }

  func deleteAppPlaylist(_ playlistID: String) async {
    await appPlaylistService.delete(playlistID)
    rebuildDerivedSummaries()
    detailService.invalidate(playlistID: playlistID)
    if selectedPlaylistID == playlistID {
      // Selected playlist was deleted — clear selection silently.
      selectedPlaylistID = nil
    }
  }

  func addSongs(_ songIDs: [String], toAppPlaylist playlistID: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.addSongs(songIDs, to: playlistID)
    }
  }

  func removeTracks(at oneBasedPositions: [Int], fromAppPlaylist playlistID: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.removeTracks(at: oneBasedPositions, from: playlistID)
    }
  }

  /// Persist a reordered membership for an app playlist (the full ordered
  /// song-id list, e.g. after a drag-to-reorder in the track table).
  func setAppPlaylistTracks(_ songIDs: [String], for playlistID: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.setTracks(songIDs, for: playlistID)
    }
  }

  /// Persist a new sidebar order for the user playlists.
  func reorderAppPlaylists(_ orderedIDs: [String]) async {
    await appPlaylistService.reorder(orderedIDs)
    rebuildDerivedSummaries()
  }

  func handle(_ command: MusicCommand) async {
    switch command {
    case .playPlaylist(let id):
      if allSummaries.contains(where: { $0.id == id }) {
        selectedPlaylistID = id
        await playSelectedPlaylist()
      }

    case .playTrack(let trackID, let playlistID):
      if let playlistID { selectedPlaylistID = playlistID }
      if
        let row = detailService.detail?.tracks.first(
          where: { $0.musicItemID == trackID }
        )
      {
        await play(row)
      }

    case .pause,
         .resume:
      await togglePlayPause()

    case .skipNext:
      await skipNext()

    case .skipPrevious:
      await skipPrevious()
    }
  }

  /// Play an arbitrary set of stored songs the user picked from the
  /// **"Recently Played"** list. Reuses the **app-playlist resolution
  /// path** (`resolveAppPlaylist` — arbitrary stored songs by id, the
  /// verified per-id `equalTo` round trip) and the same shared queue-start
  /// helper as `resolveAndPlay`'s app branch, so the load-bearing ordering
  /// invariant and the Phase-2/4 context+watermark seeding are *not*
  /// duplicated. The loaded `recentlyPlayed.rows` are the queue context so
  /// Next/Prev walk the list. The started track is fed to stats via the
  /// same `recordPlay` path (dogfooding: listening from here also counts).
  /// "Recently Played" is not a playlist, so there is no `recordRecent`
  /// (playlist-recents) bump.
  func playRecentlyPlayed(startAt row: TrackRow) async {
    let queueRows = recentlyPlayed.rows
    guard !queueRows.isEmpty else { return }
    let resolution = await resolver.resolveAppPlaylist(
      rows: queueRows,
      startAt: row,
    )
    let didStart = await startResolvedQueue(
      resolution,
      // No backing playlist — the queue context id is nil, exactly as a
      // bare song selection. Stats attribution stays the Phase-2
      // structural-position path (never an Apple id).
      contextID: nil,
      beforePlay: nil,
    )
    if didStart, let resolution {
      await recordPlayStart(
        startedSongID: resolution.startSongID ?? row.songID
      )
    }
  }

  // MARK: Private

  /// The canonical play context for the active queue, captured atomically
  /// from one resolve so its parts can never drift (set and cleared in a
  /// single assignment). `songIDs[k]` is the stored `song.id` of the
  /// player's queue entry `k` (`nil` = unattributable position);
  /// `startSongID` seeds the structural index before the first monitor
  /// tick; `lastRecordedQueueIndex` is the Phase-4 auto-advance watermark
  /// — the structural index the most recent play was recorded for. It is
  /// part of this value (not a sibling `var`) precisely so a new queue
  /// resets the watermark in the **same assignment** that swaps the
  /// context: the two can never drift (the Phase-2 atomic set/clear
  /// decision, extended to Phase 4). Seeded to the **start index** so the
  /// detector's first observation (current == seed) is not a transition
  /// and the explicitly-started first track — already recorded by
  /// `recordPlayStart` — is not re-appended. Phase-2 machinery; Phases
  /// 3–4 read it.
  private struct ActivePlayContext {
    var songIDs = [String?]()
    var startSongID: String?
    /// The structural queue index the last play was recorded for (Phase
    /// 4). Defaults to `nil` (empty/no queue ⇒ nothing recorded yet);
    /// `resolveAndPlay` seeds it to the start index for a live queue.
    var lastRecordedQueueIndex: Int?
  }

  /// The SQLite source of truth, and everything that reads/writes it. If
  /// the store can't be opened the app still runs (auth/empty states); the
  /// failure is surfaced via `storeError`.
  @ObservationIgnored private let store: LibraryStore?

  @ObservationIgnored private let preferences = UserPreferencesStore()
  @ObservationIgnored private let legacyMigration = LegacyPreferencesMigration()

  /// `@ObservationIgnored` is load-bearing: the 0.5 s monitor advances
  /// `snapshot.queueIndex` continuously and `currentStoredSongID` reads it
  /// — Observation-tracking this would invalidate `body` on every
  /// now-playing tick (the "no now-playing tick coupling" regression
  /// `plans/memory-and-laziness.md` / swiftui-pro warn against). Nothing
  /// reads it from a view body, and it must stay that way.
  @ObservationIgnored private var activePlayContext = ActivePlayContext()

  /// Last-resort in-memory store so `store == nil` never crashes the app.
  /// An in-memory `DatabaseQueue` failing to open means the process is
  /// fundamentally broken (no allocatable SQLite); a clear `fatalError` is
  /// the honest, unrecoverable outcome here (swiftui-pro: prefer
  /// `fatalError` with a description over force-try).
  private static func unsafeEmptyStore() -> LibraryStore {
    do {
      return LibraryStore(database: try AppDatabase())
    } catch {
      fatalError("Could not open an in-memory SQLite database: \(error)")
    }
  }

  private func startAuthorizedSession() async {
    subscription.start()
    // Hang the Phase-4 auto-advance detector off the existing 0.5 s
    // monitor (no second timer). Set once; a plain `@ObservationIgnored`
    // closure, so the now-playing tick stays decoupled from any view
    // `body` (swiftui-pro / memory-and-laziness).
    playback.onSnapshotRefresh = { [weak self] in
      self?.detectAndRecordAdvance()
    }
    playback.startMonitoring()

    // One-shot UserDefaults → SQLite migration of M2 favorites/recents.
    // After this the legacy keys are never read/written again.
    if let store {
      do {
        try await legacyMigration.runIfNeeded(into: store)
      } catch {
        storeError = "Could not migrate saved favorites/recents: \(error.localizedDescription)"
      }
    }

    await reloadFavoritesAndRecents()

    // User-owned playlists are independent of the Apple import — always
    // load them so "My Playlists" is populated even before/without an
    // import.
    await appPlaylistService.load()

    // First authorized launch with an empty DB → import the library so
    // the user sees their playlists (matches the M1/M2 behavior of the
    // sidebar populating on launch, now via SQLite).
    if let store, (try? await store.songCount()) == 0 {
      // Empty DB → first import. Pass `firstImport` so the genre pass
      // runs once here too (it would otherwise only run on the explicit
      // Reimport Everything path).
      await runImport(firstImport: true)
    } else {
      await library.load()
    }

    // Covers the direct `appPlaylistService.load()` /
    // `reloadFavoritesAndRecents()` calls and the `else` (non-import)
    // branch above; `runImport()` also rebuilds, idempotently. Must run
    // before `restoreSelection()` (it reads `allSummaries`/`summariesByID`).
    rebuildDerivedSummaries()
    restoreSelection()
  }

  /// After any import, keep the selection coherent: drop it if the
  /// selected playlist vanished, else refresh its detail.
  private func reconcileSelectionAfterImport() {
    if
      let id = selectedPlaylistID,
      !allSummaries.contains(where: { $0.id == id })
    {
      // Playlist disappeared between refreshes — clear silently.
      selectedPlaylistID = nil
    } else if let summary = selectedSummary {
      // Re-fetch fresh detail for the still-selected playlist.
      detailService.select(summary)
    }
  }

  /// Run the one-way import (incremental by default; `force` re-fetches
  /// every playlist), then reload the store-backed sidebar.
  ///
  /// **Genre pass trigger decision.** Album genres are refreshed only when
  /// `force` (Reimport Everything ⇧⌘R) **or** `firstImport` (the empty-DB
  /// first import). The incremental Refresh path (`refreshLibrary` →
  /// `runImport()` with both flags false) stays genre-free **on purpose**:
  /// incremental Refresh deliberately skips unchanged playlists for speed,
  /// and a full `MusicLibraryRequest<Album>` + per-album `.tracks` scan
  /// every Refresh would defeat exactly that. The genre pass runs after
  /// the playlist import so it tags rows the import has just (re)written.
  private func runImport(force: Bool = false, firstImport: Bool = false) async {
    await importService.runImport(force: force)
    // Targeted (Phase B): drop only the cached details whose snapshot the
    // import actually changed/pruned. `.skipUnchanged` playlists keep
    // their warm cache — an incremental Refresh that changed nothing no
    // longer cold-re-reads the on-screen playlist. `force` re-fetches all,
    // so this naturally degrades to "invalidate everything that existed".
    detailService.invalidate(playlistIDs: importService.changedPlaylistIDs)
    if force || firstImport {
      // Full / first import only — refines `song.genre_names` on rows the
      // import just wrote. Tolerant like the playlist import: its own
      // per-album failures are collected into `genreImportService
      // .lastError` and never abort startup/refresh.
      await genreImportService.importAlbumGenres()
    }
    await library.load()
    rebuildDerivedSummaries()
  }

  /// Recompute the derived summary collections + the O(1) id index from the
  /// current inputs (`library.summaries`, `appPlaylistService.summaries`,
  /// `favoriteIDs`, `recentIDs`). Called only on a real input change, never
  /// from `body` — the Phase-A spry fix: a sidebar render reads already-
  /// built arrays instead of re-concatenating + O(n·m)-scanning on every
  /// invalidation.
  ///
  /// FORWARD PATTERN (`plans/memory-and-laziness.md`). Single-writer for
  /// good (no multi-source sync, ever), so freshness is a discipline, not
  /// a framework concern: every input mutation funnels through here. GRDB
  /// `ValueObservation` was prototyped (Phase C) and **reverted** — its
  /// only single-writer benefit is the "can't forget to refresh"
  /// guarantee, which a mutation chokepoint gives synchronously without the
  /// async-iterator lifecycle / startup-&-reconcile sequencing tax. As
  /// features are built on this baseline, decompose this single
  /// all-collections rebuild into **per-collection** rebuilds invoked by
  /// the specific `LibraryStore` mutation, so a new surface never
  /// recomputes every other surface (the one-God-rebuild is the real
  /// scaling limit here, not observe-vs-manual).
  private func rebuildDerivedSummaries() {
    let imported = library.summaries
    let owned = appPlaylistService.summaries.map { summary -> PlaylistSummary in
      var summary = summary
      summary.isFavorite = favoriteIDs.contains(summary.id)
      return summary
    }
    appPlaylists = owned

    let combined = imported + owned
    allSummaries = combined

    var index = [String: PlaylistSummary](minimumCapacity: combined.count)
    for summary in combined { index[summary.id] = summary }
    summariesByID = index

    favoritePlaylists = combined.filter { favoriteIDs.contains($0.id) }
    recentPlaylists = recentIDs.compactMap { index[$0] }
  }

  private func handleSelectionChange() {
    if let summary = selectedSummary {
      preferences.lastSelectedPlaylistID = summary.id
      detailService.select(summary)
    } else {
      preferences.lastSelectedPlaylistID = nil
      detailService.clear()
    }
  }

  private func restoreSelection() {
    guard let raw = preferences.lastSelectedPlaylistID else { return }
    if allSummaries.contains(where: { $0.id == raw }) {
      selectedPlaylistID = raw
    } else {
      preferences.lastSelectedPlaylistID = nil
    }
  }

  private func reloadFavoritesAndRecents() async {
    guard let store else { return }
    do {
      let favorites = try await store.favorites()
      favoriteIDs = Set(favorites.map(\.playlistID))
      let recents = try await store.recentPlaylists()
      recentIDs = recents.map(\.playlistID)
    } catch {
      storeError = error.localizedDescription
    }
    rebuildDerivedSummaries()
  }

  private func recordRecentlyPlayed(_ id: String, source: PlaylistSourceKind) {
    guard let store else { return }
    // Optimistic: move to front locally now; persist async.
    var updated = recentIDs
    updated.removeAll { $0 == id }
    updated.insert(id, at: 0)
    recentIDs = Array(updated.prefix(12))
    rebuildDerivedSummaries()
    Task {
      do {
        try await store.recordRecent(playlistID: id, source: source)
      } catch {
        storeError = error.localizedDescription
      }
    }
  }

  /// Phase 3 — decide and (fire-and-forget) record a skip/replay for the
  /// track that *was* playing when a transport button was pressed. The
  /// capture order is load-bearing and must run **before**
  /// `playback.skip…` (the transport mutates `queue.currentEntry`, and
  /// thus `currentStoredSongID` / the live playhead):
  ///
  /// 1. `songID` — the pre-skip current stored song (Phase 2; **our**
  ///    `song.id` by structural queue position, never an Apple id).
  /// 2. `(elapsed, duration)` — the **live** playhead off the player at
  ///    the press instant, not the up-to-0.5 s-stale snapshot, so the
  ///    `duration / 2` boundary can't be misclassified (see
  ///    `PlaybackService.livePlayhead()`).
  /// 3. `skipKind(…)` — the pure, deterministic decision.
  /// 4. The caller then runs the unchanged transport.
  ///
  /// Recording is fire-and-forget off the optimistic path (mirrors
  /// `recordRecentlyPlayed`): a store error sets `storeError` and never
  /// blocks or delays the transport. A `.none` decision, an unknown
  /// `songID`, or no store records nothing. `recordReplay` only bumps a
  /// counter — it never appends `play_history` (Decision R4; guaranteed
  /// by `LibraryStore.recordReplay` itself).
  ///
  /// Counting is a pure observer: it does not change how playback or
  /// queueing behaves. The signed gate (pending — user) must confirm this
  /// capture actually beats MusicKit's `currentEntry` mutation under a
  /// real session; the decision is already deterministic & unit-tested.
  private func recordTransportStat(button: PlaybackResolver.TransportButton) {
    guard let store else { return }
    let songID = currentStoredSongID
    let playhead = playback.livePlayhead()
    let kind = PlaybackResolver.skipKind(
      elapsed: playhead.elapsed,
      duration: playhead.duration,
      button: button,
    )
    guard kind != .none, let songID else { return }
    Task {
      do {
        switch kind {
        case .skip:
          try await store.recordSkip(songID: songID)

        case .replay:
          try await store.recordReplay(songID: songID)

        case .none:
          break
        }
      } catch {
        storeError = error.localizedDescription
      }
    }
  }

  /// Phase 4 — record a play whenever the player **advances** to a new
  /// structural queue position (Decision R1: "the last N songs *played*"
  /// must reflect listening, not just clicks). Hung off the existing 0.5 s
  /// `PlaybackService` monitor via `onSnapshotRefresh` (no second timer);
  /// runs once per tick *after* `snapshot` is committed, so it reads the
  /// fresh `queueIndex`.
  ///
  /// The pure, exhaustively-unit-tested `PlaybackResolver.advanceToRecord`
  /// decides; this method only wires it to the detector's watermark and the
  /// store:
  /// - No transition (current == watermark — a paused/steady tick, or a
  ///   back-button **replay** that restarts the same index) → return,
  ///   nothing recorded. This is exactly how **Decision R4** is satisfied
  ///   for free: a replay keeps the same index ⇒ no append; the only count
  ///   is Phase-3's `recordReplay` counter.
  /// - A genuine advance (auto-advance / forward-skip / new-queue start at
  ///   a new position) → advance the watermark **unconditionally** (even
  ///   when the new position is an unattributable `nil` hole — so it isn't
  ///   retried and the *next* real transition is still detected) and, when
  ///   the position attributes to one of **our** `song.id`s (Phase 2;
  ///   never an Apple id), fire-and-forget `store.recordPlay` through
  ///   Phase 1's single one-transaction path (`song_stat` +
  ///   `play_history` append + cap), mirroring `recordRecentlyPlayed`'s
  ///   exact `Task { do { … } catch { storeError } }` shape.
  ///
  /// Recording-only: this is a pure observer; it changes no playback or
  /// queueing behavior. Cheap and synchronous on the monitor — the only
  /// non-trivial work (the SQLite write) is moved off-main into the `Task`.
  /// `lastRecordedQueueIndex` lives in `@ObservationIgnored`
  /// `activePlayContext` and is never read from a view `body`, so this does
  /// not regress the now-playing tick.
  ///
  /// Accepted limitation (`plans/play-statistics.md` — Phase 4): a burst of
  /// skips faster than the 0.5 s poll skips *intermediate* positions in the
  /// history (arguably not "played"); a finer-than-poll transition signal
  /// is explicitly out of scope.
  ///
  /// SIGNED GATE (pending — user): the pure detector + store path are
  /// fully unit-tested and code-complete. Only a real **signed** run can
  /// confirm that `snapshot.queueIndex` actually tracks MusicKit's queue
  /// position across a natural auto-advance and a manual skip, across
  /// pause / interrupt / loop edges, and that song 1 is not double-counted
  /// live (the seed beats the first tick under a real session).
  private func detectAndRecordAdvance() {
    guard let store else { return }
    let currentIndex = playback.snapshot.queueIndex
    guard
      let recordIndex = PlaybackResolver.advanceToRecord(
        lastRecordedIndex: activePlayContext.lastRecordedQueueIndex,
        currentIndex: currentIndex,
      )
    else { return }

    // Advance the watermark UNCONDITIONALLY on a detected transition:
    // even an unattributable (`nil`) position must move it so the same
    // hole isn't retried every tick and the next real transition is
    // still detected. A `nil` position simply records nothing.
    activePlayContext.lastRecordedQueueIndex = recordIndex

    guard
      let songID = PlaybackResolver.storedSongID(
        in: activePlayContext.songIDs,
        at: recordIndex,
      )
    else { return }

    Task {
      do {
        try await store.recordPlay(songID: songID)
      } catch LibraryStore.RecordPlayError.unknownSong(_) {
        // The auto-advance landed on a `song.id` not in the library —
        // a benign Phase-2 re-resolve/snapshot race, NOT a
        // user-actionable error. Swallow it specifically: surfacing it
        // would spam `storeError` on the 0.5 s monitor cadence until
        // the index moves (Phase 3's once-per-press path doesn't have
        // this exposure). Any other store error still surfaces below.
      } catch {
        storeError = error.localizedDescription
      }
    }
  }

  /// The local-first round trip: stored ids → re-resolved MusicKit songs →
  /// existing M1 player. Records a play event when playback actually
  /// starts. Unresolvable tracks are tolerated (they don't break the queue).
  ///
  /// Two re-resolution paths (Phase 4):
  /// - **Imported Apple playlist** → playlist-granularity re-resolve by the
  ///   stored library playlist id (the D1-proven round trip).
  /// - **App playlist** (user-owned, arbitrary songs, no backing Apple
  ///   playlist) → per-song 1:1 re-resolve (the verified `equalTo`-per-id
  ///   path; batch `memberOf` loses correspondence — see PlaybackResolver /
  ///   the risk register).
  private func resolveAndPlay(detail: PlaylistDetail, startRow: TrackRow?) async {
    let resolution: PlaybackResolver.Resolution? =
      if detail.isAppOwned {
        await resolver.resolveAppPlaylist(
          rows: detail.tracks,
          startAt: startRow,
        )
      } else {
        // `detail.id` is the imported playlist's library `MusicItemID`.
        await resolver.resolvePlaylist(
          libraryPlaylistID: detail.id,
          rows: detail.tracks,
          startAt: startRow,
        )
      }

    // The canonical-context set, the synchronous recents bump, and the
    // queue swap are the invariant-sensitive sequence — run them through
    // the single shared helper so the ordering window exists in exactly
    // one place. The recents bump is synchronous and runs *inside* that
    // window via the helper's `beforePlay` hook.
    let didStart = await startResolvedQueue(
      resolution,
      contextID: detail.id,
      beforePlay: { [self] in
        recordRecentlyPlayed(detail.id, source: detail.isAppOwned ? .app : .apple)
      },
    )

    // Record the play ONLY on a confirmed start, for the track that
    // actually started. `recordPlay` maintains song_stat in the same
    // transaction (Phase 2 machinery).
    if didStart, let resolution {
      await recordPlayStart(for: resolution, detail: detail, startRow: startRow)
    }
  }

  /// The single invariant-sensitive queue-start sequence, shared by
  /// `resolveAndPlay` (app + Apple branches) and `playRecentlyPlayed`. A
  /// `nil` resolution clears the canonical context and returns `false`
  /// (no queue set). Otherwise it sets the Phase-2 canonical context +
  /// seeds the Phase-4 watermark **atomically**, runs the synchronous
  /// `beforePlay` side effect (if any), then swaps the player queue —
  /// returning whether playback confirmed.
  ///
  /// LOAD-BEARING ORDERING INVARIANT (the reason this is ONE helper, not
  /// duplicated at each call site): there must be NO `await` suspension
  /// between the `activePlayContext` assignment below and `player.queue`
  /// being swapped to the new songs (synchronous, inside
  /// `PlaybackService.setQueueAndPlay` before its first `await`).
  /// `beforePlay` is a **synchronous** `@MainActor` closure and
  /// `await playback.play(...)` runs synchronously until
  /// `try await player.play()` — which is *after* `player.queue` is set.
  /// On the single-threaded MainActor that guarantees a 0.5 s monitor tick
  /// can only ever observe (old context, old queue) — during the resolve
  /// `await` at the call site, correctly attributing the prior queue the
  /// user is still hearing — or (new context, new queue), never a (new
  /// context, old queue) mix that would misattribute / double-count. Do
  /// NOT insert an `await`, nor make `beforePlay` async, between the
  /// assignment and `playback.play` without re-establishing this invariant
  /// another way.
  private func startResolvedQueue(
    _ resolution: PlaybackResolver.Resolution?,
    contextID: String?,
    beforePlay: (@MainActor () -> Void)?,
  ) async -> Bool {
    guard let resolution else {
      // Resolve failed → no queue is set; drop any prior context so a
      // stale one is never attributed to the next play (Phase 2). This
      // also resets the Phase-4 watermark to `nil` in the same atomic
      // assignment — context and watermark can't drift.
      activePlayContext = ActivePlayContext()
      return false
    }

    // Retain THIS queue's canonical context (replaced per queue), set
    // before `playback.play` so the seed index is valid the instant the
    // queue exists. Our data from our SQLite read — no Apple id.
    //
    // Seed the Phase-4 watermark to the structural START index in the
    // SAME assignment: the detector's first observation (current ==
    // seed) is then not a transition, so the explicitly-started first
    // track — recorded by `recordPlayStart` at the call site — is never
    // re-appended to `play_history` (no double-count of song 1).
    activePlayContext = ActivePlayContext(
      songIDs: resolution.playContext,
      startSongID: resolution.startSongID,
      lastRecordedQueueIndex: PlaybackResolver.startIndex(
        in: resolution.playContext,
        startSongID: resolution.startSongID,
      ),
    )

    // Synchronous side effect inside the invariant window (e.g. the
    // playlist-recents bump). Must NOT introduce an `await`.
    beforePlay?()

    // `play` confirms the player actually reached `.playing` (polls the
    // player's own live status, not the 0.5 s-lagged snapshot — the
    // Phase-3 follow-up fix; the old `snapshot.isPlaying` guard read the
    // stale poll too early so plays never recorded).
    return await playback.play(
      songs: resolution.songs,
      startingAt: resolution.startSong,
      playlistContextID: contextID,
    )
  }

  private func recordPlayStart(
    for resolution: PlaybackResolver.Resolution,
    detail: PlaylistDetail,
    startRow: TrackRow?,
  ) async {
    // The resolver reports the started track's *stored* `song.id` (the FK
    // target). This is deterministic and correct for both paths — unlike
    // matching the now-playing id back to a row, which fails because the
    // resolved `Song.id` is the song's own `i.` id, not the stored
    // `music_item_id` (the Track-id≠Song-id finding). Fall back to the
    // explicit start row, then the first track, if the resolver couldn't
    // attribute one.
    let startedSongID = resolution.startSongID
      ?? startRow?.songID
      ?? detail.tracks.first?.songID
    guard let startedSongID else { return }
    let recorded = await recordPlayStart(startedSongID: startedSongID)
    if recorded {
      // The play just bumped `song_stat`; refresh the on-screen
      // track table's Plays / Last Played columns from the fresh
      // `songsWithStats` join (D4). Discrete event — fired once on
      // the recorded play, not on every now-playing snapshot tick.
      await detailService.refreshStats(for: detail.id)
    }
  }

  /// Record the play of `startedSongID` through Phase 1's single
  /// one-transaction path (`song_stat` + `play_history` append + cap),
  /// shared by the playlist start path and `playRecentlyPlayed` (dogfood:
  /// listening from the Recently Played list also feeds stats). Returns
  /// whether the write succeeded so the playlist wrapper can decide whether
  /// to refresh the on-screen detail (the Recently Played list has no such
  /// detail — its own surface re-reads via `reload()`). A store error sets
  /// `storeError`, matching the codebase.
  @discardableResult
  private func recordPlayStart(startedSongID: String) async -> Bool {
    guard let store else { return false }
    do {
      try await store.recordPlay(songID: startedSongID)
      return true
    } catch {
      storeError = error.localizedDescription
      return false
    }
  }

  /// The single funnel for the membership-mutating app-playlist edits
  /// (rename / addSongs / removeTracks / setTracks): run the store
  /// mutation, then **always** re-derive the sidebar collections and
  /// refresh the on-screen detail. Routing every such edit through here
  /// makes the "forgot to rebuild after a write" bug class (the Phase-4 UI
  /// corrective) structurally impossible for these paths instead of a
  /// per-method discipline — the chokepoint the memory-and-laziness plan
  /// commits to, made structural. (`create`/`delete`/`reorder` keep their
  /// own post-mutation bookkeeping: a different shape — selection assign,
  /// silent clear, or no per-playlist detail — would only be hurt by being
  /// forced through this funnel.)
  private func mutateAppPlaylist(
    _ playlistID: String,
    _ operation: () async -> Void,
  ) async {
    await operation()
    rebuildDerivedSummaries()
    refreshSelectedDetailIfNeeded(playlistID)
  }

  /// After an app-playlist mutation, drop **that playlist's** stale cached
  /// detail (Phase B targeted invalidation — other cached details stay
  /// warm) and, if it's the one on screen, reload it so the track table
  /// reflects the edit.
  private func refreshSelectedDetailIfNeeded(_ playlistID: String) {
    detailService.invalidate(playlistID: playlistID)
    if selectedPlaylistID == playlistID, let summary = selectedSummary {
      detailService.select(summary)
    }
  }

}
