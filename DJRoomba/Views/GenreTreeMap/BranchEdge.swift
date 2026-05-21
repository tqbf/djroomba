import SwiftUI

// MARK: - BranchEdge

/// Parent → child curve renderer (`plans/son-of-genre-map.md` Phase B —
/// "Visual grammar"). Draws every parent → child edge in the trunk-tree
/// as a single cubic Bezier (`GenreTreeLayout.BezierCurve`), reusing
/// the layout pass's pre-computed control points — no re-running of the
/// spline kernel.
///
/// **Why a single Bezier per edge, not the metro renderer's
/// centripetal Catmull-Rom polyline pass.** The metro plan's
/// `StrandSpline` decomposes an `n`-point polyline into per-segment
/// cubic Beziers; this view draws *one* segment per edge (one
/// parent-child pair). The math is the same primitive — a Bezier
/// segment — but the consumer-facing shape is simpler, so the new
/// view doesn't import the retiring metro renderer.
///
/// Rendered as a SwiftUI `Canvas`: one stroke per edge, ~115 edges
/// per layout (n-1 over the MST + the depth recursion). No
/// hit-testing at the edge level — Phase C / D do all selection on
/// the pills.
///
/// Stroke styling:
///
/// - **Width**: `1.6pt` at depth-1, `1.2pt` at depth-2, `1.0pt`
///   deeper. The eye follows the trunk → branch lines first; deep
///   sub-branch edges should fade into the background.
/// - **Opacity**: `0.45` baseline. Per-edge opacity is unbumped by
///   hover/selection in Phase B; Phase C / D layer on top.
/// - **Colour**: the subtree's community colour, same hue as the
///   trunk + pills it connects. The edge inherits identity from the
///   subtree — a green subtree reads as green pills connected by
///   green lines.
struct BranchEdge: View {

  // MARK: Internal

  /// The pre-computed Bezier (start + control1 + control2 + end). The
  /// layout returns world-space coordinates; the panel passes the
  /// `project` closure to convert to screen-space at draw time.
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
      let control1 = project(curve.control1)
      let control2 = project(curve.control2)
      let end = project(curve.end)
      var path = Path()
      path.move(to: start)
      path.addCurve(to: end, control1: control1, control2: control2)
      context.stroke(
        path,
        with: .color(colour.opacity(0.45)),
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
    case 1: 1.6
    case 2: 1.2
    default: 1.0
    }
  }
}
