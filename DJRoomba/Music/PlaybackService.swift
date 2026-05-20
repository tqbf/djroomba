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

  /// Invoked at the **end** of every `refreshSnapshot()` — i.e. once per
  /// ~0.5 s monitor tick *and* after every transport/confirm refresh —
  /// after `snapshot` is assigned, so the callback observes the fresh
  /// `queueIndex`. `MusicController` sets it once (where `startMonitoring()`
  /// is called) to its Phase-4 auto-advance detector. `@ObservationIgnored`
  /// and a plain closure on purpose: this is **not** Observation-tracked
  /// state, so wiring the transition detector here does **not** couple any
  /// view `body` to the now-playing tick (the "no now-playing tick
  /// coupling" regression `plans/memory-and-laziness.md` / swiftui-pro warn
  /// against). The closure must be cheap and return immediately — it does
  /// no I/O; the detector fires its SQLite write off-main in a `Task`.
  @ObservationIgnored var onSnapshotRefresh: (@MainActor () -> Void)?

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
  ///
  /// F1a path-of-record: this method is now a single-chunk wrapper around
  /// `play(resolution:playlistContextID:)` — `playRecentlyPlayed`'s and the
  /// Phase-0 catalog probe's "play these songs" shape stays unchanged, and
  /// every app-playlist play (which can be mixed-namespace) routes through
  /// the sequential-sub-queue path via the resolution overload. The
  /// pending-chunk state is reset here so a one-shot single-queue play
  /// never inherits stale F1a chunk state from a prior mixed play.
  @discardableResult
  func play(
    songs: [MusicKit.Song],
    startingAt start: MusicKit.Song?,
    playlistContextID: String?,
    namespace: Song.IDNamespace,
  ) async -> Bool {
    self.playlistContextID = playlistContextID
    pendingChunks = []
    currentChunkIndex = 0
    chunkBoundaries = songs.isEmpty ? [] : [0]
    chunkNamespaces = songs.isEmpty ? [] : [namespace]
    singleShotNamespace = songs.isEmpty ? nil : namespace
    return await setQueueAndPlay(songs: songs, startingAt: start)
  }

  /// F1a (`plans/catalog-playlists.md` Phase-3 followup) — play a resolved
  /// queue that may interleave library and catalog songs, as a sequence of
  /// **homogeneous-namespace sub-queues** played one chunk at a time.
  /// `ApplicationMusicPlayer.Queue` deterministically rejects a mixed
  /// library+catalog `Song` array on macOS with
  /// `MPMusicPlayerControllerErrorDomain` error 6 (confirmed live in the
  /// Phase-3 finding; see PROGRESS 2026-05-20 + APPLE-TOUCHPOINTS
  /// gotcha #10); this method splits the queue at every namespace
  /// boundary, plays the start chunk via the unchanged
  /// `setQueueAndPlay` path, and the 0.5 s monitor tick detects end-of-
  /// chunk + swaps to the next. Costs a brief silence at each transition;
  /// preserves the user's playlist order.
  ///
  /// Single-chunk resolutions (library-only OR catalog-only — the common
  /// case) collapse to exactly the existing single-queue path: one chunk,
  /// no swap detection ever fires (the pending list is empty). The mixed
  /// case is the only one that ever swaps.
  ///
  /// Returns `true` once the **start chunk** has confirmed `.playing` (same
  /// signal the single-queue path returns). Subsequent chunk swaps tolerate
  /// their own errors via `lastError` — by the time a swap is needed the
  /// caller has already recorded the started play; the return value is
  /// load-bearing only for the initial start.
  @discardableResult
  func play(
    resolution: PlaybackResolver.Resolution,
    playlistContextID: String?,
  ) async -> Bool {
    self.playlistContextID = playlistContextID
    let boundaries = resolution.chunkBoundaries
    chunkBoundaries = boundaries
    chunkNamespaces = resolution.chunkNamespaces
    singleShotNamespace = nil

    // Single-chunk fast path: identical behavior to the existing
    // single-queue path (zero pending chunks, no swap state to clear).
    if boundaries.count <= 1 {
      pendingChunks = []
      currentChunkIndex = 0
      return await setQueueAndPlay(
        songs: resolution.songs,
        startingAt: resolution.startSong,
      )
    }

    // Build per-chunk views into `resolution.songs` / `playContext`.
    let chunks = buildChunks(
      songs: resolution.songs,
      playContext: resolution.playContext,
      chunkBoundaries: boundaries,
      chunkNamespaces: resolution.chunkNamespaces,
    )

    // Locate the start chunk via the start song's global index in
    // `playContext` (the same canonical lookup `MusicController` uses).
    // Fall back to chunk 0 if no start specified or not found.
    let startGlobalIndex = PlaybackResolver.startIndex(
      in: resolution.playContext,
      startSongID: resolution.startSongID,
    )
    let startChunk = Self.chunkContaining(globalIndex: startGlobalIndex, in: boundaries)
    pendingChunks = chunks
    currentChunkIndex = startChunk

    // Chunk-local start: pass `startSong` only if it lives in the start
    // chunk's songs (identity by `Song.id`). Otherwise nil → "play from the
    // top of this chunk" — identical to a no-startingAt single-queue play.
    let chunkSongs = chunks[startChunk].songs
    let startWithinChunk: MusicKit.Song? = {
      guard let s = resolution.startSong else { return nil }
      return chunkSongs.contains(where: { $0.id == s.id }) ? s : nil
    }()

    return await setQueueAndPlay(songs: chunkSongs, startingAt: startWithinChunk)
  }

  /// Idempotent pause — calls `ApplicationMusicPlayer.shared.pause()`
  /// directly rather than the play/pause toggle, so a caller that knows it
  /// wants the player paused (the Phase-0 catalog probe playback half: play
  /// briefly, then pause) doesn't accidentally toggle a not-yet-playing
  /// engine back on. Refreshes the snapshot so the now-playing bar reflects
  /// the new state without waiting for the next ~0.5 s monitor tick.
  func pause() {
    player.pause()
    refreshSnapshot()
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
    // F1a special-case (empirical, 2026-05-20 live test): at the tail of a
    // chunk, `player.skipToNextEntry()` does NOT empty the queue on macOS —
    // it wraps to the first entry of the same chunk (the queue loops
    // within itself). So the "currentEntry == nil → swap" detector
    // designed for natural end-of-chunk does not fire on a manual Next
    // press at the tail. Detect that case explicitly and perform the
    // chunk swap instead of `skipToNextEntry`. The natural-end-of-song
    // path (auto-advance through to the last entry's natural completion)
    // is unchanged — once the queue actually empties, the monitor tick
    // takes the swap.
    if shouldSwapChunkOnSkipNext() {
      await performChunkSwapForSkipNext()
      return
    }
    do {
      try await player.skipToNextEntry()
      lastError = nil
    } catch {
      lastError = error.localizedDescription
    }
    refreshSnapshot()
  }

  /// True iff the player is on the LAST entry of the current chunk AND a
  /// next chunk is pending. Pure read-only check — no I/O.
  private func shouldSwapChunkOnSkipNext() -> Bool {
    guard !pendingChunks.isEmpty else { return false }
    guard currentChunkIndex + 1 < pendingChunks.count else { return false }
    guard let entry = player.queue.currentEntry else { return false }
    guard let lastEntry = player.queue.entries.last else { return false }
    return entry.id == lastEntry.id
  }

  /// User-initiated chunk swap (Next at chunk tail). Same shape as the
  /// auto-detection swap (`advanceToNextChunkIfNeeded`) but always runs;
  /// the re-entrancy gate still prevents an overlapping auto-swap from
  /// double-firing.
  private func performChunkSwapForSkipNext() async {
    guard !chunkSwapInFlight else { return }
    let nextIndex = currentChunkIndex + 1
    guard pendingChunks.indices.contains(nextIndex) else { return }
    chunkSwapInFlight = true
    defer { chunkSwapInFlight = false }
    await performChunkSwap(
      toChunkIndex: nextIndex,
      songs: pendingChunks[nextIndex].songs,
    )
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

  // F1a sequential-sub-queue state.
  //
  // **Why `@ObservationIgnored`:** these are not view-bound state — the
  // only thing the now-playing bar reads is `snapshot`, which already
  // computes the **global** queueIndex below via `globalQueueIndex(...)`,
  // so coupling a view body to a chunk swap is the wrong shape. swiftui-pro
  // / `plans/memory-and-laziness.md`: never let the 0.5 s tick invalidate
  // `body`.
  //
  // **Why a struct array instead of three parallel arrays:** the per-chunk
  // tuple (songs, playContext) is set together, swapped together, and
  // never mutated piecewise — keeping them in one type prevents the "two
  // of three arrays got updated" bug class.
  /// Per-chunk view into a `Resolution` for sequential playback. `songs`
  /// is what the swapped `ApplicationMusicPlayer.Queue` gets; `playContext`
  /// is the parallel stored `song.id` slice (informational — the global
  /// `playContext` lives in `MusicController.activePlayContext` and is the
  /// authoritative attribution source).
  private struct PendingChunk {
    var songs: [MusicKit.Song]
    var playContext: [String?]
    /// Homogeneous-namespace tag for the chunk (F1a). Drives
    /// `PlayerStateSnapshot.nowPlayingNamespace` so the now-playing
    /// thumbnail re-resolves a catalog id via `ArtworkProvider`'s catalog
    /// branch instead of mis-routing it through the library branch
    /// (Phase 4 of `plans/catalog-playlists.md`).
    var namespace: Song.IDNamespace
  }

  /// Empty unless the active resolution actually had ≥2 chunks. The
  /// `play(songs:startingAt:playlistContextID:)` single-shape overload
  /// clears this on entry so a one-shot play can never inherit stale
  /// chunk state from a prior mixed playlist.
  @ObservationIgnored private var pendingChunks = [PendingChunk]()

  /// Index into `pendingChunks` of the currently-playing chunk. Drives the
  /// global-offset translation in `refreshSnapshot()` (so `snapshot
  /// .queueIndex` is GLOBAL across the whole resolution, not local to the
  /// current `player.queue`).
  @ObservationIgnored private var currentChunkIndex = 0

  /// The full resolution's chunk-start indices (mirrored from
  /// `Resolution.chunkBoundaries`). Used to translate
  /// `player.queue.entries`-local indices to GLOBAL queue indices so the
  /// Phase-4 `advanceToRecord` detector keeps observing a monotonic global
  /// index across chunk swaps. `[]` ⇒ no resolution loaded; `[0]` ⇒
  /// single-chunk (the unchanged single-queue path).
  @ObservationIgnored private var chunkBoundaries = [Int]()

  /// Per-chunk namespace tags, parallel to `chunkBoundaries` (mirrored
  /// from `Resolution.chunkNamespaces`). Phase 4: read by `refreshSnapshot`
  /// to stamp the now-playing snapshot with the active chunk's namespace
  /// so the now-playing thumbnail re-resolves catalog ids through the
  /// catalog branch of `ArtworkProvider`. Same emptiness semantics as
  /// `chunkBoundaries`: `[]` ⇒ no resolution loaded; one entry per chunk
  /// otherwise.
  @ObservationIgnored private var chunkNamespaces = [Song.IDNamespace]()

  /// Re-entrancy gate for the end-of-chunk swap. Set true while a swap is
  /// in flight; the 0.5 s monitor tick that runs **inside** that window
  /// must not kick off a second swap. Cleared in the swap's `defer`.
  /// MainActor-serialized state, set on the MainActor, read on the
  /// MainActor — no actor hop, no lock.
  @ObservationIgnored private var chunkSwapInFlight = false

  /// Namespace for the single-shot `play(songs:startingAt:)` path
  /// (Phase 4 of `plans/catalog-playlists.md`). Set on entry by the
  /// caller (the catalog probe → `.catalog`, recently-played → `.library`).
  /// When a resolution is loaded (multi- or single-chunk via
  /// `play(resolution:)`), `refreshSnapshot()` reads the active chunk's
  /// namespace directly from `pendingChunks` / `Resolution.chunkNamespaces`
  /// instead and this field becomes a fallback only.
  @ObservationIgnored private var singleShotNamespace: Song.IDNamespace?

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

  /// F1a — slice the full resolution into per-chunk views.
  private func buildChunks(
    songs: [MusicKit.Song],
    playContext: [String?],
    chunkBoundaries: [Int],
    chunkNamespaces: [Song.IDNamespace],
  ) -> [PendingChunk] {
    guard !chunkBoundaries.isEmpty else { return [] }
    var chunks = [PendingChunk]()
    chunks.reserveCapacity(chunkBoundaries.count)
    for k in chunkBoundaries.indices {
      let start = chunkBoundaries[k]
      let end = k + 1 < chunkBoundaries.count ? chunkBoundaries[k + 1] : songs.count
      // Parallel by construction (`reassemble` emits one namespace per
      // chunk in the same loop iteration that pushes the boundary). Fall
      // back to `.library` defensively if drift ever introduced an
      // asymmetric pair — a `.library` mis-tag on a catalog id resolves
      // to nil → placeholder rather than mis-rendering library art.
      let ns = chunkNamespaces.indices.contains(k) ? chunkNamespaces[k] : .library
      chunks.append(
        PendingChunk(
          songs: Array(songs[start..<end]),
          playContext: Array(playContext[start..<end]),
          namespace: ns,
        )
      )
    }
    return chunks
  }

  /// F1a — locate which chunk a **global** queue index falls into. The
  /// monotone search is fine for F1a's chunk counts (almost always 1, rarely
  /// >5); a binary search would be premature here.
  private static func chunkContaining(globalIndex: Int, in boundaries: [Int]) -> Int {
    guard !boundaries.isEmpty else { return 0 }
    var chosen = 0
    for k in boundaries.indices where boundaries[k] <= globalIndex {
      chosen = k
    }
    return chosen
  }

  /// F1a — kick off (asynchronously) a swap to the next pending chunk **if**
  /// the current chunk has ended (player has no current entry) and a next
  /// chunk exists. Called from the 0.5 s monitor tick (synchronously, after
  /// `snapshot` is committed). The actual transport work runs in a
  /// fire-and-forget `Task` (the tick must stay synchronous), and a
  /// re-entrancy gate (`chunkSwapInFlight`) prevents the next tick from
  /// kicking off a second swap while the first is still mid-flight.
  ///
  /// **Distinguishing user-paused from queue-ended.** A user pause keeps
  /// `player.queue.currentEntry != nil` (the entry is still loaded; the
  /// engine is just paused). A queue that ran out clears `currentEntry` to
  /// `nil`. So `currentEntry == nil` is the load-bearing distinguishing
  /// signal — paused with content keeps the entry, so it never triggers a
  /// swap. We do NOT gate on `playbackStatus`: empirically on macOS the
  /// status can land at `.paused` or `.stopped` right after a queue ends,
  /// and either way `currentEntry == nil` is the more reliable signal.
  private func advanceToNextChunkIfNeeded() {
    guard !chunkSwapInFlight else { return }
    guard !pendingChunks.isEmpty else { return }
    guard currentChunkIndex + 1 < pendingChunks.count else { return }
    guard player.queue.currentEntry == nil else { return }

    chunkSwapInFlight = true
    let nextIndex = currentChunkIndex + 1
    let nextChunk = pendingChunks[nextIndex]
    Task { [weak self] in
      await self?.performChunkSwap(toChunkIndex: nextIndex, songs: nextChunk.songs)
      // We're already on the MainActor here (the Task inherits the
      // enclosing @MainActor isolation), so the gate flip is a direct
      // assignment — no nested Task needed.
      self?.chunkSwapInFlight = false
    }
  }

  /// F1a — load the next chunk into `ApplicationMusicPlayer.Queue` and
  /// start it. Tolerate-and-surface failures via `lastError`; never retry
  /// (the next monitor tick will simply observe the still-empty queue and,
  /// because `chunkSwapInFlight` is cleared in the caller's `defer`, will
  /// retry the swap once on its own — but if Apple's player refuses two
  /// chunks in a row we surface the error and stop). The `currentChunkIndex`
  /// is advanced **only on a confirmed start** so the global-offset stays
  /// honest (a half-swapped state would misattribute the next tick).
  private func performChunkSwap(toChunkIndex newIndex: Int, songs: [MusicKit.Song]) async {
    guard !songs.isEmpty else { return }
    do {
      player.queue = ApplicationMusicPlayer.Queue(for: songs)
      try await player.play()
      lastError = nil
      let started = await confirmPlaybackStarted()
      if started {
        currentChunkIndex = newIndex
      }
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
      // Structural queue position: this entry's ordinal in `queue.entries`,
      // matched by the queue `Entry`'s OWN id (the queue's per-position
      // handle MusicKit mints, NOT the song's `MusicItemID` — attribution
      // never keys on an Apple content id). nil if not found; callers fall
      // back to the start-index seed. (Signed-gate fallback documented in
      // plans/play-statistics.md if this proves unreliable under real
      // auto-advance/skip.)
      // F1a: the player's `queue.entries` index is **local to the
      // currently-loaded chunk** (resets to 0 each chunk swap). Translate
      // to a GLOBAL queue index across all chunks so the Phase-4 detector
      // continues consuming a monotonic index. With a single-chunk
      // resolution (chunkBoundaries `[0]`) this is the identity.
      let localIndex = player.queue.entries
        .firstIndex { $0.id == entry.id }
      if let localIndex {
        snap.queueIndex = PlaybackResolver.globalQueueIndex(
          localIndex: localIndex,
          currentChunk: currentChunkIndex,
          chunkBoundaries: chunkBoundaries,
        )
      } else {
        snap.queueIndex = nil
      }
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
      // Phase 4: stamp the active chunk's namespace so the now-playing
      // thumbnail re-resolves a catalog id via `ArtworkProvider`'s catalog
      // branch. Resolution path → read directly from `chunkNamespaces`
      // (parallel to `chunkBoundaries`, one entry per chunk). Single-shot
      // path → fall back to `singleShotNamespace` set by the
      // `play(songs:startingAt:)` caller. The `PlayerStateSnapshot
      // .artworkRef` `?? .library` covers nil for total backstop.
      if chunkNamespaces.indices.contains(currentChunkIndex) {
        snap.nowPlayingNamespace = chunkNamespaces[currentChunkIndex]
      } else {
        snap.nowPlayingNamespace = singleShotNamespace
      }
    }

    snapshot = snap

    // After `snapshot` is committed, so the Phase-4 detector sees the
    // fresh `queueIndex`. Cheap, synchronous, fire-and-return.
    onSnapshotRefresh?()

    // F1a — if the player has run out of entries on the current chunk and
    // we have more chunks pending, kick off the swap (fire-and-forget; the
    // re-entrancy gate keeps a second tick during the swap from
    // double-swapping). Called LAST so the detector observed the final
    // queueIndex of the just-finished chunk first.
    advanceToNextChunkIfNeeded()
  }

}
