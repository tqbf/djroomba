import SwiftUI

/// Deliberately boring, operational track table (native `Table`). Double-click
/// or Return on a row plays the playlist starting at that track. `.searchable`
/// filters the visible tracks (⌘F focuses it).
struct TrackTableView: View {
    let detail: PlaylistDetail
    @Environment(MusicController.self) private var controller
    @State private var selection: TrackRow.ID?
    @State private var trackFilter = ""

    var body: some View {
        let tracks = filteredTracks

        Group {
            if tracks.isEmpty {
                ContentUnavailableView.search(text: trackFilter)
            } else {
                Table(tracks, selection: $selection) {
                    TableColumn("#") { row in
                        Text(row.position, format: .number)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(36)

                    TableColumn("Title") { row in
                        HStack(spacing: 6) {
                            Text(row.title)
                                .font(.body)
                                .lineLimit(1)
                            if row.isExplicit {
                                Image(systemName: "e.square.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel("Explicit")
                            }
                        }
                    }

                    TableColumn("Artist") { row in
                        Text(row.artistName)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    TableColumn("Album") { row in
                        Text(row.albumTitle ?? "—")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    TableColumn("Time") { row in
                        Text(row.duration?.musicTimeText ?? "—")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(56)
                }
                .contextMenu(forSelectionType: TrackRow.ID.self) { _ in
                    // No per-row context actions until later milestones.
                } primaryAction: { ids in
                    guard let id = ids.first,
                          let row = tracks.first(where: { $0.id == id }) else { return }
                    Task { await controller.play(row) }
                }
            }
        }
        .searchable(text: $trackFilter, prompt: "Filter Tracks")
    }

    private var filteredTracks: [TrackRow] {
        guard !trackFilter.isEmpty else { return detail.tracks }
        return detail.tracks.filter {
            $0.title.localizedStandardContains(trackFilter)
                || $0.artistName.localizedStandardContains(trackFilter)
                || ($0.albumTitle?.localizedStandardContains(trackFilter) ?? false)
        }
    }
}
