import Foundation

/// Where a playlist comes from. The app prefers user-library playlists when
/// identity is ambiguous (see plans/musickit-notes.md — identity risk).
enum PlaylistSource: Hashable, Sendable {
    case libraryUserPlaylist
    case libraryCatalogPlaylist
    case catalogPlaylist
}
