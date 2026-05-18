import SwiftUI
import Observation

/// The single `@Observable` facade tying model, layout, viewport and
/// interaction together.
///
/// Phase 2: a live force `Simulation` drives `positions`. The sim is decoupled
/// from render — `tick()` (called once per `TimelineView` frame) advances it
/// at a fixed timestep, invalidating the cached `RenderSnapshot` only while the
/// layout is live; once settled it stops stepping so an idle graph costs ~no
/// CPU. The step runs on the main actor within a wall-clock budget; if a step
/// blows the budget the work is offloaded to a detached `Task` operating on a
/// `Sendable` value copy and the result is published back here (single-writer:
/// only `GraphEngine`, on the main actor, ever mutates the live simulation).
///
/// The graph is intentionally **never fitted to the screen** — it does not and
/// should not fit. We open at a readable zoom centred on one node and let the
/// user scroll/pan around a fast, clipped view.
@Observable
@MainActor
final class GraphEngine<Value: Sendable> {
    private(set) var graph: Graph<Value>
    var viewport = Viewport()

    var selection: NodeID? {
        didSet {
            guard selection != oldValue else { return }
            recomputeDistances()
            applySelectionToSimulation()
            snapshotDirty = true
            // DJROOMBA PATCH (3): a new/cleared selection (search-select,
            // node click, host binding, or our own commit) starts the
            // neighbour-walk clean; `commitNeighborExplore` re-arms straight
            // after for the new anchor.
            resetNeighborExplore()
            // DJROOMBA PATCH (4): a selected/cleared genre ⇒ show/clear its
            // associated playlists (commit routes through here too).
            onFocusChange?(selection, nil)
        }
    }

    /// Hover does not affect the snapshot (the ring is drawn from this value
    /// directly), so changing it must NOT rebuild 1,594 nodes per mouse move.
    var hovered: NodeID?

    /// Set the first time the user pans or zooms — drives the dismissable
    /// "this is a slice" hint.
    var userHasNavigated = false

    /// Honour Reduce Motion: spring recenter → short crossfade. Set by the
    /// view from the environment.
    var reduceMotion = false

    /// Light is the primary mode: most host interfaces are light.
    var colorScheme: ColorScheme = .light {
        didSet { if colorScheme != oldValue { snapshotDirty = true } }
    }

    private(set) var seed: UInt64 = 0

    /// Live force tunables (bound by the Lab inspector). Pushed into the
    /// simulation and reheats it so a knob change is visible immediately.
    var parameters = ForceParameters.default {
        didSet {
            guard parameters != oldValue else { return }
            simulation?.parameters = parameters
            simulation?.reheat()
            preferOffMain = false   // fresh layout episode — re-evaluate in-budget
            snapshotDirty = true
            keepRedrawAlive()
        }
    }

    /// The force simulation. The single source of truth for `positions`.
    ///
    /// Sim/render internals below are `@ObservationIgnored` on purpose: they
    /// churn at ~60 Hz and the Canvas reads them via `tickedSnapshot()` (a
    /// method call, not observed-property access in `body`). `TimelineView`
    /// (.animation) drives the redraw cadence; if SwiftUI *observed* a
    /// 60 Hz-mutated position array it would invalidate the whole view tree
    /// every frame — exactly the per-node churn the architecture forbids.
    @ObservationIgnored private var simulation: Simulation?

    /// True while an off-main step task is in flight (prevents a second
    /// concurrent stepper — preserves the single-writer invariant).
    @ObservationIgnored private var isSteppingOffMain = false

    /// Whether the most recent in-budget step ran long enough that we should
    /// keep stepping off-main.
    @ObservationIgnored private var preferOffMain = false

    /// Positions parallel to `graph.nodes`. Mirrors the simulation so the
    /// snapshot/hit-test paths are unchanged from Phase 1.
    @ObservationIgnored private(set) var positions: [Vector2] = []

    /// BFS hop counts from the current selection (empty when no selection).
    private var distancesFromSelection: [NodeID: Int] = [:]

    /// The type-anywhere search. Owned here (the engine is the single facade);
    /// the view reads `searchHUDState` for the overlay and feeds keystrokes in
    /// via `handleSearchKey`. Not separately observed — its result is folded
    /// into the cached `RenderSnapshot`.
    @ObservationIgnored let search = SearchModel()

    /// Mirror of `search.matchIDs` captured at snapshot-build time so the
    /// renderer's per-edge "both endpoints match" test is O(1).
    @ObservationIgnored private var searchMatchIDs: Set<NodeID> = []

    // MARK: - Neighbour walk (DJROOMBA PATCH 3)
    //
    // When a genre is the centred selection and search is NOT active, the
    // arrow keys cycle through its *linked* genres (strongest edge first):
    // each press previews a neighbour (centre + readable zoom + hover ring,
    // no snapshot rebuild), `Return` commits it as the new centred genre
    // and the walk continues from there, and if no `Return` arrives within
    // `exploreRevertDelay` the view snaps back to the original genre. The
    // selection itself only moves on `Return`. All `@ObservationIgnored`:
    // this is interaction state, folded into the snapshot via `hovered`/
    // viewport, never observed per-frame.
    @ObservationIgnored private var exploreAnchor: NodeID?
    @ObservationIgnored private var exploreNeighbors: [NodeID] = []
    /// -1 == on the anchor, no preview yet; else an index into `exploreNeighbors`.
    @ObservationIgnored private var exploreIndex = -1
    @ObservationIgnored private var exploreRevertTask: Task<Void, Never>?
    // Instance (not `static`): `GraphEngine` is generic and Swift forbids
    // static stored properties in generic types.
    @ObservationIgnored private let exploreRevertDelay: Duration = .seconds(2)

    /// Observed so the view can show/animate the HUD overlay. Bumped only on
    /// query / match / cycle changes (never per frame).
    private(set) var searchHUDState = SearchHUDState()

    /// Snapshot of what the HUD needs, value-typed so the overlay view is a
    /// pure function of it.
    struct SearchHUDState: Equatable, Sendable {
        var isVisible = false
        var query = ""
        var matchCount = 0
        var activeIndex: Int?
    }

    /// Caller style override (defaults to library hash→hue).
    var style: (GraphNode<Value>, NodeContext) -> NodeStyle

    /// Optional caller handle for imperative tuning (Lab inspector). Weak —
    /// the caller owns it via `@State`.
    weak var controller: GraphController?

    /// The label of the node we opened centred on (for the UI hint).
    private(set) var initialCenterLabel: String = ""

    /// Live read-outs for the Lab inspector.
    var alpha: Double { simulation?.alpha ?? 0 }
    var isSettled: Bool { simulation?.isSettled ?? true }

    /// The number of on-screen edge crossings from the last settle-time
    /// detection. Observed so the HUD stat and VoiceOver summary update — but
    /// it is written **only** when `refreshCrossings()` runs (settle / finished
    /// pan-zoom), never per frame, so it does not churn the view tree.
    private(set) var crossingCount = 0

    /// Drives whether the `TimelineView` should run at display rate. This is
    /// the **idle ⇒ ~no CPU** mechanism: the Canvas redraw loop is *paused*
    /// when the layout is settled and no viewport animation / interaction is
    /// in flight, so a static graph costs ~no CPU (no sim, no rebuild, and —
    /// crucially — no 60 Hz Canvas redraw of ~1,500 nodes). It is an observed
    /// property so flipping it (un)pauses the `TimelineView`; it changes only
    /// on settle / interaction transitions, never per frame.
    ///
    /// Reheat / pin / recenter / pan / zoom set it `true`; `tick()` clears it
    /// once the sim has settled and the post-interaction "keep-alive" window
    /// has elapsed.
    private(set) var wantsContinuousRedraw = true

    /// While `> now` the redraw loop stays live even if the sim is settled
    /// (covers the viewport recenter spring and a short tail after the last
    /// pan/zoom so a paused timeline doesn't freeze an in-flight animation).
    @ObservationIgnored private var keepLiveUntil = DispatchTime.now()

    // Snapshot cache: rebuilding the full node/edge arrays + re-running the
    // style closure every frame was the Phase 1 slowness. We invalidate it on
    // each sim step *while alpha is live*, and stop entirely once settled.
    @ObservationIgnored private var cachedSnapshot: RenderSnapshot?
    @ObservationIgnored private var snapshotDirty = true
    @ObservationIgnored private var didFrameInitial = false

    /// Edge-crossing detection (uniform spatial grid). Recomputed **only** on a
    /// live→settled transition and after a settled-graph pan/zoom finishes,
    /// and **only** above the LOD label-drop zoom — never per frame and never
    /// while the simulation is live. It is plain synchronous Swift and does not
    /// touch `wantsContinuousRedraw`, so computing crossings once on settle
    /// does not by itself keep the redraw loop alive (idle ⇒ ~no CPU holds).
    @ObservationIgnored private var crossingIndex = CrossingIndex()

    /// Set whenever the crossing set may be out of date (settle reached, or a
    /// settled-graph viewport change). `tick()` recomputes once, when settled
    /// and the post-interaction keep-alive window has elapsed, then clears it.
    @ObservationIgnored private var crossingsStale = true

    /// Tracks the previous settle state so the live→settled edge is detected
    /// exactly once (the moment to recompute crossings).
    @ObservationIgnored private var wasSettled = true

    /// The node the view opened centred on. The sim moves every node off its
    /// seed position, so the viewport must *follow* this node as the layout
    /// blooms — otherwise we open looking at empty space. Following stops the
    /// moment the user takes control (pan/zoom/select).
    @ObservationIgnored private var framedCenterIndex: Int?

    var nodeCount: Int { graph.nodeCount }

    init(
        nodes: [GraphNode<Value>],
        edges: [GraphEdge],
        style: @escaping (GraphNode<Value>, NodeContext) -> NodeStyle
    ) {
        self.graph = Graph(nodes: nodes, edges: edges)
        self.style = style
        rebuildSimulation()
        syncSearchCorpus()
    }

    // MARK: - Input propagation (Phase 2 seam)

    /// Rebuild only what actually changed. The view calls this when its
    /// `nodes`/`edges` inputs change. If the *topology* is unchanged (same ids
    /// and same edge set) we keep the running layout — only labels/payloads
    /// differ, so there is no reason to drop sim state and re-seed. If the
    /// topology changed we rebuild the graph and reseed.
    func update(nodes: [GraphNode<Value>], edges: [GraphEdge]) {
        let next = Graph(nodes: nodes, edges: edges)
        if Self.sameTopology(graph, next) {
            // Labels / payloads only: swap the graph, keep positions + sim.
            graph = next
            syncSearchCorpus()
            snapshotDirty = true
            return
        }
        graph = next
        selection = nil
        hovered = nil
        distancesFromSelection = [:]
        didFrameInitial = false
        rebuildSimulation()
        clearSearch(restore: false)
        syncSearchCorpus()
    }

    /// Feed the current node ids/labels into the search model so a query is
    /// re-evaluated against the live corpus.
    private func syncSearchCorpus() {
        search.setCorpus(
            ids: graph.nodes.map(\.id),
            labels: graph.nodes.map(\.label)
        )
        refreshSearchDerivedState()
    }

    /// Cheap structural-equality check: same node ids in the same order and
    /// the same undirected edge set with the same weights.
    private static func sameTopology(_ a: Graph<Value>, _ b: Graph<Value>) -> Bool {
        guard a.nodes.count == b.nodes.count, a.edges.count == b.edges.count else {
            return false
        }
        for i in a.nodes.indices where a.nodes[i].id != b.nodes[i].id { return false }
        for i in a.edges.indices {
            let ea = a.edges[i]
            let eb = b.edges[i]
            if ea.a != eb.a || ea.b != eb.b || ea.weight != eb.weight { return false }
        }
        return true
    }

    /// Re-seed the deterministic initial layout and restart the sim from it.
    func reseed() {
        seed &+= 1
        rebuildSimulation()
    }

    /// Re-center: open on a fresh readable slice and reheat (Lab "Recenter").
    /// We never fit the whole graph.
    func recenter() {
        didFrameInitial = false
        userHasNavigated = false   // fresh slice: show the hint + follow again
        frameInitialIfNeeded()
        simulation?.reheat()
        preferOffMain = false   // fresh layout episode — re-evaluate in-budget
        snapshotDirty = true
        keepRedrawAlive()
    }

    private func rebuildSimulation() {
        let seeded = SeededLayout.positions(for: graph, seed: seed)
        positions = seeded
        var sim = Simulation(graph: graph, seedPositions: seeded, parameters: parameters)
        sim.reheat()
        simulation = sim
        preferOffMain = false   // fresh layout episode — re-evaluate in-budget
        // Old crossings belong to the old layout — drop them now so the next
        // snapshot doesn't briefly show stale knots until the live branch of
        // tick() runs.
        crossingIndex.clear()
        publishCrossingCount(0)
        crossingsStale = true
        wasSettled = false
        snapshotDirty = true
        keepRedrawAlive()
    }

    // MARK: - Tick (sim ↔ render decoupling)

    /// Advance the simulation. Called once per `TimelineView(.animation)`
    /// frame. Runs as many fixed-dt steps as fit a wall-clock budget; if a
    /// step is too slow it is moved off the main actor onto a detached `Task`
    /// (single-writer preserved via `isSteppingOffMain`). No-ops when settled
    /// — an idle graph does zero work here and the cached snapshot is reused.
    func tick() {
        guard var sim = simulation else { return }

        if sim.isSettled {
            // Live → settled transition: the layout just came to rest, so the
            // crossing set is now meaningful and stable. Mark it for one
            // recompute (gated below). This fires exactly once per settle.
            if !wasSettled {
                wasSettled = true
                crossingsStale = true
            }

            // Recompute edge crossings at most once per settle / per finished
            // settled-graph pan-zoom — never per frame. Gated to:
            //   • settled (we are, here),
            //   • above the LOD label-drop zoom (else glyphs are suppressed —
            //     nothing to draw; the cheap *count* still updates so the HUD
            //     is correct), and
            //   • the post-interaction keep-alive window elapsed, so we don't
            //     recompute every frame mid pan/zoom — we wait until the
            //     gesture is done, then recompute the final layout once.
            // This is synchronous and does NOT set `wantsContinuousRedraw`, so
            // it cannot by itself keep the redraw loop alive.
            if crossingsStale, DispatchTime.now() >= keepLiveUntil {
                refreshCrossings()
                crossingsStale = false
                snapshotDirty = true
            }

            // Settled: do no sim work. Once the post-interaction keep-alive
            // window has also elapsed AND nothing is animating, pause the
            // redraw loop entirely so an idle graph costs ~no CPU (the
            // binding "idle ⇒ ~no CPU" rule).
            //
            // DJROOMBA PATCH (1) — kill the search-pulse redraw pin.
            // Upstream kept `wantsContinuousRedraw` true for the WHOLE time
            // the search HUD is visible (unless Reduce Motion), purely to
            // breathe the match pulse. That redraws the entire opaque
            // `Canvas` at display refresh on a fully *settled* graph the
            // whole time you are typing/cycling — a tight, unnecessary loop
            // that also flickers the mouse cursor (the OS resets it over a
            // continuously-invalidating view every frame). The pulse is
            // cosmetic; matches still light up / dim (snapshot-driven, not
            // pulse-driven), and the recenter-on-cycle animation still runs
            // because `recenterViewport` extends `keepLiveUntil` for a
            // finite tail. So we make the existing no-pulse path
            // (previously only under Reduce Motion) universal: a search
            // that has settled idles like any other static graph. To
            // upstream: gate the pulse on a cheap timer the renderer reads,
            // not on pinning a full-graph redraw.
            let pulseWantsRedraw = false
            if wantsContinuousRedraw,
               !pulseWantsRedraw,
               !crossingsStale,
               DispatchTime.now() >= keepLiveUntil {
                wantsContinuousRedraw = false
            }
            publishReadouts()
            return
        }

        // Layout is live: positions churn every frame, so any previously
        // computed crossings are stale. Clear them (cheap) and mark for a
        // single recompute once it settles. We do NOT recompute here.
        if wasSettled {
            wasSettled = false
            crossingIndex.clear()
            publishCrossingCount(0)
            crossingsStale = true
        }

        if preferOffMain || isSteppingOffMain {
            stepOffMain()
            return
        }

        // Budget: ~6 ms (leaves >10 ms for render at 60 fps, per the spec).
        let budgetSeconds = 0.006
        let start = DispatchTime.now()
        var changed = false
        var steps = 0
        // At most ~4 steps/frame so a deep reheat catches up without starving
        // render; the budget usually caps it lower.
        while steps < 4 {
            let didStep = sim.step()
            changed = changed || didStep
            steps += 1
            if !didStep { break }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            if elapsed >= budgetSeconds { break }
        }

        // If a single step alone overran the budget, switch to off-main.
        if steps == 1 {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
            if elapsed >= budgetSeconds { preferOffMain = true }
        }

        simulation = sim
        if changed {
            positions = sim.positions
            snapshotDirty = true
            followFramedNodeIfNeeded()
        }
        publishReadouts()
    }

    // MARK: - Redraw keep-alive

    /// Wake the redraw loop now and keep it live for `seconds` even if the
    /// sim is/була settled. Called by every disturbance (reheat, pin, recenter,
    /// pan, zoom) so the Canvas resumes immediately and a paused timeline never
    /// freezes an in-flight viewport animation.
    func keepRedrawAlive(for seconds: Double = 0.6) {
        let deadline = DispatchTime.now() + seconds
        if deadline > keepLiveUntil { keepLiveUntil = deadline }
        if !wantsContinuousRedraw { wantsContinuousRedraw = true }
    }

    /// Pan/zoom hook for the interaction layer: a static (settled) graph would
    /// otherwise have its redraw loop paused, so a drag/scroll wouldn't repaint.
    /// This keeps it live briefly around each input.
    func noteUserInteraction() {
        userHasNavigated = true
        keepRedrawAlive(for: 0.5)
        // Crossings are computed in screen space, so a settled-graph pan/zoom
        // invalidates them. Mark stale (not recompute): `tick()` recomputes
        // once, after the keep-alive window elapses — i.e. when the gesture
        // has finished — so a drag doesn't trigger a per-frame recompute.
        crossingsStale = true
    }

    /// Throttle the inspector read-out to a few updates/sec: `alpha`/`settled`
    /// change every frame, but observing them at 60 Hz would re-render the
    /// Lab's `Form` every frame for no perceptible gain. We always publish on
    /// a settle-state transition so the badge flips promptly.
    @ObservationIgnored private var lastReadoutPublish = DispatchTime.now()
    @ObservationIgnored private var lastPublishedSettled = true
    @ObservationIgnored private var lastPublishedCrossings = 0

    private func publishReadouts() {
        guard let controller else { return }
        let now = DispatchTime.now()
        let elapsed = Double(now.uptimeNanoseconds - lastReadoutPublish.uptimeNanoseconds) / 1e9
        let settledChanged = isSettled != lastPublishedSettled
        // Crossings update only on a settle / finished pan-zoom recompute — let
        // that transition through immediately so the inspector read-out isn't
        // delayed by the 0.2 s throttle.
        let crossingsChanged = crossingCount != lastPublishedCrossings
        guard elapsed >= 0.2 || settledChanged || crossingsChanged else { return }
        lastReadoutPublish = now
        lastPublishedSettled = isSettled
        lastPublishedCrossings = crossingCount
        controller.publish(alpha: alpha, isSettled: isSettled, crossingCount: crossingCount)
    }

    /// Off-main stepping: hand a `Sendable` copy to a detached `Task`, run a
    /// batch of steps there, await it back and publish on the main actor. Only
    /// one such task at a time, so there is still a single writer.
    private func stepOffMain() {
        guard !isSteppingOffMain, let sim = simulation, !sim.isSettled else { return }
        isSteppingOffMain = true
        let snapshotSim = sim
        Task.detached(priority: .userInitiated) {
            var s = snapshotSim
            for _ in 0..<3 where !s.isSettled { s.step() }
            let result = s
            await MainActor.run { [weak self] in
                self?.publishOffMain(result)
            }
        }
    }

    private func publishOffMain(_ result: Simulation) {
        isSteppingOffMain = false
        // Re-apply the live parameters in case a knob changed while the task
        // ran. The pin (index + target) is carried inside the value copy, so
        // no pin fix-up is needed — single writer, no teleport.
        var s = result
        s.parameters = parameters
        simulation = s
        positions = s.positions
        snapshotDirty = true
        followFramedNodeIfNeeded()
        publishReadouts()
    }

    // MARK: - Controller bridge

    /// Attach a caller `GraphController` (Lab inspector). Idempotent.
    func attach(controller: GraphController) {
        guard self.controller !== controller else { return }
        self.controller = controller
        controller.attach(self)
        publishReadouts()
    }

    // MARK: - Framing (never "fit the whole graph")

    /// Open at a readable zoom centred on a populated-but-not-mega-hub node,
    /// so the first thing the user sees is legible and lively — not the whole
    /// graph crushed to dots. Runs once per (re)build.
    func frameInitialIfNeeded() {
        guard
            !didFrameInitial,
            !graph.nodes.isEmpty,
            viewport.viewSize.width > 0,
            viewport.viewSize.height > 0
        else { return }
        let idx = initialCenterIndex()
        framedCenterIndex = idx
        initialCenterLabel = graph.nodes[idx].label
        viewport.scale = Viewport.readableScale
        viewport.center(on: positions[idx])
        didFrameInitial = true
    }

    /// Keep the opening node centred while the layout blooms around it, until
    /// the user takes control (pan/zoom sets `userHasNavigated`; a selection
    /// hands the viewport to the pinned-centre animation). No animation — the
    /// positions move smoothly each step, so this is a smooth follow.
    private func followFramedNodeIfNeeded() {
        guard
            selection == nil,
            !userHasNavigated,
            let idx = framedCenterIndex,
            idx < positions.count,
            viewport.viewSize.width > 0
        else { return }
        viewport.center(on: positions[idx])
    }

    /// Pick a node with a comfortably populated neighbourhood (not the
    /// mega-hub, not a leaf) so the opening view reads well.
    private func initialCenterIndex() -> Int {
        let candidates = graph.nodes.indices.filter {
            let d = graph.adjacency[$0].count
            return d >= 6 && d <= 28
        }
        let pool = candidates.isEmpty ? Array(graph.nodes.indices) : Array(candidates)
        return pool.randomElement() ?? 0
    }

    /// Selection from a screen-space point: nearest node whose hit radius
    /// contains the point. Manual hit-testing against positions.
    func node(atScreen point: CGPoint) -> NodeID? {
        let model = viewport.toModel(point)
        var best: (id: NodeID, distanceSquared: Double)?
        let hitRadius = 22.0 / max(viewport.scale, 0.0001)
        let maxDistanceSquared = hitRadius * hitRadius
        for (i, node) in graph.nodes.enumerated() {
            let distanceSquared = (positions[i] - model).lengthSquared
            guard distanceSquared <= maxDistanceSquared else { continue }
            if best == nil || distanceSquared < best!.distanceSquared {
                best = (node.id, distanceSquared)
            }
        }
        return best?.id
    }

    private func recomputeDistances() {
        if let selection {
            distancesFromSelection = graph.distances(from: selection)
        } else {
            distancesFromSelection = [:]
        }
    }

    // MARK: - Pinned-center focus

    /// On selection: pin the node at its current position, reheat,
    /// fan its one-ring neighbours, and animate the viewport so it ends up
    /// visually centred. On deselection: unpin + reheat.
    private func applySelectionToSimulation() {
        guard simulation != nil else { return }
        guard
            let sel = selection,
            let idx = graph.indexByID[sel],
            viewport.viewSize.width > 0
        else {
            simulation?.unpin()
            preferOffMain = false
            keepRedrawAlive()
            return
        }
        // Pin at the *current* model position of the node so the layout
        // doesn't teleport; the viewport then animates so that point reaches
        // screen centre. (Pinning at the screen-centre model point instead
        // would yank the whole neighbourhood across the canvas.)
        let pinModel = positions[idx]
        let oneRing = graph.adjacency[idx].compactMap { graph.indexByID[$0] }
        simulation?.pin(index: idx, at: pinModel, neighbors: oneRing)
        preferOffMain = false
        keepRedrawAlive()
        recenterViewport(on: pinModel)
    }

    /// Ease the viewport so `modelPoint` sits at screen centre. Spring under
    /// normal motion; a short crossfade-style quick settle under Reduce Motion
    /// (the Canvas itself can't crossfade, so we use a fast ease there).
    private func recenterViewport(on modelPoint: Vector2) {
        let reduced = reduceMotion
        let animation: Animation = reduced
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.45, dampingFraction: 0.82)
        // Keep the redraw loop live across the whole recenter animation (plus
        // a little slack) so a paused timeline can't freeze it mid-flight.
        keepRedrawAlive(for: reduced ? 0.35 : 0.7)
        withAnimation(animation) {
            viewport.center(on: modelPoint)
        }
    }

    /// DJROOMBA PATCH (2): the search variant of `recenterViewport` — it
    /// also brings the zoom up to a readable floor so a cycled/narrowed
    /// match is legible ("see what it is"), not a tiny dot, when the user
    /// had zoomed out. Same animation/keep-alive as the pan-only recenter;
    /// only `center` → `focus(minScale:)` differs. Used by search cycle and
    /// query-narrowing; the layout-bloom follow and the selection pin keep
    /// the pan-only `recenterViewport` (preserving the user's zoom there).
    private func recenterViewportForSearch(on modelPoint: Vector2) {
        let reduced = reduceMotion
        let animation: Animation = reduced
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.45, dampingFraction: 0.82)
        keepRedrawAlive(for: reduced ? 0.35 : 0.7)
        withAnimation(animation) {
            viewport.focus(on: modelPoint, minScale: Viewport.readableScale)
        }
    }

    // MARK: - Type-anywhere search

    /// The selection binding the view must mirror when `Return` picks a
    /// match. The view owns the public `Binding`; the engine writes its own
    /// `selection` and signals here so the binding stays in sync.
    @ObservationIgnored var onSearchSelect: ((NodeID) -> Void)?

    /// DJROOMBA PATCH (4): reports the current focus so the host can show
    /// context (the associated-playlists card). `(genre, edgeOther)`:
    /// `edgeOther == nil` ⇒ the whole `genre` is focused; non-nil ⇒ a
    /// neighbour preview, so the focus is the `genre ↔ edgeOther` edge.
    /// `genre == nil` clears. Fired on select / neighbour preview /
    /// snap-back / commit / deselect.
    @ObservationIgnored var onFocusChange: ((NodeID?, NodeID?) -> Void)?

    /// Handle one classified keystroke from `KeyCaptureView`. Returns whether
    /// it was consumed (⇒ the monitor swallows it so it can't also pan/scroll
    /// or fire a menu item). All search interaction funnels through here.
    func handleSearchKey(_ key: SearchKey) -> Bool {
        switch key {
        case .summon:
            // ⌘F: open the HUD even with no query yet (discoverability).
            searchHUDState.isVisible = true
            refreshSearchDerivedState()
            keepRedrawAlive()
            return true

        case .character(let character):
            search.append(character)
            searchHUDState.isVisible = true
            onSearchChanged()
            return true

        case .backspace:
            guard search.isActive else { return false }
            search.deleteBackward()
            // Emptying the query with backspace keeps the HUD up (the user is
            // mid-edit) but clears dimming; Esc is the explicit dismiss.
            onSearchChanged()
            return true

        case .escape:
            // Search dismiss takes priority; otherwise leave a neighbour walk.
            if searchHUDState.isVisible || search.isActive {
                clearSearch(restore: true)
                return true
            }
            return exitNeighborExplore()

        case .return:
            if search.isActive {
                // Select the active (or top) match → existing pinned-centre
                // relayout. Dismiss the HUD; keep no dimming.
                let target = search.activeMatchID ?? search.topMatchID
                clearSearch(restore: true)
                if let target {
                    selection = target
                    onSearchSelect?(target)
                }
                return true
            }
            return commitNeighborExplore()

        case .cycleNext:
            if search.isActive, !search.matches.isEmpty {
                search.cycleForward()
                onSearchCycle()
                return true
            }
            return stepNeighborExplore(forward: true)

        case .cyclePrevious:
            if search.isActive, !search.matches.isEmpty {
                search.cycleBackward()
                onSearchCycle()
                return true
            }
            return stepNeighborExplore(forward: false)
        }
    }

    // MARK: - Neighbour walk (DJROOMBA PATCH 3)

    /// Linked genres of `id`, strongest edge first (deterministic name
    /// tiebreak) so the walk visits the most-related genres first. Derived
    /// from `graph.edges` (canonical, weighted, de-duped); cheap — the
    /// post-curation graph is small.
    private func weightedNeighbors(of id: NodeID) -> [NodeID] {
        var byNeighbor: [(id: NodeID, weight: Double)] = []
        for e in graph.edges {
            if e.a == id {
                byNeighbor.append((e.b, e.weight))
            } else if e.b == id {
                byNeighbor.append((e.a, e.weight))
            }
        }
        byNeighbor.sort { l, r in
            l.weight != r.weight ? l.weight > r.weight : l.id < r.id
        }
        return byNeighbor.map(\.id)
    }

    /// One arrow over the centred genre's links. Owns the arrows only when
    /// search is inactive AND a genre is selected (and has links); otherwise
    /// returns `false` so the key passes through to the rest of the app
    /// unchanged (no genre highlighted ⇒ normal arrow behaviour). Each step
    /// previews a neighbour — centre + readable zoom + hover ring, no
    /// selection move, no snapshot rebuild — and (re)arms the snap-back.
    private func stepNeighborExplore(forward: Bool) -> Bool {
        guard !search.isActive, let anchor = selection else { return false }
        if exploreAnchor != anchor {
            exploreAnchor = anchor
            exploreNeighbors = weightedNeighbors(of: anchor)
            exploreIndex = -1
        }
        let n = exploreNeighbors.count
        guard n > 0 else { return false } // isolated genre: let arrows pass
        let base = exploreIndex < 0 ? (forward ? -1 : 0) : exploreIndex
        exploreIndex = ((base + (forward ? 1 : -1)) % n + n) % n
        let nid = exploreNeighbors[exploreIndex]
        if let idx = graph.indexByID[nid] {
            hovered = nid // preview highlight (no snapshot rebuild)
            recenterViewportForSearch(on: positions[idx]) // centre + readable zoom
        }
        // DJROOMBA PATCH (4): narrow the card to the anchor↔neighbour edge.
        onFocusChange?(exploreAnchor, nid)
        armExploreRevert()
        return true
    }

    /// `Return` on a previewed neighbour: it becomes the new centred genre
    /// and the walk continues from it. The `selection` write re-pins and
    /// recentres (pan-only, so it preserves the readable zoom the preview
    /// already set — it stays legible) and we mirror it to the host binding.
    private func commitNeighborExplore() -> Bool {
        guard
            !search.isActive,
            exploreAnchor != nil,
            exploreIndex >= 0,
            exploreIndex < exploreNeighbors.count
        else { return false }
        let nid = exploreNeighbors[exploreIndex]
        hovered = nil
        selection = nid // didSet: recentre/pin + resetNeighborExplore()
        onSearchSelect?(nid)
        // Re-arm on the new anchor so the next arrow walks ITS links.
        exploreAnchor = nid
        exploreNeighbors = weightedNeighbors(of: nid)
        exploreIndex = -1
        return true
    }

    /// `Esc`: leave the walk. A live preview snaps back to the anchor; the
    /// selection (the anchor genre) is untouched.
    private func exitNeighborExplore() -> Bool {
        guard let anchor = exploreAnchor else { return false }
        let hadPreview = exploreIndex >= 0
        resetNeighborExplore()
        if hadPreview, let idx = graph.indexByID[anchor] {
            recenterViewportForSearch(on: positions[idx])
        }
        // DJROOMBA PATCH (4): selection (the anchor) is unchanged, so its
        // didSet won't fire — reset the card to the anchor's full list.
        onFocusChange?(anchor, nil)
        return true
    }

    /// (Re)start the "no `Return` ⇒ snap back" timer; every step resets it.
    /// A plain MainActor `Task` (no GCD), cancelled/replaced each
    /// step/commit/exit so only the latest is live. It deliberately does
    /// NOT pin the redraw loop (PATCH 1) — the revert's own recentre
    /// animation keeps the canvas live for its finite tail.
    private func armExploreRevert() {
        exploreRevertTask?.cancel()
        let delay = exploreRevertDelay // read on the MainActor before the Task
        exploreRevertTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.revertExplorePreview()
        }
    }

    /// Timer fired with no `Return`: snap the view back to the original
    /// centred genre and drop the preview. The genre stays selected and the
    /// walk stays armed (a further arrow re-previews from the anchor); `Esc`
    /// or a new selection ends it.
    private func revertExplorePreview() {
        guard exploreIndex >= 0, let anchor = exploreAnchor else { return }
        exploreIndex = -1
        hovered = nil
        if let idx = graph.indexByID[anchor] {
            recenterViewportForSearch(on: positions[idx])
        }
        // DJROOMBA PATCH (4): snapped back ⇒ card returns to the anchor's
        // full playlist list.
        onFocusChange?(anchor, nil)
    }

    /// Clear all walk state (cancel the timer, drop the preview ring).
    /// Invoked by `selection`'s didSet so a new/cleared selection starts
    /// clean; `commitNeighborExplore` re-arms right after for the new anchor.
    private func resetNeighborExplore() {
        exploreRevertTask?.cancel()
        exploreRevertTask = nil
        if exploreIndex >= 0 { hovered = nil }
        exploreAnchor = nil
        exploreNeighbors = []
        exploreIndex = -1
    }

    /// Re-rank happened (query edited): refresh dim state, keep the pulse
    /// alive, and centre when the query narrows to exactly one node.
    private func onSearchChanged() {
        refreshSearchDerivedState()
        snapshotDirty = true
        keepRedrawAlive()
        if let only = search.narrowedToOne, let idx = graph.indexByID[only] {
            // Centring ≠ relayout: ease it in, do NOT select / pin it.
            // DJROOMBA PATCH (2): focus (centre + readable zoom), not pan.
            recenterViewportForSearch(on: positions[idx])
        }
    }

    /// `↑/↓` moved the active match: re-centre on it (no selection / pin).
    private func onSearchCycle() {
        refreshSearchDerivedState()
        snapshotDirty = true
        if let active = search.activeMatchID, let idx = graph.indexByID[active] {
            // DJROOMBA PATCH (2): focus (centre + readable zoom), not pan,
            // so each cycled genre is legible instead of a tiny dot.
            recenterViewportForSearch(on: positions[idx])
        }
        keepRedrawAlive()
    }

    /// `Esc` / `Return`: drop the query. `restore` just means "this is a user
    /// dismiss" — there is no relayout either way (Return's relayout is its
    /// own selection write). Returns to full colour; the graph idles again
    /// once the keep-alive tail elapses.
    private func clearSearch(restore: Bool) {
        search.clear()
        searchHUDState.isVisible = false
        refreshSearchDerivedState()
        snapshotDirty = true
        if restore { keepRedrawAlive() }
    }

    /// Mirror the search model into the value-typed HUD/snapshot state. Cheap;
    /// called only on a query/match/cycle transition, never per frame.
    private func refreshSearchDerivedState() {
        searchMatchIDs = search.matchIDs
        let next = SearchHUDState(
            isVisible: searchHUDState.isVisible,
            query: search.query,
            matchCount: search.matches.count,
            activeIndex: search.activeMatchIndex
        )
        if next != searchHUDState { searchHUDState = next }
    }

    // MARK: - Snapshot

    /// The immutable frame description the Canvas draws. Cached: returns the
    /// last build until positions / selection / colour scheme change. Nodes
    /// are emitted **pre-ordered** for draw (ordinary → hub → selected) so the
    /// renderer never sorts 1,594 nodes per frame.
    func snapshot() -> RenderSnapshot {
        if let cachedSnapshot, !snapshotDirty { return cachedSnapshot }
        let built = buildSnapshot()
        cachedSnapshot = built
        snapshotDirty = false
        return built
    }

    /// Advance the decoupled simulation one frame's worth, then return the
    /// snapshot. The single call the `TimelineView`/`Canvas` makes per frame:
    /// when settled `tick()` is a no-op and `snapshot()` returns the cache, so
    /// an idle graph does ~no work here.
    func tickedSnapshot() -> RenderSnapshot {
        tick()
        return snapshot()
    }

    private func buildSnapshot() -> RenderSnapshot {
        let searchActive = search.isActive
        let matchIDs = searchMatchIDs
        var nodes: [RenderSnapshot.Node] = []
        nodes.reserveCapacity(graph.nodes.count)
        for (i, node) in graph.nodes.enumerated() {
            let degree = graph.adjacency[i].count
            let isMatch = searchActive && matchIDs.contains(node.id)
            let ctx = NodeContext(
                isSelected: node.id == selection,
                isHovered: false,
                hasSelection: selection != nil,
                distanceFromSelection: distancesFromSelection[node.id],
                isSearchMatch: isMatch,
                searchActive: searchActive,
                degree: degree,
                colorScheme: colorScheme
            )
            nodes.append(
                RenderSnapshot.Node(
                    id: node.id,
                    label: node.label,
                    position: positions[i],
                    style: style(node, ctx),
                    degree: degree,
                    isSearchMatch: isMatch
                )
            )
        }
        // Order once: ordinary < hub < selected (selected drawn last/on top).
        let sel = selection
        nodes.sort { drawRank($0, selection: sel) < drawRank($1, selection: sel) }

        var edges: [RenderSnapshot.Edge] = []
        edges.reserveCapacity(graph.edges.count)
        for edge in graph.edges {
            guard
                let ia = graph.indexByID[edge.a],
                let ib = graph.indexByID[edge.b]
            else { continue }
            // An edge stays lit only when search is active and *both* its
            // endpoints matched — otherwise it dims with its nodes so the
            // graph shape stays readable without burying the matches.
            let bothMatch = searchActive
                && matchIDs.contains(edge.a)
                && matchIDs.contains(edge.b)
            // An edge touching the focal node is drawn prominently so its
            // neighbours are obvious (only when not searching — search has its
            // own emphasis model).
            let incidentToFocus = !searchActive
                && selection != nil
                && (edge.a == selection || edge.b == selection)
            edges.append(
                RenderSnapshot.Edge(
                    a: positions[ia],
                    b: positions[ib],
                    weight: edge.weight,
                    bothMatch: bothMatch,
                    incidentToFocus: incidentToFocus
                )
            )
        }
        // Knot glyphs are LOD-suppressed below the label-drop zoom (nothing
        // legible to draw down there), but the cheap *count* is always carried
        // so the HUD stat is correct even when zoomed out.
        let glyphs = viewport.labelsVisible ? crossingIndex.crossings : []
        return RenderSnapshot(
            nodes: nodes,
            edges: edges,
            searchActive: searchActive,
            crossings: glyphs,
            crossingCount: crossingIndex.count
        )
    }

    /// Run the uniform-grid crossing detection over the **currently on-screen**
    /// edges. Called only from the settled branch of `tick()` (live→settled or
    /// a finished settled-graph pan/zoom) — never per frame, never while live.
    /// Synchronous and side-effect-free w.r.t. the redraw loop.
    private func refreshCrossings() {
        guard viewport.viewSize.width > 0, viewport.viewSize.height > 0 else {
            crossingIndex.clear()
            publishCrossingCount(0)
            return
        }
        // Only worth detecting when glyphs would actually be drawn. Below the
        // LOD zoom the strands are too small to read a knot on, so we clear
        // the set (the HUD then shows 0 — honest: nothing is marked).
        guard viewport.labelsVisible else {
            crossingIndex.clear()
            publishCrossingCount(0)
            return
        }
        let edges = currentEdgeGeometry()
        crossingIndex.recompute(
            edges: edges,
            viewport: viewport,
            viewSize: viewport.viewSize
        )
        publishCrossingCount(crossingIndex.count)
    }

    /// Update the observed `crossingCount` only when it actually changed, so
    /// the HUD/VoiceOver re-render at most once per recompute (never per frame).
    private func publishCrossingCount(_ value: Int) {
        if crossingCount != value { crossingCount = value }
    }

    /// Resolve every edge's current model-space endpoints (parallel to
    /// `graph.edges`). Cheap; only called on the settle/zoom recompute.
    private func currentEdgeGeometry() -> [RenderSnapshot.Edge] {
        var edges: [RenderSnapshot.Edge] = []
        edges.reserveCapacity(graph.edges.count)
        for edge in graph.edges {
            guard
                let ia = graph.indexByID[edge.a],
                let ib = graph.indexByID[edge.b]
            else { continue }
            edges.append(
                RenderSnapshot.Edge(a: positions[ia], b: positions[ib], weight: edge.weight)
            )
        }
        return edges
    }

    private func drawRank(_ node: RenderSnapshot.Node, selection: NodeID?) -> Int {
        if node.id == selection { return 3 }
        // Search matches draw above ordinary/hub nodes so their pulsing halo
        // isn't occluded by the dimmed crowd around them.
        if node.isSearchMatch { return 2 }
        if node.degree >= 24 { return 1 }
        return 0
    }
}

// MARK: - GraphControllable

extension GraphEngine: GraphControllable {
    func controllerDidRequestReseed() {
        reseed()
        publishReadouts()
    }

    func controllerDidRequestRecenter() {
        recenter()
        publishReadouts()
    }

    func controllerDidUpdateParameters(_ parameters: ForceParameters) {
        self.parameters = parameters
    }
}
