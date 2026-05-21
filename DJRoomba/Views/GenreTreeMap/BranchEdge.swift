import SwiftUI

// MARK: - BranchEdge

/// Parent → child edge renderer (`plans/son-of-genre-map.md` Phase B —
/// "Visual grammar"). Draws every parent → child edge as an **L-shaped
/// path with one rounded corner** ("metro-style" right-angle routing).
///
/// The elbow is placed so the segment travels along its predominant
/// axis first (horizontal first when `|dx| ≥ |dy|`, vertical first
/// otherwise) — this puts the corner near the child end of the edge,
/// the way a metro line lands at a station. The corner is filleted
/// by a quadratic arc of radius `min(8pt, ½ × shorter leg)`.
///
/// Why the L-shape and not the previous cubic Bezier diagonal: a
/// diagonal Bezier from a fan-out radial layout reads as visual noise
/// — every edge is a slightly-different curve and the eye can't lock
/// onto the structural skeleton. Orthogonal L-segments with a rounded
/// elbow read instantly as "tree" — the angles are quantised, the
/// connections are unmistakable.
///
/// Rendered as a SwiftUI `Canvas`: one stroke per edge, ~115 edges
/// per layout (n−1 over the MST + the depth recursion). No
/// hit-testing at the edge level — Phase C / D do all selection on
/// the pills.
///
/// Stroke styling:
///
/// - **Width**: `2.0pt` at depth-1, `1.5pt` at depth-2, `1.2pt`
///   deeper. The eye follows the trunk → branch lines first; deep
///   sub-branch edges still fade gently with depth.
/// - **Opacity**: `0.85` baseline (was `0.45` while we were on
///   diagonals — bumped after the geometry switch made the lines
///   read as primary structure, not decoration). Per-edge opacity is
///   scaled by the panel for Phase C radial-focus + Phase D compare.
/// - **Colour**: the subtree's community colour, same hue as the
///   trunk + pills it connects. The edge inherits identity from the
///   subtree — a green subtree reads as green pills connected by
///   green lines.
struct BranchEdge: View {

  // MARK: Internal

  /// The pre-computed edge geometry from `GenreTreeLayout`. Only
  /// `start` and `end` are consulted by the L renderer; the Bezier
  /// control points are left on the layout API for backward
  /// compatibility (the type is shared with the projection-time
  /// `projectedCurve` helper in `GenreTreeMapPanel`).
  var curve: GenreTreeLayout.BezierCurve
  /// Tree depth of the *child* node. Edge width tapers with depth.
  var childDepth: Int
  /// Subtree colour (inherited from the trunk's community colour).
  var colour: Color
  /// World → screen projection. Same projection closure the pills use
  /// — passed in so the edge view stays a pure consumer (doesn't
  /// observe pan/zoom state directly).
  var project: (CGPoint) -> CGPoint

  var body: some View {
    Canvas { context, _ in
      let start = project(curve.start)
      let end = project(curve.end)
      var path = Path()
      Self.addLPath(&path, from: start, to: end, cornerRadius: 8)
      context.stroke(
        path,
        with: .color(colour.opacity(0.85)),
        style: StrokeStyle(
          lineWidth: lineWidth,
          lineCap: .round,
          lineJoin: .round,
        ),
      )
    }
    .allowsHitTesting(false)
  }

  // MARK: Private

  private var lineWidth: CGFloat {
    switch childDepth {
    case 1: 2.0
    case 2: 1.5
    default: 1.2
    }
  }

  /// L-shape from `start` to `end` with one rounded elbow. Travels
  /// the larger displacement axis first; the elbow sits at the
  /// natural right angle, then is filleted with a quadratic arc.
  ///
  /// `nonisolated static` + pure: every input determines the output;
  /// no view state read.
  fileprivate static func addLPath(
    _ path: inout Path,
    from start: CGPoint,
    to end: CGPoint,
    cornerRadius r: CGFloat,
  ) {
    let dx = end.x - start.x
    let dy = end.y - start.y

    // Degenerate — both axes flat: degenerate to a point/short line.
    if abs(dx) < 0.5, abs(dy) < 0.5 {
      path.move(to: start)
      path.addLine(to: end)
      return
    }
    // Axis-aligned — single straight segment, no elbow.
    if abs(dx) < 0.5 || abs(dy) < 0.5 {
      path.move(to: start)
      path.addLine(to: end)
      return
    }

    let horizontalFirst = abs(dx) >= abs(dy)
    let elbow = horizontalFirst
      ? CGPoint(x: end.x, y: start.y)
      : CGPoint(x: start.x, y: end.y)

    let leg1Length = horizontalFirst ? abs(dx) : abs(dy)
    let leg2Length = horizontalFirst ? abs(dy) : abs(dx)
    let radius = min(r, min(leg1Length, leg2Length) / 2)

    // `approach` is where the incoming leg yields to the fillet;
    // `departure` is where the fillet hands off to the outgoing leg.
    let approach: CGPoint
    let departure: CGPoint
    if horizontalFirst {
      let sx: CGFloat = dx >= 0 ? -1 : 1
      let sy: CGFloat = dy >= 0 ? 1 : -1
      approach = CGPoint(x: elbow.x + sx * radius, y: elbow.y)
      departure = CGPoint(x: elbow.x, y: elbow.y + sy * radius)
    } else {
      let sx: CGFloat = dx >= 0 ? 1 : -1
      let sy: CGFloat = dy >= 0 ? -1 : 1
      approach = CGPoint(x: elbow.x, y: elbow.y + sy * radius)
      departure = CGPoint(x: elbow.x + sx * radius, y: elbow.y)
    }

    path.move(to: start)
    path.addLine(to: approach)
    path.addQuadCurve(to: departure, control: elbow)
    path.addLine(to: end)
  }
}
