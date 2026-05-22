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
