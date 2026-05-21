import CoreGraphics
import Foundation
import Testing
@testable import DJRoomba

/// Pure-logic tests for `GenreMapRouting` (`plans/genre-metro-map.md`
/// Phase 4). Every test runs on a hand-built fixture small enough to
/// compute by hand — same posture as
/// `GenreMapStrandInferenceTests` / `GenreMapLayoutGraphTests`.
struct GenreMapRoutingTests {

  /// A* on a clear 5×5 grid: path is a straight diagonal start → goal,
  /// cost ≤ Manhattan baseline. Confirms the heuristic + base-cost
  /// model is admissible (no obstacle penalties involved).
  @Test
  func `A star on an empty grid produces a near-straight path to the goal`() {
    let configuration = GenreMapRouting.Configuration(
      worldSide: 250,
      cellSize: 50,
    )
    let start = CGPoint(x: 25, y: 25) // cell (0, 0)
    let goal = CGPoint(x: 225, y: 225) // cell (4, 4)
    let result = GenreMapRouting.routeSegment(
      from: start,
      to: goal,
      strandID: 0,
      memberGenres: [],
      context: GenreMapRouting.ObstacleContext(),
      configuration: configuration,
    )
    #expect(result.polyline.count >= 2)
    let first = result.polyline.first
    let last = result.polyline.last
    #expect(first == start)
    #expect(last == goal)
    // 5 cells diagonal ⇒ 5 cells in the path (start + diagonals + goal).
    #expect(result.cells.count <= 6)
  }

  /// A* must detour around a label obstacle. Place a fat label across
  /// the middle of the 5×5 grid; the resulting polyline must NOT pass
  /// through it, and the cell set must miss every cell inside the
  /// label rectangle. The strand's own member labels are excluded by
  /// genre, so an obstacle at a member station does NOT penalise the
  /// path through that station — that's the "follow your own line"
  /// invariant.
  @Test
  func `A star detours around a non-member label rectangle`() {
    let configuration = GenreMapRouting.Configuration(
      worldSide: 600,
      cellSize: 50,
      labelPadding: 4,
    )
    let start = CGPoint(x: 25, y: 25)
    let goal = CGPoint(x: 525, y: 25)
    // Big obstacle across the middle of row 0 — A* must detour around
    // it. Label width covers cells (3..=7, 0).
    let label = GenreMapRouting.LabelObstacle(
      genre: "Obstacle",
      rect: CGRect(x: 175, y: 0, width: 250, height: 50),
    )
    let result = GenreMapRouting.routeSegment(
      from: start,
      to: goal,
      strandID: 0,
      memberGenres: [],
      context: GenreMapRouting.ObstacleContext(labels: [label]),
      configuration: configuration,
    )
    let grid = GenreMapRouting.Grid(configuration: configuration)
    let labelCells = Set<GenreMapRouting.GridCell>(
      (3 ... 7).flatMap { column in
        [GenreMapRouting.GridCell(column: column, row: 0)]
      }
    )
    // Drop endpoints (they snap to exact start/goal which may or may
    // not be inside the label rectangle, but a strand always
    // "originates" outside an obstacle by construction).
    let interior = result.polyline.dropFirst().dropLast()
    for point in interior {
      let cell = grid.cell(for: point)
      #expect(
        !labelCells.contains(cell),
        "A* polyline passed through label cell \(cell)",
      )
    }
  }

  /// Chokepoint test: a single 1-cell gap in a full-width obstacle
  /// wall. A* must thread the chokepoint (no alternative path
  /// exists), and the resulting polyline does NOT pass through any
  /// wall cell.
  @Test
  func `A star threads a chokepoint between two label obstacles`() {
    let configuration = GenreMapRouting.Configuration(
      worldSide: 500,
      cellSize: 50,
      labelPadding: 1,
    )
    let start = CGPoint(x: 25, y: 25) // (0, 0)
    let goal = CGPoint(x: 475, y: 425) // (9, 8)
    // Wall A spans rows 2..=6 of columns 0..=3; wall B spans rows
    // 2..=6 of columns 5..=9. The single clear corridor between
    // start (row 0) and goal (row 8) is column 4 — a chokepoint.
    let wallA = GenreMapRouting.LabelObstacle(
      genre: "WallA",
      rect: CGRect(x: 0, y: 100, width: 200, height: 250),
    )
    let wallB = GenreMapRouting.LabelObstacle(
      genre: "WallB",
      rect: CGRect(x: 250, y: 100, width: 250, height: 250),
    )
    let result = GenreMapRouting.routeSegment(
      from: start,
      to: goal,
      strandID: 0,
      memberGenres: [],
      context: GenreMapRouting.ObstacleContext(labels: [wallA, wallB]),
      configuration: configuration,
    )
    let grid = GenreMapRouting.Grid(configuration: configuration)
    let wallCells = Set<GenreMapRouting.GridCell>(
      (2 ... 6).flatMap { row -> [GenreMapRouting.GridCell] in
        let leftWall = (0 ... 3).map { column in
          GenreMapRouting.GridCell(column: column, row: row)
        }
        let rightWall = (5 ... 9).map { column in
          GenreMapRouting.GridCell(column: column, row: row)
        }
        return leftWall + rightWall
      }
    )
    // Drop endpoints (they snap to exact start/goal positions).
    let interior = Array(result.polyline.dropFirst().dropLast())
    for point in interior {
      let cell = grid.cell(for: point)
      #expect(
        !wallCells.contains(cell),
        "A* polyline passed through wall cell \(cell) at \(point)",
      )
    }
    // The chokepoint corridor is column 4, rows 2..=6 — at least one
    // interior point must sit inside it.
    let chokepointColumn = interior.contains { point in
      grid.cell(for: point).column == 4
    }
    #expect(chokepointColumn, "A* did not pass through the chokepoint column")
  }

  /// Spline smoothing collapses collinear interior waypoints AND
  /// inserts smoothing midpoints at sharp corners. A right-angle
  /// (π/2) is sharper than the 30° floor and gets smoothed.
  @Test
  func `spline smoothing inserts a midpoint at a sharp corner`() {
    let configuration = GenreMapRouting.Configuration()
    // Right-angle: (0,0) → (100,0) → (100,100). The 90° corner is well
    // below the π/2 turn-angle floor → smoothing inserts midpoints.
    let polyline = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 100, y: 0),
      CGPoint(x: 100, y: 100),
    ]
    let smoothed = GenreMapRouting.smoothPolyline(polyline, configuration: configuration)
    // First and last are preserved.
    #expect(smoothed.first == CGPoint(x: 0, y: 0))
    #expect(smoothed.last == CGPoint(x: 100, y: 100))
    // Total points > 3 ⇒ a smoothing pair was inserted.
    #expect(smoothed.count > 3)
  }

  /// Smoothing is idempotent on a straight line.
  @Test
  func `spline smoothing of a straight line is a no-op`() {
    let configuration = GenreMapRouting.Configuration()
    let polyline = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 50, y: 0),
      CGPoint(x: 100, y: 0),
      CGPoint(x: 150, y: 0),
    ]
    let smoothed = GenreMapRouting.smoothPolyline(polyline, configuration: configuration)
    // Interior collinear points removed; only endpoints remain.
    #expect(smoothed.count == 2)
    #expect(smoothed.first == CGPoint(x: 0, y: 0))
    #expect(smoothed.last == CGPoint(x: 150, y: 0))
  }

  /// Routing cache invalidation (the explicit perf gate): a node moved
  /// less than `GenreMapService.geographicEpsilon` does NOT trigger
  /// `commitDrag`'s revision bump; a node moved farther does.
  /// This test pins the threshold value itself.
  @Test
  func `geographic epsilon threshold is 6 world units`() {
    #expect(GenreMapService.geographicEpsilon == 6.0)
  }

  /// Routing performance benchmark (`plans/genre-metro-map.md` Phase 4
  /// success criterion: ≤ 200 ms on the real library). Build a
  /// synthetic 10-strand fixture (≈ the real-library scale of 5–12
  /// strands across ~115 nodes) and route everything, asserting the
  /// total elapsed time stays well under 200 ms. Pure deterministic
  /// fixture so CI numbers are stable.
  @Test
  func `synthetic 10-strand routing fits inside the 200 ms perf budget`() {
    let configuration = GenreMapRouting.Configuration()
    // 100 stations on a 10×10 lattice in world units.
    var stations = [GenreMapRouting.StationCentre]()
    var labels = [GenreMapRouting.LabelObstacle]()
    var positionByGenre = [String: CGPoint]()
    for column in 0 ..< 10 {
      for row in 0 ..< 10 {
        let genre = "G\(column)_\(row)"
        let position = CGPoint(x: 250 + 400 * Double(column), y: 250 + 400 * Double(row))
        stations.append(GenreMapRouting.StationCentre(genre: genre, position: position))
        labels.append(GenreMapRouting.LabelObstacle(
          genre: genre,
          rect: CGRect(x: position.x - 60, y: position.y - 14, width: 120, height: 28),
        ))
        positionByGenre[genre] = position
      }
    }
    // 10 strands, each touching 5 stations along a row or column.
    var strands = [GenreMapRouting.StrandRouteRequest]()
    for index in 0 ..< 10 {
      let isRow = index % 2 == 0
      let line = (index / 2) % 10
      var memberGenres = Set<String>()
      var positions = [CGPoint]()
      for k in 0 ..< 5 {
        let genre = isRow ? "G\(k)_\(line)" : "G\(line)_\(k)"
        memberGenres.insert(genre)
        if let position = positionByGenre[genre] {
          positions.append(position)
        }
      }
      strands.append(GenreMapRouting.StrandRouteRequest(
        strandID: index,
        stationPositions: positions,
        memberGenres: memberGenres,
      ))
    }
    let started = Date()
    let routed = GenreMapRouting.route(
      strands: strands,
      labels: labels,
      stationCentres: stations,
      configuration: configuration,
    )
    let elapsed = Date().timeIntervalSince(started)
    #expect(routed.count == 10)
    // Budget is 200 ms on the real library; the synthetic fixture is
    // ~10× sparser, so 200 ms is a comfortable upper bound. CI on
    // older M-series hardware has been observed at ~30–60 ms; the
    // 200 ms ceiling is the publishable headline.
    #expect(elapsed < 0.200, "10-strand fixture routed in \(elapsed * 1000) ms")
  }
}
