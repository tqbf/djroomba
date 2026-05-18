import Foundation
import Testing
@testable import DJRoomba

/// `PlaylistDetail.genreTally` — the pure, deterministic tally behind the
/// playlist header's genre strip. Pins: frequency ordering, the localized
/// case-insensitive name tiebreak, whitespace trimming, empty/whitespace
/// entries dropped, per-song dedupe (a genre listed twice on one song
/// counts once), multi-genre songs contributing to each genre, and the
/// empty / no-genre inputs collapsing to `[]`.
struct PlaylistGenresTests {

  // MARK: Internal

  @Test
  func `orders by frequency descending`() {
    let songs = [
      song(["Rock"]),
      song(["Rock"]),
      song(["Rock"]),
      song(["Jazz"]),
      song(["Jazz"]),
      song(["Ambient"]),
    ]
    #expect(PlaylistDetail.genreTally(songs) == ["Rock", "Jazz", "Ambient"])
  }

  @Test
  func `tie broken by localized case insensitive name ascending`() {
    // All four appear on exactly one song, so the count tie falls back to
    // a localized, case-insensitive name compare ("alt" < "Blues" <
    // "metal" < "Zydeco", case ignored).
    let songs = [
      song(["Zydeco"]),
      song(["metal"]),
      song(["Blues"]),
      song(["alt"]),
    ]
    #expect(PlaylistDetail.genreTally(songs) == ["alt", "Blues", "metal", "Zydeco"])
  }

  @Test
  func `frequency outranks name`() {
    // "Zzz" is rarer-name-last alphabetically but on more songs, so it
    // must still sort before the alphabetically-earlier "Aaa".
    let songs = [
      song(["Zzz"]),
      song(["Zzz"]),
      song(["Aaa"]),
    ]
    #expect(PlaylistDetail.genreTally(songs) == ["Zzz", "Aaa"])
  }

  @Test
  func `whitespace trimmed and empty entries dropped`() {
    let songs = [
      song([" Rock "]),
      song(["Rock"]),
      song(["", "   ", "\n\t"]),
      song(["  Jazz"]),
    ]
    // " Rock " trims to "Rock" (so it's the same genre, count 2); the
    // all-whitespace/empty entries are dropped entirely.
    #expect(PlaylistDetail.genreTally(songs) == ["Rock", "Jazz"])
  }

  @Test
  func `same genre twice on one song counts once`() {
    let songs = [
      song(["Rock", "Rock", " Rock "]),
      song(["Jazz"]),
    ]
    // The first song carries "Rock" three times but counts once, so the
    // tally is Rock:1, Jazz:1 — a 1:1 tie resolved by name ("Jazz" <
    // "Rock").
    #expect(PlaylistDetail.genreTally(songs) == ["Jazz", "Rock"])
  }

  @Test
  func `multi genre song contributes to each`() {
    let songs = [
      song(["Rock", "Pop"]),
      song(["Pop"]),
    ]
    // Pop:2 (both songs), Rock:1 — frequency orders Pop first.
    #expect(PlaylistDetail.genreTally(songs) == ["Pop", "Rock"])
  }

  @Test
  func `empty input is empty`() {
    #expect(PlaylistDetail.genreTally([]) == [])
  }

  @Test
  func `songs without genres are empty`() {
    let songs = [
      song([]),
      song(["", "  "]),
    ]
    #expect(PlaylistDetail.genreTally(songs) == [])
  }

  // MARK: Private

  private func song(_ genres: [String]) -> Song {
    Song(
      id: UUID().uuidString,
      musicItemID: UUID().uuidString,
      idNamespace: .library,
      title: "Untitled",
      artistName: "Artist",
      isExplicit: false,
      importedAt: .now,
      genreNames: genres,
    )
  }

}
