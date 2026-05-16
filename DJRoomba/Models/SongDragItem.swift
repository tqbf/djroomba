import CoreTransferable
import UniformTypeIdentifiers

/// What a track row carries when dragged out of the track table — just the
/// app-stable `song.id` (the FK target for app-playlist membership). Dragging
/// a row onto a "My Playlists" row appends that song. Local-first: no live
/// MusicKit identity crosses the drag; the receiver re-resolves at play time
/// like everything else.
///
/// Codable JSON over a private UTI keeps the payload entirely in-app (this is
/// not a public interchange format — DJ Roomba never writes to Apple / other
/// apps), so a stray drop elsewhere does nothing.
struct SongDragItem: Codable, Transferable, Sendable {
    let songID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .djRoombaSong)
    }
}

extension UTType {
    /// Private, app-scoped type. Exported in Info.plist so the system knows
    /// DJ Roomba owns it; nothing outside the app consumes it.
    static let djRoombaSong = UTType(exportedAs: "org.sockpuppet.djroomba.song")
}
