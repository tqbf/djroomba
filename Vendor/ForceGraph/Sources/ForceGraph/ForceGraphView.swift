import SwiftUI

/// The single public SwiftUI control: a fast, colourful, force-directed graph
/// of word nodes.
///
/// A live force simulation drives the layout; one `Canvas` inside a
/// `TimelineView` draws an immutable snapshot in immediate mode (no per-node
/// SwiftUI views, manual hit-testing) and the engine idles when the layout has
/// settled, so a static graph costs ~no CPU.
///
/// **The graph is never fitted to the screen — by design.** Real word graphs
/// don't fit and shouldn't be crushed to dots. The view opens at a readable
/// zoom centred on one node, shows a dismissable "this is a slice" hint, and
/// lets the user pan/scroll a fast, clipped slice.
///
/// Behaviour at a glance:
/// - **Click** a node → it pins to centre and the layout re-settles around it.
/// - **Type anywhere** → a floating search HUD; matches light up, the rest
///   dims, narrowing to one centres it, `Return` selects it, `Esc` clears.
/// - **Edge crossings** are marked with small over/under knot glyphs once the
///   layout settles, and a live crossing count is shown.
///
/// ```swift
/// struct Demo: View {
///     @State private var selection: String?
///     var body: some View {
///         ForceGraphView(
///             nodes: [
///                 GraphNode(id: "a", label: "Ambient"),
///                 GraphNode(id: "b", label: "Techno"),
///                 GraphNode(id: "c", label: "Dub"),
///             ],
///             edges: [
///                 GraphEdge(a: "a", b: "b", weight: 0.6),
///                 GraphEdge(a: "b", b: "c", weight: 0.9),
///             ],
///             selection: $selection
///         )
///     }
/// }
/// ```
///
/// - Requires: macOS 14 (Sonoma) or later.
public struct ForceGraphView<Value: Sendable>: View {
    private let nodes: [GraphNode<Value>]
    private let edges: [GraphEdge]
    @Binding private var selection: NodeID?
    private let style: (GraphNode<Value>, NodeContext) -> NodeStyle
    private let onActivate: ((GraphNode<Value>) -> Void)?
    private let onFocusChange: ((NodeID?, NodeID?) -> Void)?
    private let controller: GraphController?

    @State private var engine: GraphEngine<Value>
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Create a force-directed graph view.
    ///
    /// - Parameters:
    ///   - nodes: The nodes to render. Duplicate ids keep the first; the
    ///     library renders only `label` and never inspects `value`.
    ///   - edges: Undirected, weighted edges (`weight` is `0...1`). Edges
    ///     referencing unknown nodes or forming self-loops are dropped;
    ///     parallel edges merge keeping the maximum weight.
    ///   - selection: A binding to the selected node id. Writing it (or the
    ///     user clicking a node / pressing `Return` on a search match) pins
    ///     that node to centre and re-settles the layout around it; `nil`
    ///     clears the selection.
    ///   - style: Resolves each node's `NodeStyle` from the node and a
    ///     `NodeContext` (selection distance, hover, search match, degree,
    ///     colour scheme). Defaults to the zero-config stable hash→hue
    ///     palette. The library never inspects `Value`; this closure and
    ///     `onActivate` are where caller behaviour lives.
    ///   - onActivate: Called on double-click / `Return` on a node (an app
    ///     behaviour hook — e.g. open a detail view).
    ///   - onFocusChange: DJROOMBA PATCH (4). Reports what the view is
    ///     currently focused on so the host can show context (e.g. the
    ///     playlists tied to it): `(genre, edgeOther)`. `genre == nil`
    ///     clears. `edgeOther == nil` ⇒ the whole genre is focused
    ///     (selected, snapped-back, or Enter-committed); `edgeOther != nil`
    ///     ⇒ a neighbour is being previewed in the arrow-key walk, so the
    ///     focus is the `genre ↔ edgeOther` edge. Fires on select,
    ///     neighbour preview, snap-back, commit and deselect.
    ///   - controller: An optional caller-owned `GraphController` (held via
    ///     `@State`) for imperative tuning (`parameters`) and nudges
    ///     (`reseed()`, `recenter()`) plus live `alpha`/`isSettled` read-outs.
    ///     Ordinary callers don't need it.
    public init(
        nodes: [GraphNode<Value>],
        edges: [GraphEdge],
        selection: Binding<NodeID?> = .constant(nil),
        style: @escaping (GraphNode<Value>, NodeContext) -> NodeStyle = { GraphNode.defaultStyle($0, $1) },
        onActivate: ((GraphNode<Value>) -> Void)? = nil,
        onFocusChange: ((NodeID?, NodeID?) -> Void)? = nil,
        controller: GraphController? = nil
    ) {
        self.nodes = nodes
        self.edges = edges
        self._selection = selection
        self.style = style
        self.onActivate = onActivate
        self.onFocusChange = onFocusChange
        self.controller = controller
        _engine = State(wrappedValue: GraphEngine(nodes: nodes, edges: edges, style: style))
    }

    public var body: some View {
        GeometryReader { proxy in
            // Pause the redraw loop when the layout is settled and nothing is
            // animating: this is the "idle ⇒ ~no CPU" guarantee — a static
            // graph then costs no sim work, no snapshot rebuild, and no 60 Hz
            // Canvas redraw of ~1,500 nodes. Any disturbance (reheat / pin /
            // recenter / pan / zoom / hover) flips `wantsContinuousRedraw`
            // back on, which un-pauses this `TimelineView`.
            TimelineView(.animation(paused: !engine.wantsContinuousRedraw)) { timeline in
                Canvas(opaque: true, rendersAsynchronously: false) { context, size in
                    GraphCanvasRenderer.draw(
                        engine.tickedSnapshot(),
                        viewport: engine.viewport,
                        scheme: colorScheme,
                        selection: engine.selection,
                        hovered: engine.hovered,
                        pulsePhase: pulsePhase(at: timeline.date),
                        boldStrokes: boldStrokes,
                        context: context,
                        size: size
                    )
                }
            }
            .background(Palette.surface(for: colorScheme))
            .modifier(
                GraphInteractionModifier(
                    engine: engine,
                    selection: $selection,
                    onActivate: onActivate
                )
            )
            .overlay(alignment: .bottomLeading) {
                if showsHint {
                    GraphHintChip(
                        nodeCount: engine.nodeCount,
                        centerLabel: engine.initialCenterLabel
                    )
                    .padding(12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .overlay(alignment: .top) {
                if engine.searchHUDState.isVisible {
                    SearchHUDView(
                        query: engine.searchHUDState.query,
                        matchCount: engine.searchHUDState.matchCount,
                        activeIndex: engine.searchHUDState.activeIndex,
                        reduceMotion: reduceMotion
                    )
                    .padding(.top, 18)
                    .transition(searchHUDTransition)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showsCrossingStat {
                    GraphStatChip(crossingCount: engine.crossingCount)
                        .padding(12)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: showsHint)
            .animation(.easeOut(duration: 0.25), value: showsCrossingStat)
            .animation(.snappy(duration: 0.2), value: engine.crossingCount)
            .animation(searchHUDAnimation, value: engine.searchHUDState.isVisible)
            .modifier(
                KeyCaptureView(
                    isSearchActive: engine.searchHUDState.isVisible || engine.search.isActive
                ) { key in
                    engine.handleSearchKey(key)
                }
            )
            .onAppear {
                engine.reduceMotion = reduceMotion
                if let controller { engine.attach(controller: controller) }
                engine.onSearchSelect = { id in selection = id }
                engine.onFocusChange = onFocusChange // DJROOMBA PATCH (4)
                syncViewSize(proxy.size)
            }
            .onChange(of: controller?.parameters) { _, newValue in
                if let newValue { engine.parameters = newValue }
            }
            .onChange(of: proxy.size) { _, newSize in syncViewSize(newSize) }
            .onChange(of: colorScheme) { _, newScheme in
                engine.colorScheme = newScheme
            }
            .onChange(of: reduceMotion) { _, newValue in
                engine.reduceMotion = newValue
            }
            .onChange(of: selection) { _, newValue in
                engine.selection = newValue
            }
            .onChange(of: inputSignature) { _, _ in
                // Phase 2 input-propagation fix: a changed `nodes`/`edges`
                // input must reach the @State engine (the Lab previously had
                // to work around this with `.id`). `update` keeps the running
                // sim when only labels/payloads changed.
                engine.update(nodes: nodes, edges: edges)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Force-directed graph")
        .accessibilityValue(accessibilitySummary)
    }

    /// The "this is a slice" hint shows only before the user has taken
    /// control: not after they pan/zoom, not while a node is selected, and
    /// not while the search HUD is up (keep the focal view uncluttered).
    private var showsHint: Bool {
        !engine.userHasNavigated
            && engine.selection == nil
            && !engine.searchHUDState.isVisible
    }

    /// Show the crossing-count stat once there is something to report and the
    /// search HUD isn't up (keep the searching view uncluttered — the matched
    /// substructure is the focus then, not the global tangle).
    private var showsCrossingStat: Bool {
        engine.crossingCount > 0 && !engine.searchHUDState.isVisible
    }

    /// A smooth 0…1 triangle wave used to pulse search matches. Driven off
    /// the `TimelineView` clock so it animates even on a settled graph (the
    /// engine keeps the redraw loop alive while search is active). Under
    /// Reduce Motion there is no pulse — matches just sit at full emphasis.
    /// Strengthen edge / knot strokes when the user wants higher contrast
    /// (Increase Contrast) *or* asks not to rely on colour (Differentiate
    /// Without Color) — the over/under knot then reads as a firmer non-colour
    /// structural cue. Honours the binding accessibility rules.
    private var boldStrokes: Bool {
        colorSchemeContrast == .increased || differentiateWithoutColor
    }

    private func pulsePhase(at date: Date) -> Double {
        guard engine.searchHUDState.isVisible, !reduceMotion else { return 1 }
        let period = 1.4
        let t = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        // Smooth in/out cosine ease, 0 → 1 → 0.
        return 0.5 - 0.5 * cos(t * 2 * .pi)
    }

    /// Reduce Motion: a quick crossfade instead of the slide.
    private var searchHUDTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .move(edge: .top))
    }

    private var searchHUDAnimation: Animation {
        reduceMotion
            ? .easeInOut(duration: 0.12)
            : .spring(response: 0.32, dampingFraction: 0.82)
    }

    private func syncViewSize(_ size: CGSize) {
        engine.viewport.viewSize = size
        engine.colorScheme = colorScheme
        // Never fit the whole graph — open at a readable zoom on one node.
        engine.frameInitialIfNeeded()
    }

    /// A cheap content fingerprint of the inputs. `onChange` needs an
    /// `Equatable`, but `GraphNode<Value>` is not `Equatable` (the caller's
    /// `Value` is unconstrained), so we hash the parts the library actually
    /// uses (ids/labels/edges/weights). Far cheaper than a graph rebuild and
    /// only triggers `update` when something the layout cares about changed.
    private var inputSignature: Int {
        var hasher = Hasher()
        hasher.combine(nodes.count)
        hasher.combine(edges.count)
        for n in nodes {
            hasher.combine(n.id)
            hasher.combine(n.label)
        }
        for e in edges {
            hasher.combine(e.a)
            hasher.combine(e.b)
            hasher.combine(e.weight)
        }
        return hasher.finalize()
    }

    /// A spoken graph summary: size, selection, the active search (if any) and
    /// the live on-screen crossing count — so a VoiceOver user gets the same
    /// "how tangled is this" signal the sighted HUD stat conveys.
    private var accessibilitySummary: String {
        let count = engine.graph.nodeCount
        var parts: [String] = ["\(count) nodes"]
        if let selection, let node = engine.graph.node(selection) {
            parts.append("Selected: \(node.label)")
        } else {
            parts.append("no selection")
        }
        let hud = engine.searchHUDState
        if hud.isVisible {
            let matchCount = hud.matchCount
            let phrase = matchCount == 1 ? "1 match" : "\(matchCount) matches"
            parts.append("Searching “\(hud.query)”, \(phrase)")
        }
        let crossings = engine.crossingCount
        if crossings > 0 {
            parts.append(crossings == 1 ? "1 edge crossing" : "\(crossings) edge crossings")
        }
        return parts.joined(separator: ". ") + "."
    }
}
