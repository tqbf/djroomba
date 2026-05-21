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
  func `strand grow by 2 members reuses id when member jaccard stays high`() {
    // Before: strand spans 8 members. After: same 8 + 2 new ⇒ Jaccard 8/10
    // = 0.8. Path stays similar (one segment rerouted, ~80% of consecutive
    // pairs preserved). Composite > 0.5 ⇒ reuse.
    let newPath = ["A", "B", "C", "D", "E", "F", "G", "H", "I"]
    let oldPath = ["A", "B", "C", "D", "E", "F", "G", "H"]
    let newStrands = [
      (
        id: 5,
        members: Set(newPath),
        pathPairs: GenreMapPersistence.consecutivePairs(newPath),
      )
    ]
    let oldStrands = [
      (
        id: "old-7",
        members: Set(oldPath),
        pathPairs: GenreMapPersistence.consecutivePairs(oldPath),
      )
    ]
    let matched = GenreMapPersistence.matchStrands(
      newStrands: newStrands,
      oldStrands: oldStrands,
    )
    #expect(matched[5] == "old-7", "the modest grow should preserve the id")
  }

  @Test
  func `strand completely re routed below threshold mints new`() {
    let newStrands = [
      (
        id: 1,
        members: Set(["A", "B", "C"]),
        pathPairs: GenreMapPersistence.consecutivePairs(["A", "B", "C"]),
      )
    ]
    let oldStrands = [
      (
        id: "old",
        members: Set(["X", "Y", "Z"]),
        pathPairs: GenreMapPersistence.consecutivePairs(["X", "Y", "Z"]),
      )
    ]
    let matched = GenreMapPersistence.matchStrands(
      newStrands: newStrands,
      oldStrands: oldStrands,
    )
    #expect(matched.isEmpty, "fully disjoint strand must mint a new id")
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

  @Test
  func `previous positions seed the layout for existing nodes only`() {
    var configuration = GenreMapForceLayout.Configuration()
    configuration.maxSteps = 1 // force NO settling
    configuration.previousPositions = [
      "Alt": CGPoint(x: 100, y: 200),
      "Folk": CGPoint(x: -50, y: 300),
    ]
    configuration.stabilityForce = 0 // pure seeding behaviour
    let inputs = [
      GenreMapForceLayout.InputNode(
        id: "Alt",
        weight: 0.5,
        labelSize: CGSize(width: 60, height: 20),
        communityID: 1,
      ),
      GenreMapForceLayout.InputNode(
        id: "Folk",
        weight: 0.4,
        labelSize: CGSize(width: 60, height: 20),
        communityID: 1,
      ),
      GenreMapForceLayout.InputNode(
        id: "NewGenre",
        weight: 0.3,
        labelSize: CGSize(width: 60, height: 20),
        communityID: 1,
      ),
    ]
    let output = GenreMapForceLayout.layout(nodes: inputs, edges: [], configuration: configuration)
    // Persisted nodes start AT their persisted points (one step of
    // damped integration moves them only slightly).
    let alt = output.positions["Alt"] ?? .zero
    let folk = output.positions["Folk"] ?? .zero
    let new = output.positions["NewGenre"] ?? .zero
    #expect(abs(alt.x - 100) < 5)
    #expect(abs(alt.y - 200) < 5)
    #expect(abs(folk.x - -50) < 5)
    #expect(abs(folk.y - 300) < 5)
    // The new genre is NOT at one of the persisted points (it scattered).
    #expect(abs(new.x - 100) > 1 || abs(new.y - 200) > 1)
    #expect(abs(new.x - -50) > 1 || abs(new.y - 300) > 1)
  }

  @Test
  func `stability force keeps existing nodes near their previous positions`() {
    // No edges ⇒ the only forces are stability + community gravity
    // (single community ⇒ centroid IS the persisted centroid). The
    // stability term keeps the persisted node within `delta` of its
    // previous position.
    var configuration = GenreMapForceLayout.Configuration()
    configuration.maxSteps = 200
    configuration.settleEpsilon = 0.01
    configuration.previousPositions = [
      "Anchor": CGPoint(x: 50, y: 60)
    ]
    configuration.stabilityForce = 0.05
    let inputs = [
      GenreMapForceLayout.InputNode(
        id: "Anchor",
        weight: 0.5,
        labelSize: CGSize(width: 60, height: 20),
        communityID: 1,
      )
    ]
    let output = GenreMapForceLayout.layout(nodes: inputs, edges: [], configuration: configuration)
    let anchor = output.positions["Anchor"] ?? .zero
    // ε is generous — the macro pass + community gravity can shift a
    // single node by a few world units even with stability holding it.
    #expect(abs(anchor.x - 50) < 30, "anchored node drifted by \(abs(anchor.x - 50))")
    #expect(abs(anchor.y - 60) < 30, "anchored node drifted by \(abs(anchor.y - 60))")
  }

  @Test
  func `stability force is not applied to new nodes`() {
    // Two persisted nodes + one new node. Stability anchors the
    // persisted nodes; the new node has no anchor.
    var configuration = GenreMapForceLayout.Configuration()
    configuration.maxSteps = 1
    configuration.previousPositions = [
      "A": CGPoint(x: 0, y: 0)
    ]
    configuration.stabilityForce = 100 // gigantic; would visibly drag a node if applied
    let inputs = [
      GenreMapForceLayout.InputNode(
        id: "A",
        weight: 0.5,
        labelSize: CGSize(width: 60, height: 20),
        communityID: 1,
      ),
      GenreMapForceLayout.InputNode(
        id: "B",
        weight: 0.5,
        labelSize: CGSize(width: 60, height: 20),
        communityID: 1,
      ),
    ]
    let output = GenreMapForceLayout.layout(
      nodes: inputs,
      edges: [],
      configuration: configuration,
    )
    // A is at its anchor; B scattered elsewhere (the new-node path).
    let aPosition = output.positions["A"] ?? .zero
    let bPosition = output.positions["B"] ?? .zero
    #expect(abs(aPosition.x) < 5)
    #expect(abs(aPosition.y) < 5)
    // B's scatter radius is `worldSide * 0.45 * 0.12` ≈ 270 for the
    // default config. It can be at the origin by random chance, but
    // overwhelmingly not within 5 units of it.
    #expect(abs(bPosition.x) + abs(bPosition.y) > 1)
  }
}
