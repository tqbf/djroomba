import Foundation

/// A tiny bounded LRU of loaded `PlaylistDetail`s (Phase B —
/// `plans/memory-and-laziness.md`). The detail cache exists only to kill the
/// re-selection flash, **not** to hoard the library: a single playlist's
/// rows re-read from SQLite is sub-millisecond, so residency is capped at
/// `capacity` playlists and never grows with how much you browsed (the old
/// `[String: PlaylistDetail]` was unbounded with all-or-nothing clearing).
///
/// Value type, mutated only from `PlaylistDetailService` (`@MainActor`), so
/// no internal synchronization is needed. Recency is the visit order:
/// `recency.first` is the least-recently-used (next evicted),
/// `recency.last` the most-recent. The capacity is small (5) so the linear
/// `recency` maintenance is cheaper than a doubly-linked structure.
struct PlaylistDetailCache {

  // MARK: Lifecycle

  init(capacity: Int) {
    precondition(capacity > 0, "PlaylistDetailCache capacity must be > 0")
    self.capacity = capacity
  }

  // MARK: Internal

  var count: Int {
    storage.count
  }

  /// Look up a detail and mark it most-recently-used (a real selection
  /// "uses" the entry). Returns nil on a miss.
  mutating func value(forID id: String) -> PlaylistDetail? {
    guard let detail = storage[id] else { return nil }
    touch(id)
    return detail
  }

  /// Read without affecting recency — for the stats-refresh merge, which
  /// must not itself count as a use (the triggering selection already did).
  func peek(_ id: String) -> PlaylistDetail? {
    storage[id]
  }

  /// Insert/replace, mark most-recently-used, then evict the LRU entries
  /// while over capacity.
  mutating func set(_ detail: PlaylistDetail, forID id: String) {
    storage[id] = detail
    touch(id)
    evictIfNeeded()
  }

  /// Targeted invalidation: drop exactly one playlist's cached detail
  /// (its membership/snapshot changed) while every other entry stays warm.
  mutating func remove(_ id: String) {
    storage[id] = nil
    recency.removeAll { $0 == id }
  }

  mutating func remove(ids: some Sequence<String>) {
    for id in ids { remove(id) }
  }

  /// Full clear — only for a forced full reimport.
  mutating func removeAll() {
    storage.removeAll()
    recency.removeAll()
  }

  // MARK: Private

  private let capacity: Int
  private var storage = [String: PlaylistDetail]()
  private var recency = [String]()

  private mutating func touch(_ id: String) {
    recency.removeAll { $0 == id }
    recency.append(id)
  }

  private mutating func evictIfNeeded() {
    while storage.count > capacity, !recency.isEmpty {
      let lru = recency.removeFirst()
      storage[lru] = nil
    }
  }
}
