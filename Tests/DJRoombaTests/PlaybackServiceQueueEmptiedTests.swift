import Foundation
import Testing
@testable import DJRoomba

/// `PlaybackService.shouldSignalQueueEmptied` — pure predicate the grace-
/// note Up Next auto-advance keys off. The live `player.state
/// .playbackStatus` + `player.playbackTime` reads + the `onQueueEmptied`
/// dispatch stay on the service; only the five-AND ("no chunk swap, no
/// next chunk, prior tick was playing, this tick is paused or stopped,
/// playbackTime wrapped to ~0") is tested here. Documents the matrix the
/// natural end-of-song path depends on and pins:
/// - the macOS single-song-queue WRAP case ⇒ status transitions `.playing
///   → .paused` at `playbackTime ≈ 0`, NOT `.stopped` as one might guess
///   (discovered live via the playback-diag unified-log probe on the
///   signed build, 2026-05-30);
/// - the user-pause distinction: a user pause leaves `playbackTime` at
///   the paused-at value, so the wrap-to-zero threshold is what
///   separates pause from natural-end;
/// - the F1a chunk-swap interaction so a future change can't silently
///   un-gate the Up Next dispatch during a chunk swap.
struct PlaybackServiceQueueEmptiedTests {

  @Test
  func `fires on playing-to-paused with playbackTime wrapped to zero`() {
    // The live signal observed on the signed build: natural song end
    // wraps the queue to entry 0 and the engine settles to `.paused`
    // with `playbackTime ≈ 0.14 s` (logged 2026-05-30).
    #expect(
      PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 0,
        pendingChunkCount: 0,
        previousStatus: .playing,
        currentStatus: .paused,
        playbackTime: 0.14,
      )
    )
  }

  @Test
  func `also fires on playing-to-stopped with playbackTime wrapped (the queue-empty subcase)`() {
    // The (less common) "queue actually drained" subcase: the engine
    // can settle to `.stopped` instead of `.paused`. The predicate
    // covers both via the `||`.
    #expect(
      PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 0,
        pendingChunkCount: 0,
        previousStatus: .playing,
        currentStatus: .stopped,
        playbackTime: 0.0,
      )
    )
  }

  @Test
  func `does not fire on a user pause mid-song (playbackTime is not at zero)`() {
    // The load-bearing non-event: a user pause near the middle/end of
    // a song must NOT pop the queue head. The wrap-to-zero threshold
    // separates pause from natural-end.
    #expect(
      !PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 0,
        pendingChunkCount: 0,
        previousStatus: .playing,
        currentStatus: .paused,
        playbackTime: 113.5,
      )
    )
  }

  @Test
  func `does not fire on a steady paused tick (no transition)`() {
    // The transition edge is `.playing → (.paused|.stopped)`, not
    // "currently paused" — otherwise every 0.5 s tick while paused
    // would pop another queue head.
    #expect(
      !PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 0,
        pendingChunkCount: 0,
        previousStatus: .paused,
        currentStatus: .paused,
        playbackTime: 0.0,
      )
    )
  }

  @Test
  func `does not fire mid chunk-swap (the playing-to-paused is the chunk-end state)`() {
    // Between `advanceToNextChunkIfNeeded` setting the gate and the
    // swap landing, the brief `.playing → .paused` at `playbackTime ≈
    // 0` is the F1a chunk-end window — not an Up Next signal. The
    // `chunkSwapInFlight` guard pins this.
    #expect(
      !PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: true,
        currentChunkIndex: 0,
        pendingChunkCount: 2,
        previousStatus: .playing,
        currentStatus: .paused,
        playbackTime: 0.0,
      )
    )
  }

  @Test
  func `does not fire when a next chunk is pending (chunk-swap path will take it)`() {
    // F1a's `advanceToNextChunkIfNeeded` owns the "swap to next chunk"
    // case; the Up Next signal must not pre-empt it.
    #expect(
      !PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 0,
        pendingChunkCount: 2,
        previousStatus: .playing,
        currentStatus: .paused,
        playbackTime: 0.0,
      )
    )
  }

  @Test
  func `fires on the final chunk of a multi-chunk resolution after it drains`() {
    // currentChunkIndex == last chunk, no more chunks to swap to —
    // identical to the single-chunk drain case.
    #expect(
      PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 1,
        pendingChunkCount: 2,
        previousStatus: .playing,
        currentStatus: .paused,
        playbackTime: 0.0,
      )
    )
  }

  @Test
  func `does not fire on a stopped-to-paused transition (fresh launch)`() {
    // On fresh launch with system-restored stopped state, the first
    // tick can go `.stopped → .paused` if MusicKit lazily settles the
    // engine. The prior tick wasn't playing, so this must not fire.
    #expect(
      !PlaybackService.shouldSignalQueueEmptied(
        chunkSwapInFlight: false,
        currentChunkIndex: 0,
        pendingChunkCount: 0,
        previousStatus: .stopped,
        currentStatus: .paused,
        playbackTime: 0.0,
      )
    )
  }
}
