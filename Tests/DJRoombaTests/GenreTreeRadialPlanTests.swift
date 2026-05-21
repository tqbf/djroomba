import Foundation
import Testing
@testable import DJRoomba

/// Pure-geometry + neighbour-classification invariants for
/// `GenreTreeRadialPlan` (`plans/son-of-genre-map.md` Phase C).
/// Fixture-driven — no SQLite, no SwiftUI — so the ring assignment,
/// opacity targets, and canvas-clamping invariants are pinned
/// independently of the view layer.
struct GenreTreeRadialPlanTests {

  /// Make a layout output with N placed nodes at the supplied
  /// world positions. World bounds default to a generous square so
  /// canvas-clamping doesn't engage unless a test specifically wants
  /// it to.
  static func makeLayout(
    positions: [String: CGPoint],
    bounds: CGRect = CGRect(x: 0, y: 0, width: 7000, height: 7000),
  ) -> GenreTreeLayout.Output {
    let placed = positions
      .map { name, point in
        GenreTreeLayout.PlacedNode(
          genre: Genre(name: name, weight: 0.5),
          depth: 0,
          position: point,
          parentGenre: nil,
          edge: nil,
        )
      }
      .sorted { $0.genre.name < $1.genre.name }
    return GenreTreeLayout.Output(
      placedNodes: placed,
      worldBounds: bounds,
      diagonalStart: CGPoint(x: bounds.minX, y: bounds.minY),
      diagonalEnd: CGPoint(x: bounds.maxX, y: bounds.maxY),
    )
  }

  /// Build a `GenreEdgeEvidence` row for a canonical-half edge with
  /// the given total weight. The other channels (jaccards, shared
  /// counts) are zeroed — the radial plan only reads `totalWeight`.
  static func edge(_ a: String, _ b: String, weight: Double) -> GenreEdgeEvidence {
    let lo = min(a, b)
    let hi = max(a, b)
    return GenreEdgeEvidence(
      genreA: lo,
      genreB: hi,
      artistOverlapJaccard: 0,
      albumOverlapJaccard: 0,
      trackOverlapJaccard: 0,
      playlistCooccurWeight: 0,
      sharedArtistCount: 0,
      sharedAlbumCount: 0,
      sharedTrackCount: 0,
      totalWeight: weight,
    )
  }

  /// Euclidean distance.
  static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x - b.x)
    let dy = Double(a.y - b.y)
    return (dx * dx + dy * dy).squareRoot()
  }

  /// Sanity layout: 5 genres laid out on a grid. SELECTED is at the
  /// centre; A & B are 1-hop; C is 2-hop (connected through A); D is
  /// unrelated (no edges).
  static func sanityLayout() -> (GenreTreeLayout.Output, [GenreEdgeEvidence]) {
    let layout = makeLayout(positions: [
      "SELECTED": CGPoint(x: 3500, y: 3500),
      "A": CGPoint(x: 100, y: 100),
      "B": CGPoint(x: 200, y: 200),
      "C": CGPoint(x: 300, y: 300),
      "D": CGPoint(x: 400, y: 400),
    ])
    let evidence = [
      edge("SELECTED", "A", weight: 0.9),
      edge("SELECTED", "B", weight: 0.4),
      edge("A", "C", weight: 0.7),
    ]
    return (layout, evidence)
  }

  @Test
  func `one hop neighbours land on the inner ring`() throws {
    let (layout, evidence) = Self.sanityLayout()
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    let centre = plan.centre
    let a = try #require(plan.targetsByGenre["A"])
    let b = try #require(plan.targetsByGenre["B"])
    #expect(a.ring == .oneHop)
    #expect(b.ring == .oneHop)
    let dA = Self.distance(a.position, centre)
    let dB = Self.distance(b.position, centre)
    #expect(abs(dA - 280) < 0.001) // default r1
    #expect(abs(dB - 280) < 0.001)
  }

  @Test
  func `two hop neighbours land on the outer ring`() throws {
    let (layout, evidence) = Self.sanityLayout()
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    let c = try #require(plan.targetsByGenre["C"])
    #expect(c.ring == .twoHop)
    let d = Self.distance(c.position, plan.centre)
    #expect(abs(d - 520) < 0.001) // default r2
  }

  @Test
  func `out of focus genres stay at their existing layout position`() throws {
    let (layout, evidence) = Self.sanityLayout()
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    let d = try #require(plan.targetsByGenre["D"])
    #expect(d.ring == .outOfFocus)
    // D's existing layout position was (400, 400) — should be
    // preserved exactly (no animation of unrelated pills sideways).
    #expect(d.position == CGPoint(x: 400, y: 400))
  }

  @Test
  func `opacity targets follow the documented per ring schedule`() throws {
    let (layout, evidence) = Self.sanityLayout()
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    #expect(try #require(plan.targetsByGenre["SELECTED"]).opacity == 1.0)
    #expect(try #require(plan.targetsByGenre["A"]).opacity == 1.0)
    #expect(try #require(plan.targetsByGenre["B"]).opacity == 1.0)
    #expect(try #require(plan.targetsByGenre["C"]).opacity == 0.55)
    #expect(try #require(plan.targetsByGenre["D"]).opacity == 0.06)
  }

  @Test
  func `selected genre sits at the radial centre`() throws {
    let (layout, evidence) = Self.sanityLayout()
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    let selected = try #require(plan.targetsByGenre["SELECTED"])
    #expect(selected.ring == .selected)
    #expect(selected.position == CGPoint(x: 3500, y: 3500))
    #expect(plan.centre == selected.position)
  }

  @Test
  func `selecting an unknown genre returns nil`() {
    let (layout, evidence) = Self.sanityLayout()
    let plan = GenreTreeRadialPlan.plan(
      selectedGenre: "MISSING",
      layout: layout,
      evidence: evidence,
    )
    #expect(plan == nil)
  }

  @Test
  func `one hop wins over two hop classification`() throws {
    // Graph: SELECTED ↔ A, A ↔ B, SELECTED ↔ B. B is reachable in
    // both 1 step AND 2 steps; the closer ring wins.
    let layout = Self.makeLayout(positions: [
      "SELECTED": CGPoint(x: 1000, y: 1000),
      "A": CGPoint(x: 100, y: 100),
      "B": CGPoint(x: 200, y: 200),
    ])
    let evidence = [
      Self.edge("SELECTED", "A", weight: 0.5),
      Self.edge("A", "B", weight: 0.5),
      Self.edge("SELECTED", "B", weight: 0.3),
    ]
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    let b = try #require(plan.targetsByGenre["B"])
    #expect(b.ring == .oneHop)
    let distance = Self.distance(b.position, plan.centre)
    #expect(abs(distance - 280) < 0.001)
  }

  @Test
  func `ring slots are evenly spaced around the centre`() throws {
    // Four 1-hop neighbours fan around the centre evenly — pairwise
    // angular separations should be 90° each.
    let layout = Self.makeLayout(positions: [
      "C": CGPoint(x: 1000, y: 1000),
      "N1": CGPoint(x: 100, y: 100),
      "N2": CGPoint(x: 200, y: 200),
      "N3": CGPoint(x: 300, y: 300),
      "N4": CGPoint(x: 400, y: 400),
    ])
    let evidence = [
      Self.edge("C", "N1", weight: 0.9),
      Self.edge("C", "N2", weight: 0.8),
      Self.edge("C", "N3", weight: 0.7),
      Self.edge("C", "N4", weight: 0.6),
    ]
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "C",
      layout: layout,
      evidence: evidence,
    ))
    let centre = plan.centre
    func angle(_ p: CGPoint) -> Double {
      atan2(Double(p.y - centre.y), Double(p.x - centre.x))
    }
    let positions = try ["N1", "N2", "N3", "N4"].map { name in
      try #require(plan.targetsByGenre[name]).position
    }
    let angles = positions.map(angle).sorted()
    let deltas = zip(angles, angles.dropFirst()).map { $1 - $0 }
    for delta in deltas {
      #expect(abs(delta - (.pi / 2.0)) < 0.001)
    }
  }

  @Test
  func `heaviest one hop neighbour lands at the starting angle`() throws {
    // Three neighbours, edge weights 0.9 / 0.5 / 0.3. Heaviest
    // (NHeavy) should sit at the starting angle (-π/2 — top).
    let layout = Self.makeLayout(positions: [
      "C": CGPoint(x: 1000, y: 1000),
      "NHeavy": CGPoint(x: 0, y: 0),
      "NMid": CGPoint(x: 0, y: 0),
      "NLight": CGPoint(x: 0, y: 0),
    ])
    let evidence = [
      Self.edge("C", "NHeavy", weight: 0.9),
      Self.edge("C", "NMid", weight: 0.5),
      Self.edge("C", "NLight", weight: 0.3),
    ]
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "C",
      layout: layout,
      evidence: evidence,
    ))
    let centre = plan.centre
    let heavyPos = try #require(plan.targetsByGenre["NHeavy"]).position
    let expectedTop = CGPoint(x: centre.x, y: centre.y - 280)
    #expect(abs(heavyPos.x - expectedTop.x) < 0.001)
    #expect(abs(heavyPos.y - expectedTop.y) < 0.001)
  }

  @Test
  func `positions are clamped inside the canvas bounds`() throws {
    // Selected sits at the canvas corner; without clamping its
    // neighbours would land off the canvas entirely. The clamp
    // keeps every position inside the worldBounds rectangle by
    // `canvasInset`.
    let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    let layout = Self.makeLayout(
      positions: [
        "C": CGPoint(x: 50, y: 50),
        "N1": CGPoint(x: 10, y: 10),
      ],
      bounds: bounds,
    )
    let evidence = [Self.edge("C", "N1", weight: 0.5)]
    let config = GenreTreeRadialPlan.Configuration(
      r1: 500,
      r2: 800,
      canvasInset: 5,
    )
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "C",
      layout: layout,
      evidence: evidence,
      configuration: config,
    ))
    let n1 = try #require(plan.targetsByGenre["N1"]).position
    #expect(n1.x >= bounds.minX + 5)
    #expect(n1.x <= bounds.maxX - 5)
    #expect(n1.y >= bounds.minY + 5)
    #expect(n1.y <= bounds.maxY - 5)
  }

  @Test
  func `plan covers every layout node`() throws {
    let (layout, evidence) = Self.sanityLayout()
    let plan = try #require(GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    ))
    for placed in layout.placedNodes {
      #expect(plan.targetsByGenre[placed.genre.name] != nil)
    }
  }

  @Test
  func `plan is deterministic across identical inputs`() {
    let (layout, evidence) = Self.sanityLayout()
    let a = GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    )
    let b = GenreTreeRadialPlan.plan(
      selectedGenre: "SELECTED",
      layout: layout,
      evidence: evidence,
    )
    #expect(a == b)
  }
}
