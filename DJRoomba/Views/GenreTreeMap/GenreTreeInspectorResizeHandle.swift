import AppKit
import SwiftUI

/// The drag strip on the inspector's leading edge. Dragging left widens
/// the inspector (and narrows the graph), right narrows it, clamped to
/// `range`. Shows the standard macOS left/right resize cursor on hover
/// and is VoiceOver-adjustable. The horizontal sibling of
/// `GenreTreePaneResizeHandle`.
struct GenreTreeInspectorResizeHandle: View {

  // MARK: Internal

  @Binding var width: Double

  let range: ClosedRange<Double>

  var body: some View {
    ZStack {
      Rectangle()
        .fill(Color(nsColor: .separatorColor))
        .frame(width: 1)
      Capsule()
        .fill(.secondary.opacity(0.35))
        .frame(width: 4, height: 40)
    }
    .frame(width: 11)
    .frame(maxHeight: .infinity)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { value in
          let base = startWidth ?? width
          if startWidth == nil { startWidth = base }
          // Drag left (negative translation) ⇒ wider inspector.
          width = min(
            range.upperBound,
            max(range.lowerBound, base - value.translation.width),
          )
        }
        .onEnded { _ in startWidth = nil }
    )
    .onHover { inside in
      if inside {
        NSCursor.resizeLeftRight.push()
      } else {
        NSCursor.pop()
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Resize inspector")
    .accessibilityValue("\(Int(width)) points wide")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        width = min(range.upperBound, width + 24)

      case .decrement:
        width = max(range.lowerBound, width - 24)

      @unknown default:
        break
      }
    }
  }

  // MARK: Private

  @State private var startWidth: Double?
}
