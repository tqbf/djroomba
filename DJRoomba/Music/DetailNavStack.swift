import Foundation

// MARK: - DetailDestination

/// A top-pane navigation destination on the in-session Back stack. Two
/// cases only: a real playlist (by id) or a synthetic genre collection (by
/// genre name). The Recently-Played landing (no selection) is represented
/// by its *absence* — it's never pushed, so "Back from the landing" is a
/// harmless stack underflow rather than a third case.
enum DetailDestination: Hashable {
  case playlist(String)
  case genre(String)
}

// MARK: - DetailNavStack

/// The in-session top-pane Back stack: a LIFO of PRE-change destinations
/// the user can return to via the Back control. Pure value semantics so
/// the push/cap/pop rules are unit-testable in isolation (the Swift-6
/// `@MainActor @Observable` controller can't be constructed in a unit test
/// — it opens the DB and the full service graph). `MusicController` owns
/// one instance and integrates it via `selectedPlaylistID.didSet`.
///
/// Never persisted — history is per session and starts empty each launch.
struct DetailNavStack: Equatable {

  /// Capacity bound: a long browse session can't grow the stack
  /// unbounded — the oldest entries are dropped past this.
  static let capacity = 50

  private(set) var entries = [DetailDestination]()

  var canGoBack: Bool {
    !entries.isEmpty
  }

  /// Record `dest` as the destination to come back to. Skips nil (the
  /// Recently-Played landing is never a recordable destination) and a
  /// no-op repeat (same as the current top — re-selecting what's already
  /// shown must not stack a duplicate), then caps at `capacity` (oldest
  /// dropped).
  mutating func push(_ dest: DetailDestination?) {
    guard let dest, dest != entries.last else { return }
    entries.append(dest)
    if entries.count > Self.capacity {
      entries.removeFirst(entries.count - Self.capacity)
    }
  }

  /// Pop the most recent destination (LIFO). Underflow (empty — e.g.
  /// already at the landing) returns nil and is a harmless no-op.
  mutating func pop() -> DetailDestination? {
    entries.popLast()
  }

  /// After a genre rename/merge, rewrite any `.genre(old)` history entry
  /// to `.genre(new)` so Back doesn't return to a now-empty genre. Pure
  /// in-place rewrite (no reordering / capacity change); `.playlist`
  /// entries are untouched. No-op when `old == new`.
  mutating func replacingGenre(_ old: String, with new: String) {
    guard old != new else { return }
    entries = entries.map { entry in
      if case .genre(old) = entry {
        .genre(new)
      } else {
        entry
      }
    }
  }
}
