import SwiftUI

/// State handed to the caller's `style` callback so it can react to the
/// graph's current interaction state (selection, hover, search, distance).
///
/// In Phase 1 there is no simulation or search yet, so `isSearchMatch` /
/// `searchActive` are always `false`; `distanceFromSelection` is populated via
/// BFS whenever a selection exists. The shape is final so callers (and the
/// default resolver) can be written against it now.
public struct NodeContext: Sendable {
    /// This node is the current selection (the focal, pinned-centre node).
    public let isSelected: Bool
    /// The pointer is hovering this node.
    public let isHovered: Bool

    /// A node is selected somewhere in the graph (not necessarily this one).
    /// Lets the resolver tell "no selection at all" apart from "a selection
    /// exists but this node isn't connected to it" — the latter is gently
    /// dimmed so the focal node + its neighbours read.
    public let hasSelection: Bool

    /// BFS hop count from the current selection; `nil` when there is no
    /// selection or the node is unreachable from it.
    public let distanceFromSelection: Int?
    /// This node matches the active search query.
    public let isSearchMatch: Bool
    /// A search query is active (use this to dim non-matches).
    public let searchActive: Bool
    /// Number of distinct neighbours (high degree ⇒ a landmark hub).
    public let degree: Int

    /// The live appearance. Light is the primary mode; the default resolver
    /// and caller callbacks must pick colours for this scheme.
    public let colorScheme: ColorScheme

    public init(
        isSelected: Bool = false,
        isHovered: Bool = false,
        hasSelection: Bool = false,
        distanceFromSelection: Int? = nil,
        isSearchMatch: Bool = false,
        searchActive: Bool = false,
        degree: Int = 0,
        colorScheme: ColorScheme = .light
    ) {
        self.isSelected = isSelected
        self.isHovered = isHovered
        self.hasSelection = hasSelection
        self.distanceFromSelection = distanceFromSelection
        self.isSearchMatch = isSearchMatch
        self.searchActive = searchActive
        self.degree = degree
        self.colorScheme = colorScheme
    }
}
