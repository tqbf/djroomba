import SwiftUI

// MARK: - GenreTreeMapPanel

/// The genre-tree pane (`plans/son-of-genre-map.md`), docked below the
/// track list in `DetailPaneView` (per user direction 2026-05-22 — it
/// first shipped as a sheet, now lives inline). The successor to
/// `GenreMapPanel`. Renders the trunk-tree at default state: trunk
/// pills along the diagonal, branches fanning radially, faint
/// back-edges underneath. Collapsible/resizable like the retired
/// ForceGraph panel it replaced. Phase C adds radial-focus mode:
/// clicking any pill animates the layout into a centred fan of 1-hop
/// + 2-hop neighbours around the clicked genre; clicking empty
/// canvas or pressing Escape animates back to the trunk-tree.
///
/// **Inherited interaction grammar** (from the Phase-5/6 metro panel):
///
/// - Cmd-+ / Cmd-− zoom (10 % to 600 %).
/// - Cmd-0 actual-size + recenter.
/// - Cmd-9 fit-the-canvas-to-the-viewport. The default presentation is
///   **not** fitted (per the standing user directive "scrolling is
///   fine"); the user invokes Fit only when they want an overview.
/// - Magnification gesture: live pinch-zoom.
/// - Drag gesture: pan the canvas.
///
/// **Phase C additions:**
///
/// - Tap a pill ⇒ `selectedGenre` set, animation runs
///   (`withAnimation(.easeInOut(duration: animationDuration))`).
/// - Tap empty canvas ⇒ `selectedGenre` cleared, animation runs.
/// - Press Escape OR click the **Clear Focus** button in the footer
///   ⇒ same as empty-canvas tap. (Escape from inside a sheet is
///   captured by AppKit's default sheet-cancel path before SwiftUI
///   sees it on macOS 14; both `.onKeyPress(.escape)` on a focused
///   container AND a hidden `.keyboardShortcut(.escape)` button were
///   tried + failed during Phase C live verification. The Clear
///   Focus button is the visible affordance; click-empty-area is the
///   incidental gesture.)
/// - Animation duration is exposed in the header as a segmented
///   Picker so the user can flip 200 / 300 / 400 / 500 ms live and
///   pick the eventual ship default.
struct GenreTreeMapPanel: View {

  // MARK: Internal

  var body: some View {
    // Bottom-docked pane below the track list (`DetailPaneView`). The
    // top divider + resize handle + always-visible header bar are the
    // native "debug area" idiom; collapsed, only the bar remains so the
    // pane is always re-discoverable. Replaces the sheet the tree first
    // shipped in (per user direction 2026-05-22 — "it needs to live in
    // a pane below the track list, not a separate window").
    VStack(spacing: 0) {
      Divider()
      if collapsed {
        // Slim, fixed-height bar — the only thing left when collapsed,
        // so the pane is always re-discoverable. Explicit height so the
        // greedy track list above can't compress it to nothing.
        collapsedBar
          .frame(height: 36)
      } else {
        GenreTreePaneResizeHandle(
          height: $panelHeight,
          range: Self.minBodyHeight ... Self.maxBodyHeight,
        )
        header
        Divider()
        HStack(spacing: 0) {
          VStack(spacing: 0) {
            content
            Divider()
            footer
          }
          if inspectorPresented {
            // Drag handle on the inspector's leading edge — narrow it to
            // give the graph more width, widen it for the evidence lists.
            GenreTreeInspectorResizeHandle(
              width: $inspectorWidth,
              range: Self.minInspectorWidth ... Self.maxInspectorWidth,
            )
            GenreTreeInspector(
              selection: inspectorSelection,
              model: controller.genreMapService.model ?? Self.emptyMapModel,
              representativeEvidence: representativeEvidence,
              isLoadingRepresentative: isLoadingRepresentative,
              comparePaths: comparePaths,
              compareEvidence: compareEvidence,
              isLoadingCompare: isLoadingCompare,
              twoHopNeighbours: twoHopNeighboursForSelection(),
              onSelectNeighbour: selectByName,
              onListen: selectedGenre.map { genre in { triggerListen(for: genre) } },
              onSaveAsPlaylist: selectedGenre.map { genre in { triggerSaveAsPlaylist(for: genre) } },
              isListenInFlight: isListenInFlight,
              onExitCompare: endCompare,
            )
            .frame(width: CGFloat(inspectorWidth))
            .background(Color(nsColor: .windowBackgroundColor))
            .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
        .frame(height: CGFloat(panelHeight))
      }
    }
    .background(.background)
    .animation(.easeOut(duration: 0.22), value: collapsed)
    .animation(.easeInOut(duration: 0.18), value: inspectorPresented)
    .task {
      if controller.genreTreeService.renderModel == nil {
        await controller.genreTreeService.build()
      }
    }
    .onChange(of: selectedGenre) { _, newValue in
      applyFocusViewport(for: newValue)
    }
  }

  /// Community → swatch palette. Single-source duplicate of
  /// `GenreMapPanel.communityColour` (so the tree view's colours
  /// match the metro's across A/B comparisons), kept here so this
  /// view doesn't import a retiring module.
  static func communityColour(for id: Int) -> Color {
    let palette: [Color] = [
      .blue,
      .pink,
      .green,
      .orange,
      .purple,
      .teal,
      .yellow,
      .mint,
      .indigo,
      .red,
      .cyan,
      .brown,
    ]
    let safeID = ((id % palette.count) + palette.count) % palette.count
    return palette[safeID]
  }

  // MARK: Private

  private struct FitTransform {
    var scale: CGFloat
    var translation: CGSize
  }

  /// Canonical-half edge key for compare-mode path bookkeeping.
  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

  private struct ViewTransform {
    var fitted: FitTransform
    var scale: CGFloat
    var offset: CGSize

    func project(_ world: CGPoint) -> CGPoint {
      let fittedPoint = CGPoint(
        x: world.x * fitted.scale + fitted.translation.width,
        y: world.y * fitted.scale + fitted.translation.height,
      )
      return CGPoint(
        x: fittedPoint.x * scale + offset.width,
        y: fittedPoint.y * scale + offset.height,
      )
    }
  }

  private struct SavedViewState: Equatable {
    var scale: CGFloat
    var offset: CGSize
  }

  /// Canvas background — warm high-value low-saturation cream in
  /// light mode; deep low-saturation blue in dark mode. Chosen to
  /// give the strand / branch colour palette good legibility without
  /// the canvas reading as "system grey." NSColor-backed so the
  /// switch happens at the AppKit layer the moment the appearance
  /// changes (no SwiftUI `colorScheme` plumbing required).
  private static let canvasBackground = Color(
    nsColor: NSColor(name: "GenreTreeCanvasBackground") { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return isDark
        ? NSColor(red: 0.078, green: 0.094, blue: 0.122, alpha: 1)
        : NSColor(red: 0.985, green: 0.972, blue: 0.928, alpha: 1)
    }
  )

  /// Fallback empty `GenreMapModel` so the inspector can be hosted
  /// even before the substrate finishes loading. Same posture as
  /// `GenreMapPanel.emptyModel`.
  private static let emptyMapModel = GenreMapModel(
    nodes: [],
    layoutEdges: [],
    communities: [],
    worldBounds: .zero,
  )

  /// The docked body's resizable bounds. The min keeps the tree
  /// readable; the max stops the pane from swallowing the track list
  /// above it on a tall window (the user can still collapse it).
  private static let minBodyHeight: Double = 240
  private static let maxBodyHeight: Double = 900

  /// Inspector width bounds. Narrow gives the graph more room; wide
  /// gives the evidence lists more room.
  private static let minInspectorWidth: Double = 260
  private static let maxInspectorWidth: Double = 460

  @Environment(MusicController.self) private var controller

  /// Pane body height — view-layer concern, scene-persisted so a
  /// resize survives relaunch (scene state must not live inside an
  /// `@Observable`).
  @SceneStorage("genreTreePanelHeight") private var panelHeight = 440.0

  /// Inspector column width — scene-persisted like the body height.
  @SceneStorage("genreTreeInspectorWidth") private var inspectorWidth = 320.0

  @State private var scale: CGFloat = 1.0
  @State private var offset = CGSize.zero
  @State private var fitRequested = false
  /// Live viewport size, updated by `mapBody`'s `GeometryReader`.
  @State private var viewportSize = CGSize(width: 900, height: 600)

  /// Phase C — `nil` ⇒ trunk-tree mode, non-nil ⇒ radial-focus mode
  /// centred on this genre.
  @State private var selectedGenre: String?

  /// Phase D — second-genre slot for compare mode. Set by a ⇧-click on
  /// a pill while `selectedGenre` is non-nil; cleared by Exit Compare,
  /// by an unmodified click, or by clearing the selection. Never equal
  /// to `selectedGenre`.
  @State private var compareGenre: String?

  /// Phase D — Yen-k paths between `selectedGenre` and `compareGenre`,
  /// recomputed when either changes. Empty in single-genre / trunk-tree
  /// mode.
  @State private var comparePaths = [GenreMapDiscovery.Path]()

  /// Phase D — single-genre evidence (top artists / top albums) for
  /// the inspector. Loaded asynchronously on each new `selectedGenre`.
  @State private var representativeEvidence: GenreMapRepresentativeEvidence?
  @State private var isLoadingRepresentative = false
  @State private var representativeTask: Task<Void, Never>?

  /// Phase D — compare-mode evidence rollup. Three lists; loaded
  /// asynchronously when the second genre is picked.
  @State private var compareEvidence: GenreMapCompareEvidence?
  @State private var isLoadingCompare = false
  @State private var compareTask: Task<Void, Never>?

  /// Phase D — Listen / Save-as-Playlist in-flight flag. Disables
  /// repeat clicks while the SQLite read + resolver hop runs.
  @State private var isListenInFlight = false

  /// Saved viewport state at the moment the user clicked into a
  /// focus. `clearSelection()` restores from this so the user lands
  /// back on the trunk-tree view they were exploring, not on the
  /// canvas-centre identity zoom.
  @State private var preFocusViewState: SavedViewState?

  /// Phase D — inspector visibility. AppStorage to match the metro
  /// panel's posture so the user's preference persists across sessions.
  @AppStorage("genreTreeInspectorPresented") private var inspectorPresented = true

  @GestureState private var gestureScale: CGFloat = 1.0
  @GestureState private var gestureOffset = CGSize.zero

  /// Visible "Clear Focus" affordance — appears in the footer in
  /// radial-focus mode and disappears in trunk-tree mode. Carries
  /// the Escape keyboard shortcut so the user can dismiss the focus
  /// without reaching for the mouse. Keeping the button visible (a
  /// 1×1 transparent button tucked into an overlay didn't get the
  /// shortcut delivered from inside the sheet's responder chain on
  /// macOS 14; the visible button does).
  @ViewBuilder
  private var clearFocusButton: some View {
    if selectedGenre != nil {
      Button("Clear Focus", systemImage: "xmark.circle", action: clearSelection)
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
        .keyboardShortcut(.escape, modifiers: [])
        .help("Return to the trunk-tree view (Esc)")
    }
  }

  private var service: GenreTreeService {
    controller.genreTreeService
  }

  /// Collapse state lives on the controller so the toolbar button,
  /// the menu command, and this pane's header chevron all drive one
  /// shared value.
  private var collapsed: Bool {
    controller.genreTreePaneCollapsed
  }

  /// Resolve the inspector mode from the current selection state +
  /// the substrate's loaded `GenreMapModel`. The substrate is
  /// guaranteed loaded by the time `selectedGenre` is non-nil
  /// (`GenreTreeService.build` loads it as a prerequisite), so the
  /// lookup is expected to succeed; a defensive `.empty` covers the
  /// rare interleaving where the substrate failed to load.
  private var inspectorSelection: GenreTreeInspectorSelection {
    guard let mapModel = controller.genreMapService.model else { return .empty }
    if
      let selectedGenre, let second = compareGenre,
      let lhs = mapModel.nodes.first(where: { $0.genre == selectedGenre }),
      let rhs = mapModel.nodes.first(where: { $0.genre == second })
    {
      return .compare(lhs, rhs)
    }
    if
      let selectedGenre,
      let node = mapModel.nodes.first(where: { $0.genre == selectedGenre })
    {
      return .single(node)
    }
    return .empty
  }

  /// The slim bar shown when the pane is collapsed: chevron + title +
  /// count + Re-Analyze. Mirrors the docked debug-area idiom; clicking
  /// the chevron re-expands.
  private var collapsedBar: some View {
    HStack(spacing: 12) {
      collapseChevron
      Text("Genre Tree")
        .font(.headline)
      if let model = service.renderModel {
        Text("\(model.layout.placedNodes.count) genres")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button {
        Task { await controller.analyzeGenreTree() }
      } label: {
        Label("Re-Analyze", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Rebuild the genre tree from the current library")
      .disabled(service.isBuilding)
    }
    .padding(.horizontal, 16)
    .contentShape(Rectangle())
  }

  /// Shared collapse/expand chevron button.
  private var collapseChevron: some View {
    Button {
      controller.genreTreePaneCollapsed.toggle()
    } label: {
      Image(systemName: collapsed ? "chevron.up" : "chevron.down")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(collapsed ? "Show the genre tree" : "Hide the genre tree")
  }

  private var header: some View {
    HStack(spacing: 12) {
      collapseChevron

      Text("Genre Tree")
        .font(.headline)
      if service.isBuilding {
        ProgressView()
          .controlSize(.small)
        Text("Building…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if let model = service.renderModel {
        Text("\(model.layout.placedNodes.count) genres")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .fixedSize()
      } else if let error = service.lastError {
        Text(error)
          .font(.subheadline)
          .foregroundStyle(.red)
      }
      Spacer()
      // Re-Analyze is a quiet, occasional action — icon-only so it
      // doesn't shout (the auto-rebuild on import covers the common
      // case; the dev-only metric A/B lives in the Debug menu).
      Button {
        Task { await controller.analyzeGenreTree() }
      } label: {
        Label("Re-Analyze", systemImage: "arrow.clockwise")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help("Rebuild the genre tree from the current library")
      .disabled(service.isBuilding)

      if !collapsed {
        Button {
          inspectorPresented.toggle()
        } label: {
          Label("Inspector", systemImage: "sidebar.trailing")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help("Show or hide the inspector (⌘⌥I)")
        .keyboardShortcut("i", modifiers: [.command, .option])
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  @ViewBuilder
  private var content: some View {
    if let model = service.renderModel {
      GeometryReader { geometry in
        canvas(model: model, in: geometry.size)
          .task(id: geometry.size) {
            viewportSize = geometry.size
          }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Self.canvasBackground)
    } else if service.isBuilding {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Self.canvasBackground)
    } else {
      emptyState
    }
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Genre Tree Yet", systemImage: "tree")
    } description: {
      Text(
        "The genre tree appears here once your library has been analyzed. Build it once your library has genre tags — or rebuild it any time."
      )
    } actions: {
      Button("Analyze") {
        Task { await controller.analyzeGenreTree() }
      }
      .disabled(service.isBuilding)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private var footer: some View {
    HStack(spacing: 8) {
      Image(systemName: "hand.point.up.left")
      Text(
        "Drag to pan · Pinch / ⌘+ / ⌘− to zoom · ⌘0 reset · ⌘9 fit · click a genre to focus"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      clearFocusButton
      Spacer()
      Button {
        zoomIn()
      } label: {
        Label("Zoom In", systemImage: "plus.magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .controlSize(.small)
      .keyboardShortcut("+", modifiers: .command)
      Button {
        zoomOut()
      } label: {
        Label("Zoom Out", systemImage: "minus.magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .controlSize(.small)
      .keyboardShortcut("-", modifiers: .command)
      Button {
        resetZoom()
      } label: {
        Label("Actual Size", systemImage: "1.magnifyingglass")
      }
      .labelStyle(.iconOnly)
      .controlSize(.small)
      .keyboardShortcut("0", modifiers: .command)
      Button {
        fitToView()
      } label: {
        Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
      }
      .controlSize(.small)
      .keyboardShortcut("9", modifiers: .command)
      Text(String(format: "%.0f%%", scale * 100))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 44, alignment: .trailing)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(.bar)
  }

  /// On focus: animate pan + zoom so the radial-focus cluster (the
  /// selected genre at centre, the 1-hop ring around it) fills the
  /// viewport with comfortable padding. Without this the focus
  /// cluster lands at the selected pill's *original* world position,
  /// which is usually off-screen at default zoom; the labels then
  /// stack visually because the canvas isn't recentred.
  ///
  /// On clear: restore the user's pre-focus pan/zoom (so the trunk-
  /// tree view returns to where they were exploring), or to identity
  /// if no prior state was captured.
  private func applyFocusViewport(for newSelection: String?) {
    guard
      viewportSize.width > 0,
      viewportSize.height > 0,
      let model = service.renderModel
    else { return }

    if
      let genre = newSelection,
      let placed = model.layout.placedNodes.first(where: { $0.genre.name == genre })
    {
      if preFocusViewState == nil {
        preFocusViewState = SavedViewState(scale: scale, offset: offset)
      }
      let fitted = baseTransform(model: model, into: viewportSize)
      let fittedCentre = CGPoint(
        x: fitted.scale * placed.position.x + fitted.translation.width,
        y: fitted.scale * placed.position.y + fitted.translation.height,
      )
      // Target: fit the outer ring + a half-pill margin inside the
      // shorter viewport axis. `r2` is the outer-ring radius in world
      // coords; the fit scale converts it to a screen radius.
      let r2: CGFloat = 820
      let padding: CGFloat = 90
      let availableHalf = min(viewportSize.width, viewportSize.height) / 2 - padding
      let targetRingScreen = max(180, availableHalf)
      let rawScale = targetRingScreen / max(1, fitted.scale * r2)
      let targetScale = clamp(rawScale, min: 0.1, max: 6.0)
      withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
        scale = targetScale
        offset = CGSize(
          width: viewportSize.width / 2 - targetScale * fittedCentre.x,
          height: viewportSize.height / 2 - targetScale * fittedCentre.y,
        )
      }
    } else {
      let restore = preFocusViewState
      preFocusViewState = nil
      withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
        scale = restore?.scale ?? 1.0
        offset = restore?.offset ?? .zero
      }
    }
  }

  /// Current `genre_edge_evidence` rows from the render model. Empty
  /// when the build hasn't run yet.
  private func currentEvidence() -> [GenreEdgeEvidence] {
    service.renderModel?.evidence ?? []
  }

  /// Two-hop neighbours of `selectedGenre`. Reuses the radial-plan's
  /// classification — every genre whose ring is `.twoHop` for the
  /// current focus. Sorted alphabetically for stable inspector
  /// rendering (the radial plan sorts geometrically; the inspector
  /// list sorts by name).
  private func twoHopNeighboursForSelection() -> [String] {
    guard let selectedGenre, let renderModel = service.renderModel else { return [] }
    guard
      let plan = GenreTreeRadialPlan.plan(
        selectedGenre: selectedGenre,
        layout: renderModel.layout,
        evidence: renderModel.evidence,
      )
    else { return [] }
    let twoHop = plan.targetsByGenre.compactMap { name, target in
      target.ring == .twoHop ? name : nil
    }
    return twoHop.sorted()
  }

  /// Genre set highlighted in compare mode — the two endpoints plus
  /// every station on every Yen-k path. Used by the canvas to keep
  /// these pills at full opacity while the rest dim.
  private func compareHighlightGenres() -> Set<String> {
    guard let selectedGenre, let compareGenre else { return [] }
    var set: Set<String> = [selectedGenre, compareGenre]
    for path in comparePaths {
      for station in path.stations {
        set.insert(station)
      }
    }
    return set
  }

  /// Canonical-half edge keys for every consecutive pair along every
  /// Yen-k path. The canvas uses this to raise compare-mode edge
  /// opacity for path edges while the rest dim.
  private func comparePathEdgeKeys() -> Set<EdgeKey> {
    var keys = Set<EdgeKey>()
    for path in comparePaths {
      guard path.stations.count >= 2 else { continue }
      for index in 0..<(path.stations.count - 1) {
        let lhs = path.stations[index]
        let rhs = path.stations[index + 1]
        keys.insert(EdgeKey(a: min(lhs, rhs), b: max(lhs, rhs)))
      }
    }
    return keys
  }

  private func canvas(model: GenreTreeRenderModel, in size: CGSize) -> some View {
    let fitted = baseTransform(model: model, into: size)
    let viewTransform = ViewTransform(
      fitted: fitted,
      scale: scale * gestureScale,
      offset: CGSize(
        width: offset.width + gestureOffset.width,
        height: offset.height + gestureOffset.height,
      ),
    )

    // Pre-compute community colour per genre once per render — avoids
    // a per-pill dictionary scan over `topology.trunks`.
    let colourByGenre = communityColourByGenre(model: model)

    // Phase C — compute the radial plan once per render frame. SwiftUI
    // memoises the body recomputes; the plan recompute on a click-
    // induced state change costs O(n + e), well under 1 ms on the
    // real library. The plan is `nil` in trunk-tree mode.
    let radialPlan = currentRadialPlan(model: model)

    // Phase D — in compare mode the visual treatment overrides the
    // radial-focus opacity scheme: only the two endpoints + the Yen-k
    // path stations stay at full opacity; everything else dims to a
    // single uniform background tier so the two-genre comparison is
    // visually unambiguous. Computed once per frame.
    let compareHighlights = compareGenre != nil ? compareHighlightGenres() : Set<String>()
    let comparePathEdges = compareGenre != nil ? comparePathEdgeKeys() : Set<EdgeKey>()
    let inCompareMode = compareGenre != nil

    return ZStack {
      // The empty-canvas tap layer. `contentShape(Rectangle())`
      // makes the clear background hit-testable so a click that lands
      // off any pill (including in the gaps between pills) is caught
      // here and clears `selectedGenre`. Sits below the pills + edges
      // so a click on a pill goes to the pill (the pill's
      // `onTapGesture` wins because it's higher in the ZStack).
      Color.clear
        .contentShape(Rectangle())
        .onTapGesture {
          clearSelection()
        }
      backEdgesLayer(
        model: model,
        transform: viewTransform,
        radialPlan: radialPlan,
        inCompareMode: inCompareMode,
      )
      branchEdgesLayer(
        model: model,
        colourByGenre: colourByGenre,
        transform: viewTransform,
        radialPlan: radialPlan,
        comparePathEdges: comparePathEdges,
        inCompareMode: inCompareMode,
      )
      pillsLayer(
        model: model,
        colourByGenre: colourByGenre,
        transform: viewTransform,
        radialPlan: radialPlan,
        compareHighlights: compareHighlights,
        inCompareMode: inCompareMode,
      )
    }
    .contentShape(Rectangle())
    .clipped()
    .gesture(
      MagnificationGesture()
        .updating($gestureScale) { current, state, _ in
          state = current
        }
        .onEnded { final in
          scale = clamp(scale * final, min: 0.1, max: 6.0)
        }
    )
    .simultaneousGesture(
      DragGesture(minimumDistance: 4)
        .updating($gestureOffset) { value, state, _ in
          state = value.translation
        }
        .onEnded { value in
          offset = CGSize(
            width: offset.width + value.translation.width,
            height: offset.height + value.translation.height,
          )
        }
    )
  }

  /// Back-edge opacity multiplier given the current radial plan.
  /// Returns `1` in trunk-tree mode (back-edges visible at their
  /// computed Phase-B opacity); in radial-focus mode, back-edges
  /// incident to a 1-hop ring node stay at full multiplier (they
  /// still tell the eye "this neighbour is connected to the
  /// selected genre"); all other back-edges fade further toward the
  /// out-of-focus level.
  private func backEdgesLayer(
    model: GenreTreeRenderModel,
    transform: ViewTransform,
    radialPlan: GenreTreeRadialPlan.Plan?,
    inCompareMode: Bool,
  ) -> some View {
    // Compare mode wins over radial-focus: back-edges dim to a single
    // low tier so the path-edge layer reads cleanly above them. Outside
    // compare mode the existing Phase-C scheme applies.
    let multiplier =
      if inCompareMode {
        0.15
      } else if radialPlan != nil {
        0.25
      } else {
        1.0
      }
    return BackEdgeLayer(
      segments: model.backEdges,
      project: transform.project,
    )
    .opacity(multiplier)
  }

  private func branchEdgesLayer(
    model: GenreTreeRenderModel,
    colourByGenre: [String: Color],
    transform: ViewTransform,
    radialPlan: GenreTreeRadialPlan.Plan?,
    comparePathEdges: Set<EdgeKey>,
    inCompareMode: Bool,
  ) -> some View {
    // One sub-canvas per branch edge. ~115 edges on the real library —
    // a `Canvas` with a single big path would be marginally cheaper but
    // would lose the per-edge colour assignment we want (a green
    // subtree's edges are green; an orange subtree's edges are
    // orange). One BranchEdge view per non-trunk node is acceptable;
    // SwiftUI batches the Canvas strokes per frame.
    //
    // Phase C: in radial-focus mode every tree edge fades unless one
    // of its endpoints is the selected genre or a 1-hop neighbour.
    // Phase D: compare mode wins — every tree edge fades unless it
    // sits on a Yen-k path between the two compared genres.
    ForEach(branchPlacedNodes(model: model), id: \.genre.name) { placed in
      if let edge = placed.edge, let parent = placed.parentGenre {
        let edgeOpacity: Double = {
          if inCompareMode {
            let key = EdgeKey(
              a: min(parent, placed.genre.name),
              b: max(parent, placed.genre.name),
            )
            return comparePathEdges.contains(key) ? 1.0 : 0.08
          }
          return edgeOpacityFor(
            a: parent,
            b: placed.genre.name,
            radialPlan: radialPlan,
          )
        }()
        // World endpoints, projected through the radial plan if active
        // so the curve follows pills as they animate to their target
        // positions.
        let projectedCurve = projectedCurve(
          edge: edge,
          parent: parent,
          child: placed.genre.name,
          radialPlan: radialPlan,
        )
        BranchEdge(
          curve: projectedCurve,
          childDepth: placed.depth,
          colour: colourByGenre[placed.genre.name] ?? .secondary,
          project: transform.project,
        )
        .opacity(edgeOpacity)
      }
    }
    .animation(
      .easeInOut(duration: service.animationDurationSeconds),
      value: selectedGenre,
    )
    .animation(
      .easeInOut(duration: service.animationDurationSeconds),
      value: compareGenre,
    )
  }

  private func pillsLayer(
    model: GenreTreeRenderModel,
    colourByGenre: [String: Color],
    transform: ViewTransform,
    radialPlan: GenreTreeRadialPlan.Plan?,
    compareHighlights: Set<String>,
    inCompareMode: Bool,
  ) -> some View {
    ForEach(model.layout.placedNodes, id: \.genre.name) { placed in
      let target = radialPlan?.targetsByGenre[placed.genre.name]
      let worldPosition = target?.position ?? placed.position
      // Compare mode overrides the radial opacity scheme: highlights
      // stay at 1.0, everything else dims to a single low tier.
      let opacity: Double = inCompareMode
        ? (compareHighlights.contains(placed.genre.name) ? 1.0 : 0.12)
        : (target?.opacity ?? 1.0)
      let projected = transform.project(worldPosition)
      let colour = colourByGenre[placed.genre.name] ?? .secondary
      let isSelected = inCompareMode
        ? compareHighlights.contains(placed.genre.name)
        : (target?.ring == .selected)
      Group {
        if placed.depth == 0 {
          TrunkPill(
            genre: placed.genre,
            colour: colour,
            isHighlighted: isSelected,
            isFaded: false,
            onTap: { select(placed.genre.name) },
          )
        } else {
          BranchPill(
            genre: placed.genre,
            depth: placed.depth,
            colour: colour,
            isHighlighted: isSelected,
            isFaded: false,
            onTap: { select(placed.genre.name) },
          )
        }
      }
      .opacity(opacity)
      .position(projected)
    }
    .animation(
      .easeInOut(duration: service.animationDurationSeconds),
      value: selectedGenre,
    )
    .animation(
      .easeInOut(duration: service.animationDurationSeconds),
      value: compareGenre,
    )
  }

  /// Pick the visible opacity for a parent → child edge given the
  /// current radial focus state. In trunk-tree mode: full opacity.
  /// In radial-focus mode: edges adjacent to the selected genre or a
  /// 1-hop neighbour stay visible; 2-hop-adjacent edges dim; out-of-
  /// focus edges hide.
  private func edgeOpacityFor(
    a: String,
    b: String,
    radialPlan: GenreTreeRadialPlan.Plan?,
  ) -> Double {
    guard let plan = radialPlan else { return 1.0 }
    let ringA = plan.targetsByGenre[a]?.ring ?? .outOfFocus
    let ringB = plan.targetsByGenre[b]?.ring ?? .outOfFocus
    // The edge is visible at full strength when one endpoint is the
    // selected genre + the other is a 1-hop neighbour. That's the
    // "spoke" reading the eye wants.
    if (ringA == .selected && ringB == .oneHop) || (ringA == .oneHop && ringB == .selected) {
      return 1.0
    }
    // An edge between two 1-hop neighbours is the radial "rim" — kept
    // present but slightly dimmed.
    if ringA == .oneHop, ringB == .oneHop { return 0.6 }
    // 2-hop-adjacent edges (selected ↔ 2-hop OR 1-hop ↔ 2-hop): visible
    // but subordinate.
    if ringA == .twoHop || ringB == .twoHop { return 0.4 }
    // Everything else (involves an out-of-focus endpoint) hides.
    return 0.0
  }

  /// Project the layout's pre-computed world-space Bezier endpoints
  /// through the radial plan, if active. Recomputes the curve's
  /// control points whenever an endpoint moves so the curve stays
  /// anchored to the animating pill. Pure geometry; no per-frame
  /// recompute (SwiftUI interpolates the resulting BezierCurve via
  /// the `.animation(value:)` modifier).
  private func projectedCurve(
    edge: GenreTreeLayout.BezierCurve,
    parent: String,
    child: String,
    radialPlan: GenreTreeRadialPlan.Plan?,
  ) -> GenreTreeLayout.BezierCurve {
    guard let plan = radialPlan else { return edge }
    let parentPosition = plan.targetsByGenre[parent]?.position ?? edge.start
    let childPosition = plan.targetsByGenre[child]?.position ?? edge.end
    return GenreTreeLayout.makeEdge(
      from: parentPosition,
      to: childPosition,
      fraction: 0.45,
    )
  }

  /// Compute the radial plan for the current `selectedGenre`, or
  /// `nil` in trunk-tree mode.
  private func currentRadialPlan(
    model: GenreTreeRenderModel
  ) -> GenreTreeRadialPlan.Plan? {
    guard let selectedGenre else { return nil }
    return GenreTreeRadialPlan.plan(
      selectedGenre: selectedGenre,
      layout: model.layout,
      evidence: model.evidence,
    )
  }

  /// Map every placed genre → its trunk's community colour. Subtrees
  /// inherit colour from their root trunk; the BFS forest's
  /// first-claim rule guarantees no genre is on two subtrees.
  private func communityColourByGenre(model: GenreTreeRenderModel) -> [String: Color] {
    var out = [String: Color]()
    out.reserveCapacity(model.layout.placedNodes.count)
    for trunk in model.topology.trunks {
      let colour = Self.communityColour(for: trunk.communityID)
      assignColours(node: trunk.root, colour: colour, into: &out)
    }
    return out
  }

  /// Recursive walk: every descendant of `node` inherits `colour`.
  private func assignColours(
    node: GenreTreeNode,
    colour: Color,
    into out: inout [String: Color],
  ) {
    out[node.genre.name] = colour
    for child in node.children {
      assignColours(node: child, colour: colour, into: &out)
    }
  }

  /// Non-trunk placed nodes (i.e. every node that has a parent edge).
  /// Avoids a per-edge `if depth == 0` filter inside the ForEach
  /// builder.
  private func branchPlacedNodes(
    model: GenreTreeRenderModel
  ) -> [GenreTreeLayout.PlacedNode] {
    model.layout.placedNodes.filter { $0.depth > 0 }
  }

  /// Enter radial-focus mode on `genre`, or enter compare mode if the
  /// click landed with ⇧ held and a primary focus already exists.
  /// Reads the actual click event's modifier flags rather than the
  /// global `NSEvent.modifierFlags` (same pattern the metro panel
  /// uses — by the time a SwiftUI closure runs the key may already
  /// have been released, but the dispatched event still carries the
  /// modifier state). Loads single-genre or compare evidence on each
  /// new focus.
  private func select(_ genre: String) {
    let eventShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
    if eventShift, let first = selectedGenre, first != genre {
      withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
        compareGenre = genre
      }
      ensureInspectorVisible()
      loadCompareEvidence(from: first, to: genre)
      return
    }
    // Fresh single-genre focus — drop any pending compare + reset
    // evidence state, kick off the representative load.
    representativeTask?.cancel()
    compareTask?.cancel()
    withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
      selectedGenre = genre
      compareGenre = nil
    }
    comparePaths = []
    compareEvidence = nil
    isLoadingCompare = false
    representativeEvidence = nil
    isLoadingRepresentative = true
    ensureInspectorVisible()
    representativeTask = Task {
      let loaded = await controller.genreMapService.representativeEvidence(for: genre)
      if Task.isCancelled { return }
      await MainActor.run {
        representativeEvidence = loaded
        isLoadingRepresentative = false
      }
    }
  }

  /// Leave radial-focus mode (and compare mode, if active). Same
  /// animation in reverse.
  private func clearSelection() {
    guard selectedGenre != nil || compareGenre != nil else { return }
    representativeTask?.cancel()
    compareTask?.cancel()
    withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
      selectedGenre = nil
      compareGenre = nil
    }
    comparePaths = []
    compareEvidence = nil
    isLoadingCompare = false
    representativeEvidence = nil
    isLoadingRepresentative = false
  }

  /// Exit compare mode but keep the primary focus.
  private func endCompare() {
    guard compareGenre != nil else { return }
    compareTask?.cancel()
    withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
      compareGenre = nil
    }
    comparePaths = []
    compareEvidence = nil
    isLoadingCompare = false
  }

  /// Pop the inspector open if it's hidden — every fresh selection in
  /// the metro panel does this, same posture here so the user's first
  /// click after an explicit hide still surfaces the new evidence.
  private func ensureInspectorVisible() {
    if !inspectorPresented { inspectorPresented = true }
  }

  /// Click from inside the inspector's 1-hop list — re-focus the
  /// canvas on the clicked neighbour. Same posture as the metro
  /// panel's `selectByName`.
  private func selectByName(_ genre: String) {
    select(genre)
  }

  /// Phase D — Yen-k paths over the layout graph (`genre_edge_evidence`),
  /// then a paginated SQL rollup of shared artists/albums/tracks. The
  /// path search itself is pure + sub-millisecond; the SQL rollup is
  /// the async hop.
  private func loadCompareEvidence(from genreA: String, to genreB: String) {
    let evidenceEdges = currentEvidence().map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    comparePaths = GenreMapDiscovery.kShortestPaths(
      from: genreA,
      to: genreB,
      edges: evidenceEdges,
      k: 5,
    )
    compareEvidence = nil
    isLoadingCompare = true
    compareTask?.cancel()
    compareTask = Task {
      let loaded = await controller.genreMapService.compareEvidence(
        between: genreA,
        and: genreB,
      )
      if Task.isCancelled { return }
      await MainActor.run {
        compareEvidence = loaded
        isLoadingCompare = false
      }
    }
  }

  /// Phase D — start a transient queue from the deterministic Top-N
  /// pick for `genre`. Fire-and-forget; the in-flight flag disables
  /// the button so a repeated click can't queue twice.
  private func triggerListen(for genre: String) {
    guard !isListenInFlight else { return }
    isListenInFlight = true
    Task {
      await controller.listenToGenre(genre)
      await MainActor.run {
        isListenInFlight = false
      }
    }
  }

  /// Phase D — create the "Genre Tree: <name>" app playlist with the
  /// same Top-N pick. `saveListenAsAppPlaylist` selects the new
  /// playlist in the sidebar; collapsing the docked pane then hands the
  /// full detail height to the new playlist's track list so the user
  /// lands on what they just saved.
  private func triggerSaveAsPlaylist(for genre: String) {
    guard !isListenInFlight else { return }
    isListenInFlight = true
    Task {
      let newID = await controller.saveListenAsAppPlaylist(genre: genre)
      await MainActor.run {
        isListenInFlight = false
        if newID != nil {
          controller.genreTreePaneCollapsed = true
        }
      }
    }
  }

  private func zoomIn() {
    scale = clamp(scale * 1.25, min: 0.1, max: 6.0)
  }

  private func zoomOut() {
    scale = clamp(scale / 1.25, min: 0.1, max: 6.0)
  }

  private func resetZoom() {
    scale = 1.0
    offset = .zero
    fitRequested = false
  }

  private func fitToView() {
    fitRequested = true
    scale = 1.0
    offset = .zero
  }

  /// World → screen base transform.
  ///
  /// Two modes, matching the metro panel's pattern:
  ///
  /// - **Fit requested** (Cmd-9): scale the canvas's worldBounds into
  ///   the viewport with `80pt` padding, centre.
  /// - **Default**: identity scale, centre on the **canvas centre**
  ///   (not the heaviest community — the trunk tree's anchor is the
  ///   diagonal, which is itself centred on the canvas).
  private func baseTransform(model: GenreTreeRenderModel, into size: CGSize) -> FitTransform {
    let bounds = model.layout.worldBounds
    guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
      return FitTransform(scale: 1, translation: .zero)
    }
    if fitRequested {
      let padding: CGFloat = 80
      let availableWidth = max(1, size.width - 2 * padding)
      let availableHeight = max(1, size.height - 2 * padding)
      let fitScale = min(availableWidth / bounds.width, availableHeight / bounds.height)
      let scaledCentreX = (bounds.minX + bounds.width / 2) * fitScale
      let scaledCentreY = (bounds.minY + bounds.height / 2) * fitScale
      let translation = CGSize(
        width: size.width / 2 - scaledCentreX,
        height: size.height / 2 - scaledCentreY,
      )
      return FitTransform(scale: fitScale, translation: translation)
    }
    // Default — identity scale, centre on canvas centre. With the
    // diagonal layout the trunks straddle the canvas centre, so this
    // is the natural starting view.
    let centreX = bounds.minX + bounds.width / 2
    let centreY = bounds.minY + bounds.height / 2
    return FitTransform(
      scale: 1,
      translation: CGSize(
        width: size.width / 2 - centreX,
        height: size.height / 2 - centreY,
      ),
    )
  }

  private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.min(maxValue, Swift.max(minValue, value))
  }
}
