import Foundation
import Testing
@testable import DJRoomba

/// `UpNextDrainDetector` — pure low-water transition predicate the
/// Phase-5 auto-fill dispatch keys off (`plans/up-next-queue.md` —
/// "Auto-fill on queue low-water"). The live gating on the
/// UserDefaults toggle + `gpt.isKeyConfigured` stays on the
/// controller; only the "did this mutation cross the threshold?"
/// rule is tested here.
///
/// The 2026-05-30 grace note moved the trigger forward by one slot
/// (`refillThreshold = 1`) so the assistant has a song's worth of
/// playback to land its refill turn instead of leaving dead air.
struct UpNextDrainDetectorTests {

  @Test
  func `5 to 1 fires (crosses the threshold from above)`() {
    #expect(UpNextDrainDetector.didCrossLowWater(oldCount: 5, newCount: 1))
  }

  @Test
  func `5 to 0 fires (skips past the threshold)`() {
    #expect(UpNextDrainDetector.didCrossLowWater(oldCount: 5, newCount: 0))
  }

  @Test
  func `2 to 1 fires (the minimal crossing)`() {
    #expect(UpNextDrainDetector.didCrossLowWater(oldCount: 2, newCount: 1))
  }

  @Test
  func `12 to 11 does not fire (still well above threshold)`() {
    #expect(!UpNextDrainDetector.didCrossLowWater(oldCount: 12, newCount: 11))
  }

  @Test
  func `1 to 1 does not fire (no-op at threshold)`() {
    #expect(!UpNextDrainDetector.didCrossLowWater(oldCount: 1, newCount: 1))
  }

  @Test
  func `1 to 0 does not fire (already past threshold, single-flight guard re-entry)`() {
    #expect(!UpNextDrainDetector.didCrossLowWater(oldCount: 1, newCount: 0))
  }

  @Test
  func `0 to 0 does not fire (queue was already drained)`() {
    #expect(!UpNextDrainDetector.didCrossLowWater(oldCount: 0, newCount: 0))
  }

  @Test
  func `target and threshold are paired (regression: changing one without the other is suspicious)`() {
    // The "queue up 11, refill at 1 remaining" loop derives from
    // this pair. Pinning the values here so a future agent who
    // bumps one without the other has to read this test.
    #expect(UpNextDrainDetector.targetDepth == 11)
    #expect(UpNextDrainDetector.refillThreshold == 1)
  }
}
