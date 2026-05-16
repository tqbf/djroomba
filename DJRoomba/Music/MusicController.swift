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

  /// Sidebar selection. App-local state — drives lazy detail load and is
  /// persisted so it survives relaunch (if the playlist still exists).
  var selectedPlaylistID: String? {
    didSet {
      guard oldValue != selectedPlaylistID else { return }
      handleSelectionChange()
    }
  }

  /// Every selectable playlist across both libraries — imported Apple
  /// snapshots and user-owned app playlists. Selection / restore / detail
  /// lookups go through this so the two sources are uniform.
  var allSummaries: [PlaylistSummary] {
    library.summaries + appPlaylistService.summaries
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

  var selectedSummary: PlaylistSummary? {
    guard let id = selectedPlaylistID else { return nil }
    return allSummaries.first { $0.id == id }
  }

  /// Imported Apple library playlists ("Library Playlists" section).
  var libraryPlaylists: [PlaylistSummary] {
    library.summaries
  }

  /// User-owned, SQLite-only playlists ("My Playlists" section, Phase 4).
  /// `isFavorite` is overlaid here (the service leaves it false).
  var appPlaylists: [PlaylistSummary] {
    appPlaylistService.summaries.map { summary in
      var s = summary
      s.isFavorite = favoriteIDs.contains(summary.id)
      return s
    }
  }

  /// Favorites span both libraries (a user playlist can be a favorite too).
  var favoritePlaylists: [PlaylistSummary] {
    allSummaries.filter { favoriteIDs.contains($0.id) }
  }

  /// Recently played, in recency order, limited to playlists still present
  /// in either library.
  var recentPlaylists: [PlaylistSummary] {
    recentIDs.compactMap { raw in
      allSummaries.first { $0.id == raw }
    }
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

  /// The Refresh affordance (⌘R / toolbar). Re-imports from Apple Music
  /// one-way, then reloads the sidebar/detail from SQLite.
  func refreshLibrary() async {
    await runImport()
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

  func skipNext() async {
    await playback.skipNext()
  }

  func skipPrevious() async {
    await playback.skipPrevious()
  }

  /// Create a new user playlist and select it (the native "new untitled
  /// item, ready to rename" flow). Returns its id so the sidebar can put
  /// the row straight into inline-rename.
  @discardableResult
  func createAppPlaylist(named name: String = "New Playlist") async -> String? {
    let id = await appPlaylistService.create(named: name)
    if let id { selectedPlaylistID = id }
    return id
  }

  func renameAppPlaylist(_ playlistID: String, to name: String) async {
    await appPlaylistService.rename(playlistID, to: name)
    refreshSelectedDetailIfNeeded(playlistID)
  }

  func deleteAppPlaylist(_ playlistID: String) async {
    await appPlaylistService.delete(playlistID)
    detailService.invalidate()
    if selectedPlaylistID == playlistID {
      // Selected playlist was deleted — clear selection silently.
      selectedPlaylistID = nil
    }
  }

  func addSongs(_ songIDs: [String], toAppPlaylist playlistID: String) async {
    await appPlaylistService.addSongs(songIDs, to: playlistID)
    refreshSelectedDetailIfNeeded(playlistID)
  }

  func removeTracks(at oneBasedPositions: [Int], fromAppPlaylist playlistID: String) async {
    await appPlaylistService.removeTracks(at: oneBasedPositions, from: playlistID)
    refreshSelectedDetailIfNeeded(playlistID)
  }

  /// Persist a reordered membership for an app playlist (the full ordered
  /// song-id list, e.g. after a drag-to-reorder in the track table).
  func setAppPlaylistTracks(_ songIDs: [String], for playlistID: String) async {
    await appPlaylistService.setTracks(songIDs, for: playlistID)
    refreshSelectedDetailIfNeeded(playlistID)
  }

  /// Persist a new sidebar order for the user playlists.
  func reorderAppPlaylists(_ orderedIDs: [String]) async {
    await appPlaylistService.reorder(orderedIDs)
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

  /// The SQLite source of truth, and everything that reads/writes it. If
  /// the store can't be opened the app still runs (auth/empty states); the
  /// failure is surfaced via `storeError`.
  @ObservationIgnored private let store: LibraryStore?

  @ObservationIgnored private let preferences = UserPreferencesStore()
  @ObservationIgnored private let legacyMigration = LegacyPreferencesMigration()

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

    restoreSelection()
  }

  /// Run the one-way import, then reload the store-backed sidebar.
  private func runImport() async {
    await importService.runImport()
    detailService.invalidate()
    await library.load()
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
  }

  private func recordRecentlyPlayed(_ id: String, source: PlaylistSourceKind) {
    guard let store else { return }
    // Optimistic: move to front locally now; persist async.
    var updated = recentIDs
    updated.removeAll { $0 == id }
    updated.insert(id, at: 0)
    recentIDs = Array(updated.prefix(12))
    Task {
      do {
        try await store.recordRecent(playlistID: id, source: source)
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
    guard let resolution else { return }

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

  /// After an app-playlist mutation, drop the stale cached detail and (if
  /// it's the one on screen) reload it so the track table reflects the edit.
  private func refreshSelectedDetailIfNeeded(_ playlistID: String) {
    detailService.invalidate()
    if selectedPlaylistID == playlistID, let summary = selectedSummary {
      detailService.select(summary)
    }
  }

}
