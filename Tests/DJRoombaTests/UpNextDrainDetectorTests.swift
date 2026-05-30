import Foundation
import Testing
@testable import DJRoomba

/// `UpNextDrainDetector` — pure transition predicate the Phase-5
/// auto-fill dispatch keys off (`plans/up-next-queue.md` —
/// "Auto-fill on empty"). The live gating on the UserDefaults
/// toggle + `gpt.isKeyConfigured` stays on the controller; only the
/// "is this the drain edge?" rule is tested here.
struct UpNextDrainDetectorTests {

  @Test
  func `non-empty to empty is the drain edge`() {
    #expect(UpNextDrainDetector.didDrain(previousWasNonEmpty: true, isEmptyNow: true))
  }

  @Test
  func `empty to empty does not fire (queue was already drained)`() {
    #expect(!UpNextDrainDetector.didDrain(previousWasNonEmpty: false, isEmptyNow: true))
  }

  @Test
  func `non-empty to non-empty does not fire (mid-queue mutation)`() {
    #expect(!UpNextDrainDetector.didDrain(previousWasNonEmpty: true, isEmptyNow: false))
  }

  @Test
  func `empty to non-empty does not fire (queue is being filled)`() {
    #expect(!UpNextDrainDetector.didDrain(previousWasNonEmpty: false, isEmptyNow: false))
  }
}
