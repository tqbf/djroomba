import SwiftUI

/// The dismissable "you're looking at a slice" affordance.
///
/// The graph is far too large to ever fit on screen and we never try to — we
/// open zoomed in on one node. This unobtrusive chip tells the user that, and
/// how to move around. It disappears the moment they pan or zoom (progressive
/// disclosure — macOS idiom: surface guidance, then get out of the way).
struct GraphHintChip: View {
    let nodeCount: Int
    let centerLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: .capsule)
        .overlay(
            Capsule().strokeBorder(.separator, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Showing a slice of \(nodeCount) nodes near \(centerLabel). "
            + "Drag to pan, scroll to zoom."
        )
    }

    private var message: String {
        let near = centerLabel.isEmpty ? "" : " · near \(centerLabel)"
        return "Slice of \(nodeCount.formatted()) nodes\(near)  ·  drag to pan · scroll to zoom"
    }
}
