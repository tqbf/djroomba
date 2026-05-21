import CoreGraphics
import Foundation

// MARK: - GenreMapRouting

/// Obstacle-aware metro-strand routing for the genre map
/// (`plans/genre-metro-map.md` Phase 4). Pure Swift — no SwiftUI, no
/// observation, no globals; deterministic given identical inputs and
/// fully unit-testable end-to-end on a fixture.
///
/// Pipeline (each step is its own static function so tests can pin it
/// in isolation):
///
/// 1. **Obstacle map.** Discretise the world (default 5000×5000) onto
///    a coarse grid (default 100×100, 50pt cells). Each cell carries a
///    base traversal cost + a penalty if the cell intersects a station
///    label rectangle (padded). Stations that BELONG to a strand are
///    not obstacles for that strand.
/// 2. **A\* search** from the strand's first station's cell to its last
///    station's cell, with 8-way connectivity and the cost terms below.
///    Returns a sequence of waypoint cells; convert to world coordinates
///    at cell centres + snap the endpoints to the exact station positions.
/// 3. **Spline relaxation.** Cull collinear waypoints; enforce a
///    minimum-turn-angle floor by inserting a midpoint when a corner is
///    sharper than the floor.
///
/// Cost terms (per traversed cell):
/// - `baseCost` (~ Euclidean cell-to-cell distance);
/// - `labelPenalty` if the cell is inside a non-member label box;
/// - `proximityPenalty` if the cell is within `proximityPadding` of a
///   non-member station's centre;
/// - `crossingPenalty` if the cell is on another strand's already-routed
///   path (cell-bucketed). Crossings at member-cells of *both* strands
///   (transfer stations) get a discount;
/// - `turnPenalty` for direction changes (modeled as a per-step cost
///   addition when the incoming-vs-outgoing direction differs).
///
/// Phase 4 is rendered after this; the resulting `RoutedStrand` carries
/// the obstacle-aware polyline and the strand's `corridorID` + offset
/// (assigned by `GenreMapBundling`).
enum GenreMapRouting {

  // MARK: Internal

  /// Tunable cost configuration. Defaults pinned to the Phase-4
  /// success-criteria gate (no strand passes through a label; routing
  /// runs ≤ 200 ms on the real library).
  struct Configuration: Sendable {
    /// World side length (must match `GenreMapForceLayout.Configuration`).
    /// Used to size the obstacle grid.
    var worldSide: CGFloat = 5000
    /// Grid cell size in world units. 50pt at `worldSide = 5000`
    /// gives a 100×100 grid — bounded `O(n_cells · log n_cells)` A*
    /// per strand.
    var cellSize: CGFloat = 50
    /// Extra padding around each label box (world units). The label is
    /// authoritative; this padding builds a no-go halo so splines stay
    /// clear of the pill chrome and the downstream centripetal Catmull-
    /// Rom has room to round corners without re-entering the obstacle
    /// (the Phase-4 REDO fix, 2026-05-21). 12pt is the Pareto point
    /// found on the live library: large enough that A\* picks cells
    /// well outside the label rect, small enough that the obstacle map
    /// doesn't blow past the 200 ms routing budget.
    var labelPadding: CGFloat = 12
    /// Penalty added to a cell that intersects a non-member label box.
    /// Two orders of magnitude above `baseCost` so the search reliably
    /// detours around labels.
    var labelPenalty: Double = 1000
    /// Cells within this radius of a non-member station centre get a
    /// soft proximity penalty (taper from 1× → 0× of `proximityPenalty`).
    var proximityPadding: CGFloat = 40
    var proximityPenalty: Double = 80
    /// Penalty when a cell is shared with another already-routed strand
    /// that isn't bundled with this one. Tuned so the search prefers
    /// detouring through a clear cell to crossing a strand.
    var crossingPenalty: Double = 60
    /// Crossings at a member-of-both-strands cell (a transfer station)
    /// pay this much instead of `crossingPenalty`. Eye reads them as
    /// "intentional" knots.
    var transferCrossingPenalty: Double = 10
    /// Per-corner turn penalty (added on direction change).
    var turnPenalty: Double = 25
    /// Maximum deflection (radians) the smoothed polyline is allowed
    /// to bend at any interior waypoint. Corners that bend MORE than
    /// this get a fillet pair inserted bracketing the corner.
    /// 30° = "the polyline never kinks at more than a third of a
    /// right angle without a curve".
    var maxDeflection = 0.5235988 // 30°
    /// Fraction of each leg to walk back from a sharp corner when
    /// inserting fillet waypoints. 0.25 ⇒ the leadIn / leadOut sit
    /// ¼ of the leg distance from the corner. Centripetal CR through
    /// `[leadIn, corner, leadOut]` traces a smooth bend without
    /// leaving the A\* waypoint hull (the Phase-4 REDO fix,
    /// 2026-05-21 — the previous "replace the corner with two
    /// midpoints" approach removed the corner from the polyline and
    /// drew a diagonal cut that re-entered labels A\* had detoured
    /// around).
    var cornerFilletFraction = 0.25
    /// Hard cap on A* expansions per strand (defensive — should never
    /// be hit at real-library scale).
    var maxExpansions = 100_000
  }

  /// One strand's input: ordered stations + the set of cells the strand
  /// "owns" (so its own member labels are not obstacles for it).
  struct StrandRouteRequest: Equatable, Sendable {
    var strandID: Int
    /// Ordered station world positions (the Catmull-Rom anchors from
    /// Phase 3). Length ≥ 2; A* connects consecutive station cells with
    /// independent search runs so each segment can detour without
    /// dragging the whole strand off course.
    var stationPositions: [CGPoint]
    /// Member-station genre names — used by the obstacle map to exclude
    /// the strand's own labels from penalised cells.
    var memberGenres: Set<String>
  }

  /// The shared obstacle context for one routing pass — labels, station
  /// positions, and (during multi-strand passes) the already-routed
  /// cell paths of earlier strands.
  struct ObstacleContext: Sendable {
    init(
      labels: [LabelObstacle] = [],
      stationCentres: [StationCentre] = [],
      routedCellsByStrand: [Int: Set<GridCell>] = [:],
      memberGenresByStrand: [Int: Set<String>] = [:],
    ) {
      self.labels = labels
      self.stationCentres = stationCentres
      self.routedCellsByStrand = routedCellsByStrand
      self.memberGenresByStrand = memberGenresByStrand
    }

    var labels: [LabelObstacle]
    var stationCentres: [StationCentre]
    var routedCellsByStrand: [Int: Set<GridCell>]
    /// Map from strand id ⇒ the strand's member-genre set (for the
    /// transfer-station crossing discount).
    var memberGenresByStrand: [Int: Set<String>]

  }

  struct LabelObstacle: Equatable, Sendable {
    var genre: String
    var rect: CGRect
  }

  struct StationCentre: Equatable, Sendable {
    var genre: String
    var position: CGPoint
  }

  /// A grid cell index (column, row). Equatable + Hashable so it can
  /// key a `Set` for crossing detection.
  struct GridCell: Hashable, Sendable {
    var column: Int
    var row: Int
  }

  /// Output of one strand's routing run.
  struct RoutedStrandPath: Equatable, Sendable {
    var strandID: Int
    /// World-space polyline (snapped to the strand's exact station
    /// positions at each end of each segment).
    var polyline: [CGPoint]
    /// Cells the polyline occupies (for the next strand's crossing-
    /// penalty bookkeeping).
    var occupiedCells: Set<GridCell>
  }

  /// World-grid conversion helper.
  struct Grid: Sendable {

    // MARK: Lifecycle

    init(configuration: Configuration) {
      cellSize = configuration.cellSize
      let cellsPerSide = Int(ceil(Double(configuration.worldSide / configuration.cellSize)))
      self.cellsPerSide = max(1, cellsPerSide)
    }

    // MARK: Internal

    var cellSize: CGFloat
    var cellsPerSide: Int

    /// Cell containing `point`. Coordinates can fall outside the
    /// nominal world bounds (the layout doesn't clip), so the column
    /// / row may be negative or > cellsPerSide; the A* search simply
    /// uses them as integer indices (no clipping needed).
    func cell(for point: CGPoint) -> GridCell {
      let column = Int((point.x / cellSize).rounded(.down))
      let row = Int((point.y / cellSize).rounded(.down))
      return GridCell(column: column, row: row)
    }

    /// World-space centre of a cell.
    func centre(of cell: GridCell) -> CGPoint {
      CGPoint(
        x: (CGFloat(cell.column) + 0.5) * cellSize,
        y: (CGFloat(cell.row) + 0.5) * cellSize,
      )
    }

  }

  /// Pure entry: route all strands sequentially, using the prior
  /// strands' cell paths to bias the next strand's crossing penalty.
  /// Strands are routed in the caller's order (the caller sorts by
  /// rank-score so heavier strands route first into less-crowded
  /// space). Returns one `RoutedStrandPath` per input, same order.
  static func route(
    strands: [StrandRouteRequest],
    labels: [LabelObstacle],
    stationCentres: [StationCentre],
    configuration: Configuration = Configuration(),
  ) -> [RoutedStrandPath] {
    guard !strands.isEmpty else { return [] }
    var context = ObstacleContext(
      labels: labels,
      stationCentres: stationCentres,
      memberGenresByStrand: Dictionary(
        uniqueKeysWithValues: strands.map { ($0.strandID, $0.memberGenres) }
      ),
    )
    var routed = [RoutedStrandPath]()
    routed.reserveCapacity(strands.count)
    for strand in strands {
      let path = routeOne(
        request: strand,
        context: context,
        configuration: configuration,
      )
      context.routedCellsByStrand[strand.strandID] = path.occupiedCells
      routed.append(path)
    }
    return routed
  }

  /// Route one strand. Each consecutive station pair is searched
  /// independently; results are concatenated (no duplicate of the
  /// shared station between segments).
  ///
  /// **Phase-4 REDO (2026-05-21):** the per-segment `buildCostMap` call
  /// is hoisted to per-STRAND — the obstacle / proximity / crossing-
  /// penalty map only depends on the calling strand's `memberGenres`,
  /// not on which station pair is being routed inside it. On a real
  /// 12-strand × 115-station library that's a ~5× cost-map rebuild
  /// savings (one rebuild per strand instead of one per segment).
  static func routeOne(
    request: StrandRouteRequest,
    context: ObstacleContext,
    configuration: Configuration = Configuration(),
  ) -> RoutedStrandPath {
    guard request.stationPositions.count >= 2 else {
      return RoutedStrandPath(
        strandID: request.strandID,
        polyline: request.stationPositions,
        occupiedCells: [],
      )
    }
    let grid = Grid(configuration: configuration)
    let costMap = buildCostMap(
      strandID: request.strandID,
      memberGenres: request.memberGenres,
      grid: grid,
      context: context,
      configuration: configuration,
    )
    var polyline = [CGPoint]()
    var occupied = Set<GridCell>()
    polyline.append(request.stationPositions[0])
    for index in 0 ..< request.stationPositions.count - 1 {
      let from = request.stationPositions[index]
      let to = request.stationPositions[index + 1]
      let segment = routeSegmentWithCostMap(
        from: from,
        to: to,
        grid: grid,
        costMap: costMap,
        configuration: configuration,
      )
      // Drop the duplicated shared endpoint between consecutive segments.
      let appendRange = segment.polyline.dropFirst()
      polyline.append(contentsOf: appendRange)
      occupied.formUnion(segment.cells)
    }
    let smoothed = smoothPolyline(polyline, configuration: configuration)
    return RoutedStrandPath(
      strandID: request.strandID,
      polyline: smoothed,
      occupiedCells: occupied,
    )
  }

  /// Pure A\* search between two world-space points using a
  /// pre-computed `costMap`. Tests call `routeSegment` which builds
  /// the cost map inline; the multi-segment hot path
  /// (`GenreMapRouting.routeOne`) hoists the build to per-strand.
  static func routeSegmentWithCostMap(
    from start: CGPoint,
    to goal: CGPoint,
    grid: Grid,
    costMap: [GridCell: Double],
    configuration: Configuration,
  ) -> (polyline: [CGPoint], cells: Set<GridCell>) {
    let startCell = grid.cell(for: start)
    let goalCell = grid.cell(for: goal)
    if startCell == goalCell {
      return (polyline: [start, goal], cells: [startCell])
    }
    let path = aStar(
      start: startCell,
      goal: goalCell,
      costMap: costMap,
      configuration: configuration,
    )
    guard !path.isEmpty else {
      return (polyline: [start, goal], cells: [startCell, goalCell])
    }
    var polyline = [CGPoint]()
    polyline.reserveCapacity(path.count + 2)
    polyline.append(start)
    for index in 1 ..< path.count - 1 {
      polyline.append(grid.centre(of: path[index]))
    }
    polyline.append(goal)
    return (polyline: polyline, cells: Set(path))
  }

  /// Pure A* search between two world-space points (snapped to grid
  /// cells). Public for the per-segment fixture tests.
  static func routeSegment(
    from start: CGPoint,
    to goal: CGPoint,
    strandID: Int,
    memberGenres: Set<String>,
    context: ObstacleContext,
    configuration: Configuration = Configuration(),
  ) -> (polyline: [CGPoint], cells: Set<GridCell>) {
    let grid = Grid(configuration: configuration)
    let startCell = grid.cell(for: start)
    let goalCell = grid.cell(for: goal)
    if startCell == goalCell {
      return (polyline: [start, goal], cells: [startCell])
    }
    // Precompute non-member label cells / station cells / crossing cells
    // for cheap O(1) cost lookup in the inner loop.
    let costMap = buildCostMap(
      strandID: strandID,
      memberGenres: memberGenres,
      grid: grid,
      context: context,
      configuration: configuration,
    )
    let path = aStar(
      start: startCell,
      goal: goalCell,
      costMap: costMap,
      configuration: configuration,
    )
    guard !path.isEmpty else {
      // Disconnected ⇒ fall back to a direct line. Phase 4 should never
      // hit this on a real library (cells outside the world bounds get
      // padded base cost only); kept defensive.
      return (polyline: [start, goal], cells: [startCell, goalCell])
    }
    var polyline = [CGPoint]()
    polyline.reserveCapacity(path.count + 2)
    polyline.append(start)
    // Append every interior cell centre EXCEPT the first and last —
    // those snap to the exact station positions to keep splines
    // attached to the pills.
    for index in 1 ..< path.count - 1 {
      polyline.append(grid.centre(of: path[index]))
    }
    polyline.append(goal)
    return (polyline: polyline, cells: Set(path))
  }

  /// Pure A* on the grid. Returns the cell sequence start → goal
  /// (inclusive). Empty when unreachable.
  static func aStar(
    start: GridCell,
    goal: GridCell,
    costMap: [GridCell: Double],
    configuration: Configuration,
  ) -> [GridCell] {
    var open = MinHeap<AStarNode>()
    open.push(AStarNode(cell: start, gScore: 0, fScore: heuristic(from: start, to: goal)))
    var cameFrom = [GridCell: GridCell]()
    var gScore: [GridCell: Double] = [start: 0]
    var expansions = 0
    while let node = open.pop() {
      if node.cell == goal {
        return reconstructPath(cameFrom: cameFrom, current: goal)
      }
      expansions += 1
      if expansions >= configuration.maxExpansions { break }
      for neighbour in neighbours(of: node.cell) {
        let stepCost = baseCost(from: node.cell, to: neighbour)
          + (costMap[neighbour] ?? 0)
        // Turn penalty: add when direction changes.
        var turn = 0.0
        if let parent = cameFrom[node.cell] {
          if directionDelta(parent: parent, current: node.cell, next: neighbour) {
            turn = configuration.turnPenalty
          }
        }
        let tentative = node.gScore + stepCost + turn
        if tentative < (gScore[neighbour] ?? .infinity) {
          gScore[neighbour] = tentative
          cameFrom[neighbour] = node.cell
          open.push(AStarNode(
            cell: neighbour,
            gScore: tentative,
            fScore: tentative + heuristic(from: neighbour, to: goal),
          ))
        }
      }
    }
    return []
  }

  /// Build the per-cell extra-cost map for one strand. Pure read of the
  /// context; bounded to cells whose obstacle/penalty actually fires
  /// (sparse — most cells are clear).
  static func buildCostMap(
    strandID: Int,
    memberGenres: Set<String>,
    grid: Grid,
    context: ObstacleContext,
    configuration: Configuration,
  ) -> [GridCell: Double] {
    var costs = [GridCell: Double]()
    // Label cells (penalty for non-member labels).
    for label in context.labels where !memberGenres.contains(label.genre) {
      let padded = label.rect.insetBy(
        dx: -configuration.labelPadding,
        dy: -configuration.labelPadding,
      )
      let minCell = grid.cell(for: CGPoint(x: padded.minX, y: padded.minY))
      let maxCell = grid.cell(for: CGPoint(x: padded.maxX, y: padded.maxY))
      for column in minCell.column ... maxCell.column {
        for row in minCell.row ... maxCell.row {
          let cell = GridCell(column: column, row: row)
          costs[cell, default: 0] += configuration.labelPenalty
        }
      }
    }
    // Proximity to non-member station centres (soft taper).
    let proximityCells = Int(
      (configuration.proximityPadding / configuration.cellSize).rounded(.up)
    )
    for centre in context.stationCentres where !memberGenres.contains(centre.genre) {
      let here = grid.cell(for: centre.position)
      for dColumn in -proximityCells ... proximityCells {
        for dRow in -proximityCells ... proximityCells {
          let cell = GridCell(column: here.column + dColumn, row: here.row + dRow)
          let centreOfCell = grid.centre(of: cell)
          let dx = centreOfCell.x - centre.position.x
          let dy = centreOfCell.y - centre.position.y
          let distance = sqrt(dx * dx + dy * dy)
          if distance <= configuration.proximityPadding {
            let taper = 1.0 - Double(distance / configuration.proximityPadding)
            costs[cell, default: 0] += taper * configuration.proximityPenalty
          }
        }
      }
    }
    // Crossing penalty for cells already used by other strands.
    // **Phase-4 REDO (2026-05-21):** precompute the genre→cell map so
    // the inner `isTransferCell` check is `O(|bothMembers|)` instead of
    // `O(|stationCentres| × |bothMembers|)` — the live-library hot path
    // on a 12-strand × 115-station library; the previous shape pegged
    // the routing budget at multiple seconds.
    var cellByGenre = [String: GridCell](minimumCapacity: context.stationCentres.count)
    for centre in context.stationCentres {
      cellByGenre[centre.genre] = grid.cell(for: centre.position)
    }
    for (otherStrandID, cells) in context.routedCellsByStrand
      where otherStrandID != strandID
    {
      let otherMembers = context.memberGenresByStrand[otherStrandID] ?? []
      let bothMembers = memberGenres.intersection(otherMembers)
      // Cells that contain a transfer station (member of both strands).
      var transferCells = Set<GridCell>(minimumCapacity: bothMembers.count)
      for genre in bothMembers {
        if let cell = cellByGenre[genre] {
          transferCells.insert(cell)
        }
      }
      for cell in cells {
        costs[cell, default: 0] += transferCells.contains(cell)
          ? configuration.transferCrossingPenalty
          : configuration.crossingPenalty
      }
    }
    return costs
  }

  /// Smooth a polyline: remove collinear interior points; if a corner
  /// is sharper than `configuration.maxDeflection`, insert a pair of
  /// fillet points BRACKETING the corner so centripetal Catmull-Rom
  /// rounds the corner without bulging into the obstacle the A\* run
  /// was routing around. Idempotent.
  ///
  /// **Phase-4 REDO (2026-05-21):** the previous implementation
  /// replaced the corner waypoint with its `(prev+cur)/2` and
  /// `(cur+next)/2` midpoints — that REMOVED the corner from the
  /// polyline and drew a diagonal cut across it, which (a) made the
  /// metro line skip its intermediate stations and (b) was the actual
  /// source of strand-through-label crossings observed in the
  /// rejection screenshot (the diagonal cut between leadIn and
  /// leadOut sliced through neighbouring label rectangles A\* had
  /// painstakingly routed around). Fix: keep the corner; insert
  /// fillets at a configurable short distance away from the corner
  /// along each leg, so centripetal CR through `[leadIn, corner,
  /// leadOut]` traces a clean rounded turn that stays close to the
  /// A\*-chosen waypoints.
  static func smoothPolyline(
    _ points: [CGPoint],
    configuration: Configuration,
  ) -> [CGPoint] {
    guard points.count >= 3 else { return points }
    // 1) Collinearity cull (cheap — removes corners introduced by the
    // grid step that aren't real direction changes).
    var culled = [CGPoint]()
    culled.reserveCapacity(points.count)
    culled.append(points[0])
    for index in 1 ..< points.count - 1 {
      let previous = culled[culled.count - 1]
      let current = points[index]
      let next = points[index + 1]
      if abs(crossProduct(previous, current, next)) > 1.0 {
        culled.append(current)
      }
    }
    culled.append(points[points.count - 1])
    // 2) Deflection floor — at any corner sharper than `maxDeflection`,
    // insert fillet waypoints on either side of the corner along each
    // leg. The corner itself stays in the polyline; the centripetal
    // Catmull-Rom downstream renders a smooth bend through
    // `[leadIn, corner, leadOut]` without leaving the A* waypoint hull.
    let filletFraction = configuration.cornerFilletFraction
    var smoothed = [CGPoint]()
    smoothed.reserveCapacity(culled.count * 2)
    smoothed.append(culled[0])
    for index in 1 ..< culled.count - 1 {
      let previous = culled[index - 1]
      let current = culled[index]
      let next = culled[index + 1]
      let deflection = deflectionAngle(previous: previous, current: current, next: next)
      if deflection > configuration.maxDeflection {
        // Place fillet points a small fraction of the way back along
        // the previous leg and forward along the next leg. The fraction
        // is bounded by half the leg length so two adjacent sharp
        // corners can't insert overlapping fillets.
        let leadIn = CGPoint(
          x: current.x + (previous.x - current.x) * CGFloat(filletFraction),
          y: current.y + (previous.y - current.y) * CGFloat(filletFraction),
        )
        let leadOut = CGPoint(
          x: current.x + (next.x - current.x) * CGFloat(filletFraction),
          y: current.y + (next.y - current.y) * CGFloat(filletFraction),
        )
        smoothed.append(leadIn)
        smoothed.append(current)
        smoothed.append(leadOut)
      } else {
        smoothed.append(current)
      }
    }
    smoothed.append(culled[culled.count - 1])
    return smoothed
  }

  /// Deflection angle at `current`, in radians ∈ `[0, π]`. A straight
  /// line returns 0; a 90° corner returns π/2; a U-turn returns π.
  /// "How much does the polyline bend at this point."
  static func deflectionAngle(
    previous: CGPoint,
    current: CGPoint,
    next: CGPoint,
  ) -> Double {
    let inX = Double(current.x - previous.x)
    let inY = Double(current.y - previous.y)
    let outX = Double(next.x - current.x)
    let outY = Double(next.y - current.y)
    let inMag = sqrt(inX * inX + inY * inY)
    let outMag = sqrt(outX * outX + outY * outY)
    guard inMag > 0, outMag > 0 else { return 0 }
    let cosine = (inX * outX + inY * outY) / (inMag * outMag)
    let clamped = min(1.0, max(-1.0, cosine))
    return acos(clamped)
  }

  // MARK: Private

  /// A* priority-queue node. `Comparable` on `fScore` so the min-heap
  /// pops the cheapest candidate next.
  private struct AStarNode: Comparable {
    let cell: GridCell
    let gScore: Double
    let fScore: Double

    static func <(lhs: AStarNode, rhs: AStarNode) -> Bool {
      lhs.fScore < rhs.fScore
    }

    static func ==(lhs: AStarNode, rhs: AStarNode) -> Bool {
      lhs.fScore == rhs.fScore && lhs.cell == rhs.cell
    }
  }

  /// Octile heuristic on the cell grid (admissible for 8-way
  /// connectivity with unit step costs scaled by cell size).
  private static func heuristic(from: GridCell, to: GridCell) -> Double {
    let dx = abs(Double(from.column - to.column))
    let dy = abs(Double(from.row - to.row))
    let diagonal = min(dx, dy)
    let straight = abs(dx - dy)
    return diagonal * 1.41421356 + straight
  }

  private static func baseCost(from: GridCell, to: GridCell) -> Double {
    let dx = abs(Double(from.column - to.column))
    let dy = abs(Double(from.row - to.row))
    if dx == 1, dy == 1 { return 1.41421356 }
    return 1.0
  }

  /// 8-way neighbours.
  private static func neighbours(of cell: GridCell) -> [GridCell] {
    [
      GridCell(column: cell.column - 1, row: cell.row - 1),
      GridCell(column: cell.column, row: cell.row - 1),
      GridCell(column: cell.column + 1, row: cell.row - 1),
      GridCell(column: cell.column - 1, row: cell.row),
      GridCell(column: cell.column + 1, row: cell.row),
      GridCell(column: cell.column - 1, row: cell.row + 1),
      GridCell(column: cell.column, row: cell.row + 1),
      GridCell(column: cell.column + 1, row: cell.row + 1),
    ]
  }

  /// `true` when the segment `parent → current` and `current → next`
  /// have different directions (cardinal/diagonal).
  private static func directionDelta(
    parent: GridCell,
    current: GridCell,
    next: GridCell,
  ) -> Bool {
    let inDx = current.column - parent.column
    let inDy = current.row - parent.row
    let outDx = next.column - current.column
    let outDy = next.row - current.row
    return inDx != outDx || inDy != outDy
  }

  private static func reconstructPath(
    cameFrom: [GridCell: GridCell],
    current: GridCell,
  ) -> [GridCell] {
    var path = [current]
    var node = current
    while let previous = cameFrom[node] {
      path.append(previous)
      node = previous
    }
    return path.reversed()
  }

  /// 2D cross product of vectors `(b−a)` and `(c−a)`. Sign indicates
  /// turn direction; magnitude is twice the triangle area.
  private static func crossProduct(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
    let abx = Double(b.x - a.x)
    let aby = Double(b.y - a.y)
    let acx = Double(c.x - a.x)
    let acy = Double(c.y - a.y)
    return abx * acy - aby * acx
  }
}

// MARK: - MinHeap

/// Tiny binary min-heap, generic on `Comparable`. A* needs roughly
/// `O(V log V)` pops over the open set; a plain `Array.sort()` would
/// be `O(V² log V)` on the same workload and would peg the routing
/// budget. Pure value type; deterministic; no globals.
struct MinHeap<Element: Comparable> {

  // MARK: Lifecycle

  init() {
    storage = []
  }

  // MARK: Internal

  var isEmpty: Bool {
    storage.isEmpty
  }

  var count: Int {
    storage.count
  }

  mutating func push(_ element: Element) {
    storage.append(element)
    siftUp(from: storage.count - 1)
  }

  mutating func pop() -> Element? {
    guard !storage.isEmpty else { return nil }
    storage.swapAt(0, storage.count - 1)
    let popped = storage.removeLast()
    if !storage.isEmpty { siftDown(from: 0) }
    return popped
  }

  // MARK: Private

  private var storage: [Element]

  private mutating func siftUp(from start: Int) {
    var index = start
    while index > 0 {
      let parent = (index - 1) / 2
      if storage[index] < storage[parent] {
        storage.swapAt(index, parent)
        index = parent
      } else {
        return
      }
    }
  }

  private mutating func siftDown(from start: Int) {
    var index = start
    let count = storage.count
    while true {
      let left = 2 * index + 1
      let right = 2 * index + 2
      var smallest = index
      if left < count, storage[left] < storage[smallest] { smallest = left }
      if right < count, storage[right] < storage[smallest] { smallest = right }
      if smallest == index { return }
      storage.swapAt(index, smallest)
      index = smallest
    }
  }
}
