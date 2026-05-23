import SwiftUI

// MARK: - BackEdgeLayer

/// Faint non-tree edge renderer (`plans/son-of-genre-map.md` Phase B —
/// "Visual grammar" → "Faint back-edges"). Renders every
/// `genre_edge_evidence` edge that the MST dropped as a near-invisible
/// straight line — `~6%` opacity, `0.6pt` weight. The eye knows the
/// extra connectivity is there; the topology doesn't crowd because of
/// them.
///
/// One `Canvas` for the *entire* back-edge layer, not one view per
/// edge — the real library has hundreds of back-edges (~117 candidate
/// pairs, ~114 MST-kept ⇒ a few dozen back-edges, more on a wider
/// substrate). One canvas + one path draws them all in a single
/// stroke call, avoiding ~50 SwiftUI views for what's intentionally
/// background ink.
struct BackEdgeLayer: View {

  /// Each back-edge as `(start, end)` in world coordinates. The panel
  /// derives this list from `genre_edge_evidence − MST kept edges`
  /// and feeds it once per build.
  struct BackEdgeSegment: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
    /// Composite edge weight `[0, 1]`. Scales the per-edge opacity
    /// inside the `0.025 … 0.075` band so heavier dropped edges
    /// (closer to MST-membership) read fractionally more present than
    /// the long-tail noise. Capped at `~8 %` — the plan's ceiling.
    var totalWeight: Double
  }

  var segments: [BackEdgeSegment]
  var project: (CGPoint) -> CGPoint

  var body: some View {
    Canvas { context, _ in
      for segment in segments {
        let start = project(segment.start)
        let end = project(segment.end)
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let opacity = 0.025 + 0.05 * segment.totalWeight // 0.025 … ~0.075
        context.stroke(
          path,
          with: .color(.primary.opacity(opacity)),
          lineWidth: 0.6,
        )
      }
    }
    .allowsHitTesting(false)
  }
}
