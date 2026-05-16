import SwiftUI

struct PlaylistHeaderView: View {
    let detail: PlaylistDetail
    @Environment(MusicController.self) private var controller

    var body: some View {
        HStack(alignment: .bottom, spacing: 16) {
            ArtworkThumbnail(
                ref: detail.artworkRef,
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

                if let problem = controller.playbackProblem {
                    // Inline, unobtrusive native problem surface (D1): a
                    // colored warning glyph + secondary caption text, the
                    // same hierarchy tier as the subscription notice — it
                    // informs without shouting (typography-designer).
                    Label {
                        Text(problem)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .lineLimit(2)
                    .padding(.top, 2)
                    .transition(.opacity)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        // Value-driven animation so the inline problem surface fades in/out
        // rather than popping (swiftui-pro: never bare `.animation`; always
        // a watched value).
        .animation(.easeOut(duration: 0.2), value: controller.playbackProblem)
    }
}
