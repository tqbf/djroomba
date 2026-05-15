import MusicKit

/// Loaded lazily when a playlist is selected. Retains the detailed `Playlist`
/// for playback queue construction.
struct PlaylistDetail: Identifiable, Sendable {
    let id: MusicItemID
    let name: String
    let artwork: Artwork?
    let description: String?
    let isEditable: Bool?
    let tracks: [TrackRow]
    let playlist: Playlist

    var isEmpty: Bool { tracks.isEmpty }
}
