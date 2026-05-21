import SwiftUI

// MARK: - GenreMapPanel

/// Phase 1 (`plans/genre-metro-map.md`) of the genre **metro map** — a
/// sibling to the v6 `GenreGraphPanel`. Shown in a sheet from the
/// Playback menu (`Show Genre Map…`). Renders geography only:
///
/// - subtle community hulls
/// - layout-graph backbone at ≤10 % opacity
/// - station pills sized by per-genre weight
///
/// No metro strands, no transferness ticks, no dense hover edges — those
/// are Phases 2/3/5.
///
/// **Performance posture** (the plan calls it out explicitly):
/// - The constrained force pass is run **once** on rebuild and then
///   freezes. Pan + zoom only transform the viewport; the layout doesn't
///   re-tick on either gesture.
/// - Drag pins the dragged node and runs the cheap neighbour-relaxation
///   pass from `GenreMapForceLayout.relaxDragNeighbours` — bounded
///   iterations, single-hop scope, no global resettle.
/// - Edges + hulls are drawn via SwiftUI `Canvas` (one redraw per
///   viewport / drag change, not many small views per frame). Station
///   labels stay as SwiftUI views so accessibility / hit-testing / type
///   metrics are native.
struct GenreMapPanel: View {

  // MARK: Internal

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      HStack(spacing: 0) {
        content
        if
          let selectedGenre, let model = service.model,
          let node = model.nodes.first(where: { $0.genre == selectedGenre })
        {
          Divider()
          GenreMapEvidencePanel(
            node: node,
            model: model,
            hullColour: Self.communityColour(for: node.communityID),
            evidence: evidence,
            isLoadingEvidence: isLoadingEvidence,
            onDismiss: dismissEvidence,
          )
        }
      }
      Divider()
      footer
    }
    .frame(minWidth: 720, minHeight: 540)
    .frame(idealWidth: 980, idealHeight: 720)
    .task {
      // Show a previously-rebuilt map immediately, without forcing a
      // fresh recompute.
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
      // Then the user transform.
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

  @Environment(MusicController.self) private var controller
  @Environment(\.dismiss) private var dismiss

  /// Viewport state. `scale` < 1 ⇒ zoomed out, > 1 ⇒ zoomed in. `offset`
  /// is the pan in screen pixels. Both are local to the panel — the
  /// pipeline never observes them, so panning is a pure render-time
  /// transform (no physics re-tick on pan).
  @State private var scale: CGFloat = 1.0
  @State private var offset = CGSize.zero
  @State private var dragging: DragState?
  /// `true` once the panel has applied the per-rebuild **default
  /// presentation** (Phase-3-gate 2026-05-20): centre on the heaviest
  /// community at scale=1.0×, NOT fit-to-view. Reset by re-Analyze and
  /// when the model's node count changes (a fresh rebuild). Fit-to-view
  /// is opt-in via the Fit toolbar button / Cmd-9.
  @State private var centredOnce = false
  /// Opt-in fit-to-view: set by the Fit toolbar button (Cmd-9). When
  /// `true`, `baseTransform` computes a scale-and-translate that lands
  /// every node inside the pane; when `false` (default), the transform
  /// is identity-scale centred on `model.defaultCentre`. Reset on
  /// re-Analyze / node-count change.
  @State private var fitRequested = false
  /// Phase 2's click-to-evidence selection. Set by tapping a transfer-
  /// station or junction pill (ordinary pills are no-op for now), cleared
  /// by tapping outside the panel (background) or pressing the panel's
  /// close button. Drag MUST NOT spuriously set this — `StationLabel`'s
  /// `Button(action:)` only fires for a click, not a drag, so the gesture
  /// composition below keeps the two affordances separate.
  @State private var selectedGenre: String?
  @State private var evidence: GenreMapEvidenceOnDemand?
  @State private var isLoadingEvidence = false
  @State private var evidenceTask: Task<Void, Never>?
  /// Phase 3 strand hover (`plans/genre-metro-map.md` step 8). When set,
  /// the corresponding strand renders opaque + member stations highlight,
  /// every other strand fades to ~6 % opacity. Cleared on hover-exit.
  /// The full Phase-5 discovery UX adds two-strand-compare + click-pin;
  /// Phase 3 ships the minimal affordance for visual verification.
  @State private var hoveredStrandID: Int?
  /// Gesture deltas applied during an active pinch / pan, committed back
  /// onto `scale` / `offset` at gesture end (the standard SwiftUI
  /// gesture composition).
  @GestureState private var gestureScale: CGFloat = 1.0
  @GestureState private var gestureOffset = CGSize.zero

  private var service: GenreMapService {
    controller.genreMapService
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
        Text("Drag to move a genre · Pinch / ⌘+ / ⌘− to zoom · ⌘0 reset · ⌘9 fit · Hover a strand to highlight")
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

  /// Phase 3 strand-hover affordance — a horizontal row of strand chips
  /// (one per main strand; branches inherit the parent's hue and aren't
  /// chips of their own). Hovering a chip highlights the corresponding
  /// spline + member stations on the map. The full Phase-5 hover/click
  /// discovery UX (compare two; pin one; rich evidence) wraps this; for
  /// Phase 3, the chips are the minimum visual-verification affordance.
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

  /// Cmd-+ — step zoom in. Centred about the current viewport centre.
  private func zoomIn() {
    scale = clamp(scale * 1.25, min: 0.1, max: 6.0)
  }

  /// Cmd-− — step zoom out. Centred about the current viewport centre.
  private func zoomOut() {
    scale = clamp(scale / 1.25, min: 0.1, max: 6.0)
  }

  /// Cmd-0 — reset to the default presentation: scale 1.0× centred on
  /// the heaviest community. Clears `fitRequested` so the base transform
  /// re-applies the heaviest-community centring instead of staying in
  /// the fit-to-view minimap mode.
  private func resetZoom() {
    scale = 1.0
    offset = .zero
    fitRequested = false
    centredOnce = false
  }

  /// Cmd-9 — opt-in fit-to-view. Different from `resetZoom`: this
  /// computes the scale required to land all nodes inside the current
  /// pane, then re-centres on the world midpoint. Kept as an opt-in
  /// affordance per the Phase-3-gate "default is not fit-to-view"
  /// directive; the user pans / zooms after using it.
  ///
  /// Resets the interactive scale / offset so the fit transform is the
  /// only thing active — without this, a previously-panned offset
  /// pushes the fitted minimap off-screen.
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
    // Phase-3-gate 2026-05-20 (the "stop compacting" reset): the
    // "fitted" transform is now an **identity world→screen mapping
    // centred on the heaviest community** by default, NOT a fit-to-
    // viewport scale. Fit-to-view becomes opt-in via the `Fit`
    // toolbar button (Cmd-9), which sets `fitRequested = true`.
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
      // Pan only fires after a small motion threshold (4pt) so a
      // bare click on the map can never start an empty-space pan and
      // also can never starve a child `StationLabel`'s `.onTapGesture`.
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
      // Bare-click handler for the map background ⇒ dismiss the
      // evidence panel. Separate from the pan DragGesture so the two
      // never race for the same touch. Tap-gestures inside child
      // `StationLabel`s consume the tap-up before it reaches here.
      TapGesture()
        .onEnded {
          if selectedGenre != nil { dismissEvidence() }
        }
    )
    .accessibilityElement(children: .contain)
    .onAppear {
      // First-presentation hook — `baseTransform` consults `centredOnce`
      // / `fitRequested` to pick the transform, so this onAppear is a
      // no-op marker; the transform self-applies on first render.
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

  private func edgesCanvas(model: GenreMapModel, transform: ViewTransform) -> some View {
    Canvas { context, _ in
      // Lookup positions once.
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
        // Layout-backbone opacity ≤10% per the spec.
        let opacity = 0.04 + 0.06 * edge.totalWeight
        context.stroke(
          path,
          with: .color(.primary.opacity(opacity)),
          lineWidth: 0.8,
        )
      }
    }
    .allowsHitTesting(false)
  }

  /// Phase 3 metro-strand overlay. One Catmull-Rom `StrandSpline` per
  /// strand at low default opacity; the hovered strand (when any)
  /// renders opaque + every other strand fades. No routing / bundling
  /// — that's Phase 4. Splines may cross.
  private func strandsLayer(model: GenreMapModel, transform: ViewTransform) -> some View {
    let positionsByGenre = Dictionary(
      uniqueKeysWithValues: model.nodes.map { ($0.genre, $0.position) }
    )
    return ZStack {
      ForEach(model.strands) { strand in
        StrandSpline(
          positionsByGenre: positionsByGenre,
          strand: strand,
          routed: model.routedStrands[strand.id],
          colour: Self.strandColour(for: strand.colourID),
          isHighlighted: hoveredStrandID == strand.id
            || hoveredStrandID == strand.parentStrandID,
          isFaded: hoveredStrandID != nil
            && hoveredStrandID != strand.id
            && hoveredStrandID != strand.parentStrandID,
          project: transform.project,
        )
      }
    }
  }

  /// Per-station strand-tick colours. Ticks render per strand serving
  /// the station; branches share the parent strand's hue so the eye
  /// reads the corridor, not the branch. Deduped + colour-sorted for
  /// deterministic rendering.
  private func tickColours(
    for genre: String,
    in model: GenreMapModel,
  ) -> [Color] {
    var seenColourIDs = Set<Int>()
    var colours = [(colourID: Int, colour: Color)]()
    for strand in model.strands where strand.memberGenres.contains(genre) {
      // Branches contribute the parent's colour so the eye reads the
      // strand as one corridor, not a branched mess.
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
    ForEach(model.nodes) { node in
      let position = transform.project(node.position)
      let community = model.communities.first { $0.id == node.communityID }
      let ticks = tickColours(for: node.genre, in: model)
      StationLabel(
        node: node,
        community: community,
        hullColour: Self.communityColour(for: node.communityID),
        strandTickColours: ticks,
        onTap: { selectNode(node) },
      )
      .position(position)
      // Use `.simultaneousGesture` (not `.gesture`) so the
      // `StationLabel`'s inner Button still receives plain taps — a
      // `.gesture(DragGesture(minimumDistance: 1))` was claiming the
      // gesture sequence and starving the Button on a no-motion click,
      // which left the click-to-evidence affordance silent. The drag
      // path itself is gated on a non-trivial translation (>=2pt) so a
      // pure click never spuriously starts dragging.
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
            // Phase 4 (`plans/genre-metro-map.md` Phase 4, step 5):
            // recompute routing on drag release, NOT mid-drag.
            // `commitDrag` no-ops on sub-`geographicEpsilon` motion,
            // so a tiny twitch never invalidates the routing cache.
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

  /// **Phase-3-gate 2026-05-20 (the "stop compacting" reset).**
  /// Compute the base world → screen affine that the interactive
  /// `scale`/`offset` multiplies onto.
  ///
  /// Default posture: **identity scale** (world units == screen pixels)
  /// with the **translation centred on `model.defaultCentre`** — the
  /// centroid of the heaviest community. The user opens the map
  /// looking at one recognisable neighbourhood; the rest of the world
  /// scrolls. Pan / zoom is the interaction.
  ///
  /// Opt-in fit-to-view (`fitRequested == true`, set by the Fit
  /// toolbar button / Cmd-9) computes a scale that lands every node
  /// inside the pane with a padding inset. Used as a minimap
  /// affordance — the user clicks Fit, sees the dense overview, then
  /// pans / zooms back in.
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
    // Default: identity scale, centred on the heaviest community.
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

  /// Open the evidence side panel for `node`. Ordinary stops are no-op
  /// (Phase 5 will give them their own ego-network surface); junctions
  /// and transfer stations both surface the evidence panel — junctions
  /// because the inputs explain why the node is *almost* a transfer
  /// station and that's useful debugging signal.
  private func selectNode(_ node: GenreMapNode) {
    // Phase 2 ships with click-to-evidence enabled for every kind —
    // ordinary stops surface the same inputs panel (transferness will
    // simply read low), and that makes the affordance discoverable
    // before Phase 5 promotes its full ego-network mode for ordinary
    // genres. Phase 5 will scope this back to junction + transfer-
    // station only, with a richer per-kind detail surface.
    evidenceTask?.cancel()
    selectedGenre = node.genre
    evidence = nil
    isLoadingEvidence = true
    evidenceTask = Task {
      let loaded = await service.evidenceOnDemand(for: node.genre)
      if Task.isCancelled { return }
      evidence = loaded
      isLoadingEvidence = false
    }
  }

  private func dismissEvidence() {
    evidenceTask?.cancel()
    evidenceTask = nil
    selectedGenre = nil
    evidence = nil
    isLoadingEvidence = false
  }
}
