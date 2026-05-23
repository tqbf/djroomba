import SwiftUI

// MARK: - FocusSpokeLayer

/// The bold "direct connection" layer drawn only in radial-focus mode
/// (`plans/son-of-genre-map.md` Phase C). When a genre is highlighted,
/// its 1-hop neighbours fan around it — but the *connections* to them
/// were previously implicit (a dimmed back-edge here, an occasional
/// tree edge there), so they read at the same weight as everything else
/// and "blended together" (user feedback, 2026-05-22).
///
/// This layer makes them dramatically dominant: a thick, saturated spoke
/// from the focused genre (the hub) straight out to each direct
/// neighbour, the only bold ink in the focused canvas. Stronger
/// connections draw thicker (`weight` scales the line width), so the
/// most-similar genres read first.
///
/// One `Canvas` for the whole fan — same single-stroke idiom as
/// `BackEdgeLayer`. Non-hit-testing background ink; the pills above stay
/// clickable.
struct FocusSpokeLayer: View {

  /// One spoke: the neighbour's world position + the normalised edge
  /// weight `[0, 1]` (1 = the strongest connection from the hub).
  struct Spoke: Equatable, Sendable {
    var end: CGPoint
    var weight: Double
  }

  /// The focused genre's world position — the hub every spoke radiates
  /// from.
  var hub: CGPoint
  var spokes: [Spoke]
  /// The focused genre's community colour, so the spokes read as "this
  /// neighbourhood."
  var colour: Color
  var project: (CGPoint) -> CGPoint

  var body: some View {
    Canvas { context, _ in
      let origin = project(hub)
      for spoke in spokes {
        var path = Path()
        path.move(to: origin)
        path.addLine(to: project(spoke.end))
        // 2.5pt floor so even the weakest direct connection is clearly
        // bolder than the ~0.6pt back-edge web; +4pt headroom for the
        // strongest. Round caps so the spokes tuck under the pills
        // cleanly.
        let width = 2.5 + 4.0 * CGFloat(spoke.weight)
        context.stroke(
          path,
          with: .color(colour.opacity(0.9)),
          style: StrokeStyle(lineWidth: width, lineCap: .round),
        )
      }
    }
    .allowsHitTesting(false)
  }
}
