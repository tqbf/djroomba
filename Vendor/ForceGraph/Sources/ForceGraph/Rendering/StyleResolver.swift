import SwiftUI

/// Bridges the caller's `style` callback (or the built-in default) to the
/// renderer.
///
/// The library never inspects `Value`; it only passes the node and a
/// `NodeContext` to the resolver and renders whatever `NodeStyle` comes back.
/// The default resolver is pure hash→hue; a caller callback fully overrides it.
struct StyleResolver<Value: Sendable> {
    let scheme: ColorScheme
    let style: (GraphNode<Value>, NodeContext) -> NodeStyle

    func resolve(_ node: GraphNode<Value>, _ context: NodeContext) -> NodeStyle {
        style(node, context)
    }
}

extension GraphNode {
    /// The library default: stable hash→hue. Caller `style` closures default
    /// to this (see `ForceGraphView.init`).
    public static func defaultStyle(
        _ node: GraphNode<Value>,
        _ context: NodeContext
    ) -> NodeStyle {
        NodeStyle.hashHue(node.label, context, scheme: context.colorScheme)
    }
}
