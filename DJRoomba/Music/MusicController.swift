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
    importService = ImportService(store: safeStore)
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
  let importService: ImportService
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

  // MARK: Private

  /// The canonical play context for the active queue, captured atomically
  /// from one resolve so its two parts can never drift (set and cleared in
  /// a single assignment). `songIDs[k]` is the stored `song.id` of the
  /// player's queue entry `k` (`nil` = unattributable position);
  /// `startSongID` seeds the structural index before the first monitor
  /// tick. Phase-2 recording machinery; Phases 3–4 read it.
  private struct ActivePlayContext {
    var songIDs = [String?]()
    var startSongID: String?
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
      await runImport()
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
  private func runImport(force: Bool = false) async {
    await importService.runImport(force: force)
    // Targeted (Phase B): drop only the cached details whose snapshot the
    // import actually changed/pruned. `.skipUnchanged` playlists keep
    // their warm cache — an incremental Refresh that changed nothing no
    // longer cold-re-reads the on-screen playlist. `force` re-fetches all,
    // so this naturally degrades to "invalidate everything that existed".
    detailService.invalidate(playlistIDs: importService.changedPlaylistIDs)
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
    guard let resolution else {
      // Resolve failed → no queue is set; drop any prior context so a
      // stale one is never attributed to the next play (Phase 2).
      activePlayContext = ActivePlayContext()
      return
    }

    // Retain THIS queue's canonical context (replaced per queue), set
    // before `playback.play` so the seed index is valid the instant the
    // queue exists. Our data from our SQLite read — no Apple id.
    activePlayContext = ActivePlayContext(
      songIDs: resolution.playContext,
      startSongID: resolution.startSongID,
    )

    recordRecentlyPlayed(detail.id, source: detail.isAppOwned ? .app : .apple)
    // `play` confirms the player actually reached `.playing` (polls the
    // player's own live status, not the 0.5 s-lagged snapshot — the
    // Phase-3 follow-up fix; the old `snapshot.isPlaying` guard read the
    // stale poll too early so plays never recorded).
    let didStart = await playback.play(
      songs: resolution.songs,
      startingAt: resolution.startSong,
      playlistContextID: detail.id,
    )

    // Record the play ONLY on a confirmed start, for the track that
    // actually started. `recordPlay` maintains song_stat in the same
    // transaction (Phase 2 machinery).
    if didStart {
      await recordPlayStart(for: resolution, detail: detail, startRow: startRow)
    }
  }

  private func recordPlayStart(
    for resolution: PlaybackResolver.Resolution,
    detail: PlaylistDetail,
    startRow: TrackRow?,
  ) async {
    guard let store else { return }
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
    do {
      try await store.recordPlay(songID: startedSongID)
      // The play just bumped `song_stat`; refresh the on-screen
      // track table's Plays / Last Played columns from the fresh
      // `songsWithStats` join (D4). Discrete event — fired once on
      // the recorded play, not on every now-playing snapshot tick.
      await detailService.refreshStats(for: detail.id)
    } catch {
      storeError = error.localizedDescription
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
