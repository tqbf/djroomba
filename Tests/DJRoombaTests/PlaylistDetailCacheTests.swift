import Testing
@testable import DJRoomba

/// Phase B residency invariant (`plans/memory-and-laziness.md`): the detail
/// cache is a bounded LRU — residency is O(capacity), never O(browsed) —
/// with targeted invalidation that keeps unrelated entries warm.
@MainActor
struct PlaylistDetailCacheTests {

  // MARK: Internal

  @Test
  func `never exceeds capacity no matter how many playlists are selected`() {
    var cache = PlaylistDetailCache(capacity: 5)
    for i in 0..<50 {
      cache.set(detail("p\(i)"), forID: "p\(i)")
      #expect(cache.count <= 5)
    }
    #expect(cache.count == 5)
    // The whole library was "browsed"; only the last 5 are resident.
    for i in 0..<45 { #expect(cache.peek("p\(i)") == nil) }
    for i in 45..<50 { #expect(cache.peek("p\(i)") != nil) }
  }

  @Test
  func `evicts least-recently-used, and a lookup counts as use`() {
    var cache = PlaylistDetailCache(capacity: 3)
    cache.set(detail("a"), forID: "a")
    cache.set(detail("b"), forID: "b")
    cache.set(detail("c"), forID: "c")
    // Touch "a" so "b" becomes the LRU.
    _ = cache.value(forID: "a")
    cache.set(detail("d"), forID: "d") // evicts "b"
    #expect(cache.peek("b") == nil)
    #expect(cache.peek("a") != nil)
    #expect(cache.peek("c") != nil)
    #expect(cache.peek("d") != nil)
  }

  @Test
  func `peek does not affect recency (stats refresh must not be a use)`() {
    var cache = PlaylistDetailCache(capacity: 2)
    cache.set(detail("a"), forID: "a")
    cache.set(detail("b"), forID: "b")
    _ = cache.peek("a") // must NOT make "a" most-recent
    cache.set(detail("c"), forID: "c") // "a" is still LRU → evicted
    #expect(cache.peek("a") == nil)
    #expect(cache.peek("b") != nil)
    #expect(cache.peek("c") != nil)
  }

  @Test
  func `targeted invalidation drops one entry and keeps the rest warm`() {
    var cache = PlaylistDetailCache(capacity: 5)
    for id in ["a", "b", "c"] { cache.set(detail(id), forID: id) }
    cache.remove("b")
    #expect(cache.peek("b") == nil)
    #expect(cache.peek("a") != nil)
    #expect(cache.peek("c") != nil)
    cache.remove(ids: ["a", "c"])
    #expect(cache.count == 0)
  }

  // MARK: Private

  private func detail(_ id: String) -> PlaylistDetail {
    PlaylistDetail(
      id: id,
      name: id,
      isAppleLibraryPlaylist: true,
      source: .libraryUserPlaylist,
      description: nil,
      isEditable: false,
      tracks: [],
    )
  }
}
