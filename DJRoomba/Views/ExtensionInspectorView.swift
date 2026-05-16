import SwiftUI

/// The extension-readiness surface (the M3 `MusicContext`/`MusicCommand`
/// boundary, realized as a native macOS 14 `.inspector()` panel). It is a
/// **boundary demonstration**, not a feature dump (macos-design: keep it
/// minimal and native): it *observes* the controller's read-only
/// `MusicContext` and acts **only** by submitting `MusicCommand`s. It never
/// imports or touches `ApplicationMusicPlayer`, the MusicKit services, or the
/// store — exactly the contract a future extension must honor, proven here.
///
/// Collapsed by default; toggled from the toolbar (state owned by
/// `MainShellView`). Native `Form`/`LabeledContent`/`Section` so it reads like
/// an Inspector users already know (Xcode / Numbers / Freeform).
struct ExtensionInspectorView: View {

  // MARK: Internal

  var body: some View {
    Form {
      // The inspector's own label lives INSIDE the panel (the native
      // macOS inspector idiom — Xcode/Numbers put the inspector's
      // identity in its content, never as the window title). The window
      // title stays the app name; this is NOT a `.navigationTitle`.
      Section {
        Text("Extension Inspector")
          .font(.headline)
      }

      Section("Now Playing") {
        inspectorRow("Status", statusText)
        inspectorRow("Track", context.nowPlayingTitle ?? "—")
        inspectorRow("Artist", context.nowPlayingArtist ?? "—")
      }

      Section("Selection") {
        inspectorRow("Playlist", context.selectedPlaylistName ?? "—")
      }

      Section("Commands") {
        // Every action goes through the `MusicCommand` boundary — the
        // inspector cannot reach the player directly (the whole point
        // of the surface). Disabled states are derived only from the
        // read-only context, never from player internals.
        Button("Play / Pause", systemImage: playPauseSymbol, action: togglePlayPause)
          .disabled(context.nowPlayingSongID == nil)

        Button("Next", systemImage: "forward.fill") { submit(.skipNext) }
          .disabled(context.nowPlayingSongID == nil)

        Button("Previous", systemImage: "backward.fill") { submit(.skipPrevious) }
          .disabled(context.nowPlayingSongID == nil)

        Button("Play Selected Playlist", systemImage: "play.circle", action: playSelected)
          .disabled(context.selectedPlaylistID == nil)
      }

      Section {
        Text(
          "This panel only observes a read-only projection of music state and submits commands. It’s the boundary future extensions plug into."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        // Wrap (don't clip) the explainer at the panel's min
        // width — `fixedSize(vertical:)` lets it grow as many
        // lines as it needs instead of being cut at the edge.
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    // A small trailing inset so the `LabeledContent` value text and the
    // wrapping footer explainer never touch — let alone clip at — the
    // panel's trailing edge, even when the inspector is dragged to its
    // minimum column width. The grouped Form supplies the leading inset;
    // this guarantees symmetric breathing room on the trailing side so a
    // long playlist name ellipsizes *with* padding rather than running
    // flush into the divider (the in-panel half of the Phase-5 D2 fix).
    .padding(.trailing, 4)
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  /// The single read-only projection this surface is allowed to see. Pulled
  /// once per body so every row reflects one consistent snapshot.
  private var context: MusicContext {
    controller.musicContext
  }

  private var statusText: String {
    switch context.playbackStatus {
    case .playing: "Playing"
    case .paused: "Paused"
    case .stopped: "Stopped"
    case .interrupted: "Interrupted"
    case .seekingForward: "Seeking Forward"
    case .seekingBackward: "Seeking Backward"
    }
  }

  private var playPauseSymbol: String {
    context.isPlaying ? "pause.fill" : "play.fill"
  }

  /// One inspector row. The value truncates with an ellipsis *inside* the
  /// panel (never clipped under the window edge) and is selectable so a
  /// truncated value is still recoverable — the native inspector idiom
  /// (Xcode/Numbers inspectors let you copy a clipped field).
  private func inspectorRow(_ title: LocalizedStringKey, _ value: String) -> some View {
    LabeledContent(title) {
      Text(value)
        .lineLimit(1)
        .truncationMode(.tail)
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
    }
  }

  private func togglePlayPause() {
    submit(context.isPlaying ? .pause : .resume)
  }

  private func playSelected() {
    guard let id = context.selectedPlaylistID else { return }
    submit(.playPlaylist(id))
  }

  /// The *only* way this surface acts: hand a `MusicCommand` to the
  /// controller. No `await playback.…`, no MusicKit import.
  private func submit(_ command: MusicCommand) {
    Task { await controller.handle(command) }
  }
}
