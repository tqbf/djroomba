import SwiftUI

// MARK: - GenreTreeMapPanel

/// Phase B sheet content (`plans/son-of-genre-map.md` Phase B). The
/// successor to `GenreMapPanel`. Renders the trunk-tree at default
/// state: trunk pills along the diagonal, branches fanning radially,
/// faint back-edges underneath.
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
/// Phase B doesn't surface selection / hover / radial-focus / compare
/// — those are Phase C / D additions. The pills accept taps, but the
/// handler is a no-op for now (the view layer's wiring is in place
/// for Phase C to flip on).
///
/// The metro `GenreMapPanel` stays in-tree for comparison rebuilds
/// (the menu's hidden "Show Genre Map (Metro)" action) but isn't the
/// default user-visible surface anymore. Phase E retires it entirely.
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

  @GestureState private var gestureScale: CGFloat = 1.0
  @GestureState private var gestureOffset = CGSize.zero

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
        "Drag to pan · Pinch / ⌘+ / ⌘− to zoom · ⌘0 reset · ⌘9 fit"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
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

    return ZStack {
      Color.clear
        .contentShape(Rectangle())
      backEdgesLayer(model: model, transform: viewTransform)
      branchEdgesLayer(model: model, colourByGenre: colourByGenre, transform: viewTransform)
      pillsLayer(model: model, colourByGenre: colourByGenre, transform: viewTransform)
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

  private func backEdgesLayer(
    model: GenreTreeRenderModel,
    transform: ViewTransform,
  ) -> some View {
    BackEdgeLayer(
      segments: model.backEdges,
      project: transform.project,
    )
  }

  private func branchEdgesLayer(
    model: GenreTreeRenderModel,
    colourByGenre: [String: Color],
    transform: ViewTransform,
  ) -> some View {
    // One sub-canvas per branch edge. ~115 edges on the real library —
    // a `Canvas` with a single big path would be marginally cheaper but
    // would lose the per-edge colour assignment we want (a green
    // subtree's edges are green; an orange subtree's edges are
    // orange). One BranchEdge view per non-trunk node is acceptable;
    // SwiftUI batches the Canvas strokes per frame.
    ForEach(branchPlacedNodes(model: model), id: \.genre.name) { placed in
      if let edge = placed.edge {
        BranchEdge(
          curve: edge,
          childDepth: placed.depth,
          colour: colourByGenre[placed.genre.name] ?? .secondary,
          project: transform.project,
        )
      }
    }
  }

  private func pillsLayer(
    model: GenreTreeRenderModel,
    colourByGenre: [String: Color],
    transform: ViewTransform,
  ) -> some View {
    ForEach(model.layout.placedNodes, id: \.genre.name) { placed in
      let projected = transform.project(placed.position)
      let colour = colourByGenre[placed.genre.name] ?? .secondary
      Group {
        if placed.depth == 0 {
          TrunkPill(
            genre: placed.genre,
            colour: colour,
            onTap: { /* Phase C: radial-focus on this genre. */ },
          )
        } else {
          BranchPill(
            genre: placed.genre,
            depth: placed.depth,
            colour: colour,
            onTap: { /* Phase C: radial-focus on this genre. */ },
          )
        }
      }
      .position(projected)
    }
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
