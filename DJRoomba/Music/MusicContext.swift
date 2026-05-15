import MusicKit

/// Small, read-only projection of music state for extension consumers
/// (Milestone 3). Defined now so the boundary is stable and stays narrow.
/// Extensions observe this; they never touch `ApplicationMusicPlayer`.
struct MusicContext: Sendable {
    var selectedPlaylistID: MusicItemID?
    var selectedSongID: MusicItemID?
    var nowPlayingSongID: MusicItemID?
    var queuePlaylistID: MusicItemID?
    var playbackStatus: PlayerStateSnapshot.Status
}
