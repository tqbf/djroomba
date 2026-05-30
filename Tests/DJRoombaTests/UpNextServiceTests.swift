import Foundation
import MusicKit
import Testing
@testable import DJRoomba

/// `UpNextService` — pure in-memory queue (`plans/up-next-queue.md`
/// Phase 1). Every mutator is synchronous on `@MainActor`, so the
/// test cases run on the main actor too and assert against
/// `entries` / `count` / `isEmpty` directly. Each test gets a fresh
/// service (the type holds no shared / disk state).
@MainActor
struct UpNextServiceTests {

  // MARK: Internal

  @Test
  func `empty service starts empty`() {
    let svc = UpNextService()
    #expect(svc.isEmpty)
    #expect(svc.count == 0)
    #expect(svc.entries.isEmpty)
  }

  @Test
  func `append pushes songs to the tail in order`() {
    let svc = UpNextService()
    let pair1 = makePair("a")
    let pair2 = makePair("b")
    let pair3 = makePair("c")
    svc.append([pair1.song], musicItemIDs: [pair1.id])
    svc.append([pair2.song, pair3.song], musicItemIDs: [pair2.id, pair3.id])
    #expect(svc.count == 3)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c"])
    #expect(svc.entries.map(\.musicItemID.rawValue) == ["a", "b", "c"])
  }

  @Test
  func `append of an empty batch is a no-op`() {
    let svc = UpNextService()
    svc.append([], musicItemIDs: [])
    #expect(svc.isEmpty)
  }

  @Test
  func `insert at the head shifts existing entries down`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 1)
    #expect(svc.entries.map(\.song.musicItemID) == ["z", "a", "b", "c"])
  }

  @Test
  func `insert at the tail position appends`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 4)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c", "z"])
  }

  @Test
  func `insert in the middle places between existing entries`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 2)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "z", "b", "c"])
  }

  @Test
  func `insert of multiple songs preserves the batch's internal order`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b"])
    let pairX = makePair("x")
    let pairY = makePair("y")
    let pairZ = makePair("z")
    svc.insert(
      [pairX.song, pairY.song, pairZ.song],
      musicItemIDs: [pairX.id, pairY.id, pairZ.id],
      at: 2,
    )
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "x", "y", "z", "b"])
  }

  @Test
  func `insert of an empty batch is a no-op`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b"])
    svc.insert([], musicItemIDs: [], at: 1)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b"])
  }

  @Test
  func `insert at position 0 clamps to head`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 0)
    #expect(svc.entries.map(\.song.musicItemID) == ["z", "a", "b"])
  }

  @Test
  func `insert at position 1 on an empty queue appends as the only entry`() {
    let svc = UpNextService()
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 1)
    #expect(svc.entries.map(\.song.musicItemID) == ["z"])
  }

  @Test
  func `insert at position count plus 1 appends to tail`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 4)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c", "z"])
  }

  @Test
  func `insert at position count plus 5 clamps to tail`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: 8)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c", "z"])
  }

  @Test
  func `insert at negative position clamps to head`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b"])
    let pair = makePair("z")
    svc.insert([pair.song], musicItemIDs: [pair.id], at: -50)
    #expect(svc.entries.map(\.song.musicItemID) == ["z", "a", "b"])
  }

  @Test
  func `remove at a single position drops that entry`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d"])
    svc.remove(at: [2])
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "c", "d"])
  }

  @Test
  func `remove of duplicate positions only drops the entry once`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d"])
    svc.remove(at: [2, 2, 2])
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "c", "d"])
  }

  @Test
  func `remove silently ignores out-of-range positions`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    svc.remove(at: [0, 4, 99, -1])
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c"])
  }

  @Test
  func `multi-remove is index-stable so each named entry actually leaves`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d", "e"])
    // Drop positions 2 ("b") and 4 ("d"). A naive ascending-loop
    // remove would skip "d" because the first remove shifts "d"
    // down to position 3. The descending-sort guard here makes the
    // multi-remove correct.
    svc.remove(at: [2, 4])
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "c", "e"])
  }

  @Test
  func `multi-remove with a mix of valid duplicate and out-of-range positions`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d", "e"])
    svc.remove(at: [1, 1, 5, 99, 0, 3])
    #expect(svc.entries.map(\.song.musicItemID) == ["b", "d"])
  }

  @Test
  func `clear empties the queue`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    svc.clear()
    #expect(svc.isEmpty)
  }

  @Test
  func `clear on an empty queue is a no-op`() {
    let svc = UpNextService()
    svc.clear()
    #expect(svc.isEmpty)
  }

  @Test
  func `popHead on empty returns nil and stays empty`() {
    let svc = UpNextService()
    #expect(svc.popHead() == nil)
    #expect(svc.isEmpty)
  }

  @Test
  func `popHead removes and returns the head`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let popped = svc.popHead()
    #expect(popped?.song.musicItemID == "a")
    #expect(svc.entries.map(\.song.musicItemID) == ["b", "c"])
  }

  @Test
  func `popHead until empty drains the queue in order`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b"])
    #expect(svc.popHead()?.song.musicItemID == "a")
    #expect(svc.popHead()?.song.musicItemID == "b")
    #expect(svc.popHead() == nil)
    #expect(svc.isEmpty)
  }

  @Test
  func `consumeThrough(3) on a 5-entry queue leaves 2 and returns the 3rd`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d", "e"])
    let picked = svc.consumeThrough(position: 3)
    #expect(picked?.song.musicItemID == "c")
    #expect(svc.entries.map(\.song.musicItemID) == ["d", "e"])
    #expect(svc.count == 2)
  }

  @Test
  func `consumeThrough(1) is equivalent to popHead`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let picked = svc.consumeThrough(position: 1)
    #expect(picked?.song.musicItemID == "a")
    #expect(svc.entries.map(\.song.musicItemID) == ["b", "c"])
  }

  @Test
  func `consumeThrough at the tail drains the queue and returns the tail entry`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let picked = svc.consumeThrough(position: 3)
    #expect(picked?.song.musicItemID == "c")
    #expect(svc.isEmpty)
  }

  @Test
  func `consumeThrough at an out-of-range position is a no-op`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    #expect(svc.consumeThrough(position: 0) == nil)
    #expect(svc.consumeThrough(position: 4) == nil)
    #expect(svc.consumeThrough(position: -5) == nil)
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c"])
  }

  @Test
  func `consumeThrough on an empty queue returns nil`() {
    let svc = UpNextService()
    #expect(svc.consumeThrough(position: 1) == nil)
  }

  @Test
  func `range over the full queue returns every entry`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d"])
    let slice = svc.range(1, 4)
    #expect(slice.map(\.song.musicItemID) == ["a", "b", "c", "d"])
  }

  @Test
  func `range over a sub-slice returns just those entries`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d", "e"])
    let slice = svc.range(2, 4)
    #expect(slice.map(\.song.musicItemID) == ["b", "c", "d"])
  }

  @Test
  func `range clamps an over-long end to the live queue length`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let slice = svc.range(2, 99)
    #expect(slice.map(\.song.musicItemID) == ["b", "c"])
  }

  @Test
  func `range clamps a non-positive start to the head`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    let slice = svc.range(-5, 2)
    #expect(slice.map(\.song.musicItemID) == ["a", "b"])
  }

  @Test
  func `range with start greater than end returns an empty slice`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    #expect(svc.range(3, 1).isEmpty)
  }

  @Test
  func `range on an empty queue returns empty regardless of args`() {
    let svc = UpNextService()
    #expect(svc.range(1, 5).isEmpty)
    #expect(svc.range(0, 0).isEmpty)
  }

  @Test
  func `range with both bounds past the tail returns empty`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b"])
    #expect(svc.range(10, 20).isEmpty)
  }

  @Test
  func `each Entry mints a unique UUID even for the same song re-added`() {
    let svc = UpNextService()
    let pair = makePair("a")
    svc.append([pair.song], musicItemIDs: [pair.id])
    svc.append([pair.song], musicItemIDs: [pair.id])
    #expect(svc.count == 2)
    #expect(svc.entries[0].id != svc.entries[1].id)
  }

  @Test
  func `moveToTop on an empty queue is a no-op`() {
    let svc = UpNextService()
    svc.moveToTop(positions: [1, 2])
    #expect(svc.isEmpty)
  }

  @Test
  func `moveToTop with no valid positions is a no-op`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    svc.moveToTop(positions: [0, -1, 99])
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c"])
  }

  @Test
  func `moveToTop selecting every entry is a no-op`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    svc.moveToTop(positions: [1, 2, 3])
    #expect(svc.entries.map(\.song.musicItemID) == ["a", "b", "c"])
  }

  @Test
  func `moveToTop of a single tail entry promotes it to head`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d"])
    svc.moveToTop(positions: [4])
    #expect(svc.entries.map(\.song.musicItemID) == ["d", "a", "b", "c"])
  }

  @Test
  func `moveToTop preserves the relative order of picked rows`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d", "e"])
    svc.moveToTop(positions: [2, 4])
    // b and d picked → land at top in their existing relative order
    // (b before d), then the remaining rows in their existing order
    // (a, c, e).
    #expect(svc.entries.map(\.song.musicItemID) == ["b", "d", "a", "c", "e"])
  }

  @Test
  func `moveToTop is robust to duplicate and unsorted positions`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c", "d", "e"])
    svc.moveToTop(positions: [4, 2, 4, 2])
    #expect(svc.entries.map(\.song.musicItemID) == ["b", "d", "a", "c", "e"])
  }

  @Test
  func `moveToTop drops out-of-range positions silently`() {
    let svc = UpNextService()
    seed(svc, ids: ["a", "b", "c"])
    svc.moveToTop(positions: [2, 99, -1])
    #expect(svc.entries.map(\.song.musicItemID) == ["b", "a", "c"])
  }

  // MARK: Private

  private typealias Pair = (song: DJRoomba.Song, id: MusicItemID)

  private func makePair(_ id: String) -> Pair {
    let song = TestSupport.sampleSong(musicItemID: id, title: id)
    return (song, MusicItemID(id))
  }

  /// Append a sequence of songs with `musicItemID == id` so test
  /// assertions can read the queue by id without minting names.
  private func seed(_ svc: UpNextService, ids: [String]) {
    let pairs = ids.map { makePair($0) }
    svc.append(pairs.map(\.song), musicItemIDs: pairs.map(\.id))
  }
}
