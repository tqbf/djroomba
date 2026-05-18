import Foundation

/// The always-on import status text for the toolbar's `.status` slot — the
/// quiet "Importing N of M playlists…" / "Refreshing genres…" line that is
/// visible even when the sidebar is already populated (the empty-state
/// `ProgressView` it used to be the *only* surface for never shows once
/// playlists exist).
///
/// Pure value computed by `text(...)` from the signals the controller already
/// owns (`ImportService` / `GenreImportService` counts), so the wording — and
/// its precedence — is unit-testable without a live MusicKit session and stays
/// out of the view `body` (swiftui-pro: logic in methods/types; mirrors the
/// `LibrarySidebarState.resolve` precedent).
enum ImportActivity {

  /// The status string for the current import/genre activity, or `nil` when
  /// nothing is running (toolbar renders nothing — clean when idle).
  ///
  /// Precedence is load-bearing: the playlist import always runs *before* the
  /// genre pass on a full/first import, so a playlist import in flight wins
  /// over a (not-yet-started) genre pass. The playlist wording is kept
  /// **identical** to `MusicController.libraryLoadingMessage` so the toolbar
  /// and the sidebar empty-state never disagree.
  static func text(
    playlistsImporting: Bool,
    playlistsDone: Int,
    playlistsTotal: Int,
    genresImporting: Bool,
    genresDone: Int,
    genresTotal: Int,
  ) -> String? {
    if playlistsImporting {
      if playlistsTotal > 0 {
        return "Importing \(playlistsDone) of \(playlistsTotal) playlists…"
      }
      return "Loading playlists…"
    }
    if genresImporting {
      if genresTotal > 0 {
        return "Refreshing genres (\(genresDone) of \(genresTotal) albums)…"
      }
      return "Refreshing genres…"
    }
    return nil
  }
}
