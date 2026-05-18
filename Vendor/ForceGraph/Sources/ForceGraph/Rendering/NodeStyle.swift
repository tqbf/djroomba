import SwiftUI

/// A fully resolved per-node visual style.
///
/// Produced by `StyleResolver` (default hash→hue) or by the caller's `style`
/// callback, then consumed verbatim by `GraphCanvasRenderer`. It carries no
/// behaviour — purely how a node should look this frame.
public struct NodeStyle: Sendable {
    /// The node capsule fill colour.
    public var fill: Color
    /// The label colour (pick for contrast against `fill`).
    public var textColor: Color
    /// Label point size.
    public var fontSize: CGFloat
    /// Label weight (hierarchy is size + weight + opacity, not colour).
    public var fontWeight: Font.Weight
    /// Extra space (per side) between the label and the capsule edge.
    public var capsulePadding: CGSize
    /// Whole-node opacity (de-emphasis is opacity, never a lighter weight).
    public var opacity: Double
    /// Letter spacing in points; applied to the label text (focal node only
    /// by default).
    public var tracking: CGFloat

    public init(
        fill: Color,
        textColor: Color,
        fontSize: CGFloat,
        fontWeight: Font.Weight,
        capsulePadding: CGSize = CGSize(width: 10, height: 6),
        opacity: Double = 1,
        tracking: CGFloat = 0
    ) {
        self.fill = fill
        self.textColor = textColor
        self.fontSize = fontSize
        self.fontWeight = fontWeight
        self.capsulePadding = capsulePadding
        self.opacity = opacity
        self.tracking = tracking
    }

    /// The zero-config default: stable **hash → hue** fill, luminance-picked
    /// text colour, and the type role implied by `NodeContext`
    /// (selection distance, hub status). Callers can override entirely via
    /// the `ForceGraphView` `style` callback.
    public static func hashHue(
        _ label: String,
        _ ctx: NodeContext,
        scheme: ColorScheme = .light
    ) -> NodeStyle {
        var role: GraphTypography.Role
        if ctx.isSelected {
            role = GraphTypography.selected
        } else if let distance = ctx.distanceFromSelection {
            role = GraphTypography.role(forDistance: distance)
        } else if ctx.searchActive && !ctx.isSearchMatch {
            role = GraphTypography.distant
        } else if ctx.degree >= 24 {
            role = GraphTypography.hub
        } else {
            role = GraphTypography.base
        }

        // A search match (any ring) reads one size step larger, at least
        // Semibold, full opacity — the lively pulse is added by the renderer.
        // This is on top of whatever ring role it would otherwise have.
        if ctx.searchActive, ctx.isSearchMatch {
            role = GraphTypography.emphasised(role)
        }

        let opacity: Double
        if ctx.searchActive && !ctx.isSearchMatch {
            opacity = 0.18
        } else if !ctx.searchActive
            && ctx.hasSelection
            && !ctx.isSelected
            && ctx.distanceFromSelection == nil {
            // A node not connected to the focal node: slightly dimmed so the
            // focus + its neighbours stand out, while staying clearly legible
            // (much gentler than the search-dim). Connected-but-distant nodes
            // keep their ring opacity, so they read brighter than this.
            opacity = 0.5
        } else {
            opacity = role.opacity
        }

        return NodeStyle(
            fill: Palette.fill(for: label, scheme: scheme),
            textColor: Palette.textColor(onFill: label, scheme: scheme),
            fontSize: role.size,
            fontWeight: role.weight,
            opacity: opacity,
            tracking: role.tracking
        )
    }
}
