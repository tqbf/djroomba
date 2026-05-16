import Foundation
import MusicKit
import Observation

/// Thin wrapper over `ApplicationMusicPlayer.shared`. Deliberately small and
/// debuggable (per spec): MusicKit owns the real queue/playback state; this
/// exposes a derived `PlayerStateSnapshot` the now-playing bar binds to.
///
/// Local-first pivot: this no longer takes app models that carry live
/// MusicKit objects. `PlaybackResolver` re-resolves stored ids to playable
/// `MusicKit.Song`s and hands them here; the player code itself is unchanged
/// from M1 (queue construction + transport).
///
/// The snapshot is refreshed on a light async tick. MusicKit's player state
/// isn't trivially Observation-bridgeable and we need a moving elapsed time;
/// a ~0.5s structured-concurrency loop is the simple, honest choice here
/// (no GCD, no Combine) over a heavier abstraction.
@MainActor
@Observable
final class PlaybackService {

  // MARK: Internal

  private(set) var snapshot = PlayerStateSnapshot()
  private(set) var lastError: String?

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

  /// Play a resolved set of `MusicKit.Song`s (already re-fetched by
  /// `PlaybackResolver`), preserving playlist context, optionally starting
  /// at a specific song. `playlistContextID` is the app/Apple playlist id.
  ///
  /// Returns `true` once the player has **actually entered the playing
  /// state** (confirmed by polling `player.state.playbackStatus`, not the
  /// 0.5 s-lagged snapshot) so the caller can record the play against the
  /// real start signal — the Phase-3 follow-up bug fix. `false` means the
  /// queue was set but playback did not confirm within the bounded wait
  /// (error, or interrupted) — the play is then not recorded.
  @discardableResult
  func play(
    songs: [MusicKit.Song],
    startingAt start: MusicKit.Song?,
    playlistContextID: String?,
  ) async -> Bool {
    self.playlistContextID = playlistContextID
    return await setQueueAndPlay(songs: songs, startingAt: start)
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

  /// The **live** playhead, read straight off `ApplicationMusicPlayer`
  /// at the call instant: `player.playbackTime` and the current entry's
  /// song/video `duration`. Synchronous and side-effect-free.
  ///
  /// Why not `snapshot`: the snapshot is only refreshed on the ~0.5 s
  /// monitor tick, so near the `duration / 2` boundary it can be up to
  /// half a second stale and **misclassify** a skip vs. a replay (a press
  /// just before the half mark could read as just after, or vice versa).
  /// The Phase-3 decision (`PlaybackResolver.skipKind`) hinges on that
  /// exact boundary, so it must see the playhead as it is *now*, not as
  /// the last poll saw it. Uses the same `@MainActor` /
  /// `nonisolated(unsafe)` access to the shared player as
  /// `refreshSnapshot()`; `duration` is `nil` when there is no current
  /// entry or its item carries no duration (then `skipKind` → `.none`).
  ///
  /// SIGNED GATE (still pending — user): only a real signed run can
  /// confirm that reading this *before* the transport call actually beats
  /// MusicKit mutating `queue.currentEntry`, and that the returned
  /// `elapsed` is accurate to the half-second the boundary needs. The
  /// decision itself is pure and fully unit-tested; this read is the part
  /// the live gate must verify.
  func livePlayhead() -> (elapsed: TimeInterval, duration: TimeInterval?) {
    let elapsed = player.playbackTime
    guard let entry = player.queue.currentEntry else {
      return (elapsed, nil)
    }
    return (elapsed, Self.itemDuration(of: entry))
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

  // MARK: Private

  // MusicKit's ApplicationMusicPlayer is not Sendable-audited and its async
  // transport methods are `nonisolated`, so calling them from this
  // @MainActor service would "send" a non-Sendable value across actors
  // under Swift 6. All our access is in fact serialized on the MainActor
  // (this service + its monitor task), so opting the singleton out of
  // isolation checking is sound. See plans/musickit-notes.md.
  @ObservationIgnored nonisolated(unsafe) private let player = ApplicationMusicPlayer.shared
  @ObservationIgnored private var monitorTask: Task<Void, Never>?
  @ObservationIgnored private var playlistContextID: String?

  /// The playable `duration` of a queue entry's item (song or music
  /// video), or `nil` when it has none / is an unknown kind. The single
  /// place this 4-arm `entry.item` switch lives — `livePlayhead()` (the
  /// Phase-3 skip/replay decision) and `refreshSnapshot()` (the
  /// now-playing bar) both read duration the same way, so they can't drift.
  private static func itemDuration(
    of entry: ApplicationMusicPlayer.Queue.Entry
  ) -> TimeInterval? {
    switch entry.item {
    case .song(let song): song.duration
    case .musicVideo(let video): video.duration
    case .none: nil
    @unknown default: nil
    }
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

  private func setQueueAndPlay(
    songs: [MusicKit.Song],
    startingAt start: MusicKit.Song?,
  ) async -> Bool {
    guard !songs.isEmpty else {
      lastError = "This playlist has no playable tracks."
      return false
    }
    var started = false
    do {
      if let start {
        player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: start)
      } else {
        player.queue = ApplicationMusicPlayer.Queue(for: songs)
      }
      try await player.play()
      lastError = nil
      started = await confirmPlaybackStarted()

      // Phase 5 auto-start polish (carried Phase-3/4 follow-up):
      // on macOS, `player.play()` can resolve while the queue is still
      // loading and the engine settles to `.paused` — the symptom was
      // the now-playing bar showing ▶ at 0:05 until the transport was
      // pressed. One bounded re-issue of `play()` reliably kicks it
      // into `.playing` without a manual nudge. Idempotent (a player
      // already playing stays playing); structured concurrency only.
      if !started, !Task.isCancelled {
        try await player.play()
        started = await confirmPlaybackStarted()
      }
    } catch {
      lastError = error.localizedDescription
    }
    refreshSnapshot()
    return started
  }

  /// `player.play()` resolving does not guarantee the engine has reached
  /// `.playing` yet (the queue may still be loading), and the now-playing
  /// snapshot is only refreshed on a ~0.5 s poll — reading it right after
  /// `play()` (the old bug) saw a stale `.stopped` so plays never recorded
  /// *and* the UI sat on ▶ until the transport was pressed. Poll the
  /// player's *own* live status on a short bounded loop, and the instant it
  /// reports `.playing` publish a fresh snapshot so the now-playing bar
  /// flips to "playing" immediately (no waiting for the next 0.5 s tick — the
  /// Phase-5 auto-start immediacy fix). Structured concurrency only; never
  /// `Task.sleep(nanoseconds:)`.
  private func confirmPlaybackStarted(
    timeout: Duration = .milliseconds(2500),
    poll: Duration = .milliseconds(50),
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if player.state.playbackStatus == .playing {
        // Reflect the real start the moment it happens, not on the
        // next lagged poll — the UI must not need a transport nudge.
        refreshSnapshot()
        return true
      }
      // .stopped / .interrupted right after play() usually just means
      // the queue is still loading; keep waiting until the deadline
      // rather than failing on the first poll.
      try? await Task.sleep(for: poll)
    }
    let confirmed = player.state.playbackStatus == .playing
    if confirmed { refreshSnapshot() }
    return confirmed
  }

  private func refreshSnapshot() {
    var snap = PlayerStateSnapshot()
    snap.status = Self.map(player.state.playbackStatus)
    snap.elapsed = player.playbackTime
    snap.playlistContextID = playlistContextID

    if let entry = player.queue.currentEntry {
      snap.title = entry.title
      snap.artist = entry.subtitle
      // Structural queue position: this entry's ordinal in `queue.entries`,
      // matched by the queue `Entry`'s OWN id (the queue's per-position
      // handle MusicKit mints, NOT the song's `MusicItemID` — attribution
      // never keys on an Apple content id). nil if not found; callers fall
      // back to the start-index seed. (Signed-gate fallback documented in
      // plans/play-statistics.md if this proves unreliable under real
      // auto-advance/skip.)
      snap.queueIndex = player.queue.entries
        .firstIndex { $0.id == entry.id }
      snap.duration = Self.itemDuration(of: entry)
      switch entry.item {
      case .song(let song):
        snap.nowPlayingItemID = song.id.rawValue

      case .musicVideo(let video):
        snap.nowPlayingItemID = video.id.rawValue

      case .none:
        break

      @unknown default:
        break
      }
    }

    snapshot = snap
  }

}
