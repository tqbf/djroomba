import Foundation

/// Where a playlist comes from. The app prefers user-library playlists when
/// identity is ambiguous (see plans/musickit-notes.md — identity risk).
///
/// `appPlaylist` (Phase 4) is a user-owned, SQLite-only playlist that is
/// **never** written back to Apple. It is editable and its playback goes
/// through the per-song app-playlist resolution path (arbitrary songs not
/// backed by an Apple playlist).
enum PlaylistSource: Hashable, Sendable {
    case libraryUserPlaylist
    case libraryCatalogPlaylist
    case catalogPlaylist
    case appPlaylist

    /// User-owned (created/edited in DJ Roomba), not an imported snapshot.
    var isAppOwned: Bool { self == .appPlaylist }
}
