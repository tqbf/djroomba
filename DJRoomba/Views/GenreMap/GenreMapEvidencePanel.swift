import SwiftUI

// MARK: - GenreMapEvidencePanel

/// Side panel that opens when a user clicks a transfer-station pill
/// (`plans/genre-metro-map.md` Phase 2's click-to-evidence). Minimal
/// scope on purpose — Phase 5 hardens this surface. Phase 2 shows:
///
/// - genre name + classification + composite percent
/// - the four transferness input contributions as labelled bars
/// - the neighbour-community list (each community contributing up to
///   five sample member genres for now — algorithmic names land in
///   Phase 3)
/// - evidence edges from this node only — the strongest 1-hop layout-
///   graph neighbours with their composite `total_weight`
/// - **store-side evidence-on-demand** — top shared artists / albums /
///   tracks for the selected genre vs the union of its neighbours.
///   Kicks off in a `Task`; spinner while pending.
struct GenreMapEvidencePanel: View {

  // MARK: Internal

  var node: GenreMapNode
  var model: GenreMapModel
  var hullColour: Color
  var evidence: GenreMapEvidenceOnDemand?
  var isLoadingEvidence: Bool
  var onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      headerRow
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          inputsSection
          neighbourCommunitiesSection
          evidenceEdgesSection
          sharedEvidenceSection
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
    .frame(width: 320)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  // MARK: Private

  private var headerRow: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(node.genre)
          .font(.title3.weight(.semibold))
          .lineLimit(2)
        HStack(spacing: 6) {
          if let glyph = kindGlyph {
            Image(systemName: glyph)
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(hullColour)
          }
          Text(kindLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
          Text("·")
            .foregroundStyle(.secondary)
          Text("transferness \(percentString(node.transferness))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button {
        onDismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(.tertiary)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close evidence panel")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private var inputsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Transferness inputs")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      bar(label: "Betweenness", value: node.transfernessInputs.betweenness)
      bar(label: "Neighbour entropy", value: node.transfernessInputs.neighbourEntropy)
      bar(label: "Cross-community", value: node.transfernessInputs.crossCommunityFraction)
      bar(label: "Membership entropy", value: node.transfernessInputs.membershipEntropy)
      if node.transfernessInputs.dampening < 1.0 {
        HStack {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
          Text("Generic-giant dampening engaged (×\(String(format: "%.2f", node.transfernessInputs.dampening)))")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }
    }
  }

  private var neighbourCommunitiesSection: some View {
    let connectedCommunityIDs = connectedNeighbourCommunityIDs()
    return VStack(alignment: .leading, spacing: 6) {
      Text("Connected neighbourhoods")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if connectedCommunityIDs.isEmpty {
        Text("No connected neighbourhoods.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(connectedCommunityIDs, id: \.self) { id in
          if let community = model.communities.first(where: { $0.id == id }) {
            neighbourCommunityRow(community)
          }
        }
      }
    }
  }

  private var evidenceEdgesSection: some View {
    let edges = strongestNeighbourEdges()
    return VStack(alignment: .leading, spacing: 6) {
      Text("Strongest edges")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if edges.isEmpty {
        Text("No layout-graph edges incident to this node.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(edges, id: \.other) { row in
          HStack {
            Text(row.other)
              .font(.caption)
              .lineLimit(1)
            Spacer()
            Text(String(format: "%.3f", row.weight))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private var sharedEvidenceSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Shared with neighbours")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if isLoadingEvidence {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Loading evidence…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let evidence {
        sharedList(title: "Artists", items: evidence.sharedArtists)
        sharedList(title: "Albums", items: evidence.sharedAlbums)
        sharedList(title: "Tracks", items: evidence.sharedTracks)
        if
          evidence.sharedArtists.isEmpty,
          evidence.sharedAlbums.isEmpty,
          evidence.sharedTracks.isEmpty
        {
          Text("No shared library items found.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else {
        Text("Evidence unavailable.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var kindLabel: String {
    switch node.nodeKind {
    case .ordinary: "Ordinary"
    case .junction: "Junction"
    case .transferStation: "Transfer station"
    }
  }

  private var kindGlyph: String? {
    switch node.nodeKind {
    case .ordinary: nil
    case .junction: "diamond.fill"
    case .transferStation: "point.3.connected.trianglepath.dotted"
    }
  }

  private func bar(label: String, value: Double) -> some View {
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
            .fill(hullColour.opacity(0.7))
            .frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
        }
      }
      .frame(height: 6)
      Text(percentString(value))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 36, alignment: .trailing)
    }
  }

  private func neighbourCommunityRow(_ community: GenreMapCommunity) -> some View {
    let colour = GenreMapPanel.communityColour(for: community.id)
    let sample = community.members
      .filter { $0 != node.genre }
      .prefix(5)
    return HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(colour)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
      Text(sample.joined(separator: ", "))
        .font(.caption)
        .foregroundStyle(.primary)
        .lineLimit(3)
      Spacer()
    }
  }

  @ViewBuilder
  private func sharedList(title: String, items: [GenreMapEvidenceItem]) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        ForEach(items.prefix(5)) { item in
          HStack {
            Text(item.display)
              .font(.caption)
              .lineLimit(1)
            Spacer()
            Text("×\(item.overlapCount)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }
      }
      .padding(.top, 4)
    }
  }

  private func percentString(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private func connectedNeighbourCommunityIDs() -> [Int] {
    var ids = Set<Int>()
    let nodesByName = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.genre, $0) })
    for edge in model.layoutEdges {
      let other: String? =
        if edge.genreA == node.genre { edge.genreB }
        else if edge.genreB == node.genre { edge.genreA }
        else { nil }
      if let other, let neighbourNode = nodesByName[other] {
        ids.insert(neighbourNode.communityID)
      }
    }
    return ids.sorted()
  }

  private func strongestNeighbourEdges() -> [(other: String, weight: Double)] {
    var rows = [(other: String, weight: Double)]()
    for edge in model.layoutEdges {
      if edge.genreA == node.genre {
        rows.append((other: edge.genreB, weight: edge.totalWeight))
      } else if edge.genreB == node.genre {
        rows.append((other: edge.genreA, weight: edge.totalWeight))
      }
    }
    return rows
      .sorted { $0.weight > $1.weight }
      .prefix(6)
      .map { $0 }
  }
}
