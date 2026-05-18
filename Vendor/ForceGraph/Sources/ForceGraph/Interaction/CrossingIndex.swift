import CoreGraphics

/// Detects segment intersections among the **currently on-screen** edges using
/// a uniform spatial grid, so the tangle can be marked with knot glyphs.
///
/// ## Why a grid (never O(E²), never per-frame)
///
/// A naïve all-pairs test is `O(E²)` — on the corpus that would be ~1.3M pairs
/// every recompute, and catastrophic if run per frame. Instead each visible
/// edge's screen-space bounding box is rasterised into a uniform grid; two
/// edges are tested for intersection **only when they share at least one
/// cell**. With the sparse corpus (≈1,642 edges, most of degree ≤2, ~268
/// isolated nodes, ~303 components) only a small window of edges is ever
/// on screen at the readable zoom, and the grid keeps the candidate set
/// near-linear in the number of visible edges.
///
/// ## When it runs (gating — the binding idle-CPU rule)
///
/// `GraphEngine` calls `recompute` **only** when:
///   1. the layout is *settled* (or on an explicit settle event) — never while
///      the simulation is live and positions churn every frame, and
///   2. the viewport is **above the LOD label-drop zoom** — when zoomed out
///      far the knot glyphs are suppressed anyway, so there is nothing to draw.
///
/// It is plain synchronous Swift on the main actor: it does **not** start a
/// task, schedule a timer, or set `wantsContinuousRedraw`, so computing
/// crossings once on settle does not by itself keep the redraw loop alive — an
/// idle graph still drops to ~no CPU. The live crossing *count* it produces is
/// cheap and remains available for the HUD even when the glyphs are
/// LOD-suppressed.
///
/// The detector works purely in **screen space** off the immutable snapshot, so
/// it never touches the simulation and is trivially unit-testable.
struct CrossingIndex {
    /// One detected crossing: the screen-space intersection point plus the
    /// screen-space direction of each crossing strand, used to draw the
    /// over/under knot glyph (one strand bridged over the other).
    struct Crossing: Equatable, Sendable {
        /// Screen-space intersection point.
        var point: CGPoint
        /// Unit direction of the strand drawn *over* (the bridge).
        var overDirection: CGVector
        /// Unit direction of the strand drawn *under* (gapped at the crossing).
        var underDirection: CGVector
    }

    /// The crossing glyphs to actually draw. **Bounded** to `glyphBudget`: a
    /// dense tangle can have tens of thousands of true crossings (the sparse
    /// corpus's ~303 components all gravitate to one core), and drawing a knot
    /// at every one would be illegible noise — the exact opposite of the
    /// spec's "register the tangle *without losing the focal structure*". So
    /// we draw a representative, spatially-thinned subset; the HUD `count`
    /// still reports the **true** total (cheap, honest), per the spec's
    /// explicit separation of the count from the glyphs.
    private(set) var crossings: [Crossing] = []

    /// The true number of crossings detected (may exceed `crossings.count`
    /// when the glyph set was capped). This is what the HUD stat / VoiceOver
    /// report — always meaningful even when glyphs are LOD-suppressed.
    private(set) var count = 0

    /// Max knot glyphs carried for drawing. Past this the tangle is so dense
    /// that more marks only add clutter; a thinned subset still communicates
    /// "there is a knot here" while the count conveys the magnitude.
    static let glyphBudget = 600

    /// DJROOMBA PATCH (5) — bound the per-cell all-pairs test.
    ///
    /// The grid's "near-linear, never O(E²)" guarantee (see the type doc)
    /// silently fails for a **high-degree hub**: when a hub node is selected
    /// the layout centres/zooms on it, so *all* of its incident edges converge
    /// at the hub's screen point and land in the **same one or two grid
    /// cells**. That single super-cell then has `members.count ≈ degree(hub)`,
    /// and the `for x { for y in x+1… }` pair loop below is O(members²) in that
    /// one cell — i.e. the whole detector degrades back to O(E²) precisely for
    /// the hub-star topology. On the real (post-import) genre graph that pegged
    /// the main thread for seconds on every drag-induced settle (a profiler
    /// caught ~67 % of the main thread in `recompute`, dominated by the pair
    /// loop's `Set<Int>` churn + cross-module Swift generic-metadata
    /// instantiation), presenting as an app-wide beachball.
    ///
    /// A cell this crowded is, by construction, an illegible knot core: the
    /// `glyphBudget`/`glyphCell` thinning would discard nearly all of its marks
    /// anyway, and almost every pair in it shares the hub endpoint (rejected by
    /// `sharesEndpoint`, so not a crossing). So we **skip the pair test for any
    /// cell past `maxCellMembers`**. Effect: bounded O(maxCellMembers²)
    /// per cell ⇒ the detector is genuinely near-linear again; only the
    /// crossings *interior to a degenerate hub core* are omitted, which makes
    /// the HUD `count` a lower bound there — consistent with the spec's
    /// already-explicit "representative, not exhaustive" glyph contract. Normal
    /// (non-hub) graphs are unaffected: their cells are far below the cap.
    /// To upstream: the grid needs hub-aware cell sizing or a degree cap; this
    /// is the surgical bound.
    static let maxCellMembers = 96

    /// Recompute crossings for the edges currently on screen.
    ///
    /// - Parameters:
    ///   - edges: the immutable snapshot edges (model-space endpoints).
    ///   - viewport: the current model↔screen transform.
    ///   - viewSize: the on-screen size, defining the visible rect.
    ///
    /// Builds the visible-edge set (cheap segment-vs-rect reject), buckets each
    /// into a uniform grid by its screen bounding box, then tests only edge
    /// pairs that share a cell and do not share an endpoint. Complexity is
    /// `O(V + Σ pairs-per-cell)` where `V` is the number of visible edges —
    /// effectively linear on the sparse corpus at a readable zoom, and never
    /// the `O(E²)` all-pairs test.
    mutating func recompute(edges: [RenderSnapshot.Edge], viewport: Viewport, viewSize: CGSize) {
        crossings.removeAll(keepingCapacity: true)
        count = 0
        guard viewSize.width > 0, viewSize.height > 0, !edges.isEmpty else { return }

        // Inflate a little so an edge straddling the border still participates
        // (matches the renderer's cull inset so on/off-screen agree).
        let bounds = CGRect(origin: .zero, size: viewSize).insetBy(dx: -80, dy: -80)

        // 1. Project to screen + keep only the visible segments.
        var segments: [Segment] = []
        segments.reserveCapacity(edges.count)
        for edge in edges {
            let a = viewport.toScreen(edge.a)
            let b = viewport.toScreen(edge.b)
            // Cheap reject: skip when both ends are off the same side (keeps
            // long edges that cross the viewport). Same test the renderer uses.
            if (a.x < bounds.minX && b.x < bounds.minX) ||
                (a.x > bounds.maxX && b.x > bounds.maxX) ||
                (a.y < bounds.minY && b.y < bounds.minY) ||
                (a.y > bounds.maxY && b.y > bounds.maxY) {
                continue
            }
            segments.append(Segment(a: a, b: b))
        }
        guard segments.count > 1 else { return }

        // 2. Uniform grid. Cell size ≈ a generous edge stride so each segment
        //    touches only a handful of cells; clamp the column count so a
        //    pathological zoom can't allocate an enormous map.
        let cell = 96.0
        let cols = max(1, min(512, Int(bounds.width / cell) + 1))
        func key(_ cx: Int, _ cy: Int) -> Int { cy &* cols &+ cx }

        var buckets: [Int: [Int]] = [:]
        buckets.reserveCapacity(segments.count * 2)
        for (i, seg) in segments.enumerated() {
            let minX = Int((min(seg.a.x, seg.b.x) - bounds.minX) / cell)
            let maxX = Int((max(seg.a.x, seg.b.x) - bounds.minX) / cell)
            let minY = Int((min(seg.a.y, seg.b.y) - bounds.minY) / cell)
            let maxY = Int((max(seg.a.y, seg.b.y) - bounds.minY) / cell)
            for cy in minY...maxY {
                for cx in minX...maxX {
                    buckets[key(max(0, cx), max(0, cy)), default: []].append(i)
                }
            }
        }

        // 3. Test only pairs that share a cell. A `Set` of ordered pairs
        //    deduplicates the case where two segments share several cells.
        //    Every true crossing increments `count`; the *glyph* set is
        //    spatially thinned (≤ one knot per `glyphCell` px) and capped at
        //    `glyphBudget`, so a dense core stays legible while the count
        //    still reports the real magnitude.
        let glyphCell = 22.0
        let glyphCols = max(1, Int(bounds.width / glyphCell) + 1)
        var occupiedGlyphCells = Set<Int>()
        var tested = Set<Int>()
        tested.reserveCapacity(segments.count)
        for (_, members) in buckets where members.count > 1 {
            // DJROOMBA PATCH (5): skip a degenerate hub-star super-cell —
            // O(members²) here is the measured main-thread beachball; such a
            // cell is an illegible knot the glyph thinning discards anyway.
            if members.count > Self.maxCellMembers { continue }
            for x in 0..<members.count {
                for y in (x + 1)..<members.count {
                    let i = members[x]
                    let j = members[y]
                    let lo = min(i, j)
                    let hi = max(i, j)
                    let pair = lo &* segments.count &+ hi
                    if !tested.insert(pair).inserted { continue }
                    let s1 = segments[lo]
                    let s2 = segments[hi]
                    // Edges meeting at a shared node aren't a crossing.
                    if Self.sharesEndpoint(s1, s2) { continue }
                    guard let p = Self.intersection(s1, s2) else { continue }
                    count += 1

                    // Spatially thin the drawn glyphs: at most one knot per
                    // coarse cell, and never more than the budget. The count
                    // above is unaffected — it stays the true total.
                    guard crossings.count < Self.glyphBudget else { continue }
                    let gx = Int((p.x - bounds.minX) / glyphCell)
                    let gy = Int((p.y - bounds.minY) / glyphCell)
                    let gKey = gy &* glyphCols &+ gx
                    guard occupiedGlyphCells.insert(gKey).inserted else { continue }
                    crossings.append(
                        Crossing(
                            point: p,
                            overDirection: s1.unitDirection,
                            underDirection: s2.unitDirection
                        )
                    )
                }
            }
        }
    }

    /// Drop all crossings (e.g. the layout reheated, or we zoomed below the
    /// LOD threshold so glyphs are suppressed).
    mutating func clear() {
        crossings.removeAll(keepingCapacity: true)
        count = 0
    }

    // MARK: - Geometry

    /// A screen-space segment plus a couple of cached scalars.
    struct Segment: Equatable, Sendable {
        let a: CGPoint
        let b: CGPoint

        var unitDirection: CGVector {
            let dx = b.x - a.x
            let dy = b.y - a.y
            let len = (dx * dx + dy * dy).squareRoot()
            guard len > 1e-9 else { return CGVector(dx: 1, dy: 0) }
            return CGVector(dx: dx / len, dy: dy / len)
        }
    }

    /// Two segments "share an endpoint" if any pair of their ends is within a
    /// hair (sub-pixel) of each other — they meet at a shared graph node, which
    /// is not a tangle.
    private static func sharesEndpoint(_ s1: Segment, _ s2: Segment) -> Bool {
        let eps = 0.25
        return near(s1.a, s2.a, eps) || near(s1.a, s2.b, eps)
            || near(s1.b, s2.a, eps) || near(s1.b, s2.b, eps)
    }

    private static func near(_ p: CGPoint, _ q: CGPoint, _ eps: CGFloat) -> Bool {
        abs(p.x - q.x) <= eps && abs(p.y - q.y) <= eps
    }

    /// Proper segment–segment intersection point, or `nil` if they don't cross.
    /// Endpoint-touching and collinear overlaps are intentionally *not*
    /// reported as crossings (collinear edges aren't a knot, and shared
    /// endpoints are filtered earlier).
    static func intersection(_ s1: Segment, _ s2: Segment) -> CGPoint? {
        let p = s1.a
        let r = CGVector(dx: s1.b.x - s1.a.x, dy: s1.b.y - s1.a.y)
        let q = s2.a
        let s = CGVector(dx: s2.b.x - s2.a.x, dy: s2.b.y - s2.a.y)

        let rxs = r.dx * s.dy - r.dy * s.dx
        guard abs(rxs) > 1e-9 else { return nil } // parallel / collinear

        let qp = CGVector(dx: q.x - p.x, dy: q.y - p.y)
        let t = (qp.dx * s.dy - qp.dy * s.dx) / rxs
        let u = (qp.dx * r.dy - qp.dy * r.dx) / rxs

        // Strictly interior (a tiny epsilon trims endpoint touches the
        // shared-endpoint test might have missed by rounding).
        let lo = 1e-6
        let hi = 1.0 - 1e-6
        guard t >= lo, t <= hi, u >= lo, u <= hi else { return nil }

        return CGPoint(x: p.x + t * r.dx, y: p.y + t * r.dy)
    }
}
