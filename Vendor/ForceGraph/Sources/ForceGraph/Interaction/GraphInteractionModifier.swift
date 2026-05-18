import SwiftUI

/// Pan / zoom / hover / click handling for the graph Canvas.
///
/// Kept out of `ForceGraphView.body` (swiftui-pro: short bodies, extract
/// behaviour). All hit-testing is manual against the engine's positions — no
/// SwiftUI hit-testing, no per-node views.
struct GraphInteractionModifier<Value: Sendable>: ViewModifier {
    let engine: GraphEngine<Value>
    @Binding var selection: NodeID?
    let onActivate: ((GraphNode<Value>) -> Void)?

    @State private var dragStartTranslation: CGSize?

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .gesture(panGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let next = engine.node(atScreen: point)
                    if next != engine.hovered {
                        engine.hovered = next
                        // Repaint the hover ring even if the layout is settled
                        // (the redraw loop may be paused).
                        engine.keepRedrawAlive(for: 0.25)
                    }
                case .ended:
                    if engine.hovered != nil {
                        engine.hovered = nil
                        engine.keepRedrawAlive(for: 0.25)
                    }
                }
            }
            .onTapGesture(count: 2) { location in
                if let id = engine.node(atScreen: location),
                   let node = engine.graph.node(id) {
                    onActivate?(node)
                }
            }
            .onTapGesture(count: 1) { location in
                let id = engine.node(atScreen: location)
                selection = id
                engine.selection = id
            }
            .modifier(ScrollZoomModifier(engine: engine))
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                engine.noteUserInteraction()
                let start = dragStartTranslation ?? engine.viewport.translation
                if dragStartTranslation == nil { dragStartTranslation = start }
                engine.viewport.translation = CGSize(
                    width: start.width + value.translation.width,
                    height: start.height + value.translation.height
                )
            }
            .onEnded { _ in dragStartTranslation = nil }
    }
}
