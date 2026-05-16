import Foundation
import Observation

/// Reads the sidebar's playlist summaries from the local SQLite store (NOT
/// live MusicKit — local-first pivot). Replaces M1's `PlaylistLibraryService`
/// as the sidebar's source of truth; MusicKit reads now happen only in
/// `ImportService`.
///
/// Concurrency: `@MainActor @Observable` (the view binds to it). It `await`s
/// the `Sendable`, off-main `LibraryStore` and republishes the results as
/// observable state — the documented controller↔store boundary.
@MainActor
@Observable
final class LibraryReadService {
    private(set) var summaries: [PlaylistSummary] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    @ObservationIgnored private let store: LibraryStore

    init(store: LibraryStore) {
        self.store = store
    }

    /// Reload the imported Apple playlists from SQLite. Favorites are merged
    /// by the controller (it owns the favorite state); summaries here carry
    /// `isFavorite = false` and the controller overlays it.
    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let playlists = try await store.applePlaylists()
            summaries = playlists
                .map { playlist in
                    PlaylistSummary(
                        id: playlist.id,
                        name: playlist.name,
                        // Sidebar row shows a count only when non-nil; M1
                        // never set one, so keep nil to stay pixel-equivalent
                        // with the Phase-1-verified look (count is a Phase 4
                        // surfacing decision, not a Phase 3 visual change).
                        trackCount: nil,
                        // MusicKit doesn't cleanly expose editability for
                        // library playlists on macOS 14 (carried forward).
                        isEditable: nil,
                        source: .libraryUserPlaylist,
                        isFavorite: false
                        // artwork is re-resolved by id (ArtworkProvider) — a
                        // computed `artworkRef` on PlaylistSummary, no stored
                        // URL (D2).
                    )
                }
                .sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        } catch {
            loadError = error.localizedDescription
            summaries = []
        }
    }
}
