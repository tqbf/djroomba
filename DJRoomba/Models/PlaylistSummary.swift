import Foundation

/// Lightweight, sidebar-facing representation of a playlist, read from the
/// local SQLite store (NOT a live MusicKit object — local-first pivot, see
/// `plans/architecture.md`). It carries only stored ids + display fields;
/// playback re-resolves the underlying MusicKit items by id at play time
/// via `PlaybackResolver`. Equality is by stable id + the fields the row
/// actually renders (favorite, so the star toggles re-render; trackCount,
/// so a membership change reloaded from SQLite re-renders the count — D3:
/// omitting it made `ForEach` treat a count-only change as "no change" and
/// the "My Playlists" count went stale after add/remove). Hashing stays
/// id-only (the stable identity) so the value is still a good Set/Dictionary
/// key; `Hashable`'s contract only requires equal values hash equally, and
/// `==` still implies same `id`.
struct PlaylistSummary: Identifiable, Hashable, Sendable {
    /// Apple library `MusicItemID` raw value (the `apple_playlist` PK), or an
    /// app playlist UUID. The stable app-local key for selection/favorites.
    let id: String
    let name: String
    let trackCount: Int?
    let isEditable: Bool?
    let source: PlaylistSource
    var isFavorite: Bool

    /// Re-resolvable artwork (D2). An imported Apple playlist's `id` *is* a
    /// library `MusicItemID`, so `ArtworkProvider` re-fetches the playlist's
    /// cover by it; app playlists have no Apple artwork (nil → placeholder).
    var artworkRef: ArtworkRef? {
        source == .libraryUserPlaylist ? .playlist(id) : nil
    }

    static func == (lhs: PlaylistSummary, rhs: PlaylistSummary) -> Bool {
        lhs.id == rhs.id
            && lhs.isFavorite == rhs.isFavorite
            && lhs.trackCount == rhs.trackCount
            && lhs.name == rhs.name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
