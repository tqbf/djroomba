import MusicKit

/// Lightweight, sidebar-facing representation of a playlist. Retains the
/// underlying `Playlist` so detail/playback can resolve lazily without
/// re-fetching by id. Equality/hashing is by stable id only.
struct PlaylistSummary: Identifiable, Hashable, Sendable {
    let id: MusicItemID
    let name: String
    let artwork: Artwork?
    let trackCount: Int?
    let isEditable: Bool?
    let source: PlaylistSource
    var isFavorite: Bool
    /// Underlying MusicKit item, kept for lazy detail + playback.
    let playlist: Playlist

    static func == (lhs: PlaylistSummary, rhs: PlaylistSummary) -> Bool {
        lhs.id == rhs.id && lhs.isFavorite == rhs.isFavorite
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
