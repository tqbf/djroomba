import MusicKit
import Observation

/// Thin wrapper over `ApplicationMusicPlayer.shared`. Deliberately small and
/// debuggable (per spec): MusicKit owns the real queue/playback state; this
/// exposes a derived `PlayerStateSnapshot` the now-playing bar binds to.
///
/// The snapshot is refreshed on a light async tick. MusicKit's player state
/// isn't trivially Observation-bridgeable and we need a moving elapsed time;
/// a ~0.5s structured-concurrency loop is the simple, honest choice here
/// (no GCD, no Combine) over a heavier abstraction.
@MainActor
@Observable
final class PlaybackService {
    private(set) var snapshot = PlayerStateSnapshot()
    private(set) var lastError: String?

    // MusicKit's ApplicationMusicPlayer is not Sendable-audited and its async
    // transport methods are `nonisolated`, so calling them from this
    // @MainActor service would "send" a non-Sendable value across actors
    // under Swift 6. All our access is in fact serialized on the MainActor
    // (this service + its monitor task), so opting the singleton out of
    // isolation checking is sound. See plans/musickit-notes.md.
    @ObservationIgnored nonisolated(unsafe) private let player = ApplicationMusicPlayer.shared
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var playlistContextID: MusicItemID?

    func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshSnapshot()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - Intents

    func play(playlist: PlaylistDetail) async {
        playlistContextID = playlist.id
        await setQueueAndPlay(tracks: playlist.tracks.map(\.track), startingAt: nil)
    }

    func play(playlist: PlaylistDetail, startingAt row: TrackRow) async {
        playlistContextID = playlist.id
        await setQueueAndPlay(tracks: playlist.tracks.map(\.track), startingAt: row.track)
    }

    func togglePlayPause() async {
        do {
            if player.state.playbackStatus == .playing {
                player.pause()
            } else {
                try await player.play()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshSnapshot()
    }

    func skipNext() async {
        do {
            try await player.skipToNextEntry()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshSnapshot()
    }

    func skipPrevious() async {
        do {
            try await player.skipToPreviousEntry()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshSnapshot()
    }

    // MARK: - Internals

    private func setQueueAndPlay(tracks: [Track], startingAt start: Track?) async {
        guard !tracks.isEmpty else {
            lastError = "This playlist has no playable tracks."
            return
        }
        do {
            if let start {
                player.queue = ApplicationMusicPlayer.Queue(for: tracks, startingAt: start)
            } else {
                player.queue = ApplicationMusicPlayer.Queue(for: tracks)
            }
            try await player.play()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshSnapshot()
    }

    private func refreshSnapshot() {
        var snap = PlayerStateSnapshot()
        snap.status = Self.map(player.state.playbackStatus)
        snap.elapsed = player.playbackTime
        snap.playlistContextID = playlistContextID

        if let entry = player.queue.currentEntry {
            snap.title = entry.title
            snap.artist = entry.subtitle
            snap.artwork = entry.artwork
            switch entry.item {
            case .song(let song):
                snap.duration = song.duration
                snap.nowPlayingItemID = song.id
            case .musicVideo(let video):
                snap.duration = video.duration
                snap.nowPlayingItemID = video.id
            case .none:
                break
            @unknown default:
                break
            }
        }

        snapshot = snap
    }

    private static func map(
        _ status: MusicPlayer.PlaybackStatus
    ) -> PlayerStateSnapshot.Status {
        switch status {
        case .playing: .playing
        case .paused: .paused
        case .stopped: .stopped
        case .interrupted: .interrupted
        case .seekingForward: .seekingForward
        case .seekingBackward: .seekingBackward
        @unknown default: .stopped
        }
    }
}
