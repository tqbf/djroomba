import SwiftUI

// MARK: - TrunkPill

/// A trunk-rank genre pill (`plans/son-of-genre-map.md` Phase B —
/// "Visual grammar"). Renders the depth-0 genre at the largest size
/// in the type scale + a semibold-or-bold weight + community colour,
/// so the eye picks the trunks out of the canvas at a glance.
///
/// Typography (semantic — the `typography-designer` skill picks the
/// scale + weights, this file pins them):
///
/// - **Font size**: `18pt` floor → `22pt` ceiling, scaled by per-genre
///   `weight` (`[0, 1]`). A trunk's role on the canvas is recognisable
///   first by size — the smallest trunk (`weight = 0`) reads at 18pt
///   semibold, which is still 4–5pt larger than every branch pill.
/// - **Weight**: `.semibold` floor → `.bold` above `weight ≥ 0.55`.
///   Two-step ramp so the heaviest trunk reads as bold and the lighter
///   trunks as semibold; matches macos-design's "use weight, not just
///   size, to express hierarchy" guidance.
/// - **Design**: `.rounded` to match `StationLabel`. Trunks and metro
///   stations share the same pill chrome family — we deliberately
///   *don't* introduce a different type family; the tree replaces the
///   metro, but the type idiom carries.
/// - **Background**: thick community-colour border (1.5pt @ 0.7
///   opacity) over a `.regularMaterial` capsule + 0.14-opacity colour
///   wash. The border is the dominant visual; the wash gives the
///   colour identity at a glance.
///
/// Selection / fade state are surfaced for Phase C (radial focus)
/// but inert in Phase B — the panel always passes `isHighlighted =
/// false, isFaded = false`. Wiring them now keeps the renderer's
/// API stable across phases.
struct TrunkPill: View {

  // MARK: Internal

  /// Font-size floor for trunks — `18pt`. Floor (not range floor) so
  /// every trunk reads as a "trunk-rank" label even at minimum weight.
  /// 18 reads as Apple's `.title3`-adjacent without dipping into the
  /// branch range; macos-design + typography-designer both confirm
  /// 18pt as a defensible "section title" anchor for ambient labels.
  static let minFontSize: CGFloat = 18
  /// Font-size ceiling for trunks — `22pt`. Ceiling tight enough that
  /// even the heaviest trunk fits inside a comfortable pill on the
  /// canvas; bigger reads as a heading-rank glyph competing with the
  /// branches, not as a trunk.
  static let maxFontSize: CGFloat = 22

  /// Genre + per-genre weight (`[0, 1]`).
  var genre: Genre
  /// Community colour for this trunk (Phase B uses
  /// `GenreMapPanel.communityColour(for: communityID)`). Border + wash
  /// pull from this.
  var colour: Color
  /// Phase C affordance; Phase B passes `false`.
  var isHighlighted = false
  /// Phase C affordance; Phase B passes `false`.
  var isFaded = false
  /// Phase B click — Phase C will use this to enter radial-focus mode.
  /// Phase B owns the gesture for the inspector affordance only.
  var onTap: () -> Void = { }

  var body: some View {
    Text(genre.name)
      .font(.system(size: fontSize, weight: fontWeight, design: .rounded))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(
        Capsule(style: .continuous)
          .fill(.regularMaterial)
          .overlay(
            Capsule(style: .continuous)
              .fill(colour.opacity(0.14))
          )
          .overlay(
            Capsule(style: .continuous)
              .strokeBorder(colour.opacity(borderOpacity), lineWidth: borderWidth)
          )
      )
      .foregroundStyle(.primary)
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .opacity(isFaded ? 0.18 : 1.0)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(genre.name), trunk, weight \(weightPercent)")
      .accessibilityAddTraits(.isButton)
  }

  // MARK: Private

  private var fontSize: CGFloat {
    Self.minFontSize + CGFloat(genre.weight) * (Self.maxFontSize - Self.minFontSize)
  }

  private var fontWeight: Font.Weight {
    // Two-step weight ramp. Above 0.55 of the per-genre weight range a
    // trunk reads as bold (a recognisable continent-rank label);
    // below, semibold. Matches the metro plan's four-tier ramp on
    // `StationLabel`, simplified for a trunk-only widget.
    genre.weight >= 0.55 ? .bold : .semibold
  }

  private var borderOpacity: Double {
    isHighlighted ? 0.95 : 0.7
  }

  private var borderWidth: CGFloat {
    isHighlighted ? 2.5 : 1.5
  }

  private var weightPercent: Int {
    Int((genre.weight * 100).rounded())
  }
}
