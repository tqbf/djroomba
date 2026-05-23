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
    genreGraphService = GenreGraphService(store: safeStore)
    genreMapService = GenreMapService(store: safeStore)
    genreTreeService = GenreTreeService(store: safeStore, mapService: genreMapService)
    catalogIngestService = CatalogIngestService(store: safeStore)
    snapshotService = SnapshotService(store: safeStore)
    resolver = PlaybackResolver()
    autoReanalyzeGenreGraph = preferences.autoReanalyzeGenreGraph
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
  /// The "Analyze" action: rebuilds the genre co-occurrence graph from all
  /// playlists. Pure SQLite (no MusicKit), so it is also re-run
  /// automatically after a playlist change when `autoReanalyzeGenreGraph`
  /// is on.
  let genreGraphService: GenreGraphService
  /// Phase 1 of `plans/genre-metro-map.md` — the genre **map** substrate
  /// (sibling, not replacement, of `genreGraphService`). Driven by the
  /// new "Analyze (Map)" action and a `runMapRebuildIfEnabled()` hook
  /// alongside the existing genre-graph one. Phase 6 will consolidate.
  let genreMapService: GenreMapService

  /// Phase B of `plans/son-of-genre-map.md` — the genre **tree** view's
  /// binding target. A thin observable that runs the pure Phase A
  /// (`GenreTreeBuilder` MST + trunk selection + BFS forest) and
  /// Phase B (`GenreTreeLayout` diagonal + radial fanning) pipelines
  /// against the metro substrate. Reads `genre_node` +
  /// `genre_edge_evidence` from the store; pulls the medium-resolution
  /// Louvain partition out of `genreMapService.model` so community
  /// detection runs once across both views. No schema change.
  let genreTreeService: GenreTreeService
  /// `.djroomba` library snapshot export / import + revert
  /// (`plans/snapshot-export-import.md`). Non-MusicKit; the controller
  /// owns the post-op UI reload + genre reanalyze, exactly as it does for
  /// `ImportService` ↔ `runImport`.
  let snapshotService: SnapshotService
  let resolver: PlaybackResolver

  /// Phase 1 (`plans/catalog-playlists.md`): catalog `Song` → SQLite `song`
  /// row, the prerequisite for any catalog track to participate in app
  /// playlists. Phase 2's "Add Catalog Result to Playlist" path
  /// (`addCatalogSong(_:toAppPlaylist:)`) calls into this; nothing else
  /// does today. Kept internal — views never reach this service directly,
  /// they go through the controller, exactly like every other write path.
  let catalogIngestService: CatalogIngestService

  /// Phase 2 (`plans/catalog-playlists.md`): the subordinate Apple Music
  /// catalog search surface. `@Observable` so the search sheet binds to
  /// `results` / `isSearching` / `lastError` / `hasMore` directly. Stateless
  /// w.r.t. SQLite — ingest only happens when the user *acts on* a result.
  let catalogSearch = CatalogSearchService()

  /// Observable mirrors of the persisted app state. SQLite is authoritative;
  /// these are refreshed from it after writes (no dual store).
  private(set) var favoriteIDs = Set<String>()
  private(set) var recentIDs = [String]()

  /// Bumped by the ⌘L / ⌘1 commands; the sidebar observes this to take
  /// keyboard focus (commands are app-scoped, so this bridges to the view).
  private(set) var focusSidebarRequest = 0

  /// The neutral, dismissible self-diagnosis for the last *full / first*
  /// album-genre pass that finished without an error yet tagged zero songs
  /// (so playlist genre chips / the genre graph would be bare with the app
  /// otherwise showing nothing). The pure, unit-tested `GenreImportSummary
  /// .notice` decides the triad + most-likely cause; this is its observed
  /// home. `nil` ⇒ no notice (success-with-tags clears it; an errored pass
  /// leaves it `nil` because the orange `libraryProblem` already surfaces
  /// `genreImportService.lastError`). Set only on a full/first import; a
  /// later incremental Refresh leaves the prior value (it describes the last
  /// full pass — acceptable). Dismissible via `dismissGenreImportNotice()`.
  private(set) var genreImportNotice: String?

  /// The last Phase-0 catalog access probe verdict (a human-readable
  /// success/failure string from `CatalogProbeService`). `nil` ⇒ no probe
  /// run since launch or it was dismissed. Surfaced in the toolbar `.status`
  /// slot via the same calm dismissible-popover idiom as `genreImportNotice`;
  /// dismissed via `dismissCatalogProbeResult()`.
  private(set) var catalogProbeResult: String?

  /// Whether the Phase-2 catalog search sheet is presented. Bound by
  /// `MainShellView.sheet(isPresented:)`; flipped by the Search ▸ Search
  /// Apple Music… (⇧⌘F) menu command via `presentCatalogSearch()`. Not
  /// `private(set)` because SwiftUI's `Bindable` needs settability for the
  /// `.sheet(isPresented:)` two-way binding (the standard idiom for
  /// app-level sheet state under `@Observable`).
  var catalogSearchPresented = false

  /// Collapse state of the genre-tree pane docked below the track
  /// list in the detail column. `false` ⇒ expanded (visible). Lives
  /// on the controller (not `@SceneStorage`) so the menu command, the
  /// toolbar button, and the pane's own header chevron all drive one
  /// shared value. Phase B of `plans/son-of-genre-map.md` first shipped
  /// the tree as a sheet; per user direction (2026-05-22) it now lives
  /// inline as a docked pane, matching the retired ForceGraph's home.
  var genreTreePaneCollapsed = false

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

  /// Every distinct genre tag in the library, alphabetical (the
  /// `appPlaylists`-style observable mirror — reloaded on session start
  /// and after any genre edit / import). Backs the "Add to Genre ▸"
  /// context submenu. `plans/genre-editing.md`.
  private(set) var allGenres = [String]()

  /// Drives the single modal genre-name `.sheet(item:)` (rename a browsed
  /// genre, or assign a genre to selected tracks). Mutable so the view
  /// binds it via `@Bindable` (swiftui-pro: `sheet(item:)` over
  /// `isPresented`, no `Binding(get:set:)`); set to `nil` to dismiss.
  var genreNameRequest: GenreNameRequest?

  /// Favorites span both libraries (a user playlist can be a favorite too).
  private(set) var favoritePlaylists = [PlaylistSummary]()

  /// Recently played, in recency order, limited to playlists still present
  /// in either library.
  private(set) var recentPlaylists = [PlaylistSummary]()

  /// O(1) id → summary index over `allSummaries`. Backs `selectedSummary`
  /// and every `…contains(where: id ==)` / `first(where: id ==)` lookup so
  /// they stop being O(n) scans over a freshly concatenated array.
  private(set) var summariesByID = [String: PlaylistSummary]()

  /// The synthetic genre collection currently shown in the top pane (the
  /// genre-graph navigation), or nil. Mutually exclusive with a playlist
  /// selection: picking a playlist clears this, and `showGenre` clears
  /// `selectedPlaylistID`. Observed; drives the detail pane + sidebar
  /// highlight suppression. In-memory only — genres are per-session.
  private(set) var selectedGenre: String?

  /// The in-session top-pane Back stack (LIFO of PRE-change destinations).
  /// Observed so `canGoBack` recomputes when it changes. The push/cap/pop
  /// rules live in the pure, unit-tested `DetailNavStack`; this controller
  /// only decides *what* destination to record/replay. Never persisted —
  /// starts empty each launch.
  private(set) var navBackStack = DetailNavStack()

  /// `.fileExporter` / `.fileImporter` presentation, bound from
  /// `MainShellView` via `@Bindable` (swiftui-pro: no `Binding(get:set:)`).
  /// The exporter is only flipped true *after* `snapshotExportDocument` is
  /// built off-main, so the picker always has its bytes ready.
  var isPresentingSnapshotExporter = false
  var isPresentingSnapshotImporter = false
  private(set) var snapshotExportDocument: SnapshotDocument?

  /// Observable mirror of `UserPreferencesStore.autoReanalyzeGenreGraph`
  /// (default on). Same pattern as `lastSelectedPlaylistID`: the
  /// UserDefaults store is the durable truth (it can't live inside an
  /// `@Observable` as `@AppStorage`), this is the observed mirror the menu
  /// toggle binds to, and the `didSet` writes the change straight back.
  /// Turning it on does NOT itself rebuild — "Analyze Genre Graph" is the
  /// explicit on-demand action; this only governs the automatic reanalyze.
  var autoReanalyzeGenreGraph: Bool {
    didSet {
      guard oldValue != autoReanalyzeGenreGraph else { return }
      preferences.autoReanalyzeGenreGraph = autoReanalyzeGenreGraph
    }
  }

  /// Sidebar selection. App-local state — drives lazy detail load and is
  /// persisted so it survives relaunch (if the playlist still exists).
  ///
  /// STORED (least-risk): its `didSet` is the single integration point for
  /// the in-session Back stack. On a *user* selection change it records the
  /// PRE-change destination onto `navBackStack` and clears any genre view
  /// (a sidebar/playlist pick exits a genre). During Back/restore replay
  /// (`suppressNavRecording == true`) it does neither — the caller owns
  /// genre/history state — so launch restore creates no phantom history and
  /// `goBack` doesn't re-record what it's popping.
  var selectedPlaylistID: String? {
    didSet {
      guard oldValue != selectedPlaylistID else { return }
      if !suppressNavRecording {
        navBackStack.push(selectedGenre.map(DetailDestination.genre) ?? oldValue.map(DetailDestination.playlist))
        selectedGenre = nil
      }
      handleSelectionChange()
    }
  }

  /// Whether the Back control is enabled (there is a previous destination).
  var canGoBack: Bool {
    navBackStack.canGoBack
  }

  /// True while the library is being (re)populated — an Apple import is
  /// running OR the store-backed sidebar is reloading. Drives the sidebar's
  /// existing "Loading playlists…" state so first-launch import doesn't
  /// briefly flash "No Playlists" (same UI, just honest about the import).
  var isLibraryBusy: Bool {
    importService.isImporting
      || genreImportService.isImporting
      || snapshotService.isExporting
      || snapshotService.isImporting
      || library.isLoading
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

  /// The always-on import status text for the toolbar's `.status` slot —
  /// visible during any playlist import or genre pass *regardless of whether
  /// the sidebar is already populated* (the defect: `libraryLoadingMessage`
  /// only ever renders in the empty sidebar, so a Reimport Everything over a
  /// populated library gave zero feedback for 90–120 s). `nil` when nothing
  /// is running. The wording + precedence live in the pure, unit-tested
  /// `ImportActivity.text`; this just feeds it the live service counts. The
  /// playlist branch is kept word-identical to `libraryLoadingMessage` so the
  /// two surfaces never disagree.
  var importActivity: String? {
    ImportActivity.text(
      playlistsImporting: importService.isImporting,
      playlistsDone: importService.importedPlaylistCount,
      playlistsTotal: importService.totalPlaylistCount,
      genresImporting: genreImportService.isImporting,
      genresDone: genreImportService.importedAlbumCount,
      genresTotal: genreImportService.totalAlbumCount,
    )
  }

  /// A user-facing problem string for the sidebar's error state: a store
  /// open/migration failure, an import failure, or a swallowed genre-pass
  /// failure. Import/genre come before the library read (which has its own
  /// retry); `storeError` stays first. The genre term is load-bearing — a
  /// `GenreImportService.lastError` on a populated library was previously in
  /// *no* surface at all, so a failed album-genre pass was completely silent.
  var libraryProblem: String? {
    storeError
      ?? importService.lastError
      ?? genreImportService.lastError
      ?? snapshotService.lastError
      ?? library.loadError
  }

  /// The quiet `.status` spinner text: the playlist/genre import wins
  /// (the load-bearing precedence `ImportActivity` owns), else a snapshot
  /// export/import in flight, else nil. Keeps the existing tested
  /// `ImportActivity` contract untouched while folding in the new op.
  var activityText: String? {
    if let importActivity { return importActivity }
    if snapshotService.isExporting { return "Exporting library snapshot…" }
    if snapshotService.isImporting { return "Importing library snapshot…" }
    return nil
  }

  /// The dismissible post-import result for the `.status` chip (reuses the
  /// `genreImportNotice` chip/popover pattern). `nil` before any import /
  /// once dismissed / after a revert.
  var snapshotResult: SnapshotMergeSummary? {
    snapshotService.lastResult
  }

  /// Whether "Revert Last Snapshot Import" is available (a pre-import
  /// backup exists). Drives the menu item's enabled state.
  var canRevertSnapshot: Bool {
    snapshotService.canRevert
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

  /// Dismiss the neutral genre-import self-diagnosis (the toolbar info chip's
  /// "Dismiss"). One-way: clears it until the next full/first pass re-derives.
  func dismissGenreImportNotice() {
    genreImportNotice = nil
  }

  /// Dismiss the Phase-0 catalog probe verdict (the toolbar info chip's
  /// "Dismiss"). One-way: clears it until the probe is re-run.
  func dismissCatalogProbeResult() {
    catalogProbeResult = nil
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

  /// The **"Analyze"** action (menu / ⌥⌘A): rebuild the genre
  /// co-occurrence graph from every playlist, on demand. Always runs
  /// regardless of the `autoReanalyzeGenreGraph` toggle (that toggle only
  /// governs the *automatic* reanalyze after a change). Pure SQLite — no
  /// MusicKit, no import — so it is cheap and works offline; failures are
  /// surfaced via the service's `lastError`, never thrown.
  func analyzeGenreGraph() async {
    await runGenreAnalysis()
  }

  /// **Analyze Genre Tree** — Phase B of `plans/son-of-genre-map.md`.
  /// User-facing rebuild of the trunk-tree view. Reuses the metro
  /// substrate (community detection lives in `GenreMapService`) so the
  /// Louvain pass runs at most once across both views.
  ///
  /// Sequence:
  ///
  /// 1. Run `runGenreAnalysis` (v6 + v7 substrate rebuild) — same as
  ///    `analyzeGenreMap` because the tree reads the same evidence
  ///    rows.
  /// 2. Force a metro `GenreMapService.build` so the medium-resolution
  ///    Louvain partition is fresh in `genreMapService.model`.
  /// 3. Run `genreTreeService.build` — pure Phase A + Phase B pipeline,
  ///    no SQL outside steps 1–2.
  func analyzeGenreTree() async {
    await runGenreAnalysis()
    await genreMapService.build()
    await genreTreeService.build()
  }

  /// Auto-rebuild hook for the genre tree. Single funnel called from
  /// every mutation trigger (`runImport`, `addSongs`, `removeTracks`,
  /// `setAppPlaylistTracks`, `deleteAppPlaylist`). Fire-and-forget on
  /// the MainActor; gated on the `autoReanalyzeGenreGraph` UserDefaults
  /// key (semantics preserved across the metro → tree pivot — the key
  /// flips BOTH the v6 graph + the v7 substrate + the tree view).
  ///
  /// Sequence: v6 `rebuildGenreGraph` first (the map's playlist
  /// channel reads from it), then v7 `rebuildGenreMap` substrate +
  /// `GenreTreeService.build` (which persists tree positions back to
  /// `v9.genreMapState`). Each service coalesces concurrent triggers
  /// via its own `isAnalyzing` flag, so a burst of edits collapses
  /// into one rebuild — the next trigger after it lands already
  /// reflects every change in between.
  func runMapRebuildIfEnabled() {
    guard autoReanalyzeGenreGraph else { return }
    Task { await runGenreAnalysis() }
    Task {
      await genreMapService.build()
      await genreTreeService.build()
    }
  }

  /// File ▸ Export Library Snapshot…. Build the compressed `.djroomba`
  /// bytes off-main first, then present `.fileExporter` (only if the build
  /// succeeded — a failure surfaces via `libraryProblem`).
  func beginSnapshotExport() async {
    let document = await snapshotService.prepareExport()
    guard let document else { return }
    snapshotExportDocument = document
    isPresentingSnapshotExporter = true
  }

  /// `.fileImporter` completion: merge the picked snapshot's metadata onto
  /// the current library (content-matched, song-only — never blitzes
  /// playlists/history), then reload all derived UI and reanalyze the
  /// genre graph (genres changed). The pre-import backup + Revert
  /// affordance are handled by `SnapshotService`.
  func applySnapshot(from url: URL) async {
    let summary = await snapshotService.apply(snapshotAt: url)
    guard summary != nil else { return }
    await reloadAfterSnapshotChange()
  }

  /// Revert the last snapshot import by swapping the pre-import backup DB
  /// back in (File-menu item or the `.status` chip's button), then reload.
  func revertSnapshotImport() async {
    let ok = await snapshotService.revert()
    guard ok else { return }
    await reloadAfterSnapshotChange()
  }

  /// Dismiss the post-import `.status` chip without reverting.
  func dismissSnapshotResult() {
    snapshotService.dismissResult()
  }

  /// `.fileExporter` completion. Frees the built bytes; surfaces a real
  /// write failure (user cancellation is silent).
  func completeSnapshotExport(_ result: Result<URL, Error>) {
    snapshotExportDocument = nil
    if case .failure(let error) = result, !Self.isCancellation(error) {
      snapshotService.noteFailure(
        "Could not write the snapshot: \(error.localizedDescription)"
      )
    }
  }

  /// `.fileImporter` completion → merge on success; surface a real open
  /// failure (user cancellation is silent).
  func completeSnapshotImport(_ result: Result<URL, Error>) async {
    switch result {
    case .success(let url):
      await applySnapshot(from: url)

    case .failure(let error):
      if !Self.isCancellation(error) {
        snapshotService.noteFailure(
          "Could not open the snapshot: \(error.localizedDescription)"
        )
      }
    }
  }

  /// Header "Rename" affordance (only shown for a browsed genre). Opens
  /// the modal sheet seeded with the current genre name, fully selected.
  func beginRenameBrowsedGenre() {
    guard let genre = selectedGenre else { return }
    genreNameRequest = GenreNameRequest(
      title: "Rename Genre",
      prompt: "Genre Name",
      initialText: genre,
      action: .renameBrowsedGenre,
    )
  }

  /// Right-click a genre pill in the genre map ▸ "Rename…". Opens the
  /// modal sheet seeded with that genre's name. Unlike
  /// `beginRenameBrowsedGenre`, the target is named explicitly (the
  /// clicked pill), so it works regardless of what's in the track pane.
  func beginRenameGenre(_ genre: String) {
    let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    genreNameRequest = GenreNameRequest(
      title: "Rename Genre",
      prompt: "Genre Name",
      initialText: trimmed,
      action: .renameGenre(from: trimmed),
    )
  }

  /// "Add to Genre ▸ New Genre…" — open the sheet to type a new genre for
  /// the selected tracks.
  func beginAssignNewGenre(toSongs songIDs: [String]) {
    guard !songIDs.isEmpty else { return }
    genreNameRequest = GenreNameRequest(
      title: "Assign Genre",
      prompt: "Genre Name",
      initialText: "",
      action: .assignToSongs(songIDs),
    )
  }

  func cancelGenreNameSheet() {
    genreNameRequest = nil
  }

  /// Commit the modal sheet. `name` is already trimmed/non-empty (the
  /// sheet's default button is disabled otherwise). Renaming to the same
  /// name (or an empty selection) is a safe no-op.
  func commitGenreNameSheet(_ request: GenreNameRequest, name: String) async {
    genreNameRequest = nil
    switch request.action {
    case .renameBrowsedGenre:
      guard let old = selectedGenre else { return }
      await renameGenreTag(from: old, to: name)

    case .renameGenre(let from):
      await renameGenreTag(from: from, to: name)

    case .assignToSongs(let songIDs):
      await addGenre(name, toSongs: songIDs)
    }
  }

  /// Right-click "Add to Genre ▸ <existing>" — assign an existing genre to
  /// the selected tracks (idempotent; merges naturally).
  func addGenre(_ genre: String, toSongs songIDs: [String]) async {
    guard let store, !songIDs.isEmpty else { return }
    let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      _ = try await store.addGenre(trimmed, toSongIDs: songIDs)
      await reloadAfterGenreEdit()
    } catch {
      storeError = error.localizedDescription
    }
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

  /// Debug menu action: run the Phase-0 catalog access probe and surface its
  /// verdict in the toolbar notice slot. Fire-and-forget-safe — the service
  /// never throws (it returns a diagnostic string for both success and
  /// failure). No `#if DEBUG` gate, for the same reason as
  /// `seedSyntheticHistory`: the user's normal `make` build is debug-config
  /// and the clearly-labelled "Debug" button is wanted.
  ///
  /// Two halves, both required for Phase 0 to pass
  /// (`plans/catalog-playlists.md`): (1) a catalog search returns a song;
  /// (2) that song actually plays via `ApplicationMusicPlayer`. The service
  /// owns half (1) and hands back the first hit; the controller layers
  /// half (2) by routing the song through the existing `PlaybackService`
  /// — the same proven auto-start path the rest of the app uses, so a
  /// success here proves catalog playback end-to-end, not a side channel.
  /// On a confirmed play we let it run ~1.5 s (long enough to be visibly
  /// audible / capture in a screenshot) and then pause; on a non-confirmed
  /// play we report the failure and skip the pause.
  /// Menu command target: open the Phase-2 catalog search sheet. Idempotent
  /// — calling while presented is a no-op. The sheet owns the search field
  /// (auto-focused on appear) and the debouncer.
  func presentCatalogSearch() {
    catalogSearchPresented = true
  }

  func runCatalogAccessProbe() async {
    let probe = await catalogProbeService.searchProbe()
    guard let firstSong = probe.firstSong else {
      // Search half failed (or returned 0) — the service's verdict is the
      // diagnostic; no playback to attempt.
      catalogProbeResult = probe.verdict
      return
    }
    let started = await playback.play(
      songs: [firstSong],
      startingAt: firstSong,
      playlistContextID: nil,
      namespace: .catalog,
    )
    guard started else {
      catalogProbeResult = """
        \(probe.verdict)

        ❌ Playback FAILED — ApplicationMusicPlayer did not confirm `.playing` \
        within the bounded wait. \
        \(playback.lastError.map { "Player error: \($0)" } ?? "No player error reported.")

        Phase 0 SEARCH PASSED, PLAYBACK FAILED.
        """
      return
    }
    // Audible window — long enough to be obviously playing (and to capture
    // in a screenshot of the now-playing bar) without being annoying.
    try? await Task.sleep(for: .milliseconds(1500))
    playback.pause()
    catalogProbeResult = """
      \(probe.verdict)

      ✅ Playback OK — ApplicationMusicPlayer confirmed `.playing` and was \
      paused after ~1.5 s.

      Phase 0 FULLY PASSED.
      """
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
    // Removing a playlist drops its membership → the set of genres that
    // shared it can change. Reanalyze (if enabled).
    runMapRebuildIfEnabled()
  }

  func addSongs(_ songIDs: [String], toAppPlaylist playlistID: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.addSongs(songIDs, to: playlistID)
    }
    runMapRebuildIfEnabled()
  }

  /// Phase 2 (`plans/catalog-playlists.md`) — Add Catalog Result to App
  /// Playlist. Two-step seam built explicitly by Phase 1:
  ///
  ///   1. `CatalogSearchService.ingestResult(withCatalogID:using:)` maps the
  ///      cached `MusicKit.Song` (from the in-memory search results) into
  ///      our SQLite `song` table via `CatalogIngestService` and hands back
  ///      the stable `song.id` (the same UUID an app-playlist FKs against).
  ///   2. `appPlaylistService.addSongs(_:to:)` — verbatim the library path's
  ///      add affordance. Catalog and library songs differ only in
  ///      `id_namespace`; app-playlist membership is namespace-agnostic.
  ///
  /// `MusicKit.Song` is intentionally never reaches this method — the
  /// controller stays MusicKit-free. The caller refers to a result by its
  /// catalog id (`Song.id.rawValue`, which the view already shows / a
  /// context-menu binding can carry), and the search service does the
  /// MusicKit-side ingest hop inside its own boundary. Same shape as the
  /// Phase-0 probe path (`firstSong` stays inside `CatalogProbeService`).
  ///
  /// Surfaces failures into `storeError` (the same place SQLite errors
  /// land) — tolerate-and-surface, never crash on a bad ingest.
  func addCatalogResult(
    catalogID: String,
    toAppPlaylist playlistID: String,
  ) async {
    do {
      guard
        let songID = try await catalogSearch.ingestResult(
          withCatalogID: catalogID,
          using: catalogIngestService,
        )
      else {
        // Result vanished (a new search came in mid-click). Quietly no-op
        // — the next click on a current result will succeed.
        return
      }
      await mutateAppPlaylist(playlistID) {
        await appPlaylistService.addSongs([songID], to: playlistID)
      }
      runMapRebuildIfEnabled()
    } catch {
      storeError = error.localizedDescription
    }
  }

  func removeTracks(at oneBasedPositions: [Int], fromAppPlaylist playlistID: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.removeTracks(at: oneBasedPositions, from: playlistID)
    }
    runMapRebuildIfEnabled()
  }

  /// Persist a reordered membership for an app playlist (the full ordered
  /// song-id list, e.g. after a drag-to-reorder in the track table).
  func setAppPlaylistTracks(_ songIDs: [String], for playlistID: String) async {
    await mutateAppPlaylist(playlistID) {
      await appPlaylistService.setTracks(songIDs, for: playlistID)
    }
    // `setTracks` is both reorder-in-place and full-membership replace; the
    // latter changes which songs (genres) are in the playlist, so reanalyze
    // (a pure reorder is a cheap no-op for the graph — acceptable, and not
    // worth distinguishing here).
    runMapRebuildIfEnabled()
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

  /// Show a synthetic genre collection in the top pane (genre-graph
  /// navigation). Records the pre-change destination, clears the sidebar
  /// selection (so no playlist row stays highlighted) WITHOUT recording a
  /// second history entry or re-running the genre-clear path, then loads
  /// the genre detail. No-op if the genre is already shown.
  func showGenre(_ genre: String) {
    guard genre != selectedGenre else { return }
    navBackStack.push(currentDestination)
    suppressNavRecording = true
    selectedPlaylistID = nil
    suppressNavRecording = false
    selectedGenre = genre
    preferences.lastSelectedPlaylistID = nil
    detailService.selectGenre(genre)
  }

  /// Navigate the top pane to a playlist from the genre graph's
  /// associated-playlists card. Ordinary playlist navigation: assigning
  /// `selectedPlaylistID` lets the existing `didSet` record history, clear
  /// the genre view, and drive the detail load. If that id is already the
  /// selection while a genre is showing, the `didSet` won't fire (value
  /// unchanged) — handle that case by clearing the genre + reselecting
  /// explicitly. No-op if the playlist isn't known.
  func openAssociatedPlaylist(id: String) {
    guard summariesByID[id] != nil else { return }
    if selectedPlaylistID == id {
      navBackStack.push(currentDestination)
      selectedGenre = nil
      handleSelectionChange()
    } else {
      selectedPlaylistID = id
    }
  }

  /// Pop the in-session Back stack and apply that destination WITHOUT
  /// recording it (the pop is the navigation, not a new forward step).
  /// LIFO. Underflow (empty stack — e.g. already at the landing) no-ops.
  func goBack() {
    guard let dest = navBackStack.pop() else { return }
    suppressNavRecording = true
    switch dest {
    case .playlist(let pid):
      selectedGenre = nil
      if selectedPlaylistID == pid {
        handleSelectionChange()
      } else {
        selectedPlaylistID = pid
      }

    case .genre(let g):
      selectedPlaylistID = nil
      selectedGenre = g
      preferences.lastSelectedPlaylistID = nil
      detailService.selectGenre(g)
    }
    suppressNavRecording = false
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

  /// Phase-0 catalog access gate (`plans/catalog-playlists.md`). Internal —
  /// views never read it; they read `catalogProbeResult`, exactly like the
  /// genre-import notice. No store dependency, so it self-initializes.
  private let catalogProbeService = CatalogProbeService()

  /// The SQLite source of truth, and everything that reads/writes it. If
  /// the store can't be opened the app still runs (auth/empty states); the
  /// failure is surfaced via `storeError`.
  @ObservationIgnored private let store: LibraryStore?

  @ObservationIgnored private let preferences = UserPreferencesStore()
  @ObservationIgnored private let legacyMigration = LegacyPreferencesMigration()

  /// While true, `selectedPlaylistID.didSet` does NOT record history and
  /// does NOT clear `selectedGenre` — the active replay (Back / launch
  /// restore) owns that state itself. `@ObservationIgnored`: it's pure
  /// control flow, never observed.
  @ObservationIgnored private var suppressNavRecording = false

  /// `@ObservationIgnored` is load-bearing: the 0.5 s monitor advances
  /// `snapshot.queueIndex` continuously and `currentStoredSongID` reads it
  /// — Observation-tracking this would invalidate `body` on every
  /// now-playing tick (the "no now-playing tick coupling" regression
  /// `plans/memory-and-laziness.md` / swiftui-pro warn against). Nothing
  /// reads it from a view body, and it must stay that way.
  @ObservationIgnored private var activePlayContext = ActivePlayContext()

  /// The destination currently shown in the top pane: a genre takes
  /// precedence (it's mutually exclusive with a playlist), else the
  /// selected playlist, else nil (the Recently-Played landing — never
  /// pushed).
  private var currentDestination: DetailDestination? {
    selectedGenre.map(DetailDestination.genre)
      ?? selectedPlaylistID.map(DetailDestination.playlist)
  }

  private static func isCancellation(_ error: Error) -> Bool {
    (error as? CocoaError)?.code == .userCancelled
  }

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

  /// A snapshot merge/revert rewrites `song` metadata in place (genres,
  /// etc.) but never touches playlist/app/history structure. Every cached
  /// `PlaylistDetail` embeds song fields, so invalidate them all and
  /// reload the on-screen surfaces; rebuild the sidebar derivations; and
  /// reanalyze the genre graph since `genre_names` changed. Mirrors the
  /// post-`runImport` reload, scoped to what a metadata-only change needs.
  private func reloadAfterSnapshotChange() async {
    await library.load()
    await appPlaylistService.load()
    await reloadFavoritesAndRecents()
    detailService.invalidateAll()
    rebuildDerivedSummaries()
    reconcileSelectionAfterImport()
    recentlyPlayed.reload()
    runMapRebuildIfEnabled()
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
    await loadAllGenres()
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
      // Self-diagnose this full/first pass immediately: a pass that tagged
      // ≥1 song clears the notice to nil; an errored pass → nil here (the
      // orange `libraryProblem` already surfaces `genreImportService
      // .lastError`); a clean 0-tagged pass → the diagnostic triad. The
      // pure classifier owns the wording/precedence.
      genreImportNotice = GenreImportSummary.notice(
        ran: true,
        failed: genreImportService.lastError != nil,
        totalAlbums: genreImportService.totalAlbumCount,
        albumsWithGenre: genreImportService.albumsWithGenreCount,
        taggedSongs: genreImportService.taggedSongCount,
      )
    }
    await library.load()
    rebuildDerivedSummaries()
    // An import changes Apple-playlist membership and, on a full/first
    // import, refreshes `song.genre_names` — both alter the genre graph,
    // and a full/first import is exactly the "new playlists added" case.
    // Reanalyze (if enabled). Runs after the genre pass so it derives from
    // the genres just (re)written, never a stale read.
    runMapRebuildIfEnabled()
    await loadAllGenres()
  }

  /// The single funnel into `GenreGraphService.analyze`, shared by the
  /// on-demand `analyzeGenreGraph()` and the auto-reanalyze hook. Reads the
  /// current analysis thresholds from `UserPreferencesStore` (the Advanced
  /// pane writes the same keys) here, so both paths always use the live
  /// settings and the preference read lives in exactly one place.
  private func runGenreAnalysis() async {
    await genreGraphService.analyze(
      maxPlaylistTracks: preferences.genreAnalysisMaxPlaylistTracks,
      maxPairsPerPlaylist: preferences.genreAnalysisMaxPairsPerPlaylist,
    )
  }

  /// Rename a genre tag `old → new` in place. This is an edit, not a
  /// navigation. If `old` is the **currently browsed** genre, the Back
  /// stack's `.genre(old)` entries are rewritten to `.genre(new)` (so
  /// Back never lands on a now-empty genre) and the genre view re-points
  /// to `new` WITHOUT pushing history; if `old` isn't the browsed genre
  /// (the genre-map right-click case), only the tags + downstream
  /// derivations change. No-op if the trimmed name is unchanged. Merge
  /// is implicit in the store (literal-tag rewrite + dedupe). The
  /// `reloadAfterGenreEdit` tail recomputes the genre map automatically.
  private func renameGenreTag(from old: String, to newName: String) async {
    guard let store else { return }
    let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !new.isEmpty, new != old else { return }
    do {
      _ = try await store.renameGenre(from: old, to: new)
      if selectedGenre == old {
        navBackStack.replacingGenre(old, with: new)
        selectedGenre = new
      }
      await reloadAfterGenreEdit()
    } catch {
      storeError = error.localizedDescription
    }
  }

  /// A genre edit rewrites `song.genre_names` in place (never playlist/app
  /// /history structure). Playlist header genre chips can change, every
  /// cached `PlaylistDetail` embeds song fields, the genre node set
  /// changed, and the distinct-genre list moved — so reload library +
  /// invalidate/re-select the on-screen detail (a genre view re-points to
  /// the possibly-renamed `selectedGenre`), rebuild sidebar derivations,
  /// refresh `allGenres`, and reanalyze the graph (its wholesale rebuild
  /// collapses a merge automatically). Mirrors the post-`runImport`
  /// reload, scoped to a metadata-only change.
  private func reloadAfterGenreEdit() async {
    await library.load()
    detailService.invalidateAll()
    if let genre = selectedGenre {
      detailService.selectGenre(genre)
    } else if let summary = selectedSummary {
      detailService.select(summary)
    }
    rebuildDerivedSummaries()
    runMapRebuildIfEnabled()
    await loadAllGenres()
  }

  /// Refresh the observable `allGenres` mirror from SQLite (the
  /// `appPlaylists`-style pattern). A read failure surfaces via
  /// `storeError`, matching the codebase, and leaves the prior list.
  private func loadAllGenres() async {
    guard let store else { return }
    do {
      allGenres = try await store.distinctGenres()
    } catch {
      storeError = error.localizedDescription
    }
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
      // Launch restore must not create phantom Back history and must not
      // touch `selectedGenre` — `navBackStack` is in-memory only and
      // starts empty each session.
      suppressNavRecording = true
      selectedPlaylistID = raw
      suppressNavRecording = false
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
        // A synthetic genre collection has a `"genre:<name>"` sentinel id
        // that must NEVER enter `recent_playlist`. Skip the recents bump
        // for it; `recordPlayStart` (song stats) still runs below —
        // playing genre songs SHOULD count.
        if !detail.isGenre {
          recordRecentlyPlayed(detail.id, source: detail.isAppOwned ? .app : .apple)
        }
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
    //
    // F1a (`plans/catalog-playlists.md` Phase-3 followup): we always route
    // through the resolution-aware overload now. For a single-chunk
    // resolution (library-only OR catalog-only — the common case) this is
    // identical to the prior `play(songs:startingAt:)` call: same player
    // queue, same confirm-poll, no swap state. The only behavior change is
    // in the **mixed** case, where the overload splits the queue at
    // namespace boundaries and the 0.5 s monitor tick swaps chunks
    // sequentially (the workaround for `MPMusicPlayerControllerErrorDomain`
    // error 6 on a mixed `ApplicationMusicPlayer.Queue`).
    return await playback.play(
      resolution: resolution,
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
