import SwiftUI

// MARK: - StationLabel

/// A single genre node rendered as a labelled pill
/// (`plans/genre-metro-map.md` Phase 1, step 7 — "major nodes as labelled
/// pills sized by per-genre weight").
///
/// Font size scales with the genre's normalised `weight` (`[0, 1]`),
/// clamped to `minFontSize…maxFontSize` so a tiny genre stays legible and
/// a giant one doesn't dominate. Background uses `.regularMaterial` for the
/// native macOS chrome (vibrancy-aware, dark-mode-correct).
struct StationLabel: View {

  // MARK: Internal

  /// Font size for `weight`. Public so the layout pipeline can read the
  /// SAME numbers for its label-rectangle repulsion.
  static let minFontSize: CGFloat = 11
  static let maxFontSize: CGFloat = 22

  var node: GenreMapNode
  var community: GenreMapCommunity?
  /// Tint by community id. Drawn as a thin coloured ring + low-opacity
  /// fill on the pill, so the eye groups same-coloured pills together
  /// even at small font sizes.
  var hullColour: Color

  /// The label is wrapped in a `Button` so accessibility + selection
  /// behaviour are native; the action is set by the parent.
  var onTap: () -> Void

  var body: some View {
    Button(action: onTap) {
      Text(node.genre)
        .font(.system(size: fontSize, weight: weightForFont, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
          Capsule(style: .continuous)
            .fill(.regularMaterial)
            .overlay(
              Capsule(style: .continuous)
                .strokeBorder(hullColour.opacity(0.45), lineWidth: 1)
            )
            .overlay(
              Capsule(style: .continuous)
                .fill(hullColour.opacity(0.06))
            )
        )
        .foregroundStyle(.primary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(node.genre), weight \(Int((node.weight * 100).rounded()))")
  }

  // MARK: Private

  private var fontSize: CGFloat {
    Self.minFontSize
      + CGFloat(node.weight) * (Self.maxFontSize - Self.minFontSize)
  }

  /// Bigger genres get a heavier weight (typography-designer: visual
  /// hierarchy expressed in size + weight, not size alone).
  private var weightForFont: Font.Weight {
    switch node.weight {
    case ..<0.25: .regular
    case ..<0.6: .medium
    default: .semibold
    }
  }
}
