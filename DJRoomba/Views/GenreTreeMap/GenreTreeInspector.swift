import SwiftUI

// MARK: - GenreTreeInspectorSelection

/// Phase D inspector mode (`plans/son-of-genre-map.md` Phase D).
/// Maps the panel's `(selectedGenre, compareGenre)` pair to one of
/// three modes the inspector dispatches on. The inspector is **pure
/// presentational** — every async load + every state change comes in
/// via the parent `GenreTreeMapPanel`.
enum GenreTreeInspectorSelection: Equatable {
  case empty
  case single(GenreMapNode)
  case compare(GenreMapNode, GenreMapNode)
}

// MARK: - GenreTreeInspector

/// Phase D inspector. Right-docked 340pt side column inside the sheet
/// (precedent: `GenreMapPanel`'s metro inspector). Three modes:
///
/// - **Empty** — no genre selected. Hint card explains the click +
///   shift-click + listen affordances.
/// - **Single genre** — header (genre name + community colour swatch +
///   transferness% + track/album/artist counts) + a **Listen** action
///   that starts playback on a transient queue + Save-as-Playlist
///   follow-up + 1-hop neighbours (click-to-navigate) + 2-hop
///   neighbours read-only + top artists + top albums (paginated via
///   the existing `LibraryStore+GenreMap` reads).
/// - **Compare** — Yen-k shortest paths between the two genres
///   (re-uses `GenreMapDiscovery.kShortestPaths`) + shared
///   artists/albums/tracks (re-uses `LibraryStore.genreMapShared*`).
///
/// The single-genre header is a clean inline view (swatch + name +
/// condensed counts); the representative artists/albums roll-up reuses
/// the metro plan's `EvidenceRepresentative` subview verbatim, and
/// compare mode reuses `EvidenceCompare`. The metro `EvidenceStrands` /
/// `EvidenceConnectedNeighbourhoods` subviews are intentionally NOT
/// reused — Son of Genre Map retires the strand grammar, replacing
/// "connected neighbourhoods via intersecting strands" with the
/// "1-hop + 2-hop" reading the radial focus already trains the user
/// on.
struct GenreTreeInspector: View {

  // MARK: Internal

  var selection: GenreTreeInspectorSelection
  /// The metro substrate's loaded model. The inspector reads
  /// `layoutEdges` (Yen-k input) + per-node transferness inputs from
  /// it. Always non-nil when the tree panel has finished its build;
  /// the panel passes an `emptyModel` fallback so the inspector can
  /// be hosted even before the substrate loads.
  var model: GenreMapModel
  /// Single-genre evidence (top artists / top albums). `nil` until
  /// the panel kicks off a fetch.
  var representativeEvidence: GenreMapRepresentativeEvidence?
  var isLoadingRepresentative: Bool
  /// Compare-mode payload — the paths come from the panel; the SQL
  /// roll-up comes via the panel's evidence load.
  var comparePaths: [GenreMapDiscovery.Path]
  var compareEvidence: GenreMapCompareEvidence?
  var isLoadingCompare: Bool
  /// Pure-list two-hop neighbour set for the focused genre, computed
  /// once by the panel (the radial-plan path already enumerates this
  /// for the focus visualisation; passing it in avoids a second
  /// enumeration here).
  var twoHopNeighbours: [String]
  /// Tap a neighbour name in the single-genre 1-hop list ⇒ jump
  /// focus to that genre. Forwarded from the panel.
  var onSelectNeighbour: (String) -> Void
  /// Tap "Listen" in the header ⇒ start playback on a transient
  /// queue (the picker-based deterministic top-N).
  var onListen: (() -> Void)?
  /// Tap "Save as Playlist" in the header (or the post-listen affordance) ⇒
  /// create a "Genre Tree: <name>" app playlist with the picked tracks.
  var onSaveAsPlaylist: (() -> Void)?
  /// Disabled state for Listen / Save buttons — true while the action
  /// is in flight. Lets the panel coalesce repeated clicks.
  var isListenInFlight: Bool
  /// Tap "Done" in the compare card ⇒ leave compare mode, return to
  /// the previous single-genre focus.
  var onExitCompare: (() -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      // The title bar repeats the genre name in single-genre mode (the
      // big header below already carries it), so it only shows for the
      // empty + compare modes — single mode lets the inline header be
      // the title.
      if showsTitleBar {
        inspectorTitleBar
        Divider()
      }
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

  private var showsTitleBar: Bool {
    switch selection {
    case .single: false
    default: true
    }
  }

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
        "Click a genre to see its neighbours and representative artists. Shift-click a second genre to compare. Click Listen to start playing a deterministic top-N selection."
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

  private var listenActions: some View {
    HStack(spacing: 8) {
      Button {
        onListen?()
      } label: {
        Label("Listen", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(onListen == nil || isListenInFlight)
      .help("Start playing a top-N selection from this genre")

      Button {
        onSaveAsPlaylist?()
      } label: {
        Label("Save as Playlist", systemImage: "square.and.arrow.down")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(onSaveAsPlaylist == nil || isListenInFlight)
      .help("Save this genre's top-N selection as a new app playlist")

      if isListenInFlight {
        ProgressView()
          .controlSize(.small)
      }
      Spacer()
    }
    .padding(.top, 2)
  }

  @ViewBuilder
  private func singleSections(node: GenreMapNode) -> some View {
    let hullColour = GenreTreeMapPanel.communityColour(for: node.communityID)
    // Clean inline header — colour swatch + name + a single condensed
    // counts line. (Replaces the metro-era `EvidenceHeader`, which
    // stacked the name, an "Ordinary / Junction / Transfer station ·
    // Transferness N%" jargon line, and three boxed count tiles.)
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Circle()
          .fill(hullColour)
          .frame(width: 10, height: 10)
        Text(node.genre)
          .font(.title2.weight(.bold))
          .lineLimit(2)
      }
      Text(
        "\(node.trackCount) tracks · \(node.albumCount) albums · \(node.artistCount) artists"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    listenActions
    Divider()
    oneHopSection(node: node, hullColour: hullColour)
    if !twoHopNeighbours.isEmpty {
      Divider()
      twoHopSection(hullColour: hullColour)
    }
    Divider()
    EvidenceRepresentative(
      evidence: representativeEvidence,
      isLoading: isLoadingRepresentative,
    )
  }

  private func oneHopSection(node: GenreMapNode, hullColour: Color) -> some View {
    let edges = model.layoutEdges.map {
      GenreMapDiscovery.Edge(a: $0.genreA, b: $0.genreB, weight: $0.totalWeight)
    }
    let neighbours = GenreMapDiscovery.oneHopNeighbours(of: node.genre, edges: edges)
    let maxWeight = neighbours.first?.weight ?? 0
    return VStack(alignment: .leading, spacing: 6) {
      Text("Most Similar")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      if neighbours.isEmpty {
        Text("Nothing closely related to this genre yet.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        ForEach(Array(neighbours.prefix(8)), id: \.genre) { row in
          Button {
            onSelectNeighbour(row.genre)
          } label: {
            HStack(spacing: 6) {
              Circle()
                .fill(hullColour)
                .frame(width: 5, height: 5)
              Text(row.genre)
                .font(.caption)
                .lineLimit(1)
              Spacer()
              // A relative-strength bar instead of the raw composite
              // weight — the decimals (0.045 …) meant nothing at a
              // glance. Normalised to the strongest neighbour shown.
              strengthBar(value: row.weight, maxValue: maxWeight, colour: hullColour)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
  }

  /// Relative-strength capsule — a filled bar proportional to
  /// `value / maxValue`, on a faint track. Conveys "how related" at a
  /// glance without surfacing the opaque composite-weight number.
  private func strengthBar(value: Double, maxValue: Double, colour: Color) -> some View {
    let fraction = maxValue > 0 ? CGFloat(value / maxValue) : 0
    let trackWidth: CGFloat = 44
    return Capsule()
      .fill(Color.primary.opacity(0.08))
      .frame(width: trackWidth, height: 4)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(colour)
          .frame(width: Swift.max(4, trackWidth * fraction), height: 4)
      }
      .accessibilityLabel("Relatedness")
      .accessibilityValue("\(Int((fraction * 100).rounded())) percent of the strongest")
  }

  private func twoHopSection(hullColour: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Also Related")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
      ForEach(Array(twoHopNeighbours.prefix(12)), id: \.self) { name in
        Button {
          onSelectNeighbour(name)
        } label: {
          HStack(spacing: 6) {
            Circle()
              .fill(hullColour.opacity(0.4))
              .frame(width: 5, height: 5)
            Text(name)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer()
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  @ViewBuilder
  private func compareSections(lhs: GenreMapNode, rhs: GenreMapNode) -> some View {
    let lhsColour = GenreTreeMapPanel.communityColour(for: lhs.communityID)
    let rhsColour = GenreTreeMapPanel.communityColour(for: rhs.communityID)
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
    EvidenceCompare(
      genreA: lhs.genre,
      genreB: rhs.genre,
      paths: comparePaths,
      transferStations: uniqueTransferStations,
      evidence: compareEvidence,
      isLoading: isLoadingCompare,
    )
  }
}
