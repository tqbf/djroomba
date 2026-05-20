import Foundation

/// Pure, synchronous decider for the catalog search debounce/dispatch
/// policy. **No `Task.sleep`, no Combine, no Timer here** — the decider is a
/// total function from inputs to a `SearchDecision`. The view layer wires the
/// timing (`.task(id: query)` + `Task.sleep(for:)` + cancellation-on-typed-
/// key); this type just answers *should we fire now, wait, or clear?*
/// keeping the rule unit-testable without async machinery (the plan's
/// pure-decider mandate).
///
/// Rules (in order):
///
///   1. The trimmed query is **empty** → `.clear` (drop any current results,
///      do not fire a request; mirrors how `.searchable` clears a filter).
///   2. The trimmed query is shorter than `minLength` → `.wait` (don't spam
///      Apple's rate-limited catalog endpoint with 1-character queries; do
///      NOT clear, the user is mid-type).
///   3. The trimmed query equals the **last fired** query → `.wait` (a real
///      no-op — re-firing the same request gains nothing and burns rate).
///   4. Otherwise → `.fire(query)` only if `elapsedSinceLastInputMS >=
///      debounceMS`; until then, `.wait`.
///
/// All four rules are exhaustively covered by `CatalogSearchDebouncerTests`.
///
/// Defaults: `minLength = 2`, `debounceMS = 250`. Chosen because (a) the
/// rest of macOS (Spotlight, Music.app inline search) starts dispatching at
/// roughly 2 characters and (b) 250 ms is the sweet spot the wider Apple
/// ecosystem trends to — short enough that a deliberate pause feels live,
/// long enough that an idle middle keystroke doesn't fire its own request.
enum CatalogSearchDebouncer {

  // MARK: Internal

  /// What the view layer should do next for the user's current query state.
  /// All three cases carry only `Sendable` values so the decider stays
  /// nonisolated and trivially testable across actors.
  enum SearchDecision: Equatable, Sendable {
    /// Empty query → drop any in-flight results and DO NOT fire a request.
    case clear
    /// The user is still typing, or the elapsed-since-last-input hasn't
    /// crossed the debounce yet, or the trimmed query equals the last
    /// fired query (idempotent re-fire is worthless and wastes rate).
    case wait
    /// Fire a catalog search for this exact (trimmed) query.
    case fire(String)
  }

  /// Pure decision from the current keystroke against the last fired query
  /// and how long it's been since the *most recent* keystroke. The view
  /// layer measures `elapsedSinceLastInputMS` (via `.task(id:)` + a sleep);
  /// this function does NOT measure time — passing time is an input.
  ///
  /// Whitespace-only queries are treated as empty (`.clear`) — the user
  /// hasn't typed anything meaningful yet.
  static func decision(
    for newTerm: String,
    lastFiredTerm: String?,
    elapsedSinceLastInputMS: Int,
    minLength: Int = 2,
    debounceMS: Int = 250,
  ) -> SearchDecision {
    let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return .clear
    }
    if trimmed.count < minLength {
      return .wait
    }
    if trimmed == lastFiredTerm {
      return .wait
    }
    if elapsedSinceLastInputMS < debounceMS {
      return .wait
    }
    return .fire(trimmed)
  }

}
