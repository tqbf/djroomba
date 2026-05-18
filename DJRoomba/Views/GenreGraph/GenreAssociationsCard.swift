import SwiftUI

/// The small, pretty card pinned in the corner of the graph showing the
/// playlists tied to the focused genre — or, during the neighbour-walk, the
/// playlists pertinent to the focused **edge**. Strongest association first
/// (the store sorts + caps); this view is pure presentation of what it's
/// handed.
///
/// Native macOS overlay idiom: a `.regularMaterial` rounded panel with a
/// hairline border and a soft shadow (reads as a floating HUD over the
/// canvas, not a window chrome). Typography reuses the established semantic
/// scale — a `.subheadline` semibold title + a `.caption` secondary
/// subtitle (the "primary label + quiet metadata" hierarchy the genre
/// panel header / `PlaylistHeaderView` use), `.callout` rows with a quiet
/// monospaced strength figure so the numbers align.
struct GenreAssociationsCard: View {

  // MARK: Internal

  let genre: String
  /// Non-nil during neighbour-walk: the card is narrowed to the
  /// `genre ↔ neighbor` edge.
  let neighbor: String?
  let playlists: [PlaylistAssociation]
  /// Invoked when a playlist row is activated — navigates the top pane to
  /// that playlist. The card stays pure presentation; the caller owns the
  /// navigation.
  let onOpen: (PlaylistAssociation) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(genre)
          .font(.subheadline.weight(.semibold))
          .lineLimit(1)
        // A `Text` built from a `LocalizedStringKey` literal (NOT a
        // precomputed `String`) so `^[…](inflect: true)` actually
        // pluralises — `Text(someString)` is verbatim.
        subtitleText
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      Divider()

      VStack(alignment: .leading, spacing: 5) {
        ForEach(playlists) { playlist in
          // A plain-styled `Button` row: native, accessible (a single
          // focusable/VoiceOver element with a hover + press affordance),
          // and keeps the existing layout/typography intact — the macOS
          // idiom for a list-like row inside a HUD card.
          Button {
            onOpen(playlist)
          } label: {
            HStack(spacing: 6) {
              Image(systemName: playlist.isAppOwned ? "music.note.list" : "music.note")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 12)
              Text(playlist.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
              Spacer(minLength: 8)
              Text(playlist.strength, format: .number)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Open playlist \(playlist.name)")
        }
      }
    }
    .padding(12)
    .frame(width: 240, alignment: .leading)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(.quaternary, lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    // The rows are now interactive (each navigates to its playlist), so
    // the card must stay a CONTAINER whose children — the header and
    // every playlist button — remain individually focusable for
    // VoiceOver. `.combine` would flatten them into one static element
    // and destroy the per-row activation, so it's no longer used here;
    // the scope label still names the card for the rotor.
    .accessibilityElement(children: .contain)
    .accessibilityLabel(accessibilityText)
  }

  // MARK: Private

  private var subtitleText: Text {
    if let neighbor {
      Text("shared with \(neighbor) · ^[\(playlists.count) playlist](inflect: true)")
    } else {
      Text("^[\(playlists.count) playlist](inflect: true)")
    }
  }

  private var accessibilityText: String {
    let scope = neighbor.map { "\(genre) shared with \($0)" } ?? genre
    return "Playlists for \(scope): "
      + playlists.map(\.name).joined(separator: ", ")
  }
}
