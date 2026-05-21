import SwiftUI

// MARK: - GenreMapPanel

/// Phase 1+2+3+4+5 (`plans/genre-metro-map.md`) of the genre **metro map**
/// — a sibling to the v6 `GenreGraphPanel`. Shown in a sheet from the
/// Playback menu (`Show Genre Map…`).
///
/// Phase 5 layering on top of the Phase 1–4 substrate:
///
/// - **Hover** a genre ⇒ pure-cosmetic highlight + neighbour brighten +
///   serving-strand brighten + 1-hop neighbours pop, with a hover
///   tooltip overlay near the pill. Never recomputes layout / routing.
/// - **Click** a genre ⇒ inspector enters single-genre mode. Ordinary
///   = ego network + representative artists/albums. Junction = above +
///   connected-neighbourhood placenames. Transfer station = pan + zoom
///   to centre the pill, raise the layout edges to ≤20 % (the only
///   state where dense edges are allowed), and the inspector lists
///   serving strands + next 3–5 stations along each.
/// - **Shift-click** a second genre ⇒ inspector enters compare mode:
///   Yen-k paths over the layout graph + shared evidence (artists,
///   albums, tracks).
///
/// The inspector is a native macOS 14 `.inspector()` column hosted by
/// the sheet. Toolbar toggle + scene-storage persistence match the
/// existing `MainShellView` ExtensionInspector pattern.
struct GenreMapPanel: View {

  // MARK: Internal

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          content
          Divider()
          footer
        }
        if inspectorPresented {
          Divider()
          GenreMapInspector(
            selection: inspectorSelection,
            model: service.model ?? emptyModel,
            representativeEvidence: representativeEvidence,
            isLoadingRepresentative: isLoadingRepresentative,
            comparePaths: comparePaths,
            compareEvidence: compareEvidence,
            isLoadingCompare: isLoadingCompare,
            onSelectNeighbour: selectByName,
            onRequestCompare: beginCompare,
            onExitCompare: endCompare,
          )
          .frame(width: 340)
          .background(Color(nsColor: .windowBackgroundColor))
          .transition(.move(edge: .trailing).combined(with: .opacity))
        }
      }
    }
    .animation(.easeInOut(duration: 0.18), value: inspectorPresented)
    .frame(minWidth: 720, minHeight: 540)
    .frame(idealWidth: 1140, idealHeight: 760)
    .task {
      await controller.genreMapService.load(
        measureLabel: GenreMapService.defaultMeasureLabel
      )
    }
  }

  /// Deterministic community palette — small set of distinguishable hues
  /// so adjacent communities don't read as the same colour.
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
    return palette[((id % palette.count) + palette.count) % palette.count]
  }

  /// Strand palette — distinguishable hues, **offset from** the community
  /// palette so a strand colour doesn't accidentally match the community
  /// it traverses. The strand and its containing community can both be
  /// on screen at once; matching hues confuse what carries semantic
  /// weight (strand vs community).
  static func strandColour(for colourID: Int) -> Color {
    let palette: [Color] = [
      .red,
      .orange,
      .yellow,
      .green,
      .mint,
      .cyan,
      .blue,
      .indigo,
      .purple,
      .pink,
      .brown,
      .teal,
    ]
    return palette[((colourID % palette.count) + palette.count) % palette.count]
  }

  // MARK: Private

  private struct DragState: Equatable {
    var genre: String
    var initialPosition: CGPoint
  }

  private struct FitTransform {
    var scale: CGFloat
    var translation: CGSize
  }

  private struct ViewTransform {
    var fitted: FitTransform
    var scale: CGFloat
    var offset: CGSize

    func project(_ world: CGPoint) -> CGPoint {
      let scaled = CGPoint(
        x: world.x * fitted.scale + fitted.translation.width,
        y: world.y * fitted.scale + fitted.translation.height,
      )
      let centred = CGPoint(
        x: (scaled.x - 0) * scale + 0,
        y: (scaled.y - 0) * scale + 0,
      )
      return CGPoint(
        x: centred.x + offset.width,
        y: centred.y + offset.height,
      )
    }

    func unproject(_ screen: CGPoint) -> CGPoint {
      let centred = CGPoint(
        x: screen.x - offset.width,
        y: screen.y - offset.height,
      )
      let scaled = CGPoint(
        x: centred.x / scale,
        y: centred.y / scale,
      )
      return CGPoint(
        x: (scaled.x - fitted.translation.width) / fitted.scale,
        y: (scaled.y - fitted.translation.height) / fitted.scale,
      )
    }
  }

  private struct EdgeKey: Hashable {
    var a: String
    var b: String
  }

  @Environment(MusicController.self) private var controller
  @Environment(\.dismiss) private var dismiss

  @State private var scale: CGFloat = 1.0
  @State private var offset = CGSize.zero
  @State private var dragging: DragState?
  @State private var centredOnce = false
  @State private var fitRequested = false
  /// Phase 5 selection. `selectedGenre` is the focused genre; in
  /// compare-mode `compareSecondGenre` is set and the inspector shows
  /// the compare card.
  @State private var selectedGenre: String?
  @State private var compareSecondGenre: String?
  /// `true` while the panel is waiting for a ⇧-click to pick the
  /// compare partner. The cursor doesn't change (avoid OS contention)
  /// — instead the inspector header swaps to a "pick another genre"
  /// hint.
  @State private var comparePending = false
  /// Phase 5 cosmetic-only hover state. Hovering a genre populates
  /// this; never triggers an evidence load or a recompute.
  @State private var hoveredGenre: String?
  @State private var hoveredStrandID: Int?

  /// Phase 5 evidence rollups. Loaded on demand by the panel's
  /// `Task`s; the inspector reads.
  @State private var representativeEvidence: GenreMapRepresentativeEvidence?
  @State private var isLoadingRepresentative = false
  @State private var representativeTask: Task<Void, Never>?
  @State private var comparePaths = [GenreMapDiscovery.Path]()
  @State private var compareEvidence: GenreMapCompareEvidence?
  @State private var isLoadingCompare = false
  @State private var compareTask: Task<Void, Never>?

  @SceneStorage("genreMapInspectorPresented") private var inspectorPresented = true

  @GestureState private var gestureScale: CGFloat = 1.0
  @GestureState private var gestureOffset = CGSize.zero

  private var service: GenreMapService {
    controller.genreMapService
  }

  /// `true` ⇒ a transfer-station has been clicked and the canvas is
  /// in transfer-map mode (denser edges allowed, pill centred).
  private var transferMapMode: Bool {
    guard
      compareSecondGenre == nil,
      let selectedGenre, let model = service.model,
      let node = model.nodes.first(where: { $0.genre == selectedGenre })
    else { return false }
    return node.nodeKind == .transferStation
  }

  private var inspectorSelection: GenreMapInspectorSelection {
    guard let model = service.model else { return .empty }
    if
      let selectedGenre, let second = compareSecondGenre,
      let lhs = model.nodes.first(where: { $0.genre == selectedGenre }),
      let rhs = model.nodes.first(where: { $0.genre == second })
    {
      return .compare(lhs, rhs)
    }
    if
      let selectedGenre,
      let node = model.nodes.first(where: { $0.genre == selectedGenre })
    {
      return .single(node)
    }
    return .empty
  }

  /// Fallback empty model so the inspector can always be present even
  /// before the first build finishes (it shows the `.empty` state).
  private var emptyModel: GenreMapModel {
    GenreMapModel(
      nodes: [],
      layoutEdges: [],
      communities: [],
      worldBounds: .zero,
    )
  }

  private var header: some View {
    HStack {
      Text("Genre Map")
        .font(.headline)
      if service.isAnalyzing {
        ProgressView()
          .controlSize(.small)
        Text("Analyzing…")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      } else if let model = service.model {
        Text("\(model.nodes.count) genres · \(model.layoutEdges.count) layout edges · \(model.communities.count) neighbourhoods")
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Re-Analyze", systemImage: "arrow.clockwise") {
        Task {
          await controller.analyzeGenreMap()
          centredOnce = false
        }
      }
      .labelStyle(.titleAndIcon)
      .disabled(service.isAnalyzing)
      Button {
        inspectorPresented.toggle()
      } label: {
        Label("Inspector", systemImage: "sidebar.trailing")
      }
      .labelStyle(.iconOnly)
      .help("Show or hide the inspector (⌘⌥I)")
      .keyboardShortcut("i", modifiers: [.command, .option])
      Button("Done") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var content: some View {
    Group {
      if service.model == nil {
        emptyState
      } else if let model = service.model {
        GeometryReader { geometry in
          mapBody(model: model, in: geometry.size)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .underPageBackgroundColor))
  }

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No Genre Map Yet", systemImage: "map")
    } description: {
      Text(
        "Genres + their structural relationships appear here once the map has been analyzed. Build it once your library has genre tags — or rebuild it any time."
      )
    } actions: {
      Button("Analyze") {
        Task {
          await controller.analyzeGenreMap()
          centredOnce = false
        }
      }
      .disabled(service.isAnalyzing)
    }
  }

  private var footer: some View {
    VStack(spacing: 4) {
      strandHoverRow
      HStack {
        Image(systemName: "hand.point.up.left")
        Text(
          "Drag a genre · Click for evidence · ⇧-click to compare · Pinch / ⌘+ / ⌘− zoom · ⌘0 reset · ⌘9 fit · Hover a strand or pill"
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
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(.bar)
  }

  @ViewBuilder
  private var strandHoverRow: some View {
    if
      let model = service.model,
      !model.strands.filter({ !$0.isBranch }).isEmpty
    {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 6) {
          ForEach(model.strands.filter { !$0.isBranch }) { strand in
            strandChip(strand)
          }
        }
        .padding(.horizontal, 2)
      }
      .frame(maxHeight: 28)
    }
  }

  /// Compute the set of layout-graph edges whose endpoints lie along
  /// any of the compare-mode top-k paths. Returns canonical-half
  /// `EdgeKey`s.
  private var compareEdgeSet: Set<EdgeKey> {
    guard !comparePaths.isEmpty else { return [] }
    var keys = Set<EdgeKey>()
    for path in comparePaths {
      let stations = path.stations
      guard stations.count >= 2 else { continue }
      for index in 0..<(stations.count - 1) {
        let lhs = stations[index]
        let rhs = stations[index + 1]
        keys.insert(EdgeKey(a: min(lhs, rhs), b: max(lhs, rhs)))
      }
    }
    return keys
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
    centredOnce = false
  }

  private func fitToView() {
    guard
      let model = service.model,
      model.worldBounds.width > 0,
      model.worldBounds.height > 0
    else { return }
    fitRequested = true
    scale = 1.0
    offset = .zero
  }

  private func strandChip(_ strand: GenreMapStrandInference.Strand) -> some View {
    let colour = Self.strandColour(for: strand.colourID)
    let isHovered = hoveredStrandID == strand.id
    let chipLabel = strand.label.isEmpty
      ? strand.representativeGenres.first ?? "Strand \(strand.id + 1)"
      : strand.label
    return HStack(spacing: 5) {
      Circle()
        .fill(colour)
        .frame(width: 8, height: 8)
      Text(chipLabel)
        .font(.caption2)
        .lineLimit(1)
        .foregroundStyle(isHovered ? .primary : .secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(
      Capsule(style: .continuous)
        .fill(colour.opacity(isHovered ? 0.18 : 0.08))
        .overlay(
          Capsule(style: .continuous)
            .strokeBorder(colour.opacity(isHovered ? 0.7 : 0.3), lineWidth: 1)
        )
    )
    .onHover { isInside in
      hoveredStrandID = isInside ? strand.id : (hoveredStrandID == strand.id ? nil : hoveredStrandID)
    }
    .help(strandTooltip(strand))
  }

  private func strandTooltip(_ strand: GenreMapStrandInference.Strand) -> String {
    let members = strand.memberGenres.prefix(6).joined(separator: ", ")
    let suffix = strand.memberGenres.count > 6 ? "…" : ""
    return "\(strand.label.isEmpty ? "Strand" : strand.label) — \(members)\(suffix)"
  }

  @ViewBuilder
  private func mapBody(model: GenreMapModel, in size: CGSize) -> some View {
    let fitted = baseTransform(model: model, into: size)
    let activeScale = scale * gestureScale
    let activeOffset = CGSize(
      width: offset.width + gestureOffset.width,
      height: offset.height + gestureOffset.height,
    )
    let viewTransform = ViewTransform(
      fitted: fitted,
      scale: activeScale,
      offset: activeOffset,
    )

    ZStack {
      hullsCanvas(model: model, transform: viewTransform)
      edgesCanvas(model: model, transform: viewTransform)
      strandsLayer(model: model, transform: viewTransform)
      labelsLayer(model: model, transform: viewTransform)
      hoverTooltipOverlay(model: model, transform: viewTransform)
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
          guard dragging == nil else { return }
          state = value.translation
        }
        .onEnded { value in
          guard dragging == nil else { return }
          offset = CGSize(
            width: offset.width + value.translation.width,
            height: offset.height + value.translation.height,
          )
        }
    )
    .simultaneousGesture(
      TapGesture()
        .onEnded {
          if selectedGenre != nil { dismissEvidence() }
        }
    )
    .accessibilityElement(children: .contain)
    .onAppear {
      if !centredOnce { centredOnce = true }
    }
    .onChange(of: model.nodes.count) { _, _ in
      centredOnce = false
      fitRequested = false
      scale = 1.0
      offset = .zero
    }
  }

  private func hullsCanvas(model: GenreMapModel, transform: ViewTransform) -> some View {
    Canvas { context, _ in
      for community in model.communities where !community.members.isEmpty {
        let members = model.nodes.filter { community.members.contains($0.genre) }
        guard !members.isEmpty else { continue }
        var centroidX: CGFloat = 0
        var centroidY: CGFloat = 0
        for member in members {
          let point = transform.project(member.position)
          centroidX += point.x
          centroidY += point.y
        }
        centroidX /= CGFloat(members.count)
        centroidY /= CGFloat(members.count)
        var radius: CGFloat = 0
        for member in members {
          let point = transform.project(member.position)
          radius = max(
            radius,
            hypot(point.x - centroidX, point.y - centroidY),
          )
        }
        radius = max(64, radius * 1.5)
        let colour = Self.communityColour(for: community.id)
        let rect = CGRect(
          x: centroidX - radius,
          y: centroidY - radius,
          width: radius * 2,
          height: radius * 2,
        )
        let gradient = Gradient(colors: [
          colour.opacity(0.20),
          colour.opacity(0),
        ])
        context.fill(
          Path(ellipseIn: rect),
          with: .radialGradient(
            gradient,
            center: CGPoint(x: centroidX, y: centroidY),
            startRadius: 0,
            endRadius: radius,
          ),
        )
      }
    }
    .allowsHitTesting(false)
  }

  /// Edges canvas. Phase 5: on a clicked transfer station the layout
  /// edges incident to it raise to ~30 % opacity (dense edges allowed
  /// here, per the plan — the user has explicitly asked). Compare-mode
  /// raises the edges along the highest-weight path. Hover never
  /// changes edge opacity (cosmetic state shouldn't move strokes).
  private func edgesCanvas(model: GenreMapModel, transform: ViewTransform) -> some View {
    let hoverNeighbourSet = hoverNeighbourGenreSet(model: model)
    let transferEdgeSet = transferModeEdgeSet(model: model)
    let compareEdgeSet = compareEdgeSet
    return Canvas { context, _ in
      var positions = [String: CGPoint]()
      positions.reserveCapacity(model.nodes.count)
      for node in model.nodes {
        positions[node.genre] = transform.project(node.position)
      }
      for edge in model.layoutEdges {
        guard
          let lhs = positions[edge.genreA],
          let rhs = positions[edge.genreB]
        else { continue }
        var path = Path()
        path.move(to: lhs)
        path.addLine(to: rhs)
        let baseOpacity = 0.04 + 0.06 * edge.totalWeight
        let key = EdgeKey(a: min(edge.genreA, edge.genreB), b: max(edge.genreA, edge.genreB))
        var opacity = baseOpacity
        var lineWidth: CGFloat = 0.8
        if compareEdgeSet.contains(key) {
          opacity = 0.55
          lineWidth = 1.8
        } else if transferEdgeSet.contains(key) {
          opacity = 0.30
          lineWidth = 1.2
        } else if hoverNeighbourSet.contains(edge.genreA) || hoverNeighbourSet.contains(edge.genreB) {
          opacity = min(0.28, baseOpacity + 0.16)
          lineWidth = 1.1
        }
        context.stroke(
          path,
          with: .color(.primary.opacity(opacity)),
          lineWidth: lineWidth,
        )
      }
    }
    .allowsHitTesting(false)
  }

  /// Transfer-station-mode edge set: every layout-edge whose endpoint
  /// IS the selected transfer station, or whose either endpoint is a
  /// 1-hop neighbour. The plan calls this out as the ONLY default
  /// state where dense edges (beyond the layout backbone) are safe.
  private func transferModeEdgeSet(model: GenreMapModel) -> Set<EdgeKey> {
    guard transferMapMode, let selectedGenre else { return [] }
    let edges = model.layoutEdges.map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    var neighbourSet: Set<String> = [selectedGenre]
    for neighbour in GenreMapDiscovery.oneHopNeighbours(of: selectedGenre, edges: edges) {
      neighbourSet.insert(neighbour.genre)
    }
    var keys = Set<EdgeKey>()
    for edge in model.layoutEdges {
      if edge.genreA == selectedGenre || edge.genreB == selectedGenre {
        keys.insert(EdgeKey(a: min(edge.genreA, edge.genreB), b: max(edge.genreA, edge.genreB)))
      } else if neighbourSet.contains(edge.genreA), neighbourSet.contains(edge.genreB) {
        keys.insert(EdgeKey(a: min(edge.genreA, edge.genreB), b: max(edge.genreA, edge.genreB)))
      }
    }
    return keys
  }

  private func hoverNeighbourGenreSet(model: GenreMapModel) -> Set<String> {
    guard let hoveredGenre else { return [] }
    let edges = model.layoutEdges.map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    var out: Set<String> = [hoveredGenre]
    for neighbour in GenreMapDiscovery.oneHopNeighbours(of: hoveredGenre, edges: edges) {
      out.insert(neighbour.genre)
    }
    return out
  }

  private func strandsLayer(model: GenreMapModel, transform: ViewTransform) -> some View {
    let positionsByGenre = Dictionary(
      uniqueKeysWithValues: model.nodes.map { ($0.genre, $0.position) }
    )
    let hoverServingStrandIDs = strandIDsForHover(model: model)
    let compareStrandIDs: Set<Int> = {
      guard !comparePaths.isEmpty else { return [] }
      var ids = Set<Int>()
      for path in comparePaths {
        ids.formUnion(GenreMapDiscovery.strandsOverlappingPath(path: path, strands: model.strands))
      }
      return ids
    }()
    return ZStack {
      ForEach(model.strands) { strand in
        let parentID = strand.isBranch ? (strand.parentStrandID ?? strand.id) : strand.id
        let chipHovered = hoveredStrandID == strand.id || hoveredStrandID == strand.parentStrandID
        let pillHovered = !hoverServingStrandIDs.isEmpty
          && hoverServingStrandIDs.contains(parentID)
        let compareHighlight = compareStrandIDs.contains(parentID)
        let highlighted = chipHovered || pillHovered || compareHighlight
        let anyHover = hoveredStrandID != nil || hoveredGenre != nil
        let faded = anyHover && !highlighted
          || (!comparePaths.isEmpty && !compareHighlight && hoveredStrandID == nil && hoveredGenre == nil)
        StrandSpline(
          positionsByGenre: positionsByGenre,
          strand: strand,
          routed: model.routedStrands[strand.id],
          colour: Self.strandColour(for: strand.colourID),
          isHighlighted: highlighted,
          isFaded: faded,
          project: transform.project,
        )
      }
    }
  }

  /// Strand ids highlighted by the current hover, if any: serving
  /// strands of `hoveredGenre`. Returns `[]` when nothing is hovered.
  private func strandIDsForHover(model: GenreMapModel) -> Set<Int> {
    guard let hoveredGenre else { return [] }
    return GenreMapDiscovery.servingStrandIDs(of: hoveredGenre, strands: model.strands)
  }

  private func tickColours(
    for genre: String,
    in model: GenreMapModel,
  ) -> [Color] {
    var seenColourIDs = Set<Int>()
    var colours = [(colourID: Int, colour: Color)]()
    for strand in model.strands where strand.memberGenres.contains(genre) {
      let canonicalColourID = strand.isBranch
        ? (strand.parentStrandID ?? strand.colourID)
        : strand.colourID
      if seenColourIDs.insert(canonicalColourID).inserted {
        colours.append((canonicalColourID, Self.strandColour(for: canonicalColourID)))
      }
    }
    return colours.sorted { $0.colourID < $1.colourID }.map(\.colour)
  }

  private func labelsLayer(model: GenreMapModel, transform: ViewTransform) -> some View {
    let hoverNeighbours = hoverNeighbourGenreSet(model: model)
    let compareGenres: Set<String> = {
      var out = Set<String>()
      if let selectedGenre { out.insert(selectedGenre) }
      if let compareSecondGenre { out.insert(compareSecondGenre) }
      for path in comparePaths { out.formUnion(path.stations) }
      return out
    }()
    return ForEach(model.nodes) { node in
      let position = transform.project(node.position)
      let community = model.communities.first { $0.id == node.communityID }
      let ticks = tickColours(for: node.genre, in: model)
      let isHovered = hoveredGenre == node.genre
      let isFocused = selectedGenre == node.genre || compareSecondGenre == node.genre
      let isAdjacent = hoverNeighbours.contains(node.genre)
      let isOnComparePath = compareGenres.contains(node.genre)
      let highlighted = isHovered || isFocused || isOnComparePath
      let fadeFromHover = hoveredGenre != nil && !isHovered && !isAdjacent
      let fadeFromCompare = !comparePaths.isEmpty && !isOnComparePath
      let faded = fadeFromHover || fadeFromCompare
      StationLabel(
        node: node,
        community: community,
        hullColour: Self.communityColour(for: node.communityID),
        strandTickColours: ticks,
        isHighlighted: highlighted,
        isFaded: faded,
        onTap: { selectNode(node) },
        onHover: { isInside in
          if isInside {
            hoveredGenre = node.genre
          } else if hoveredGenre == node.genre {
            hoveredGenre = nil
          }
        },
      )
      .position(position)
      .simultaneousGesture(
        DragGesture(minimumDistance: 2)
          .onChanged { value in
            if dragging?.genre != node.genre {
              dragging = DragState(genre: node.genre, initialPosition: node.position)
            }
            let world = transform.unproject(value.location)
            service.applyDrag(dragged: node.genre, to: world)
          }
          .onEnded { _ in
            if
              let info = dragging,
              let current = service.model?.nodes.first(where: { $0.genre == info.genre })
            {
              service.commitDrag(
                dragged: info.genre,
                originalPosition: info.initialPosition,
                finalPosition: current.position,
              )
            }
            dragging = nil
          }
      )
    }
  }

  /// Hover tooltip overlay — a small floating card near the hovered
  /// pill summarising counts + transferness + the top-3 strongest
  /// neighbours with their composite weight. Pure cosmetic.
  @ViewBuilder
  private func hoverTooltipOverlay(
    model: GenreMapModel,
    transform: ViewTransform,
  ) -> some View {
    if
      let hoveredGenre,
      let node = model.nodes.first(where: { $0.genre == hoveredGenre })
    {
      let position = transform.project(node.position)
      let edges = model.layoutEdges.map {
        GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
      }
      let neighbours = Array(GenreMapDiscovery.oneHopNeighbours(of: hoveredGenre, edges: edges).prefix(3))
      HoverTooltipCard(node: node, neighbours: neighbours)
        .fixedSize()
        .position(x: position.x, y: position.y - 64)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }

  private func baseTransform(model: GenreMapModel, into size: CGSize) -> FitTransform {
    let bounds = model.worldBounds
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
    let centre = model.defaultCentre
    let translation = CGSize(
      width: size.width / 2 - centre.x,
      height: size.height / 2 - centre.y,
    )
    return FitTransform(scale: 1, translation: translation)
  }

  private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
    Swift.min(maxValue, Swift.max(minValue, value))
  }

  private func selectNode(_ node: GenreMapNode) {
    if comparePending, let first = selectedGenre, first != node.genre {
      // Second genre clicked while compare-pending — enter compare.
      compareSecondGenre = node.genre
      comparePending = false
      loadCompareEvidence(from: first, to: node.genre)
      ensureInspectorVisible()
      return
    }
    if NSEvent.modifierFlags.contains(.shift), let first = selectedGenre, first != node.genre {
      compareSecondGenre = node.genre
      comparePending = false
      loadCompareEvidence(from: first, to: node.genre)
      ensureInspectorVisible()
      return
    }
    // Fresh single-genre selection — clear any compare state.
    representativeTask?.cancel()
    compareTask?.cancel()
    selectedGenre = node.genre
    compareSecondGenre = nil
    comparePaths = []
    compareEvidence = nil
    isLoadingCompare = false
    representativeEvidence = nil
    isLoadingRepresentative = true
    ensureInspectorVisible()
    representativeTask = Task {
      let loaded = await service.representativeEvidence(for: node.genre)
      if Task.isCancelled { return }
      await MainActor.run {
        representativeEvidence = loaded
        isLoadingRepresentative = false
      }
    }
    if node.nodeKind == .transferStation {
      applyTransferMapPlan(for: node)
    }
  }

  private func selectByName(_ genre: String) {
    guard let model = service.model else { return }
    guard let node = model.nodes.first(where: { $0.genre == genre }) else { return }
    selectNode(node)
  }

  private func beginCompare() {
    comparePending = true
  }

  private func endCompare() {
    comparePending = false
    compareSecondGenre = nil
    comparePaths = []
    compareEvidence = nil
    isLoadingCompare = false
    compareTask?.cancel()
  }

  private func loadCompareEvidence(from genreA: String, to genreB: String) {
    guard let model = service.model else { return }
    let edges = model.layoutEdges.map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    comparePaths = GenreMapDiscovery.kShortestPaths(
      from: genreA,
      to: genreB,
      edges: edges,
      k: 5,
    )
    compareEvidence = nil
    isLoadingCompare = true
    compareTask?.cancel()
    compareTask = Task {
      let loaded = await service.compareEvidence(between: genreA, and: genreB)
      if Task.isCancelled { return }
      await MainActor.run {
        compareEvidence = loaded
        isLoadingCompare = false
      }
    }
  }

  private func applyTransferMapPlan(for node: GenreMapNode) {
    guard let model = service.model else { return }
    let edges = model.layoutEdges.map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let nodesByGenre = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.genre, $0) })
    // Use a reasonable proxy for the canvas viewport size — the panel
    // doesn't have the geometry here, so fall back to a representative
    // 900×600. The pan/zoom is animated in `mapBody`'s transform, so
    // a slightly-mismatched plan only means a slightly tighter or
    // looser fit, not a broken render.
    guard
      let plan = GenreMapDiscovery.transferMapPlan(
        centreGenre: node.genre,
        nodesByGenre: nodesByGenre,
        edges: edges,
        viewport: CGSize(width: 900, height: 600),
      )
    else { return }
    withAnimation(.easeInOut(duration: 0.25)) {
      // The world→screen base transform centres on defaultCentre at
      // identity scale; we offset by (defaultCentre − plan.centre) so
      // the new centre lands at the viewport middle.
      let bias = CGSize(
        width: model.defaultCentre.x - plan.centre.x,
        height: model.defaultCentre.y - plan.centre.y,
      )
      offset = bias
      scale = plan.scale
      fitRequested = false
    }
  }

  private func ensureInspectorVisible() {
    if !inspectorPresented { inspectorPresented = true }
  }

  private func dismissEvidence() {
    representativeTask?.cancel()
    compareTask?.cancel()
    selectedGenre = nil
    compareSecondGenre = nil
    comparePending = false
    representativeEvidence = nil
    compareEvidence = nil
    comparePaths = []
    isLoadingRepresentative = false
    isLoadingCompare = false
  }

}

// MARK: - HoverTooltipCard

/// Small floating card the Phase-5 hover affordance renders near the
/// hovered pill. Counts + transferness + top-3 neighbours with their
/// composite weight. Strictly cosmetic; never observed by the layout.
private struct HoverTooltipCard: View {

  // MARK: Internal

  var node: GenreMapNode
  var neighbours: [GenreMapDiscovery.Neighbour]

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(node.genre)
          .font(.callout.weight(.semibold))
        Text("·")
          .foregroundStyle(.secondary)
        Text("transferness \(Int((node.transferness * 100).rounded()))%")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        countText("Tracks", node.trackCount)
        countText("Albums", node.albumCount)
        countText("Artists", node.artistCount)
      }
      if !neighbours.isEmpty {
        Divider().padding(.vertical, 1)
        VStack(alignment: .leading, spacing: 2) {
          ForEach(neighbours, id: \.genre) { neighbour in
            HStack(spacing: 4) {
              Text(neighbour.genre)
                .font(.caption)
              Spacer()
              Text(String(format: "%.2f", neighbour.weight))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
    .padding(8)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(.regularMaterial)
        .shadow(color: Color.black.opacity(0.18), radius: 6, y: 2)
    )
    .frame(maxWidth: 240)
  }

  // MARK: Private

  private func countText(_ label: String, _ value: Int) -> some View {
    HStack(spacing: 3) {
      Text("\(value)")
        .font(.caption2.weight(.semibold).monospacedDigit())
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
  }
}
