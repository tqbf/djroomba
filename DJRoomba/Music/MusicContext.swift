/// Small, read-only projection of music state for extension consumers
/// (the Milestone-3 boundary, realized as the Phase-5 inspector). Defined so
/// the boundary is stable and stays narrow. Extensions (and the inspector)
/// **observe** this; they never touch `ApplicationMusicPlayer` or the MusicKit
/// services — the only way to act is by submitting a `MusicCommand` to
/// `MusicController`.
///
/// Ids are raw strings (local-first pivot): the boundary deliberately carries
/// no live MusicKit identity types. Playlist ids are `apple_playlist`/
/// `app_playlist` keys; song ids are `MusicItemID.rawValue`. A few display
/// fields (names/title) are included so a consumer can render something
/// human-readable without re-querying the store across the boundary — they're
/// plain `String`s, still no MusicKit types.
struct MusicContext: Sendable, Equatable {
  var selectedPlaylistID: String?
  var selectedPlaylistName: String?
  var selectedSongID: String?
  var nowPlayingSongID: String?
  var nowPlayingTitle: String?
  var nowPlayingArtist: String?
  var queuePlaylistID: String?
  var playbackStatus: PlayerStateSnapshot.Status

  /// Whether anything is playing right now (convenience for consumers so
  /// they don't have to know the `Status` enum's cases).
  var isPlaying: Bool {
    playbackStatus == .playing
  }
}
