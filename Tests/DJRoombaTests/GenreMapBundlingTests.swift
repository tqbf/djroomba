import CoreGraphics
import Foundation
import Testing
@testable import DJRoomba

/// Pure-logic tests for `GenreMapBundling` (`plans/genre-metro-map.md`
/// Phase 4, step 3 + step 4). Hand-built fixtures small enough to
/// compute by hand. Same posture as the routing tests above.
struct GenreMapBundlingTests {

  /// Two strands sharing 3 consecutive cells are bundled into ONE
  /// corridor; each gets a symmetric offset slot (±centred so the
  /// corridor centerline stays at the A* line).
  @Test
  func `two strands sharing three cells form one corridor`() {
    let sharedCells: Set = [
      GenreMapRouting.GridCell(column: 5, row: 0),
      GenreMapRouting.GridCell(column: 5, row: 1),
      GenreMapRouting.GridCell(column: 5, row: 2),
    ]
    var lhsCells = sharedCells
    lhsCells.insert(GenreMapRouting.GridCell(column: 4, row: 0))
    var rhsCells = sharedCells
    rhsCells.insert(GenreMapRouting.GridCell(column: 6, row: 0))
    let routed = [
      GenreMapRouting.RoutedStrandPath(
        strandID: 0,
        polyline: [
          CGPoint(x: 200, y: 0),
          CGPoint(x: 275, y: 50),
          CGPoint(x: 275, y: 125),
          CGPoint(x: 275, y: 200),
        ],
        occupiedCells: lhsCells,
      ),
      GenreMapRouting.RoutedStrandPath(
        strandID: 1,
        polyline: [
          CGPoint(x: 350, y: 0),
          CGPoint(x: 275, y: 50),
          CGPoint(x: 275, y: 125),
          CGPoint(x: 275, y: 200),
        ],
        occupiedCells: rhsCells,
      ),
    ]
    let result = GenreMapBundling.bundle(
      routed: routed,
      memberGenresByStrand: [0: ["A"], 1: ["B"]],
    )
    #expect(result.corridorCount == 1)
    #expect(result.bundledCorridorCount == 1)
    #expect(result.maxStrandsPerCorridor == 2)
    // Both share the same corridor id (0); slots are symmetric (-0, +1
    // for an even pair => slots {-0, 1} or equivalently {0, 1} after
    // the centring formula). The exact slot values aren't pinned; what
    // matters is they differ AND aren't both 0.
    let strandLhs = try? #require(result.bundled.first { $0.strandID == 0 })
    let strandRhs = try? #require(result.bundled.first { $0.strandID == 1 })
    #expect(strandLhs?.corridorID == strandRhs?.corridorID)
    #expect(strandLhs?.slot != strandRhs?.slot)
    #expect(strandLhs?.isBundled == true)
    #expect(strandRhs?.isBundled == true)
  }

  /// Two strands sharing only 1 cell do NOT bundle (below the
  /// `minSharedCells = 3` floor). Each is its own corridor.
  @Test
  func `single overlapping cell does not form a corridor`() {
    let routed = [
      GenreMapRouting.RoutedStrandPath(
        strandID: 0,
        polyline: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100)],
        occupiedCells: [
          GenreMapRouting.GridCell(column: 0, row: 0),
          GenreMapRouting.GridCell(column: 1, row: 1),
          GenreMapRouting.GridCell(column: 2, row: 2),
        ],
      ),
      GenreMapRouting.RoutedStrandPath(
        strandID: 1,
        polyline: [CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 100)],
        occupiedCells: [
          GenreMapRouting.GridCell(column: 2, row: 2),
          GenreMapRouting.GridCell(column: 3, row: 3),
          GenreMapRouting.GridCell(column: 4, row: 4),
        ],
      ),
    ]
    let result = GenreMapBundling.bundle(
      routed: routed,
      memberGenresByStrand: [0: ["A"], 1: ["B"]],
    )
    #expect(result.corridorCount == 2)
    #expect(result.bundledCorridorCount == 0)
    #expect(result.maxStrandsPerCorridor == 1)
    // Cell (2,2) is shared but the strands aren't bundled (1 cell <
    // minSharedCells=3), so it counts as a crossing.
    #expect(result.crossingCount == 1)
  }

  /// Five strands sharing the same corridor cells get five distinct
  /// offset slots — the five-colour benchmark from
  /// `plans/genre-metro-map.md` Phase 4 step 3.
  @Test
  func `five strands sharing a corridor get five distinct slots`() {
    let corridor = Set((0 ..< 5).map { row in
      GenreMapRouting.GridCell(column: 5, row: row)
    })
    var routed = [GenreMapRouting.RoutedStrandPath]()
    for strandID in 0 ..< 5 {
      routed.append(GenreMapRouting.RoutedStrandPath(
        strandID: strandID,
        polyline: [
          CGPoint(x: 275, y: 0),
          CGPoint(x: 275, y: 125),
          CGPoint(x: 275, y: 250),
        ],
        occupiedCells: corridor.union([
          // Each strand gets one unique cell so its set isn't a strict
          // subset of another (bundling still triggers on the shared
          // corridor count alone).
          GenreMapRouting.GridCell(column: strandID, row: -1)
        ]),
      ))
    }
    let members = Dictionary(
      uniqueKeysWithValues: (0 ..< 5).map { (Int($0), Set<String>(["S\($0)"])) }
    )
    let result = GenreMapBundling.bundle(
      routed: routed,
      memberGenresByStrand: members,
    )
    #expect(result.maxStrandsPerCorridor == 5)
    #expect(result.bundledCorridorCount == 1)
    let slots = result.bundled.map(\.slot)
    let uniqueSlots = Set(slots)
    #expect(uniqueSlots.count == 5, "expected five distinct slots, got \(slots)")
    // Slots are symmetric around 0 for 5 entries: {-2, -1, 0, 1, 2}.
    #expect(Set(slots) == Set([-2, -1, 0, 1, 2]))
  }

  /// Offset application: a slot != 0 shifts interior polyline points
  /// perpendicular to the local tangent; endpoints stay attached to
  /// the original station positions.
  @Test
  func `perpendicular offset preserves endpoints and shifts interior`() {
    let polyline = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 100, y: 0),
    ]
    let offset = GenreMapBundling.applyPerpendicularOffset(
      polyline: polyline,
      slot: 1,
      offsetStep: 6,
    )
    #expect(offset.count == 3)
    #expect(offset.first == polyline.first)
    #expect(offset.last == polyline.last)
    // Tangent is along +x; perpendicular is along +y (rotation 90°).
    // The interior point shifts by +6 along y.
    #expect(offset[1].x == 50)
    #expect(offset[1].y == 6)
  }

  /// Slot 0 ⇒ no offset (a corridor of size 1 keeps the original
  /// polyline byte-identical).
  @Test
  func `slot zero applies no offset`() {
    let polyline = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 100, y: 0),
    ]
    let offset = GenreMapBundling.applyPerpendicularOffset(
      polyline: polyline,
      slot: 0,
      offsetStep: 6,
    )
    #expect(offset == polyline)
  }
}
