import SwiftUI

// MARK: - GenreMapInspectorSelection

/// Inspector mode selector for the tree inspector. Originated as the
/// metro Phase-5 inspector dispatcher; the metro view retired in Phase
/// E of `plans/son-of-genre-map.md`, but the enum + the three subviews
/// below survive verbatim — the tree inspector (`GenreTreeInspector`)
/// reuses them for the single-genre header, the representative
/// artists/albums roll-up, and the compare-mode card.
enum GenreMapInspectorSelection: Equatable {
  case empty
  case single(GenreMapNode)
  case compare(GenreMapNode, GenreMapNode)
}

// MARK: - EvidenceHeader

/// Shared header for the single-genre inspector — name, kind chip,
/// transferness%. Pulled out as its own struct per swiftui-pro's
/// "extract subviews" rule.
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
        Text("Transferness \(percentString(node.transferness))")
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

// MARK: - EvidenceRepresentative

/// "Representative artists / albums" pulled from `song_genre`. Two
/// short lists; loading spinner while the `Task` is in flight; empty
/// rows hidden.
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

// MARK: - EvidenceCompare

/// Compare-mode card. Shows up to k highest-weight paths between two
/// selected genres, the involved transfer stations, and three lists
/// of shared evidence (artists / albums / tracks). The metro-era
/// "strands traversed" section retired in Phase E of
/// `plans/son-of-genre-map.md` along with the strand grammar itself.
struct EvidenceCompare: View {

  // MARK: Internal

  var genreA: String
  var genreB: String
  var paths: [GenreMapDiscovery.Path]
  var transferStations: [String]
  var evidence: GenreMapCompareEvidence?
  var isLoading: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      pathsSection
      transferStationsSection
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
