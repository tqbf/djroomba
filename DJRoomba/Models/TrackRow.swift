import Foundation
import MusicKit

/// UI-focused representation of a single playlist entry. `id` is composed from
/// the row position so a playlist containing the same song twice still has
/// unique, stable row identity. `track` is retained for playback.
struct TrackRow: Identifiable, Hashable, Sendable {
    /// Unique within a playlist: "<position>-<musicItemID>".
    let id: String
    /// 1-based position in the playlist (the boring table's first column).
    let position: Int
    let musicItemID: MusicItemID
    let title: String
    let artistName: String
    let albumTitle: String?
    let duration: TimeInterval?
    let artwork: Artwork?
    let isExplicit: Bool
    /// Underlying MusicKit item, kept for playback.
    let track: Track

    static func == (lhs: TrackRow, rhs: TrackRow) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
