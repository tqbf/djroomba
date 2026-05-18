import AppKit
import SwiftUI

/// The drag strip on the genre panel's top edge. Dragging it up grows the
/// graph body, down shrinks it (the panel is bottom-docked, so the top edge
/// is the resizable one), clamped to `range`. Shows the standard macOS
/// up/down resize cursor on hover and is VoiceOver-adjustable.
struct GenreGraphResizeHandle: View {

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
      // Standard resize affordance; pop on exit so the cursor doesn't
      // stick if the pointer leaves mid-idle.
      if inside {
        NSCursor.resizeUpDown.push()
      } else {
        NSCursor.pop()
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Resize genre graph")
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

  /// Body height at the drag's start, so the resize tracks the pointer
  /// from where it grabbed rather than drifting per frame.
  @State private var startHeight: Double?
}
