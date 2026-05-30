import Foundation

// MARK: - UpNextDrainDetector

/// Pure low-water transition predicate for the Phase-5 auto-fill
/// dispatch (`plans/up-next-queue.md` — "Auto-fill on queue
/// low-water"). Extracted from `MusicController.notifyUpNextMutated`
/// so the rule that decides "should the auto-fill task fire on this
/// mutation?" can be unit-tested without spinning up a controller —
/// the live gating (`UserDefaults` toggle + `gpt.isKeyConfigured`)
/// stays on the controller where it can reach those collaborators.
///
/// **Grace-note refinement (2026-05-30).** The trigger moved forward
/// by one slot: instead of waiting for the queue to fully drain
/// (`isEmpty`) before asking the assistant to refill, we fire as soon
/// as the queue depth drops to `refillThreshold` (=1). That gives the
/// `gpt-5.4` + `flex` turn (~10–30 s typical) one full song of
/// playback to land its `up_next_add` call, so the user doesn't sit
/// through dead air between the last queued track and the next batch.
///
/// `targetDepth` and `refillThreshold` are named together because
/// the user-visible loop ("queue up 11, refill at 10 remaining")
/// derives from their pairing — change one, reconsider the other.
enum UpNextDrainDetector {

  /// How many tracks the auto-fill seed prompt asks the assistant
  /// for per refill. The model picks tracks; we don't expect
  /// bit-exact `added = targetDepth` every turn, but the directive
  /// in the seed prompt is this number.
  static let targetDepth = 11

  /// The queue depth at (or below) which a refill turn fires. With
  /// `targetDepth = 11` and `refillThreshold = 1` the steady-state
  /// floor is 1 (leftover from the previous batch is playing) and
  /// the ceiling is 12 (1 leftover + 11 added).
  static let refillThreshold = 1

  /// Returns `true` iff this mutation crossed the low-water mark —
  /// i.e. the queue depth was strictly above `refillThreshold` before
  /// and is at or below it now. A mutation that stays on either side
  /// of the threshold (including `0 → 0` and a hypothetical
  /// `1 → 1` no-op) does NOT fire; re-entrancy after a fired refill
  /// is the controller's single-flight guard's problem, not the
  /// predicate's.
  static func didCrossLowWater(oldCount: Int, newCount: Int) -> Bool {
    oldCount > refillThreshold && newCount <= refillThreshold
  }
}
