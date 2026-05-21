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
  @State private var fittedOnce = false
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
          fittedOnce = false
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
          fittedOnce = false
        }
      }
      .disabled(service.isAnalyzing)
    }
  }

  private var footer: some View {
    HStack {
      Image(systemName: "hand.point.up.left")
      Text("Drag to move a genre · Pinch to zoom · Drag empty space to pan")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      Button {
        scale = 1.0
        offset = .zero
        fittedOnce = false
      } label: {
        Label("Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
      }
      .controlSize(.small)
      Stepper(value: $scale, in: 0.25 ... 4.0, step: 0.1) {
        Text(String(format: "%.0f%%", scale * 100))
          .font(.caption.monospacedDigit())
      }
      .labelsHidden()
      .controlSize(.small)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(.bar)
  }

  @ViewBuilder
  private func mapBody(model: GenreMapModel, in size: CGSize) -> some View {
    let fitted = fitTransform(model: model, into: size)
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
          scale = clamp(scale * final, min: 0.25, max: 4.0)
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
      // Fit-to-view once per rebuild — re-runs after re-Analyze via the
      // `fittedOnce` reset in the header button.
      if !fittedOnce { fittedOnce = true }
    }
    .onChange(of: model.nodes.count) { _, _ in
      fittedOnce = false
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

  private func labelsLayer(model: GenreMapModel, transform: ViewTransform) -> some View {
    ForEach(model.nodes) { node in
      let position = transform.project(node.position)
      let community = model.communities.first { $0.id == node.communityID }
      StationLabel(
        node: node,
        community: community,
        hullColour: Self.communityColour(for: node.communityID),
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
            dragging = nil
          }
      )
    }
  }

  /// Fit-to-view: compute the affine that maps world coords into the
  /// panel's geometry. The interactive `scale`/`offset` multiply onto
  /// THIS fit, so the user starts looking at the whole map and refines
  /// from there.
  private func fitTransform(model: GenreMapModel, into size: CGSize) -> FitTransform {
    let bounds = model.worldBounds
    guard bounds.width > 0, bounds.height > 0, size.width > 0, size.height > 0 else {
      return FitTransform(scale: 1, translation: .zero)
    }
    let padding: CGFloat = 80
    let availableWidth = max(1, size.width - 2 * padding)
    let availableHeight = max(1, size.height - 2 * padding)
    let scale = min(availableWidth / bounds.width, availableHeight / bounds.height)
    let scaledCentreX = (bounds.minX + bounds.width / 2) * scale
    let scaledCentreY = (bounds.minY + bounds.height / 2) * scale
    let translation = CGSize(
      width: size.width / 2 - scaledCentreX,
      height: size.height / 2 - scaledCentreY,
    )
    return FitTransform(scale: scale, translation: translation)
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
