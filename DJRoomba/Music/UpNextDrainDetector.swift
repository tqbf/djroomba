import Foundation

// MARK: - UpNextDrainDetector

/// Pure transition predicate for the Phase-5 auto-fill dispatch
/// (`plans/up-next-queue.md` — "Auto-fill on empty"). Extracted from
/// `MusicController.notifyUpNextMutated` so the rule that decides
/// "should the auto-fill task fire on this mutation?" can be unit-
/// tested without spinning up a controller — the live gating
/// (`UserDefaults` toggle + `gpt.isKeyConfigured`) stays on the
/// controller where it can reach those collaborators.
///
/// The detector is the non-empty → empty edge. Empty → empty does
/// not fire (the queue was already drained), and any →non-empty
/// transition obviously doesn't (the queue still has tracks).
enum UpNextDrainDetector {

  /// Returns `true` iff the Up Next queue transitioned from
  /// non-empty to empty between the previous mutation and the
  /// current one.
  static func didDrain(previousWasNonEmpty: Bool, isEmptyNow: Bool) -> Bool {
    previousWasNonEmpty && isEmptyNow
  }
}
