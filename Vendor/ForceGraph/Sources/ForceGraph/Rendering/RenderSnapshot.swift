import Foundation

/// An immutable, value-type description of everything the Canvas needs to draw
/// one frame.
///
/// `GraphEngine` (the only `@Observable`) republishes this when state changes;
/// the Canvas reads it without touching the engine, so expensive math never
/// runs in `body` and there is no per-node view churn. Indices into the arrays
/// are parallel to `nodes` / `edges` so the renderer can iterate without
/// dictionary lookups.
struct RenderSnapshot: Sendable {
    /// One drawable node. `style` is pre-resolved for the current colour
    /// scheme and interaction state. `isSearchMatch` lets the renderer add a
    /// lively pulse to matches without re-running the style closure per frame.
    struct Node: Sendable {
        let id: NodeID
        let label: String
        let position: Vector2
        let style: NodeStyle
        let degree: Int
        let isSearchMatch: Bool

        init(
            id: NodeID,
            label: String,
            position: Vector2,
            style: NodeStyle,
            degree: Int,
            isSearchMatch: Bool = false
        ) {
            self.id = id
            self.label = label
            self.position = position
            self.style = style
            self.degree = degree
            self.isSearchMatch = isSearchMatch
        }
    }

    /// One drawable edge as resolved endpoint positions plus weight.
    /// `bothMatch` (search active, both endpoints matched) keeps the edge lit
    /// while every other edge dims down with its nodes.
    struct Edge: Sendable {
        let a: Vector2
        let b: Vector2
        let weight: Double
        let bothMatch: Bool
        /// One endpoint is the selected/focal node — drawn prominently
        /// (heavier, brighter, on top) so the focal node's neighbours are
        /// unmistakable.
        let incidentToFocus: Bool

        init(
            a: Vector2,
            b: Vector2,
            weight: Double,
            bothMatch: Bool = false,
            incidentToFocus: Bool = false
        ) {
            self.a = a
            self.b = b
            self.weight = weight
            self.bothMatch = bothMatch
            self.incidentToFocus = incidentToFocus
        }
    }

    /// Search is active for this frame (drives edge dimming + node pulse).
    let searchActive: Bool

    /// Pre-ordered for draw (ordinary → hub → selected) by `GraphEngine` so
    /// the renderer never sorts per frame.
    let nodes: [Node]
    let edges: [Edge]

    /// Screen-space edge crossings detected by `CrossingIndex` on the last
    /// settle (LOD-gated). Carried on the snapshot so the renderer can draw
    /// knot glyphs without recomputing — it never recomputes per frame.
    let crossings: [CrossingIndex.Crossing]

    /// The live crossing count, surfaced in the HUD even when the knot glyphs
    /// themselves are LOD-suppressed (cheap; `crossings` may be empty while
    /// this is non-zero if glyph rendering is suppressed).
    let crossingCount: Int

    static let empty = RenderSnapshot(nodes: [], edges: [])

    init(
        nodes: [Node],
        edges: [Edge],
        searchActive: Bool = false,
        crossings: [CrossingIndex.Crossing] = [],
        crossingCount: Int = 0
    ) {
        self.nodes = nodes
        self.edges = edges
        self.searchActive = searchActive
        self.crossings = crossings
        self.crossingCount = crossingCount
    }
}
