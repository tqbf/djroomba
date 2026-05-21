import SwiftUI

// MARK: - GenreTreeMapPanel

/// Phase B + C sheet content (`plans/son-of-genre-map.md`). The
/// successor to `GenreMapPanel`. Renders the trunk-tree at default
/// state: trunk pills along the diagonal, branches fanning radially,
/// faint back-edges underneath. Phase C adds radial-focus mode:
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
    VStack(spacing: 0) {
      header
      Divider()
      content
      Divider()
      footer
    }
    .frame(minWidth: 720, minHeight: 540)
    .frame(idealWidth: 1140, idealHeight: 760)
    .task {
      if controller.genreTreeService.renderModel == nil {
        await controller.genreTreeService.build()
      }
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

  @Environment(MusicController.self) private var controller
  @Environment(\.dismiss) private var dismiss

  @State private var scale: CGFloat = 1.0
  @State private var offset = CGSize.zero
  @State private var fitRequested = false
  /// Live viewport size, updated by `mapBody`'s `GeometryReader`.
  @State private var viewportSize = CGSize(width: 900, height: 600)

  /// Phase C — `nil` ⇒ trunk-tree mode, non-nil ⇒ radial-focus mode
  /// centred on this genre.
  @State private var selectedGenre: String?

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

  private var header: some View {
    HStack(spacing: 12) {
      Text("Genre Tree")
        .font(.headline)
      if service.isBuilding {
        ProgressView()
          .controlSize(.small)
        Text("Building…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if let model = service.renderModel {
        let trunkCount = model.topology.trunks.count
        let nodeCount = model.layout.placedNodes.count
        let backEdgeCount = model.backEdges.count
        Text(
          "\(trunkCount) trunks · \(nodeCount) genres · \(backEdgeCount) back-edges"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
      } else if let error = service.lastError {
        Text(error)
          .font(.subheadline)
          .foregroundStyle(.red)
      }
      Spacer()
      // Trunk-selection metric — live A/B toggle per the plan's
      // "user picks default after seeing all three" deferral. Picker
      // not Menu because the three states are equally weighted; a
      // segmented picker reads as "live A/B switch" not "preference".
      Picker("Trunk metric", selection: Bindable(service).metric) {
        Text("Transferness")
          .tag(TrunkSelectionMetric.highestTransferness)
        Text("Weight")
          .tag(TrunkSelectionMetric.highestWeight)
        Text("Centrality")
          .tag(TrunkSelectionMetric.highestCentrality)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 320)
      .labelsHidden()
      .help("Switch which member of each community gets the trunk slot")

      // Phase C — animation-duration A/B toggle. Picks the eventual
      // ship default after live verification on the real library.
      // Surfaces as compact segmented "ms" tags so the header doesn't
      // crowd; the labels read as durations rather than ordinals.
      Picker("Animation duration", selection: Bindable(service).animationDurationSeconds) {
        Text("200").tag(0.2)
        Text("300").tag(0.3)
        Text("400").tag(0.4)
        Text("500").tag(0.5)
      }
      .pickerStyle(.segmented)
      .frame(maxWidth: 180)
      .labelsHidden()
      .help("Radial-focus animation duration in milliseconds")

      Button("Re-Analyze", systemImage: "arrow.clockwise") {
        Task {
          await controller.analyzeGenreTree()
        }
      }
      .labelStyle(.titleAndIcon)
      .disabled(service.isBuilding)

      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
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
      .background(Color(nsColor: .underPageBackgroundColor))
    } else if service.isBuilding {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
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
      )
      branchEdgesLayer(
        model: model,
        colourByGenre: colourByGenre,
        transform: viewTransform,
        radialPlan: radialPlan,
      )
      pillsLayer(
        model: model,
        colourByGenre: colourByGenre,
        transform: viewTransform,
        radialPlan: radialPlan,
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
  ) -> some View {
    let multiplier: Double = radialPlan == nil ? 1.0 : 0.25
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
    ForEach(branchPlacedNodes(model: model), id: \.genre.name) { placed in
      if let edge = placed.edge, let parent = placed.parentGenre {
        let edgeOpacity = edgeOpacityFor(
          a: parent,
          b: placed.genre.name,
          radialPlan: radialPlan,
        )
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
  }

  private func pillsLayer(
    model: GenreTreeRenderModel,
    colourByGenre: [String: Color],
    transform: ViewTransform,
    radialPlan: GenreTreeRadialPlan.Plan?,
  ) -> some View {
    ForEach(model.layout.placedNodes, id: \.genre.name) { placed in
      let target = radialPlan?.targetsByGenre[placed.genre.name]
      let worldPosition = target?.position ?? placed.position
      let opacity = target?.opacity ?? 1.0
      let projected = transform.project(worldPosition)
      let colour = colourByGenre[placed.genre.name] ?? .secondary
      let isSelected = target?.ring == .selected
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

  /// Enter radial-focus mode on `genre`. Wrapped in a single
  /// `withAnimation` block so SwiftUI interpolates every
  /// `.position()` + `.opacity()` from current to target across the
  /// duration. No per-frame work beyond the SwiftUI interpolation
  /// itself — the radial plan's targets are computed once and held
  /// in `currentRadialPlan` for the rest of the frame.
  private func select(_ genre: String) {
    withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
      selectedGenre = genre
    }
  }

  /// Leave radial-focus mode. Same animation in reverse.
  private func clearSelection() {
    guard selectedGenre != nil else { return }
    withAnimation(.easeInOut(duration: service.animationDurationSeconds)) {
      selectedGenre = nil
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
