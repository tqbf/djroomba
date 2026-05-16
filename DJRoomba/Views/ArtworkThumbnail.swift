import MusicKit
import SwiftUI

// MARK: - ArtworkRef

/// Identifies the artwork to display by the stored `MusicItemID` (+ its
/// namespace + owning item kind). Local-first: the store keeps only the id;
/// the live `Artwork` is re-resolved on demand by `ArtworkProvider`. Nil =
/// nothing to resolve → show the placeholder (the same native fallback as
/// before).
struct ArtworkRef: Equatable, Sendable {
  let musicItemID: String
  let namespace: Song.IDNamespace
  let kind: ArtworkProvider.Kind

  static func song(_ musicItemID: String, namespace: Song.IDNamespace) -> ArtworkRef {
    ArtworkRef(musicItemID: musicItemID, namespace: namespace, kind: .song)
  }

  /// An imported Apple playlist's own id is a library `MusicItemID`.
  static func playlist(_ musicItemID: String) -> ArtworkRef {
    ArtworkRef(musicItemID: musicItemID, namespace: .library, kind: .playlist)
  }
}

// MARK: - ArtworkThumbnail

/// Consistent artwork thumbnail. **D2 corrective**: renders real cover art
/// via MusicKit's own `ArtworkImage` (exactly as Phase 1 did, which displayed
/// real artwork) from an `Artwork` re-resolved by id through the cached
/// `ArtworkProvider` — replacing the broken stored-private-URL path.
///
/// Pixel-equivalent to the Phase-1 look (reviewed with macos-design): the
/// frame is fixed *before* anything resolves so there is **no layout shift**;
/// while resolving (or on any miss / nil ref) it shows the identical
/// `.quaternary` rounded-rect + secondary SF Symbol placeholder; the resolved
/// `ArtworkImage` cross-fades in gently (a subtle native state transition —
/// it must not "pop"). `ArtworkProvider` caches per process so scrolling
/// never re-resolves or flickers. Decorative for VoiceOver — surrounding
/// title/artist text carries the meaning.
struct ArtworkThumbnail: View {

  // MARK: Internal

  let ref: ArtworkRef?
  let size: Double
  var cornerRadius: Double = 6
  var placeholderSymbol = "music.note"

  var body: some View {
    ZStack {
      placeholder
        .opacity(artwork == nil ? 1 : 0)

      if let artwork {
        ArtworkImage(artwork, width: size, height: size)
          .transition(.opacity)
      }
    }
    .frame(width: size, height: size)
    .clipShape(.rect(cornerRadius: cornerRadius))
    .accessibilityHidden(true)
    .animation(.easeOut(duration: 0.2), value: artwork == nil)
    .task(id: ref) {
      artwork = nil
      guard let ref else { return }
      let resolved = await ArtworkProvider.shared.artwork(
        forMusicItemID: ref.musicItemID,
        namespace: ref.namespace,
        kind: ref.kind,
      )
      if !Task.isCancelled {
        artwork = resolved
      }
    }
  }

  // MARK: Private

  @State private var artwork: Artwork?

  private var placeholder: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
      .fill(.quaternary)
      .overlay {
        Image(systemName: placeholderSymbol)
          .foregroundStyle(.secondary)
      }
  }
}
