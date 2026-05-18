import SwiftUI

/// A tiny, unobtrusive HUD stat — currently the live edge-crossing count.
///
/// Bottom-trailing, out of the way of the top-centre search HUD and the
/// bottom-leading slice hint. Secondary tone, 11pt (the rendering spec's HUD
/// stat size), vibrancy material so it floats over the opaque graph without
/// fighting it. The count is the cheap value `CrossingIndex` produces on settle
/// — it is *always* meaningful even when the knot glyphs are LOD-suppressed, so
/// it stays a useful read-out at any zoom.
///
/// Honours Differentiate Without Color: the meaning never relies on colour, it
/// is always an icon + a number + a word.
struct GraphStatChip: View {
    let crossingCount: Int

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "scribble.variable")
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 11, weight: .regular))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: .capsule)
        .overlay(
            Capsule().strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edge crossings")
        .accessibilityValue(label)
    }

    private var label: String {
        crossingCount == 1 ? "1 crossing" : "\(crossingCount) crossings"
    }
}
