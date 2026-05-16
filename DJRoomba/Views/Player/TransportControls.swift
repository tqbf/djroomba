import SwiftUI

/// Prev / play-pause / next. Icon buttons keep accessible text labels
/// (rendered icon-only) so VoiceOver still announces them.
struct TransportControls: View {

  // MARK: Internal

  var body: some View {
    HStack(spacing: 14) {
      Button("Previous", systemImage: "backward.fill") {
        Task { await controller.skipPrevious() }
      }
      .help("Previous (⌘←)")

      Button(
        isPlaying ? "Pause" : "Play",
        systemImage: isPlaying ? "pause.fill" : "play.fill",
      ) {
        Task { await controller.togglePlayPause() }
      }
      .help(isPlaying ? "Pause (Space)" : "Play (Space)")

      Button("Next", systemImage: "forward.fill") {
        Task { await controller.skipNext() }
      }
      .help("Next (⌘→)")
    }
    .labelStyle(.iconOnly)
    .buttonStyle(.borderless)
    .font(.title3)
    .disabled(!hasContent)
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  private var isPlaying: Bool {
    controller.playback.snapshot.isPlaying
  }

  private var hasContent: Bool {
    controller.playback.snapshot.hasContent
  }

}
