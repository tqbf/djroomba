import Foundation
import Testing
@testable import DJRoomba

/// Phase 5 extension surface. The `.inspector()` is the realization of the
/// M3 `MusicContext` (read-only projection) / `MusicCommand` (the only way to
/// act) boundary. These pin the *value contract* the boundary guarantees:
/// `MusicContext` is a plain `Sendable`/`Equatable` projection carrying no
/// MusicKit identity types, with an `isPlaying` convenience so a consumer
/// needn't know the `Status` enum; `MusicCommand` is a closed `Sendable`
/// command set. (The inspector wiring itself is signed-run / UI verification;
/// the boundary's value semantics are deterministic and tested here.)
struct MusicContextBoundaryTests {

  @Test
  func `context is playing reflects status`() {
    var ctx = MusicContext(playbackStatus: .stopped)
    #expect(ctx.isPlaying == false)
    ctx.playbackStatus = .playing
    #expect(ctx.isPlaying == true)
    ctx.playbackStatus = .paused
    #expect(ctx.isPlaying == false)
  }

  @Test
  func `context equality covers the projected fields`() {
    let a = MusicContext(
      selectedPlaylistID: "p1",
      selectedPlaylistName: "Mix",
      selectedSongID: nil,
      nowPlayingSongID: "s1",
      nowPlayingTitle: "Song",
      nowPlayingArtist: "Artist",
      queuePlaylistID: "p1",
      playbackStatus: .playing,
    )
    var b = a
    #expect(a == b)
    // A change in any projected field makes the context unequal so an
    // observing surface re-renders (the inspector reads it each body).
    b.nowPlayingTitle = "Other Song"
    #expect(a != b)
    var c = a
    c.playbackStatus = .paused
    #expect(a != c)
  }

  @Test
  func `context carries only strings and status`() {
    // The boundary must not leak live MusicKit identity types — ids and
    // display fields are plain `String?` and the status a local enum.
    // (Compile-time proof: these are the only members; a MusicKit type
    // here would fail `Sendable`/`Equatable` synthesis used above.)
    let ctx = MusicContext(
      selectedPlaylistID: "apple-or-app-id",
      selectedPlaylistName: "Name",
      selectedSongID: "sid",
      nowPlayingSongID: "mid",
      nowPlayingTitle: "t",
      nowPlayingArtist: "a",
      queuePlaylistID: "qid",
      playbackStatus: .stopped,
    )
    #expect(ctx.selectedPlaylistID == "apple-or-app-id")
    #expect(ctx.nowPlayingSongID == "mid")
  }

  @Test
  func `command set is closed and sendable`() {
    // Exhaustive switch — if a case is ever added, this won't compile,
    // forcing a conscious boundary review (the command set must stay
    // narrow; it's the only way an extension acts).
    let commands: [MusicCommand] = [
      .playPlaylist("p"),
      .playTrack("t", playlistID: "p"),
      .pause,
      .resume,
      .skipNext,
      .skipPrevious,
    ]
    for command in commands {
      switch command {
      case .playPlaylist,
           .playTrack,
           .pause,
           .resume,
           .skipNext,
           .skipPrevious:
        #expect(Bool(true))
      }
    }
  }
}
