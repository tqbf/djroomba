import SwiftUI

/// Persistent bottom bar. Always visible in the authorized shell — playback
/// controls are never gated behind navigation state.
struct NowPlayingBar: View {
    @Environment(MusicController.self) private var controller

    private var snapshot: PlayerStateSnapshot {
        controller.playback.snapshot
    }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkThumbnail(ref: snapshot.artworkRef, size: 40, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 2) {
                if snapshot.hasContent {
                    Text(snapshot.title ?? "")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(snapshot.artist ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not Playing")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 160, alignment: .leading)

            Spacer(minLength: 12)

            if snapshot.hasContent {
                Text("\(snapshot.elapsed.musicTimeText) / \(snapshot.duration?.musicTimeText ?? "—")")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            TransportControls()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(height: 60)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
