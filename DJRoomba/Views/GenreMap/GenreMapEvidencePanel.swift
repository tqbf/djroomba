import SwiftUI

// MARK: - GenreMapInspectorSelection

/// Phase 5 inspector mode. The panel maps its `selectedGenre` /
/// `compareSecondGenre` state to one of these cases; the inspector
/// dispatches on the case.
enum GenreMapInspectorSelection: Equatable {
  case empty
  case single(GenreMapNode)
  case compare(GenreMapNode, GenreMapNode)
}

// MARK: - EvidenceHeader

/// Shared header for the single-genre inspector — name, kind chip,
/// transferness%. Pulled out as its own struct per swiftui-pro's
/// "extract subviews" rule; the panel's `body` was already large at
/// Phase 2 and Phase 5 adds three more sections.
struct EvidenceHeader: View {

  // MARK: Internal

  var node: GenreMapNode
  var hullColour: Color
  var onCompareToggle: (() -> Void)?
  var compareSubtitle: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
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
        if let subtitle = compareSubtitle {
          Text("·")
            .foregroundStyle(.secondary)
          Text(subtitle)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let onCompareToggle {
          Button {
            onCompareToggle()
          } label: {
            Label("Compare", systemImage: "rectangle.on.rectangle.angled")
          }
          .controlSize(.small)
          .buttonStyle(.bordered)
          .help("Shift-click another genre to compare")
        }
      }
      HStack(spacing: 10) {
        countTile(label: "Tracks", value: node.trackCount)
        countTile(label: "Albums", value: node.albumCount)
        countTile(label: "Artists", value: node.artistCount)
      }
      .padding(.top, 4)
    }
  }

  // MARK: Private

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

  private func percentString(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private func countTile(label: String, value: Int) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("\(value)")
        .font(.callout.weight(.semibold).monospacedDigit())
      Text(label)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.primary.opacity(0.04))
    )
  }
}

// MARK: - EvidenceNeighbours

/// One-hop layout-graph neighbours of the selected genre with their
/// composite weight. The ego network of the click target. Reads
/// `GenreMapDiscovery.oneHopNeighbours` — pure / fast / no I/O.
struct EvidenceNeighbours: View {

  // MARK: Internal

  var genre: String
  var model: GenreMapModel
  var hullColour: Color
  /// Tap a neighbour name ⇒ jump the inspector + the canvas highlight
  /// to that genre. Optional so the compare-section can re-use the
  /// rendering without a tap target.
  var onSelect: ((String) -> Void)?

  var body: some View {
    let edges = neighbours()
    return VStack(alignment: .leading, spacing: 6) {
      Text("Nearest neighbours")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if edges.isEmpty {
        Text("No layout-graph edges incident to this node.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(edges, id: \.genre) { row in
          neighbourRow(row)
        }
      }
    }
  }

  // MARK: Private

  private func neighbours() -> [GenreMapDiscovery.Neighbour] {
    let edges = model.layoutEdges.map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    return Array(GenreMapDiscovery.oneHopNeighbours(of: genre, edges: edges).prefix(8))
  }

  @ViewBuilder
  private func neighbourRow(_ row: GenreMapDiscovery.Neighbour) -> some View {
    let content = HStack(spacing: 6) {
      Circle()
        .fill(hullColour)
        .frame(width: 5, height: 5)
      Text(row.genre)
        .font(.caption)
        .lineLimit(1)
      Spacer()
      Text(String(format: "%.3f", row.weight))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
    if let onSelect {
      Button {
        onSelect(row.genre)
      } label: {
        content
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
    } else {
      content
    }
  }
}

// MARK: - EvidenceStrands

/// "Serving strands" list — the strands whose `memberGenres` include
/// the selected genre. Each row is the strand's algorithmic placename
/// + a coloured dot at the strand colour. On transfer stations this
/// is the answer to "which corridors meet here".
struct EvidenceStrands: View {

  // MARK: Internal

  var genre: String
  var model: GenreMapModel

  var body: some View {
    let strands = servingStrands()
    return VStack(alignment: .leading, spacing: 6) {
      Text("Serving strands")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if strands.isEmpty {
        Text("Not on any inferred strand.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(strands) { strand in
          HStack(spacing: 6) {
            Circle()
              .fill(GenreMapPanel.strandColour(for: strand.colourID))
              .frame(width: 7, height: 7)
            Text(strandLabel(strand))
              .font(.caption)
              .lineLimit(1)
            Spacer()
          }
        }
      }
    }
  }

  // MARK: Private

  private func servingStrands() -> [GenreMapStrandInference.Strand] {
    var seen = Set<Int>()
    var out = [GenreMapStrandInference.Strand]()
    for strand in model.strands where strand.memberGenres.contains(genre) {
      let canonicalID = strand.isBranch ? (strand.parentStrandID ?? strand.id) : strand.id
      guard seen.insert(canonicalID).inserted else { continue }
      // Find the canonical (non-branch) record if present.
      let canonical = model.strands.first { $0.id == canonicalID && !$0.isBranch } ?? strand
      out.append(canonical)
    }
    return out.sorted { $0.id < $1.id }
  }

  private func strandLabel(_ strand: GenreMapStrandInference.Strand) -> String {
    if !strand.label.isEmpty { return strand.label }
    if let first = strand.representativeGenres.first { return first }
    return "Strand \(strand.id + 1)"
  }
}

// MARK: - EvidenceRepresentative

/// Phase 5 "representative artists / albums" pulled from `song_genre`.
/// Two short lists; identical posture to the existing Phase-2 shared-
/// evidence section but for a single genre. Loading spinner while the
/// `Task` in flight; empty rows hidden.
struct EvidenceRepresentative: View {

  // MARK: Internal

  var evidence: GenreMapRepresentativeEvidence?
  var isLoading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Representative")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if isLoading {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Loading evidence…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let evidence {
        list(title: "Artists", items: evidence.topArtists)
        list(title: "Albums", items: evidence.topAlbums)
        if evidence.topArtists.isEmpty, evidence.topAlbums.isEmpty {
          Text("No representative items.")
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

  // MARK: Private

  @ViewBuilder
  private func list(title: String, items: [GenreMapEvidenceItem]) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        ForEach(items.prefix(8)) { item in
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
}

// MARK: - EvidenceConnectedNeighbourhoods

/// "Connected neighbourhoods" — the Phase-2 community-list surface
/// kept verbatim, but pulled into its own subview. Lists the medium-
/// resolution communities reachable from the selected genre's
/// layout-graph neighbours, with a 5-member sample per community.
struct EvidenceConnectedNeighbourhoods: View {

  // MARK: Internal

  var genre: String
  var model: GenreMapModel

  var body: some View {
    let ids = connectedNeighbourCommunityIDs()
    return VStack(alignment: .leading, spacing: 6) {
      Text("Connected neighbourhoods")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if ids.isEmpty {
        Text("No connected neighbourhoods.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(ids, id: \.self) { id in
          if let community = model.communities.first(where: { $0.id == id }) {
            row(community)
          }
        }
      }
    }
  }

  // MARK: Private

  private func connectedNeighbourCommunityIDs() -> [Int] {
    var ids = Set<Int>()
    let nodesByName = Dictionary(uniqueKeysWithValues: model.nodes.map { ($0.genre, $0) })
    for edge in model.layoutEdges {
      let other: String? =
        if edge.genreA == genre { edge.genreB }
        else if edge.genreB == genre { edge.genreA }
        else { nil }
      if let other, let neighbourNode = nodesByName[other] {
        ids.insert(neighbourNode.communityID)
      }
    }
    return ids.sorted()
  }

  private func row(_ community: GenreMapCommunity) -> some View {
    let colour = GenreMapPanel.communityColour(for: community.id)
    // Phase 5 — try to surface algorithmic placenames from the strands
    // serving this community (instead of just a 5-member name sample).
    // Falls back to the member sample when no strand intersects.
    let names = communityPlacenames(community)
    return HStack(alignment: .top, spacing: 8) {
      Circle()
        .fill(colour)
        .frame(width: 8, height: 8)
        .padding(.top, 5)
      Text(names)
        .font(.caption)
        .foregroundStyle(.primary)
        .lineLimit(3)
      Spacer()
    }
  }

  private func communityPlacenames(_ community: GenreMapCommunity) -> String {
    let memberSet = Set(community.members)
    let labels = model.strands
      .filter { !$0.isBranch }
      .filter { strand in
        strand.memberGenres.contains { memberSet.contains($0) }
      }
      .map(\.label)
      .filter { !$0.isEmpty }
    if !labels.isEmpty {
      return labels.prefix(3).joined(separator: " · ")
    }
    return community.members
      .filter { $0 != genre }
      .prefix(5)
      .joined(separator: ", ")
  }
}

// MARK: - EvidenceCompare

/// Phase 5 compare-mode card. Shows up to k highest-weight paths
/// between the two selected genres, the involved transfer stations,
/// and three lists of shared evidence (artists / albums / tracks).
/// Loading state covers the SQL roll-up; the path search itself is
/// pure + sub-millisecond.
struct EvidenceCompare: View {

  // MARK: Internal

  var genreA: String
  var genreB: String
  var paths: [GenreMapDiscovery.Path]
  var transferStations: [String]
  var involvedStrandIDs: Set<Int>
  var model: GenreMapModel
  var evidence: GenreMapCompareEvidence?
  var isLoading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      pathsSection
      transferStationsSection
      strandsSection
      sharedSection
    }
  }

  // MARK: Private

  private var pathsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Highest-weight paths")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if paths.isEmpty {
        Text("\(genreA) and \(genreB) are disconnected in the layout graph.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(paths.enumerated()), id: \.offset) { index, path in
          VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
              Text("\(index + 1).")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
              Text(path.stations.joined(separator: " → "))
                .font(.caption)
                .lineLimit(2)
              Spacer()
              Text(String(format: "Σ%.2f", path.totalWeight))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var transferStationsSection: some View {
    if !transferStations.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Transfer stations along the way")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        Text(transferStations.joined(separator: ", "))
          .font(.caption)
      }
    }
  }

  @ViewBuilder
  private var strandsSection: some View {
    if !involvedStrandIDs.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("Strands traversed")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .textCase(.uppercase)
        let strands = model.strands.filter { involvedStrandIDs.contains($0.id) }
        ForEach(strands) { strand in
          HStack(spacing: 6) {
            Circle()
              .fill(GenreMapPanel.strandColour(for: strand.colourID))
              .frame(width: 7, height: 7)
            Text(strand.label.isEmpty
              ? (strand.representativeGenres.first ?? "Strand \(strand.id + 1)")
              : strand.label)
              .font(.caption)
              .lineLimit(1)
            Spacer()
          }
        }
      }
    }
  }

  private var sharedSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Shared evidence")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if isLoading {
        HStack {
          ProgressView()
            .controlSize(.small)
          Text("Loading evidence…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let evidence {
        list(title: "Artists", items: evidence.sharedArtists)
        list(title: "Albums", items: evidence.sharedAlbums)
        list(title: "Tracks", items: evidence.sharedTracks)
        if
          evidence.sharedArtists.isEmpty,
          evidence.sharedAlbums.isEmpty,
          evidence.sharedTracks.isEmpty
        {
          Text("No shared library items found.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private func list(title: String, items: [GenreMapEvidenceItem]) -> some View {
    if !items.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.caption2.weight(.medium))
          .foregroundStyle(.secondary)
        ForEach(items.prefix(10)) { item in
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
}
