import CoreGraphics
import Foundation
import Testing
@testable import DJRoomba

/// Phase 6 pure-logic invariants for `GenreMapPersistence` + the builder's
/// matching pass (`plans/genre-metro-map.md` Phase 6). Tests are fixture-
/// driven — no SQLite, no SwiftUI, no MusicKit — so the matching pass is
/// pinned independently of the store.
struct GenreMapPersistenceTests {

  @Test
  func `jaccard above 0_5 preserves community id below mints fresh`() {
    let new: [Int: Set<String>] = [
      10: ["A", "B", "C"],
      11: ["X", "Y"],
    ]
    let old: [String: Set<String>] = [
      "old-1": ["A", "B", "C"], // identical ⇒ Jaccard 1.0
      "old-2": ["X", "Y", "Z", "W"], // Jaccard 2/4 = 0.5 (boundary)
      "old-3": ["P", "Q"], // disjoint
    ]
    let matched = GenreMapPersistence.matchCommunities(
      newPartition: new,
      oldPartition: old,
    )
    #expect(matched[10] == "old-1", "perfect match must reuse the id")
    #expect(matched[11] == "old-2", "boundary 0.5 still reuses the id (>=)")
  }

  @Test
  func `community split below threshold mints fresh ids for both children`() {
    // Before: one community of 6 members. After: split into two of 3.
    // Each child has Jaccard 3/6 = 0.5 against the parent (boundary).
    let new: [Int: Set<String>] = [
      1: ["A", "B", "C"],
      2: ["D", "E", "F"],
    ]
    let old: [String: Set<String>] = [
      "parent": ["A", "B", "C", "D", "E", "F"]
    ]
    let matched = GenreMapPersistence.matchCommunities(
      newPartition: new,
      oldPartition: old,
    )
    // The LARGER new community wins the predecessor (deterministic tie-
    // break by member-count, then by new id). Here both are equal in
    // size, so the smaller new id (1) takes the parent and 2 mints.
    #expect(matched.count == 1)
    #expect(matched[1] == "parent")
    #expect(matched[2] == nil)
  }

  @Test
  func `larger child inherits when parent splits unequally`() {
    let new: [Int: Set<String>] = [
      // 4 members of the parent: Jaccard 4/6 ≈ 0.67 ⇒ matches.
      1: ["A", "B", "C", "D"],
      // 2 members of the parent: Jaccard 2/6 ≈ 0.33 ⇒ below threshold.
      2: ["E", "F"],
    ]
    let old: [String: Set<String>] = [
      "parent": ["A", "B", "C", "D", "E", "F"]
    ]
    let matched = GenreMapPersistence.matchCommunities(
      newPartition: new,
      oldPartition: old,
    )
    #expect(matched[1] == "parent", "larger child must inherit")
    #expect(matched[2] == nil, "smaller child below threshold mints fresh")
  }

  @Test
  func `disjoint partitions mint fresh ids everywhere`() {
    let new: [Int: Set<String>] = [
      1: ["A", "B"],
      2: ["C", "D"],
    ]
    let old: [String: Set<String>] = [
      "old": ["X", "Y", "Z"]
    ]
    #expect(GenreMapPersistence.matchCommunities(
      newPartition: new,
      oldPartition: old,
    ).isEmpty)
  }

  @Test
  func `strand id codec round trips integer arrays`() {
    let ids = [3, 1, 4, 1, 5, 9, 2]
    let encoded = GenreMapPersistence.encodeStrandIDs(ids)
    #expect(encoded == "[1,1,2,3,4,5,9]")
    #expect(GenreMapPersistence.decodeStrandIDs(encoded).sorted() == ids.sorted())
    #expect(GenreMapPersistence.decodeStrandIDs("[]").isEmpty)
    #expect(GenreMapPersistence.decodeStrandIDs("garbage").isEmpty)
  }

  @Test
  func `label tokens codec round trips string arrays`() {
    let tokens = ["Alternative", "Britpop"]
    let encoded = GenreMapPersistence.encodeLabelTokens(tokens)
    #expect(GenreMapPersistence.decodeLabelTokens(encoded) == tokens)
    #expect(GenreMapPersistence.decodeLabelTokens("[]").isEmpty)
  }

}
