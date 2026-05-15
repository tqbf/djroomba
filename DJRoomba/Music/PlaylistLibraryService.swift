import MusicKit
import Observation

/// Fetches the user's MusicKit *library* playlists (not catalog), pages
/// through all batches, and normalizes to `PlaylistSummary`. Track contents
/// are intentionally not fetched here — that is lazy per selection.
@MainActor
@Observable
final class PlaylistLibraryService {
    private(set) var summaries: [PlaylistSummary] = []
    private(set) var isLoading = false
    private(set) var loadError: String?

    /// Hard cap on pagination loops to avoid pathological infinite paging.
    private let maxBatches = 1000

    func load() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            var request = MusicLibraryRequest<Playlist>()
            request.limit = 100
            let response = try await request.response()

            var collected: [Playlist] = []
            var batch: MusicItemCollection<Playlist>? = response.items
            var batchCount = 0
            while let current = batch {
                collected.append(contentsOf: current)
                batchCount += 1
                if current.hasNextBatch, batchCount < maxBatches {
                    batch = try await current.nextBatch()
                } else {
                    batch = nil
                }
            }

            summaries = collected
                .map(Self.summary(from:))
                .sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
        } catch {
            loadError = error.localizedDescription
            summaries = []
        }
    }

    private static func summary(from playlist: Playlist) -> PlaylistSummary {
        PlaylistSummary(
            id: playlist.id,
            name: playlist.name,
            artwork: playlist.artwork,
            // Not loaded by a library request; surfaced lazily in detail.
            trackCount: nil,
            // MusicKit doesn't cleanly expose editability for library
            // playlists on macOS 14; left nil until proven (see plans).
            isEditable: nil,
            source: .libraryUserPlaylist,
            isFavorite: false,
            playlist: playlist
        )
    }
}
