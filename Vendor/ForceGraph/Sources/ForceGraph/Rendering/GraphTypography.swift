import SwiftUI

/// The node-label type scale.
///
/// Hierarchy is expressed via *size + weight + opacity* — colour is owned by
/// `Palette`, never used to signal importance. Sizes follow the rendering
/// spec and the macOS convention that 13pt is "body" (we don't inflate).
/// `Font.system` lets the OS pick SF Pro Display (≥20pt) vs SF Pro Text
/// automatically. Minimum on-screen size is 11pt; below the LOD threshold
/// labels are dropped entirely rather than drawn illegibly small.
public enum GraphTypography {
    /// A resolved label role: the three orthogonal hierarchy axes plus the
    /// optional tracking used for the focal anchor.
    public struct Role: Sendable {
        /// Label point size for this role.
        public let size: CGFloat
        /// Label weight for this role.
        public let weight: Font.Weight
        /// Label opacity (de-emphasis is opacity, never a lighter weight).
        public let opacity: Double
        /// Letter spacing in points (negative tightens). Applied to the
        /// focal node only.
        public let tracking: CGFloat

        public init(
            size: CGFloat,
            weight: Font.Weight,
            opacity: Double,
            tracking: CGFloat = 0
        ) {
            self.size = size
            self.weight = weight
            self.opacity = opacity
            self.tracking = tracking
        }
    }

    /// Absolute minimum rendered label size. Below the LOD zoom threshold the
    /// renderer drops labels instead of shrinking past this.
    public static let minimumLabelSize: CGFloat = 11

    /// The focal (selected) node — the unmistakable anchor.
    /// 22 / Bold / 1.0, tracking −0.02em (≈ −0.44pt at 22pt).
    public static let selected = Role(size: 22, weight: .bold, opacity: 1.0, tracking: -0.44)

    /// Ring-1: nodes directly adjacent to the focus.
    public static let ring1 = Role(size: 16, weight: .semibold, opacity: 1.0)

    /// Ring-2.
    public static let ring2 = Role(size: 13, weight: .medium, opacity: 0.92)

    /// Ring-3 and beyond / distant. De-emphasised via opacity, never a
    /// lighter weight.
    public static let distant = Role(size: 12, weight: .regular, opacity: 0.7)

    /// A high-degree node when nothing is selected — reads as a landmark.
    public static let hub = Role(size: 15, weight: .semibold, opacity: 1.0)

    /// Default idle role for an ordinary, unselected node.
    public static let base = Role(size: 13, weight: .regular, opacity: 1.0)

    /// The search-match treatment applied on top of a node's existing ring
    /// role: one size step up (≈ +3pt, clamped so it never out-shouts the
    /// focal node), at least Semibold, full opacity. The lively pulse/scale
    /// is added by the renderer, not here.
    public static func emphasised(_ role: Role) -> Role {
        let bumpedSize = min(role.size + 3, selected.size)
        let bumpedWeight: Font.Weight
        switch role.weight {
        case .bold, .heavy, .black:
            bumpedWeight = role.weight
        default:
            bumpedWeight = .semibold
        }
        return Role(
            size: bumpedSize,
            weight: bumpedWeight,
            opacity: 1.0,
            tracking: role.tracking
        )
    }

    /// Role for a node at the given BFS distance from the current selection.
    public static func role(forDistance distance: Int?) -> Role {
        switch distance {
        case .some(0): selected
        case .some(1): ring1
        case .some(2): ring2
        case .some: distant
        case nil: base
        }
    }
}
