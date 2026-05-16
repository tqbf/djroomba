/// The only way extensions request playback actions (Milestone 3). They submit
/// commands to `MusicController`; they do not reach into the player directly.
///
/// Ids are raw strings (local-first pivot) — the boundary carries no live
/// MusicKit identity types. Playlist ids are `apple_playlist`/`app_playlist`
/// keys; track ids are `MusicItemID.rawValue`.
enum MusicCommand: Sendable {
  case playPlaylist(String)
  case playTrack(String, playlistID: String?)
  case pause
  case resume
  case skipNext
  case skipPrevious
}
