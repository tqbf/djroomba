import Foundation

/// The honest, self-diagnosing readout for a completed album-genre import
/// pass. On a primary machine a full / first import can finish with
/// `song.genre_names` empty for three genuinely-different reasons that the
/// raw counts alone don't distinguish — and the app would otherwise show
/// nothing, indistinguishable from "broken". This turns the
/// `GenreImportService` counts into one plain diagnostic-triad sentence so
/// the failure mode is unambiguous (and readable off-screen):
///
/// - **(a)** 0 albums scanned ⇒ the library/`Album` request returned nothing
///   (no library visible to the app on this Mac).
/// - **(b)** albums scanned but 0 carried a genre tag ⇒ that library's albums
///   simply have no genre metadata (check Music.app's Genre column).
/// - **(c)** albums HAD genre tags but 0 songs matched ⇒ the album→song id
///   join is broken on this Mac — a real attribution bug, not the library.
///
/// Pure value computed by `notice(...)` from inputs the controller already
/// owns, so the wording is unit-testable without a live MusicKit session and
/// stays out of the view `body` (swiftui-pro: logic in methods/types; mirrors
/// the `ImportActivity.text` / `LibrarySidebarState.resolve` precedent).
enum GenreImportSummary {

  /// The diagnostic notice for a completed full / first genre pass, or `nil`
  /// when no notice is warranted.
  ///
  /// Returns `nil` unless the pass actually `ran`, did **not** `fail`, and
  /// tagged **zero** songs: success-with-tags needs no notice, and the
  /// errored path is already covered by the orange `libraryProblem` surface
  /// (which shows `GenreImportService.lastError`), so this stays silent for
  /// `failed == true` to avoid a duplicate/conflicting message.
  ///
  /// When non-`nil` the string is the diagnostic triad + the most-likely
  /// cause, and always encodes `totalAlbums` (and, for (b)/(c),
  /// `albumsWithGenre`) so the user can read the triad off-screen:
  /// - `totalAlbums == 0` → cause (a).
  /// - `totalAlbums > 0 && albumsWithGenre == 0` → cause (b).
  /// - `totalAlbums > 0 && albumsWithGenre > 0` → cause (c).
  nonisolated static func notice(
    ran: Bool,
    failed: Bool,
    totalAlbums: Int,
    albumsWithGenre: Int,
    taggedSongs: Int,
  ) -> String? {
    guard ran, !failed, taggedSongs == 0 else { return nil }

    if totalAlbums == 0 {
      // (a) The MusicLibraryRequest<Album> returned nothing.
      return "Reimport finished, but no library albums were returned "
        + "(0 scanned). Genres come from your Music library albums — none "
        + "were visible to the app on this Mac."
    }
    if albumsWithGenre == 0 {
      // (b) Albums were scanned, but none carry a genre tag.
      return "Reimport scanned \(totalAlbums) albums; none carried a genre "
        + "tag, so no genres were imported. (Album genre is Music library "
        + "metadata — check the Genre column in Music.app for these albums.)"
    }
    // (c) Albums had genre tags but no song matched — a join bug here.
    return "Reimport scanned \(totalAlbums) albums; \(albumsWithGenre) had "
      + "genre tags but 0 songs matched them — a genre-attribution problem "
      + "on this Mac, not your library. (Counts: \(albumsWithGenre) tagged "
      + "albums, \(taggedSongs) songs.)"
  }
}
