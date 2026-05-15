import SwiftUI

struct PlaylistHeaderView: View {
    let detail: PlaylistDetail
    @Environment(MusicController.self) private var controller

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ArtworkThumbnail(
                artwork: detail.artwork,
                size: 104,
                cornerRadius: 8,
                placeholderSymbol: "music.note.list"
            )
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)

                Text("^[\(detail.tracks.count) track](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button {
                        Task { await controller.playSelectedPlaylist() }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(minWidth: 72)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(detail.isEmpty || !controller.canAttemptPlayback)

                    if let reason = controller.playbackUnavailableReason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
