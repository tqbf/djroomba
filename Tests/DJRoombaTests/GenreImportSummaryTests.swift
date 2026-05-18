import Foundation
import Testing
@testable import DJRoomba

/// The honest, self-diagnosing readout for a completed album-genre pass (the
/// UX defect fix: on a primary machine `song.genre_names` could end up empty
/// with the app showing *nothing*, indistinguishable from "broken").
/// `GenreImportSummary.notice` is the pure classifier that turns the
/// `GenreImportService` counts the controller already tracks into the
/// diagnostic-triad sentence. Deterministic, so it is unit-tested here; the
/// MusicKit signals themselves are signed-run verification.
///
/// The (a)/(b)/(c) mapping under test:
/// - (a) `totalAlbums == 0` — no library albums returned.
/// - (b) `totalAlbums > 0 && albumsWithGenre == 0` — no album carried a tag.
/// - (c) `totalAlbums > 0 && albumsWithGenre > 0` — tags existed, join broke.
struct GenreImportSummaryTests {

  @Test
  func `a pass that did not run is nil`() {
    #expect(
      GenreImportSummary.notice(
        ran: false,
        failed: false,
        totalAlbums: 0,
        albumsWithGenre: 0,
        taggedSongs: 0,
      ) == nil
    )
  }

  @Test
  func `an errored pass is nil so the orange problem owns it`() {
    // The errored path is covered by the orange `libraryProblem`
    // (genreImportService.lastError) — this stays silent to avoid a
    // duplicate/conflicting surface even though 0 songs were tagged.
    #expect(
      GenreImportSummary.notice(
        ran: true,
        failed: true,
        totalAlbums: 873,
        albumsWithGenre: 412,
        taggedSongs: 0,
      ) == nil
    )
  }

  @Test
  func `a successful pass that tagged songs is nil`() {
    #expect(
      GenreImportSummary.notice(
        ran: true,
        failed: false,
        totalAlbums: 873,
        albumsWithGenre: 412,
        taggedSongs: 5_201,
      ) == nil
    )
  }

  @Test
  func `cause a — zero albums scanned mentions none scanned`() throws {
    let notice = GenreImportSummary.notice(
      ran: true,
      failed: false,
      totalAlbums: 0,
      albumsWithGenre: 0,
      taggedSongs: 0,
    )
    let text = try #require(notice)
    #expect(text.contains("0 scanned"))
    #expect(text.lowercased().contains("none"))
    // Must NOT misreport as the (b)/(c) "scanned N albums" shape.
    #expect(!text.contains("scanned 0 albums"))
  }

  @Test
  func `cause b — albums scanned but none tagged names the total and genre`() throws {
    let notice = GenreImportSummary.notice(
      ran: true,
      failed: false,
      totalAlbums: 873,
      albumsWithGenre: 0,
      taggedSongs: 0,
    )
    let text = try #require(notice)
    // The total MUST be interpolated so the user can read it off-screen.
    #expect(text.contains("873"))
    #expect(text.contains("genre"))
    #expect(text.contains("none carried a genre"))
  }

  @Test
  func `cause c — tags existed but no song matched names a join bug here`() throws {
    let notice = GenreImportSummary.notice(
      ran: true,
      failed: false,
      totalAlbums: 873,
      albumsWithGenre: 412,
      taggedSongs: 0,
    )
    let text = try #require(notice)
    // Both distinctive numbers MUST be interpolated.
    #expect(text.contains("873"))
    #expect(text.contains("412"))
    // Clear "this Mac, not your library" attribution wording.
    #expect(text.contains("not your library"))
    #expect(text.lowercased().contains("attribution"))
  }
}
