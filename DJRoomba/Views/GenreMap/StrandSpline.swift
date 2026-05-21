import SwiftUI

// MARK: - StrandSpline

/// Phase 3 / Phase 4 renderer for one metro strand
/// (`plans/genre-metro-map.md` Phase 3, step 6 + Phase 4 routing). Draws
/// a faint **centripetal** Catmull-Rom spline (the Phase-4-gate fix,
/// 2026-05-21) through either the strand's obstacle-aware routed
/// polyline (Phase 4) or its ordered station positions (Phase 3
/// fallback during routing in flight / disconnected routing). The
/// centripetal parameterisation eliminates the self-overlapping curl
/// loops that uniform CR produced on sharp interior corners (the lasso
/// artefact in `/tmp/phase4-routing-default.png`).
///
/// The strand is drawn inside a SwiftUI `Canvas` because we render many
/// strands at once and the underlying path is just a stroke (no hit-
/// testing needed at this level — strand hover routes through the
/// view-layer affordance in `GenreMapPanel`).
///
/// Phase 3 does **not** scale the line width by strand rank — the
/// Phase-1 layout backbone is already at ≤10 % opacity, so a strand
/// drawn at a uniform 2pt with a low non-selected opacity reads as a
/// metro line rather than a thicker version of the substrate. When a
/// strand is hovered (selected), the renderer bumps it opaque + ups
/// the line weight slightly so the eye can follow the corridor.
struct StrandSpline: View {

  // MARK: Internal

  /// World-space station positions, indexed by genre name. The spline
  /// projects each `pathStations[i]` through this map at draw time.
  var positionsByGenre: [String: CGPoint]
  /// Strand to render.
  var strand: GenreMapStrandInference.Strand
  /// Phase 4 (`plans/genre-metro-map.md` Phase 4): optional routed
  /// polyline keyed off `strand.id`. When non-nil + non-empty, the
  /// renderer draws the obstacle-aware A* polyline (with corridor
  /// offset already applied) instead of the naïve Phase-3 Catmull-Rom
  /// over `pathStations`. When `nil` (routing in flight, or
  /// disconnected fallback) the renderer falls back to Phase 3.
  var routed: GenreMapRoutedStrand?
  /// Hue derived from the strand's `colourID`. Same palette as
  /// `GenreMapPanel.communityColour` but indexed off the strand colour
  /// id — community hue + strand hue don't have to match.
  var colour: Color
  /// `true` when the user is hovering this strand (or its parent
  /// strand, for branches). Opaque + slightly thicker line.
  var isHighlighted: Bool
  /// `true` when *any* strand is hovered AND this strand isn't it —
  /// fade to very faint so the highlighted strand reads cleanly.
  var isFaded: Bool
  /// World → screen transform applied at draw time. The map's pan/zoom
  /// state propagates through this closure; the spline view doesn't
  /// observe the transform itself, only the resulting projected points.
  var project: (CGPoint) -> CGPoint

  var body: some View {
    Canvas { context, _ in
      // Phase 4 prefers the routed polyline (obstacle-aware A* +
      // corridor offset). Fall back to Phase-3 Catmull-Rom through
      // station positions when routing is in flight / unavailable.
      let projected: [CGPoint] =
        if let routed, routed.polyline.count >= 2 {
          routed.polyline.map(project)
        } else {
          strand.pathStations.compactMap { genre -> CGPoint? in
            guard let position = positionsByGenre[genre] else { return nil }
            return project(position)
          }
        }
      guard projected.count >= 2 else { return }
      let path = Self.catmullRomPath(points: projected)
      let opacity: Double =
        isHighlighted
          ? 0.9
          : isFaded
            ? 0.06
            : 0.22
      let lineWidth: CGFloat =
        isHighlighted
          ? 2.8
          : strand.isBranch
            ? 1.2
            : 1.6
      context.stroke(
        path,
        with: .color(colour.opacity(opacity)),
        style: StrokeStyle(
          lineWidth: lineWidth,
          lineCap: .round,
          lineJoin: .round,
        ),
      )
    }
    .allowsHitTesting(false)
  }

  /// Build a **centripetal** Catmull-Rom path through `points`
  /// (parameterisation knot exponent `α = 0.5`). Endpoints are
  /// duplicated so the curve starts/ends at the first/last sample.
  /// Returns a straight polyline for n < 3.
  ///
  /// **Phase-4 gate (2026-05-21):** switched from uniform CR (the one
  /// that produces the visible self-overlapping "curl loops" near sharp
  /// interior corners on the Alt/BritPop neighbourhood) to centripetal
  /// CR. Centripetal CR is mathematically guaranteed not to self-
  /// intersect on a non-self-intersecting control polygon — i.e. the
  /// failure mode that produced the lasso-loop artefact in
  /// `/tmp/phase4-routing-default.png` is structurally eliminated, not
  /// just papered over with a tension reduction.
  ///
  /// Math: with control points `p0 p1 p2 p3` and knot intervals
  /// `t1 = (|p1 - p0|)^α`, `t2 = (|p2 - p1|)^α`, `t3 = (|p3 - p2|)^α`,
  /// the cubic-Bezier control handles for the `p1 → p2` segment are
  ///
  /// ```
  /// c1 = p1 + (p2 - p0 * (t2/t1) + p1 * (t2/t1 - 1)) * (t2 / (3 * (t1 + t2)))
  /// c2 = p2 + (p1 - p3 * (t2/t3) + p2 * (t2/t3 - 1)) * (t2 / (3 * (t2 + t3)))
  /// ```
  ///
  /// (See Yuksel et al. 2011, "Parameterization and Applications of
  /// Catmull-Rom Curves" — the exact formulation that converts the
  /// non-uniform CR spline into per-segment cubic Beziers without
  /// rebuilding the curve.) Coincident control points fall back to
  /// the uniform `(p_next - p_prev) / 6` form because the centripetal
  /// formula has zero-distance singularities there.
  nonisolated static func catmullRomPath(points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    if points.count == 2 {
      path.addLine(to: points[1])
      return path
    }
    // Duplicate endpoints so the first and last segments curve naturally.
    var samples = points
    samples.insert(samples.first ?? .zero, at: 0)
    samples.append(samples.last ?? .zero)
    let alpha = 0.5 // centripetal
    for i in 1 ..< samples.count - 2 {
      let p0 = samples[i - 1]
      let p1 = samples[i]
      let p2 = samples[i + 1]
      let p3 = samples[i + 2]
      let (control1, control2) = centripetalControlPoints(
        p0: p0,
        p1: p1,
        p2: p2,
        p3: p3,
        alpha: alpha,
      )
      path.addCurve(to: p2, control1: control1, control2: control2)
    }
    return path
  }

  /// Compute the cubic-Bezier control handles for the centripetal
  /// Catmull-Rom segment that interpolates `p1 → p2`. Falls back to
  /// the uniform formula on zero-distance singularities so coincident
  /// waypoints (which the A* + smoothing pipeline can occasionally
  /// produce on a degenerate strand) still yield a finite path.
  nonisolated static func centripetalControlPoints(
    p0: CGPoint,
    p1: CGPoint,
    p2: CGPoint,
    p3: CGPoint,
    alpha: Double,
  ) -> (CGPoint, CGPoint) {
    let d01 = distance(p0, p1)
    let d12 = distance(p1, p2)
    let d23 = distance(p2, p3)
    let t1 = pow(d01, alpha)
    let t2 = pow(d12, alpha)
    let t3 = pow(d23, alpha)
    // Uniform-CR fallback on coincident points — the centripetal
    // formula's denominators go to zero. Matches the previous Phase-3
    // behaviour at the degenerate input.
    guard t1 > 1.0e-9, t2 > 1.0e-9, t3 > 1.0e-9 else {
      return (
        CGPoint(
          x: p1.x + (p2.x - p0.x) / 6.0,
          y: p1.y + (p2.y - p0.y) / 6.0,
        ),
        CGPoint(
          x: p2.x - (p3.x - p1.x) / 6.0,
          y: p2.y - (p3.y - p1.y) / 6.0,
        ),
      )
    }
    // c1 along the tangent at p1, sized by the centripetal knot spacing.
    let m1x = (p2.x - p0.x * CGFloat(t2 / t1) + p1.x * CGFloat(t2 / t1 - 1)) * CGFloat(t2 / (3 * (t1 + t2)))
    let m1y = (p2.y - p0.y * CGFloat(t2 / t1) + p1.y * CGFloat(t2 / t1 - 1)) * CGFloat(t2 / (3 * (t1 + t2)))
    // c2 along the tangent at p2, mirrored.
    let m2x = (p1.x - p3.x * CGFloat(t2 / t3) + p2.x * CGFloat(t2 / t3 - 1)) * CGFloat(t2 / (3 * (t2 + t3)))
    let m2y = (p1.y - p3.y * CGFloat(t2 / t3) + p2.y * CGFloat(t2 / t3 - 1)) * CGFloat(t2 / (3 * (t2 + t3)))
    return (
      CGPoint(x: p1.x + m1x, y: p1.y + m1y),
      CGPoint(x: p2.x + m2x, y: p2.y + m2y),
    )
  }

  /// De Casteljau quadratic Bezier evaluation at parameter `t ∈ [0, 1]`.
  /// Hoisted out of `Path.forEach` sample loops so its callers (the
  /// `GenreMapRoutingVerifier` DEBUG strand verifier + the spline-
  /// geometry / routing unit tests) share one implementation. Broken
  /// into named intermediates so Swift's type-checker doesn't blow up
  /// on chained `*`-expressions (`swiftformat preferForLoop` rewrite
  /// hit this previously).
  nonisolated static func quadBezier(
    from p0: CGPoint,
    control p1: CGPoint,
    to p2: CGPoint,
    t: Double,
  ) -> CGPoint {
    let oneMinusT = 1.0 - t
    let ax = oneMinusT * oneMinusT * Double(p0.x)
    let bx = 2 * oneMinusT * t * Double(p1.x)
    let cx = t * t * Double(p2.x)
    let ay = oneMinusT * oneMinusT * Double(p0.y)
    let by = 2 * oneMinusT * t * Double(p1.y)
    let cy = t * t * Double(p2.y)
    return CGPoint(x: ax + bx + cx, y: ay + by + cy)
  }

  /// De Casteljau cubic Bezier evaluation at parameter `t ∈ [0, 1]`.
  /// Same dedupe + named-intermediate rationale as `quadBezier`.
  nonisolated static func cubicBezier(
    from p0: CGPoint,
    control1 p1: CGPoint,
    control2 p2: CGPoint,
    to p3: CGPoint,
    t: Double,
  ) -> CGPoint {
    let oneMinusT = 1.0 - t
    let m = oneMinusT * oneMinusT * oneMinusT
    let n = 3.0 * oneMinusT * oneMinusT * t
    let o = 3.0 * oneMinusT * t * t
    let p = t * t * t
    let x = m * Double(p0.x) + n * Double(p1.x) + o * Double(p2.x) + p * Double(p3.x)
    let y = m * Double(p0.y) + n * Double(p1.y) + o * Double(p2.y) + p * Double(p3.y)
    return CGPoint(x: x, y: y)
  }

  // MARK: Private

  private nonisolated static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    let dx = Double(a.x - b.x)
    let dy = Double(a.y - b.y)
    return (dx * dx + dy * dy).squareRoot()
  }
}
