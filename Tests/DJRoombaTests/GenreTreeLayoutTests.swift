import Foundation
import Testing
@testable import DJRoomba

/// Pure-geometry invariants for `GenreTreeLayout`
/// (`plans/son-of-genre-map.md` Phase B). Fixture-driven — no SQLite,
/// no SwiftUI — so the diagonal placement, radial fanning, depth
/// recursion, and per-arc weight ordering are pinned independently of
/// the substrate and the renderer.
struct GenreTreeLayoutTests {

  /// Compute the (x, y) distance between two points.
  static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x - b.x)
    let dy = Double(a.y - b.y)
    return (dx * dx + dy * dy).squareRoot()
  }

  /// Look up a placed node by genre name. Fails the test if the
  /// genre isn't present.
  static func placed(
    _ output: GenreTreeLayout.Output,
    _ genre: String,
    sourceLocation: SourceLocation = #_sourceLocation,
  ) -> GenreTreeLayout.PlacedNode {
    guard let placed = output.placedNodes.first(where: { $0.genre.name == genre }) else {
      Issue.record(
        "expected placed node \(genre)",
        sourceLocation: sourceLocation,
      )
      return GenreTreeLayout.PlacedNode(
        genre: Genre(name: genre, weight: 0),
        depth: 0,
        position: .zero,
        parentGenre: nil,
        edge: nil,
      )
    }
    return placed
  }

  /// Single-trunk fixture: one trunk on the diagonal, three children
  /// fanned around it.
  static func singleTrunkModel() -> GenreTreeModel {
    GenreTreeModel(
      trunks: [
        GenreTreeTrunk(
          root: GenreTreeNode(
            genre: Genre(name: "Trunk", weight: 0.8),
            depth: 0,
            children: [
              GenreTreeNode(
                genre: Genre(name: "A", weight: 0.5), // heaviest → centre
                depth: 1,
                children: [],
              ),
              GenreTreeNode(
                genre: Genre(name: "B", weight: 0.3),
                depth: 1,
                children: [],
              ),
              GenreTreeNode(
                genre: Genre(name: "C", weight: 0.1),
                depth: 1,
                children: [],
              ),
            ],
          ),
          communityID: 0,
        )
      ],
      orphans: [],
    )
  }

  /// Two-trunk fixture for side-alternation tests.
  static func twoTrunkModel() -> GenreTreeModel {
    GenreTreeModel(
      trunks: [
        GenreTreeTrunk(
          root: GenreTreeNode(
            genre: Genre(name: "T0", weight: 0.7),
            depth: 0,
            children: [
              GenreTreeNode(
                genre: Genre(name: "T0a", weight: 0.4),
                depth: 1,
                children: [],
              )
            ],
          ),
          communityID: 0,
        ),
        GenreTreeTrunk(
          root: GenreTreeNode(
            genre: Genre(name: "T1", weight: 0.6),
            depth: 0,
            children: [
              GenreTreeNode(
                genre: Genre(name: "T1a", weight: 0.4),
                depth: 1,
                children: [],
              )
            ],
          ),
          communityID: 1,
        ),
      ],
      orphans: [],
    )
  }

  /// Empty model → empty placed nodes, but the worldBounds + diagonal
  /// endpoints still match the configured canvas (the renderer wants
  /// a valid frame even before the build lands).
  @Test
  func `empty model returns empty placed nodes with canvas bounds`() {
    let configuration = GenreTreeLayout.Configuration(worldSide: 5000, diagonalPadding: 360)
    let output = GenreTreeLayout.layout(
      model: GenreTreeModel(trunks: [], orphans: []),
      configuration: configuration,
    )
    #expect(output.placedNodes.isEmpty)
    #expect(output.worldBounds.width == 5000)
    #expect(output.worldBounds.height == 5000)
    #expect(output.diagonalStart == CGPoint(x: 360, y: 360))
    #expect(output.diagonalEnd == CGPoint(x: 4640, y: 4640))
  }

  /// Single trunk is placed at the diagonal midpoint with even spacing.
  /// k = 1 ⇒ parameter `(0 + 1) / (1 + 1) = 0.5` ⇒ midpoint of the
  /// diagonal segment.
  @Test
  func `single trunk lands at diagonal midpoint`() {
    let configuration = GenreTreeLayout.Configuration(worldSide: 5000, diagonalPadding: 360)
    let output = GenreTreeLayout.layout(
      model: Self.singleTrunkModel(),
      configuration: configuration,
    )
    let trunk = Self.placed(output, "Trunk")
    #expect(trunk.depth == 0)
    #expect(trunk.parentGenre == nil)
    #expect(trunk.edge == nil)
    // Diagonal midpoint = (start + end) / 2 = ((360 + 4640) / 2, …)
    #expect(abs(trunk.position.x - 2500) < 1.0e-6)
    #expect(abs(trunk.position.y - 2500) < 1.0e-6)
  }

  /// Three children on a single trunk: arc width is the configured
  /// default (120° in radians). With the bisector pointing along the
  /// up-left side (135°), the three slots are
  /// `[bisector, bisector + arc/2, bisector − arc/2]`. Heaviest (A)
  /// lands on the bisector; the two lighter ones at the arc edges.
  @Test
  func `three children fan around the bisector with heaviest centred`() {
    let configuration = GenreTreeLayout.Configuration(
      worldSide: 5000,
      diagonalPadding: 360,
      branchArcWidthDegrees: 120,
      depth1Radius: 360,
    )
    let output = GenreTreeLayout.layout(
      model: Self.singleTrunkModel(),
      configuration: configuration,
    )
    let trunk = Self.placed(output, "Trunk")
    let a = Self.placed(output, "A")
    let b = Self.placed(output, "B")
    let c = Self.placed(output, "C")

    // All three children are exactly `depth1Radius` from the trunk.
    let radiusA = Self.distance(trunk.position, a.position)
    let radiusB = Self.distance(trunk.position, b.position)
    let radiusC = Self.distance(trunk.position, c.position)
    #expect(abs(radiusA - 360) < 1.0e-6)
    #expect(abs(radiusB - 360) < 1.0e-6)
    #expect(abs(radiusC - 360) < 1.0e-6)

    // Heaviest (A) sits on the bisector ⇒ angle from trunk to A
    // equals -π/4 (the .aboveDiagonal normal). In screen coords
    // (y-down), -π/4 is "upper-right of the diagonal" → vector
    // (+1, -1). Trunk 0 fans above the diagonal by default.
    let angleA = atan2(Double(a.position.y - trunk.position.y), Double(a.position.x - trunk.position.x))
    #expect(abs(angleA - (-.pi / 4.0)) < 1.0e-6)

    // The depth-1 children all carry an edge back to the trunk.
    #expect(a.edge != nil)
    #expect(b.edge != nil)
    #expect(c.edge != nil)
    if let edge = a.edge {
      #expect(edge.start == trunk.position)
      #expect(edge.end == a.position)
    }
  }

  /// Arc edges (B and C, lighter siblings on a 3-child fan) sit
  /// symmetrically around the bisector — angles to them are
  /// `bisector ± arc/2`. The arc is `120° = 2π/3` rad, so the
  /// half-arc is `60° = π/3`.
  @Test
  func `three children put lighter siblings at the arc edges`() {
    let configuration = GenreTreeLayout.Configuration(
      worldSide: 5000,
      diagonalPadding: 360,
      branchArcWidthDegrees: 120,
      depth1Radius: 360,
    )
    let output = GenreTreeLayout.layout(
      model: Self.singleTrunkModel(),
      configuration: configuration,
    )
    let trunk = Self.placed(output, "Trunk")
    let b = Self.placed(output, "B") // second-heaviest (index 1)
    let c = Self.placed(output, "C") // lightest (index 2)
    let bisector = -.pi / 4.0
    let halfArc = (120.0 * .pi / 180.0) / 2.0 // π/3

    let angleB = atan2(Double(b.position.y - trunk.position.y), Double(b.position.x - trunk.position.x))
    let angleC = atan2(Double(c.position.y - trunk.position.y), Double(c.position.x - trunk.position.x))

    // Child 1 (index 1) lands at +halfArc; child 2 at -halfArc.
    #expect(abs(angleB - (bisector + halfArc)) < 1.0e-6)
    #expect(abs(angleC - (bisector - halfArc)) < 1.0e-6)
  }

  /// Trunk alternation: first trunk fans up-left of the diagonal, the
  /// second fans down-right. Verified by checking the bisector
  /// direction of each trunk's only child.
  @Test
  func `trunks alternate sides of the diagonal`() {
    let configuration = GenreTreeLayout.Configuration(
      worldSide: 5000,
      diagonalPadding: 360,
      depth1Radius: 360,
    )
    let output = GenreTreeLayout.layout(
      model: Self.twoTrunkModel(),
      configuration: configuration,
    )
    let trunk0 = Self.placed(output, "T0")
    let trunk1 = Self.placed(output, "T1")
    let child0 = Self.placed(output, "T0a")
    let child1 = Self.placed(output, "T1a")
    let angle0 = atan2(Double(child0.position.y - trunk0.position.y), Double(child0.position.x - trunk0.position.x))
    let angle1 = atan2(Double(child1.position.y - trunk1.position.y), Double(child1.position.x - trunk1.position.x))
    // First trunk fans above the diagonal ⇒ child at -π/4.
    #expect(abs(angle0 - (-.pi / 4.0)) < 1.0e-6)
    // Second trunk fans below ⇒ child at +3π/4.
    #expect(abs(angle1 - 3.0 * .pi / 4.0) < 1.0e-6)
  }

  /// Disable alternation ⇒ every trunk fans above the diagonal.
  @Test
  func `disabled alternation makes every trunk fan above the diagonal`() {
    let configuration = GenreTreeLayout.Configuration(
      depth1Radius: 360,
      alternateSides: false,
    )
    let output = GenreTreeLayout.layout(
      model: Self.twoTrunkModel(),
      configuration: configuration,
    )
    let trunk0 = Self.placed(output, "T0")
    let trunk1 = Self.placed(output, "T1")
    let child0 = Self.placed(output, "T0a")
    let child1 = Self.placed(output, "T1a")
    let angle0 = atan2(Double(child0.position.y - trunk0.position.y), Double(child0.position.x - trunk0.position.x))
    let angle1 = atan2(Double(child1.position.y - trunk1.position.y), Double(child1.position.x - trunk1.position.x))
    #expect(abs(angle0 - (-.pi / 4.0)) < 1.0e-6)
    #expect(abs(angle1 - (-.pi / 4.0)) < 1.0e-6)
  }

  /// Two trunks are placed at parameters 1/3 and 2/3 of the diagonal.
  @Test
  func `two trunks land at one third and two thirds of the diagonal`() {
    let configuration = GenreTreeLayout.Configuration(worldSide: 5000, diagonalPadding: 360)
    let output = GenreTreeLayout.layout(
      model: Self.twoTrunkModel(),
      configuration: configuration,
    )
    let trunk0 = Self.placed(output, "T0")
    let trunk1 = Self.placed(output, "T1")
    // Diagonal span = 4640 - 360 = 4280. 1/3 ≈ 1426.67; 2/3 ≈ 2853.33.
    let oneThird = 360.0 + 4280.0 / 3.0
    let twoThirds = 360.0 + 4280.0 * 2.0 / 3.0
    #expect(abs(Double(trunk0.position.x) - oneThird) < 1.0e-6)
    #expect(abs(Double(trunk0.position.y) - oneThird) < 1.0e-6)
    #expect(abs(Double(trunk1.position.x) - twoThirds) < 1.0e-6)
    #expect(abs(Double(trunk1.position.y) - twoThirds) < 1.0e-6)
  }

  /// Depth-recursion narrows the arc by the configured shrink factor.
  @Test
  func `depth recursion narrows arc width by the configured factor`() {
    let configuration = GenreTreeLayout.Configuration(
      branchArcWidthDegrees: 120,
      depthArcShrink: 0.5,
    )
    let depth0Arc = GenreTreeLayout.childArcWidth(depth: 0, configuration: configuration)
    let depth1Arc = GenreTreeLayout.childArcWidth(depth: 1, configuration: configuration)
    let depth2Arc = GenreTreeLayout.childArcWidth(depth: 2, configuration: configuration)
    // Depth-0's children ⇒ depth-1's arc width = base (120° in rad).
    #expect(abs(depth0Arc - 2.0 * .pi / 3.0) < 1.0e-6)
    // Depth-1's children ⇒ depth-2's arc width = base * 0.5 (60° in rad).
    #expect(abs(depth1Arc - .pi / 3.0) < 1.0e-6)
    // Depth-2's children ⇒ depth-3's arc width = base * 0.25 (30° in rad).
    #expect(abs(depth2Arc - .pi / 6.0) < 1.0e-6)
  }

  /// Per-arc weight ordering puts the heaviest sibling at the
  /// bisector. The builder is already responsible for sorting
  /// children by per-genre weight desc; the layout consumes that
  /// order without re-sorting. The test pins the contract: child 0
  /// (the builder's heaviest) sits on the bisector across an
  /// odd-sized fan.
  @Test
  func `per arc weight ordering puts heaviest at the bisector`() {
    let configuration = GenreTreeLayout.Configuration(
      worldSide: 5000,
      diagonalPadding: 360,
      branchArcWidthDegrees: 120,
      depth1Radius: 360,
    )
    // 5 children → middle slot (index 2 by slot, but child 0 by
    // weight gets the slot closest to the bisector).
    let model = GenreTreeModel(
      trunks: [
        GenreTreeTrunk(
          root: GenreTreeNode(
            genre: Genre(name: "T", weight: 0.9),
            depth: 0,
            children: [
              GenreTreeNode(genre: Genre(name: "Heaviest", weight: 0.7), depth: 1, children: []),
              GenreTreeNode(genre: Genre(name: "Second", weight: 0.5), depth: 1, children: []),
              GenreTreeNode(genre: Genre(name: "Third", weight: 0.3), depth: 1, children: []),
              GenreTreeNode(genre: Genre(name: "Fourth", weight: 0.2), depth: 1, children: []),
              GenreTreeNode(genre: Genre(name: "Lightest", weight: 0.1), depth: 1, children: []),
            ],
          ),
          communityID: 0,
        )
      ],
      orphans: [],
    )
    let output = GenreTreeLayout.layout(model: model, configuration: configuration)
    let trunk = Self.placed(output, "T")
    let heaviest = Self.placed(output, "Heaviest")
    let bisector = -.pi / 4.0
    let heaviestAngle = atan2(
      Double(heaviest.position.y - trunk.position.y),
      Double(heaviest.position.x - trunk.position.x),
    )
    #expect(abs(heaviestAngle - bisector) < 1.0e-6)
  }

  /// Arc partitioning sums to (close to) the allocated arc width on a
  /// 5-child fan. The angular span between the leftmost and rightmost
  /// children should equal the configured arc.
  @Test
  func `arc partitioning sums to the allocated arc width`() throws {
    let configuration = GenreTreeLayout.Configuration(
      branchArcWidthDegrees: 120,
      depth1Radius: 400,
    )
    let positions = GenreTreeLayout.childPositions(
      parentPosition: CGPoint(x: 1000, y: 1000),
      childCount: 5,
      parentBisector: 0,
      arcWidthRadians: 2.0 * .pi / 3.0,
      radius: 400,
    )
    let angles = positions.map { atan2(Double($0.y - 1000), Double($0.x - 1000)) }
    let maxAngle = try #require(angles.max())
    let minAngle = try #require(angles.min())
    let span = maxAngle - minAngle
    #expect(abs(span - 2.0 * .pi / 3.0) < 1.0e-6)
    _ = configuration // configuration used implicitly via the same arc width values
  }

  /// Cubic-Bezier endpoints land where the layout placed the parent
  /// and child. Control points sit `fraction × distance` from each
  /// endpoint along the start → end line.
  @Test
  func `branch edge starts and ends on the parent and child positions`() {
    let start = CGPoint(x: 100, y: 200)
    let end = CGPoint(x: 500, y: 600)
    let curve = GenreTreeLayout.makeEdge(from: start, to: end, fraction: 0.45)
    #expect(curve.start == start)
    #expect(curve.end == end)
    // Control points should sit along the line.
    let expectedControl1 = CGPoint(
      x: start.x + (end.x - start.x) * 0.45,
      y: start.y + (end.y - start.y) * 0.45,
    )
    let expectedControl2 = CGPoint(
      x: end.x - (end.x - start.x) * 0.45,
      y: end.y - (end.y - start.y) * 0.45,
    )
    #expect(abs(curve.control1.x - expectedControl1.x) < 1.0e-6)
    #expect(abs(curve.control1.y - expectedControl1.y) < 1.0e-6)
    #expect(abs(curve.control2.x - expectedControl2.x) < 1.0e-6)
    #expect(abs(curve.control2.y - expectedControl2.y) < 1.0e-6)
  }

  /// Depth-2 children fan around their depth-1 parent in the
  /// outward direction (the bisector that the depth-1 child was
  /// reached along).
  @Test
  func `depth two grandchildren fan around the depth one parents outward direction`() {
    let configuration = GenreTreeLayout.Configuration(
      worldSide: 5000,
      diagonalPadding: 360,
      branchArcWidthDegrees: 120,
      depthArcShrink: 0.5,
      depth1Radius: 360,
      depthRadiusShrink: 0.7,
    )
    let model = GenreTreeModel(
      trunks: [
        GenreTreeTrunk(
          root: GenreTreeNode(
            genre: Genre(name: "Trunk", weight: 0.8),
            depth: 0,
            children: [
              GenreTreeNode(
                genre: Genre(name: "Branch", weight: 0.7),
                depth: 1,
                children: [
                  GenreTreeNode(
                    genre: Genre(name: "Grand", weight: 0.5),
                    depth: 2,
                    children: [],
                  )
                ],
              )
            ],
          ),
          communityID: 0,
        )
      ],
      orphans: [],
    )
    let output = GenreTreeLayout.layout(model: model, configuration: configuration)
    let trunk = Self.placed(output, "Trunk")
    let branch = Self.placed(output, "Branch")
    let grand = Self.placed(output, "Grand")
    // Trunk→Branch angle = -π/4 (above the diagonal). Branch→Grand
    // should continue outward in the same direction (single child
    // sits on the bisector, which is the trunk→branch direction).
    let trunkToBranch = atan2(Double(branch.position.y - trunk.position.y), Double(branch.position.x - trunk.position.x))
    let branchToGrand = atan2(Double(grand.position.y - branch.position.y), Double(grand.position.x - branch.position.x))
    #expect(abs(trunkToBranch - branchToGrand) < 1.0e-6)
    // Depth-2 radius = depth1Radius * depthRadiusShrink = 360 * 0.7 = 252.
    let distance = Self.distance(branch.position, grand.position)
    #expect(abs(distance - 252) < 1.0e-6)
  }

  /// Layout is deterministic — same input twice ⇒ identical output.
  @Test
  func `layout is deterministic across runs`() {
    let configuration = GenreTreeLayout.Configuration()
    let one = GenreTreeLayout.layout(model: Self.twoTrunkModel(), configuration: configuration)
    let two = GenreTreeLayout.layout(model: Self.twoTrunkModel(), configuration: configuration)
    #expect(one == two)
  }
}
