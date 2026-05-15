import MusicKit

/// The only way extensions request playback actions (Milestone 3). They submit
/// commands to `MusicController`; they do not reach into the player directly.
enum MusicCommand: Sendable {
    case playPlaylist(MusicItemID)
    case playTrack(MusicItemID, playlistID: MusicItemID?)
    case pause
    case resume
    case skipNext
    case skipPrevious
}
