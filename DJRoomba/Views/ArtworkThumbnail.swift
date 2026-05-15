import SwiftUI
import MusicKit

/// Consistent artwork thumbnail with a graceful placeholder when artwork is
/// missing (MusicKit metadata is often partial). Decorative for VoiceOver —
/// the surrounding title/artist text carries the meaning.
struct ArtworkThumbnail: View {
    let artwork: Artwork?
    let size: CGFloat
    var cornerRadius: CGFloat = 6
    var placeholderSymbol = "music.note"

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: placeholderSymbol)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }
}
