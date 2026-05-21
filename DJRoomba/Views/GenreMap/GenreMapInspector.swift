import SwiftUI

// MARK: - GenreMapInspector

/// Phase 5 inspector for the Genre Map sheet
/// (`plans/genre-metro-map.md` Phase 5, step E). Replaces the Phase-2
/// half-pane-inside-the-sheet: the inspector is now a native
/// `.inspector()` column the sheet hosts, with a toolbar toggle and a
/// scene-storage persisted open/closed flag. Three modes:
///
/// - **Empty** — no genre selected. Render a hint card explaining the
///   click affordance.
/// - **Single genre** — one of `ordinary`, `junction`, `transferStation`.
///   Header + neighbours + serving strands + (kind-dependent)
///   connected-neighbourhood / representative-evidence sections.
/// - **Compare two genres** — Yen-k paths + transfer stations along
///   them + traversed strands + shared evidence (artists / albums /
///   tracks).
///
/// The view is **pure presentational** — every async load + every
/// state change comes in via the parent `GenreMapPanel`.
struct GenreMapInspector: View {

  // MARK: Internal

  var selection: GenreMapInspectorSelection
  var model: GenreMapModel
  /// Phase 5 representative-evidence rollup for the focused genre.
  /// Nil ⇒ not requested yet; `isLoadingRepresentative=true` ⇒ in
  /// flight. Two-state pattern matches the existing Phase 2 loading
  /// idiom.
  var representativeEvidence: GenreMapRepresentativeEvidence?
  var isLoadingRepresentative: Bool
  /// Phase 5 compare-mode payload — paths + the SQL roll-up.
  var comparePaths: [GenreMapDiscovery.Path]
  var compareEvidence: GenreMapCompareEvidence?
  var isLoadingCompare: Bool
  /// Tap a neighbour name in the single-genre ego list ⇒ jump focus
  /// to that genre. Forwarded from the panel.
  var onSelectNeighbour: (String) -> Void
  /// Tap "Compare" in the header ⇒ start a two-genre selection
  /// (panel enters compare-pending state and waits for a ⇧-click).
  var onRequestCompare: (() -> Void)?
  /// Tap "Done" in the compare card ⇒ leave compare mode and return
  /// to the previous single-genre focus.
  var onExitCompare: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      inspectorTitleBar
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch selection {
          case .empty:
            emptyState
          case .single(let node):
            singleSections(node: node)
          case .compare(let lhs, let rhs):
            compareSections(lhs: lhs, rhs: rhs)
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: Private

  private var title: String {
    switch selection {
    case .empty: "Inspector"
    case .single(let node): node.genre
    case .compare(let lhs, let rhs): "\(lhs.genre) ↔ \(rhs.genre)"
    }
  }

  private var inspectorTitleBar: some View {
    HStack {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      Spacer()
      if case .compare = selection, let onExitCompare {
        Button("Done", action: onExitCompare)
          .controlSize(.small)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Image(systemName: "hand.point.up.left")
          .foregroundStyle(.secondary)
        Text("Discover")
          .font(.caption.weight(.semibold))
          .textCase(.uppercase)
          .foregroundStyle(.secondary)
      }
      Text(
        "Click a genre to see its ego network. Click a transfer station to enter transfer-map mode. Hover or shift-click a second genre to compare two."
      )
      .font(.callout)
      .foregroundStyle(.primary)
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(0.04))
    )
  }

  @ViewBuilder
  private func singleSections(node: GenreMapNode) -> some View {
    let hullColour = GenreMapPanel.communityColour(for: node.communityID)
    EvidenceHeader(
      node: node,
      hullColour: hullColour,
      onCompareToggle: onRequestCompare,
      compareSubtitle: nil,
    )
    Divider()
    EvidenceStrands(genre: node.genre, model: model)
    Divider()
    EvidenceNeighbours(
      genre: node.genre,
      model: model,
      hullColour: hullColour,
      onSelect: onSelectNeighbour,
    )
    Divider()
    switch node.nodeKind {
    case .ordinary:
      EvidenceRepresentative(
        evidence: representativeEvidence,
        isLoading: isLoadingRepresentative,
      )

    case .junction:
      EvidenceConnectedNeighbourhoods(genre: node.genre, model: model)
      Divider()
      EvidenceRepresentative(
        evidence: representativeEvidence,
        isLoading: isLoadingRepresentative,
      )

    case .transferStation:
      EvidenceConnectedNeighbourhoods(genre: node.genre, model: model)
      Divider()
      EvidenceRepresentative(
        evidence: representativeEvidence,
        isLoading: isLoadingRepresentative,
      )
    }
    transfernessInputs(node: node, hullColour: hullColour)
  }

  @ViewBuilder
  private func compareSections(lhs: GenreMapNode, rhs: GenreMapNode) -> some View {
    let lhsColour = GenreMapPanel.communityColour(for: lhs.communityID)
    let rhsColour = GenreMapPanel.communityColour(for: rhs.communityID)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Circle().fill(lhsColour).frame(width: 8, height: 8)
        Text(lhs.genre).font(.title3.weight(.semibold)).lineLimit(1)
        Text("↔").font(.title3).foregroundStyle(.secondary)
        Text(rhs.genre).font(.title3.weight(.semibold)).lineLimit(1)
        Circle().fill(rhsColour).frame(width: 8, height: 8)
      }
      Text("Comparing two genres — paths run through the layout graph.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    Divider()
    let nodesByGenre = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.genre, $0) })
    let transferStations = comparePaths.flatMap {
      GenreMapDiscovery.transferStations(along: $0, nodesByGenre: nodesByGenre)
    }
    let uniqueTransferStations = Array(NSOrderedSet(array: transferStations)) as? [String] ?? []
    let involvedStrandIDs = comparePaths.reduce(into: Set<Int>()) { acc, path in
      acc.formUnion(GenreMapDiscovery.strandsOverlappingPath(
        path: path,
        strands: model.strands,
      ))
    }
    EvidenceCompare(
      genreA: lhs.genre,
      genreB: rhs.genre,
      paths: comparePaths,
      transferStations: uniqueTransferStations,
      involvedStrandIDs: involvedStrandIDs,
      model: model,
      evidence: compareEvidence,
      isLoading: isLoadingCompare,
    )
  }

  private func transfernessInputs(node: GenreMapNode, hullColour: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Text("Transferness inputs")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      bar(label: "Betweenness", value: node.transfernessInputs.betweenness, colour: hullColour)
      bar(label: "Neighbour entropy", value: node.transfernessInputs.neighbourEntropy, colour: hullColour)
      bar(label: "Cross-community", value: node.transfernessInputs.crossCommunityFraction, colour: hullColour)
      bar(label: "Membership entropy", value: node.transfernessInputs.membershipEntropy, colour: hullColour)
      if node.transfernessInputs.dampening < 1.0 {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
          Text("Generic-giant dampening ×\(String(format: "%.2f", node.transfernessInputs.dampening))")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }
    }
  }

  private func bar(label: String, value: Double, colour: Color) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.primary)
        .frame(width: 130, alignment: .leading)
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.primary.opacity(0.06))
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(colour.opacity(0.7))
            .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
        }
      }
      .frame(height: 6)
      Text("\(Int((value * 100).rounded()))%")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 36, alignment: .trailing)
    }
  }
}
