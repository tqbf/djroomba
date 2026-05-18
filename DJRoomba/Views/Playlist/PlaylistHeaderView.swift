import SwiftUI

struct PlaylistHeaderView: View {

  // MARK: Internal

  let detail: PlaylistDetail

  var body: some View {
    HStack(alignment: .bottom, spacing: 16) {
      // A synthetic genre collection has no backing playlist artwork
      // (`artworkRef` is nil), so the slot always renders the native
      // `.quaternary` placeholder — a genre-appropriate `music.note`
      // glyph reads better there than the playlist `music.note.list`.
      ArtworkThumbnail(
        ref: detail.artworkRef,
        size: 104,
        cornerRadius: 8,
        placeholderSymbol: detail.isGenre ? "music.note" : "music.note.list",
      )
      VStack(alignment: .leading, spacing: 6) {
        Text(detail.name)
          .font(.largeTitle.weight(.bold))
          .lineLimit(2)

        Text("^[\(detail.tracks.count) track](inflect: true)")
          .font(.subheadline)
          .foregroundStyle(.secondary)

        if !detail.genres.isEmpty {
          genreStrip
        }

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

  // MARK: Private

  @Environment(MusicController.self) private var controller

  /// The playlist's distinct genres as a single quiet, horizontally
  /// scrollable row of capsule tags — secondary metadata, not a
  /// call-to-action. One scrollable line shows *all* of them without
  /// growing the header vertically or shoving the track table down. Only
  /// rendered when there's at least one genre (inherently hidden for a
  /// genre detail / a playlist whose tracks carry no genre).
  private var genreStrip: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        ForEach(detail.genres, id: \.self) { genre in
          chip(genre)
        }
      }
      // A little vertical breathing room so the capsules aren't clipped
      // by the scroll viewport.
      .padding(.vertical, 2)
    }
    .scrollIndicators(.hidden)
  }

  /// A single tappable genre tag. Styled to match `GenreAssociationsCard`'s
  /// quiet material/hairline aesthetic — `.caption` secondary text on a
  /// `.quaternary` capsule — so it reads as a subtle tag in both light and
  /// dark. Tapping reuses the existing genre navigation (`showGenre`
  /// integrates with the Back stack).
  private func chip(_ genre: String) -> some View {
    Button {
      controller.showGenre(genre)
    } label: {
      Text(genre)
        .font(.caption)
        .lineLimit(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: Capsule())
        .contentShape(.capsule)
    }
    .buttonStyle(.plain)
    .help(genre)
    .accessibilityLabel("Genre: \(genre)")
  }

}
