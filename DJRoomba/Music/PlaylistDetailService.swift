import MusicKit
import Observation

/// Lazily loads a selected playlist's tracks, normalizes to `TrackRow`, and
/// caches the result in memory keyed by playlist id. Cache is invalidated on
/// manual refresh. Selection changes cancel any in-flight load.
@MainActor
@Observable
final class PlaylistDetailService {
    private(set) var detail: PlaylistDetail?
    private(set) var isLoading = false
    private(set) var loadError: String?

    @ObservationIgnored private var cache: [MusicItemID: PlaylistDetail] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private let maxTrackBatches = 5000

    func select(_ summary: PlaylistSummary) {
        loadTask?.cancel()

        if let cached = cache[summary.id] {
            detail = cached
            loadError = nil
            isLoading = false
            return
        }

        detail = nil
        loadError = nil
        loadTask = Task { [weak self] in
            await self?.load(summary)
        }
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

    private func load(_ summary: PlaylistSummary) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            let detailed = try await summary.playlist.with([.tracks])
            if Task.isCancelled { return }

            var allTracks: [Track] = []
            var batch: MusicItemCollection<Track>? = detailed.tracks
            var batchCount = 0
            while let current = batch {
                allTracks.append(contentsOf: current)
                batchCount += 1
                if current.hasNextBatch, batchCount < maxTrackBatches, !Task.isCancelled {
                    batch = try await current.nextBatch()
                } else {
                    batch = nil
                }
            }
            if Task.isCancelled { return }

            let result = PlaylistDetail(
                id: detailed.id,
                name: detailed.name,
                artwork: detailed.artwork,
                description: nil,
                isEditable: nil,
                tracks: Self.rows(from: allTracks),
                playlist: detailed
            )
            cache[summary.id] = result
            detail = result
        } catch {
            if Task.isCancelled { return }
            loadError = error.localizedDescription
        }
    }

    private static func rows(from tracks: [Track]) -> [TrackRow] {
        tracks.enumerated().map { index, track in
            TrackRow(
                id: "\(index + 1)-\(track.id.rawValue)",
                position: index + 1,
                musicItemID: track.id,
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                duration: track.duration,
                artwork: track.artwork,
                isExplicit: track.contentRating == .explicit,
                track: track
            )
        }
    }
}
