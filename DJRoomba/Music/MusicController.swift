import MusicKit
import Observation

/// Top-level coordinator. Owns the service instances and the app-level state
/// the UI binds to. Coordinates startup; delegates fetching/playback to
/// services (it is a coordinator, not a god object).
@MainActor
@Observable
final class MusicController {
    let authorization = MusicAuthorizationService()
    let subscription = MusicSubscriptionService()
    let library = PlaylistLibraryService()
    let detailService = PlaylistDetailService()
    let playback = PlaybackService()

    @ObservationIgnored private let preferences = UserPreferencesStore()
    @ObservationIgnored private let favoritesStore = FavoritesStore()
    @ObservationIgnored private let recentsStore = RecentlyPlayedStore()

    /// Observable mirrors of the persisted app state (the stores can't be
    /// `@Observable` themselves).
    private(set) var favoriteIDs: Set<String> = []
    private(set) var recentIDs: [String] = []

    /// Bumped by the ⌘L / ⌘1 commands; the sidebar observes this to take
    /// keyboard focus (commands are app-scoped, so this bridges to the view).
    private(set) var focusSidebarRequest = 0

    func requestSidebarFocus() {
        focusSidebarRequest &+= 1
    }

    /// Sidebar selection. App-local state — drives lazy detail load and is
    /// persisted so it survives relaunch (if the playlist still exists).
    var selectedPlaylistID: MusicItemID? {
        didSet {
            guard oldValue != selectedPlaylistID else { return }
            handleSelectionChange()
        }
    }

    // MARK: - Startup

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

    private func startAuthorizedSession() async {
        subscription.start()
        playback.startMonitoring()
        favoriteIDs = favoritesStore.load()
        recentIDs = recentsStore.load()
        await library.load()
        restoreSelection()
    }

    func refreshLibrary() async {
        detailService.invalidate()
        await library.load()
        if let id = selectedPlaylistID,
           !library.summaries.contains(where: { $0.id == id }) {
            // Playlist disappeared between refreshes — clear silently.
            selectedPlaylistID = nil
        } else if let summary = selectedSummary {
            // Re-fetch fresh detail for the still-selected playlist.
            detailService.select(summary)
        }
    }

    // MARK: - Selection

    var selectedSummary: PlaylistSummary? {
        guard let id = selectedPlaylistID else { return nil }
        return library.summaries.first { $0.id == id }
    }

    private func handleSelectionChange() {
        if let summary = selectedSummary {
            preferences.lastSelectedPlaylistID = summary.id.rawValue
            detailService.select(summary)
        } else {
            preferences.lastSelectedPlaylistID = nil
            detailService.clear()
        }
    }

    private func restoreSelection() {
        guard let raw = preferences.lastSelectedPlaylistID else { return }
        if library.summaries.contains(where: { $0.id.rawValue == raw }) {
            selectedPlaylistID = MusicItemID(raw)
        } else {
            preferences.lastSelectedPlaylistID = nil
        }
    }

    // MARK: - Favorites & recents (app state)

    func isFavorite(_ summary: PlaylistSummary) -> Bool {
        favoriteIDs.contains(summary.id.rawValue)
    }

    func toggleFavorite(_ summary: PlaylistSummary) {
        let key = summary.id.rawValue
        if favoriteIDs.contains(key) {
            favoriteIDs.remove(key)
        } else {
            favoriteIDs.insert(key)
        }
        favoritesStore.save(favoriteIDs)
    }

    private func recordRecentlyPlayed(_ id: MusicItemID) {
        recentIDs = recentsStore.record(id.rawValue, into: recentIDs)
    }

    /// Library playlists sorted by name (the service already sorts; this is
    /// the source the sidebar sections derive from).
    var libraryPlaylists: [PlaylistSummary] {
        library.summaries
    }

    var favoritePlaylists: [PlaylistSummary] {
        library.summaries.filter { favoriteIDs.contains($0.id.rawValue) }
    }

    /// Recently played, in recency order, limited to playlists still present.
    var recentPlaylists: [PlaylistSummary] {
        recentIDs.compactMap { raw in
            library.summaries.first { $0.id.rawValue == raw }
        }
    }

    // MARK: - Playback capability

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

    // MARK: - Playback intents

    func playSelectedPlaylist() async {
        guard let detail = detailService.detail, !detail.isEmpty else { return }
        recordRecentlyPlayed(detail.id)
        await playback.play(playlist: detail)
    }

    func play(_ row: TrackRow) async {
        guard let detail = detailService.detail else { return }
        recordRecentlyPlayed(detail.id)
        await playback.play(playlist: detail, startingAt: row)
    }

    func togglePlayPause() async { await playback.togglePlayPause() }
    func skipNext() async { await playback.skipNext() }
    func skipPrevious() async { await playback.skipPrevious() }

    // MARK: - Extension boundary (Milestone 3 scaffold)

    var musicContext: MusicContext {
        MusicContext(
            selectedPlaylistID: selectedPlaylistID,
            selectedSongID: nil,
            nowPlayingSongID: playback.snapshot.nowPlayingItemID,
            queuePlaylistID: playback.snapshot.playlistContextID,
            playbackStatus: playback.snapshot.status
        )
    }

    func handle(_ command: MusicCommand) async {
        switch command {
        case .playPlaylist(let id):
            if library.summaries.contains(where: { $0.id == id }) {
                selectedPlaylistID = id
                await playSelectedPlaylist()
            }
        case .playTrack(let trackID, let playlistID):
            if let playlistID { selectedPlaylistID = playlistID }
            if let row = detailService.detail?.tracks.first(
                where: { $0.musicItemID == trackID }
            ) {
                await play(row)
            }
        case .pause, .resume:
            await togglePlayPause()
        case .skipNext:
            await skipNext()
        case .skipPrevious:
            await skipPrevious()
        }
    }
}
