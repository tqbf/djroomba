import SwiftUI

// MARK: - BranchPill

/// A depth-1+ branch genre pill (`plans/son-of-genre-map.md` Phase B —
/// "Visual grammar"). Renders sub-trunk genres at a smaller weight +
/// size than `TrunkPill`, so the visual hierarchy reads top-down:
/// **trunks first, branches next, sub-branches last**. The community
/// colour pulls from the trunk this branch belongs to (claimed by the
/// BFS forest) so an entire subtree shares one hue.
///
/// Typography (depth-driven):
///
/// - **Depth 1 (branch)**: `13pt` → `15pt`, `.medium` weight.
/// - **Depth 2 (sub-branch)**: `11pt` → `12pt`, `.regular` weight.
/// - **Depth 3+ (deep)**: `10pt`, `.regular`. Floor — the real-library
///   MST rarely recurses that deep; if it does, the labels stay
///   legible without competing with the upper levels.
///
/// Trunk vs branch differentiation is by size + weight + chrome
/// thickness, NOT by glyph (the metro plan's diamond.fill glyph for
/// junctions is metro-specific and retires with the metro panel).
struct BranchPill: View {

  // MARK: Internal

  /// Genre + per-genre weight (`[0, 1]`). Weight currently affects
  /// only the depth-1 font size (depths 2+ ignore it); both reads of
  /// the field are commented below.
  var genre: Genre
  /// Tree depth (1, 2, 3+). The renderer picks the size + weight ramp
  /// off depth, not off `weight`, because the visual hierarchy *is*
  /// the tree's depth.
  var depth: Int
  /// Subtree's community colour. The same hue across the whole
  /// subtree — the BFS forest's first-claim rule means every branch
  /// of a trunk renders in the trunk's community colour.
  var colour: Color
  /// Phase C affordance; Phase B passes `false`.
  var isHighlighted = false
  /// Phase C affordance; Phase B passes `false`.
  var isFaded = false
  var onTap: () -> Void = { }
  /// Right-click ▸ "Rename…" (genre editing on the map). No-op by default.
  var onRename: () -> Void = { }

  var body: some View {
    Text(genre.name)
      .font(.system(size: fontSize, weight: fontWeight, design: .rounded))
      .lineLimit(1)
      .fixedSize()
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background(
        Capsule(style: .continuous)
          .fill(.regularMaterial)
          .overlay(
            Capsule(style: .continuous)
              .fill(colour.opacity(backgroundOpacity))
          )
          .overlay(
            Capsule(style: .continuous)
              .strokeBorder(colour.opacity(borderOpacity), lineWidth: borderWidth)
          )
      )
      .foregroundStyle(.primary)
      .contentShape(Rectangle())
      .onTapGesture(perform: onTap)
      .contextMenu {
        Button("Rename…", systemImage: "pencil", action: onRename)
      }
      .opacity(isFaded ? 0.18 : 1.0)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityDescription)
      .accessibilityAddTraits(.isButton)
  }

  // MARK: Private

  /// Depth-driven font size. Depth-1 scales modestly with per-genre
  /// weight (the heaviest branch reads a touch larger than its
  /// siblings); depths 2+ pin to a single size — the hierarchy is
  /// already expressed by depth, and varying inside a depth would
  /// muddy the read.
  private var fontSize: CGFloat {
    switch depth {
    case 1: 13 + CGFloat(genre.weight) * 2 // 13 → 15
    case 2: 11 + CGFloat(genre.weight) * 1 // 11 → 12
    default: 10
    }
  }

  private var fontWeight: Font.Weight {
    switch depth {
    case 1: .medium
    default: .regular
    }
  }

  private var horizontalPadding: CGFloat {
    switch depth {
    case 1: 10
    case 2: 8
    default: 6
    }
  }

  private var verticalPadding: CGFloat {
    switch depth {
    case 1: 4
    case 2: 3
    default: 2
    }
  }

  /// Background tint. Slightly tinted at depth 1, very faint at depth
  /// 2+ — the eye reads the parent subtree by colour, but a deep
  /// branch shouldn't read as a coloured block (the trunk is the
  /// colour anchor; deep branches are subordinate).
  private var backgroundOpacity: Double {
    switch depth {
    case 1: 0.10
    case 2: 0.06
    default: 0.04
    }
  }

  /// Border opacity. Depth 1 has a clear ring; depth 2+ a faint one.
  /// Highlighted ⇒ bumps a step for both depths.
  private var borderOpacity: Double {
    let base: Double = depth == 1 ? 0.5 : 0.35
    return isHighlighted ? min(1, base + 0.3) : base
  }

  private var borderWidth: CGFloat {
    let base: CGFloat = depth == 1 ? 1.0 : 0.8
    return isHighlighted ? base + 0.8 : base
  }

  private var accessibilityDescription: String {
    let kind: String = depth == 1 ? "branch" : "sub-branch"
    let percent = Int((genre.weight * 100).rounded())
    return "\(genre.name), \(kind), depth \(depth), weight \(percent)"
  }
}
