import SwiftUI

// MARK: - StrandSpline

/// Phase 3 renderer for one metro strand
/// (`plans/genre-metro-map.md` Phase 3, step 6). Draws a faint
/// Catmull-Rom spline through the strand's ordered station positions
/// in world space. No routing / bundling / obstacle avoidance yet —
/// that's Phase 4. Splines may cross; we lean into the "metro overlay
/// is more sketch than diagram" affordance until Phase 4 lands.
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

  /// Build a Catmull-Rom path through `points` (uniform parameterisation,
  /// tension = 0.5). Endpoints are duplicated so the curve starts/ends
  /// at the first/last sample. Returns a straight polyline for n < 3.
  static func catmullRomPath(points: [CGPoint]) -> Path {
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
    for i in 1 ..< samples.count - 2 {
      let p0 = samples[i - 1]
      let p1 = samples[i]
      let p2 = samples[i + 1]
      let p3 = samples[i + 2]
      let control1 = CGPoint(
        x: p1.x + (p2.x - p0.x) / 6.0,
        y: p1.y + (p2.y - p0.y) / 6.0,
      )
      let control2 = CGPoint(
        x: p2.x - (p3.x - p1.x) / 6.0,
        y: p2.y - (p3.y - p1.y) / 6.0,
      )
      path.addCurve(to: p2, control1: control1, control2: control2)
    }
    return path
  }
}
