import AppKit
import SwiftUI

/// The drag strip on the bottom dock pane's top edge. Dragging up grows
/// the body, down shrinks it (the pane is bottom-docked, so the top edge
/// is the resizable one), clamped to `range`. Shows the standard macOS
/// up/down resize cursor on hover and is VoiceOver-adjustable.
///
/// Originally `GenreTreePaneResizeHandle` (genre-map-only); when the
/// genre map began sharing the docked pane with the DJ Roomba assistant
/// tab (2026-05-29) this generalised to `BottomDockResizeHandle`.
struct BottomDockResizeHandle: View {

  // MARK: Internal

  @Binding var height: Double

  let range: ClosedRange<Double>

  var body: some View {
    ZStack {
      Color.clear
      Capsule()
        .fill(.secondary.opacity(0.35))
        .frame(width: 40, height: 4)
    }
    .frame(height: 11)
    .contentShape(Rectangle())
    .gesture(
      DragGesture(minimumDistance: 1)
        .onChanged { value in
          let base = startHeight ?? height
          if startHeight == nil { startHeight = base }
          // Drag up (negative translation) ⇒ taller.
          height = min(
            range.upperBound,
            max(range.lowerBound, base - value.translation.height),
          )
        }
        .onEnded { _ in startHeight = nil }
    )
    .onHover { inside in
      if inside {
        NSCursor.resizeUpDown.push()
      } else {
        NSCursor.pop()
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Resize bottom pane")
    .accessibilityValue("\(Int(height)) points tall")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        height = min(range.upperBound, height + 24)

      case .decrement:
        height = max(range.lowerBound, height - 24)

      @unknown default:
        break
      }
    }
  }

  // MARK: Private

  @State private var startHeight: Double?
}
