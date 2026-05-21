import SwiftUI

// MARK: - StationLabel

/// A single genre node rendered as a labelled pill
/// (`plans/genre-metro-map.md` Phase 1, step 7 + Phase 2's three node
/// kinds — ordinary stop, junction, transfer station).
///
/// Font size scales with the genre's normalised `weight` (`[0, 1]`),
/// clamped to `minFontSize…maxFontSize` so a tiny genre stays legible and
/// a giant one doesn't dominate. Background uses `.regularMaterial` for the
/// native macOS chrome (vibrancy-aware, dark-mode-correct).
///
/// **Phase 2 differentiation** (per typography-designer review):
/// - **No font-size or weight bump** for junctions / transfer stations —
///   the weight-derived size/weight ramp already established the visual
///   hierarchy; competing on size+kind muddies both signals.
/// - **Leading SF Symbol glyph** inside the pill instead. `diamond.fill`
///   for junctions; `point.3.connected.trianglepath.dotted` for transfer
///   stations. Glyph renders in `hullColour` at full opacity, sized
///   `fontSize * 0.85` semibold, leading the `HStack(spacing: 4)`.
/// - **Border-weight differentiation:** ordinary 1pt @ 0.45α; junction
///   1pt @ 0.55α; transfer station 1.5pt @ 0.85α. Background fills land
///   at 0.06 / 0.08 / 0.12 of `hullColour`. Border thickness lives inside
///   the capsule, so it doesn't change measured `labelSize`.
struct StationLabel: View {

  // MARK: Internal

  /// Font size for `weight`. Public so the layout pipeline can read the
  /// SAME numbers for its label-rectangle repulsion. Range widened
  /// 11→22 ⇒ 12→26 at the Phase-1 gate per typography-designer: a 2×
  /// span over a long-tailed ~115-genre distribution wasn't enough
  /// visual altitude for the giants vs the medium band; 12pt is the
  /// Apple-readable floor for ambient label text.
  static let minFontSize: CGFloat = 12
  static let maxFontSize: CGFloat = 26

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
    HStack(spacing: 4) {
      if let glyph = leadingGlyph {
        Image(systemName: glyph)
          .font(.system(size: fontSize * 0.85, weight: .semibold))
          .foregroundStyle(hullColour)
      }
      Text(node.genre)
        .font(.system(size: fontSize, weight: weightForFont, design: .rounded))
        .lineLimit(1)
        .fixedSize()
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 4)
    .background(
      Capsule(style: .continuous)
        .fill(.regularMaterial)
        .overlay(
          Capsule(style: .continuous)
            .strokeBorder(hullColour.opacity(borderOpacity), lineWidth: borderWidth)
        )
        .overlay(
          Capsule(style: .continuous)
            .fill(hullColour.opacity(backgroundOpacity))
        )
    )
    .foregroundStyle(.primary)
    // Tap-gesture on the pill body (instead of a Button) so the parent
    // panel can attach a `.simultaneousGesture(DragGesture)` for node
    // drag without a Button's internal gesture stack starving simple
    // taps. `.contentShape(Capsule())` makes the entire pill rectangle
    // a click target — pre-shape clips were letting clicks fall through
    // the pill outside the capsule's bounds.
    .contentShape(Capsule(style: .continuous))
    .onTapGesture(perform: onTap)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(accessibilityDescription)
    .accessibilityAddTraits(.isButton)
  }

  // MARK: Private

  private var fontSize: CGFloat {
    Self.minFontSize
      + CGFloat(node.weight) * (Self.maxFontSize - Self.minFontSize)
  }

  /// Bigger genres get a heavier weight (typography-designer: visual
  /// hierarchy expressed in size + weight, not size alone). Four tiers
  /// (regular → medium → semibold → bold) at the Phase-1 gate per the
  /// typography-designer review: the top ~5 % of giants need to read as
  /// "a different class of label" (continent-rank), not as slightly
  /// thicker peers.
  private var weightForFont: Font.Weight {
    switch node.weight {
    case ..<0.20: .regular
    case ..<0.55: .medium
    case ..<0.80: .semibold
    default: .bold
    }
  }

  private var leadingGlyph: String? {
    switch node.nodeKind {
    case .ordinary: nil
    case .junction: "diamond.fill"
    case .transferStation: "point.3.connected.trianglepath.dotted"
    }
  }

  private var borderOpacity: Double {
    switch node.nodeKind {
    case .ordinary: 0.45
    case .junction: 0.55
    case .transferStation: 0.85
    }
  }

  private var borderWidth: CGFloat {
    switch node.nodeKind {
    case .ordinary,
         .junction: 1.0
    case .transferStation: 1.5
    }
  }

  private var backgroundOpacity: Double {
    switch node.nodeKind {
    case .ordinary: 0.06
    case .junction: 0.08
    case .transferStation: 0.12
    }
  }

  private var accessibilityDescription: String {
    let weightPercent = Int((node.weight * 100).rounded())
    switch node.nodeKind {
    case .ordinary:
      return "\(node.genre), weight \(weightPercent)"
    case .junction:
      return "\(node.genre), junction, weight \(weightPercent)"
    case .transferStation:
      let transferPercent = Int((node.transferness * 100).rounded())
      return "\(node.genre), transfer station, transferness \(transferPercent), weight \(weightPercent)"
    }
  }
}
