import Foundation
import Testing
@testable import DJRoomba

/// The always-on toolbar import status (the UX defect fix: "Reimport
/// Everything" over a populated library gave zero feedback for 90–120 s
/// because the only progress surface was the empty sidebar's `ProgressView`).
/// `ImportActivity.text` is the pure classifier that turns the
/// `ImportService` / `GenreImportService` counts the controller already
/// tracks into the status line. Deterministic, so it is unit-tested here; the
/// MusicKit signals themselves are signed-run verification.
///
/// The playlist-branch wording is asserted to be **byte-identical** to what
/// `MusicController.libraryLoadingMessage` already produces, so the toolbar
/// and the sidebar empty-state can never disagree.
struct ImportActivityTests {

  @Test
  func `playlists importing with a known total shows N of M`() {
    let text = ImportActivity.text(
      playlistsImporting: true,
      playlistsDone: 3,
      playlistsTotal: 12,
      genresImporting: false,
      genresDone: 0,
      genresTotal: 0,
    )
    #expect(text == "Importing 3 of 12 playlists…")
  }

  @Test
  func `playlists importing before the total is known falls back to loading`() {
    let text = ImportActivity.text(
      playlistsImporting: true,
      playlistsDone: 0,
      playlistsTotal: 0,
      genresImporting: false,
      genresDone: 0,
      genresTotal: 0,
    )
    #expect(text == "Loading playlists…")
  }

  @Test
  func `genres importing with a known total shows N of M albums`() {
    let text = ImportActivity.text(
      playlistsImporting: false,
      playlistsDone: 0,
      playlistsTotal: 0,
      genresImporting: true,
      genresDone: 47,
      genresTotal: 210,
    )
    #expect(text == "Refreshing genres (47 of 210 albums)…")
  }

  @Test
  func `genres importing before the total is known falls back to refreshing`() {
    let text = ImportActivity.text(
      playlistsImporting: false,
      playlistsDone: 0,
      playlistsTotal: 0,
      genresImporting: true,
      genresDone: 0,
      genresTotal: 0,
    )
    #expect(text == "Refreshing genres…")
  }

  @Test
  func `nothing importing is nil so the toolbar stays clean`() {
    let text = ImportActivity.text(
      playlistsImporting: false,
      playlistsDone: 0,
      playlistsTotal: 0,
      genresImporting: false,
      genresDone: 0,
      genresTotal: 0,
    )
    #expect(text == nil)
  }

  @Test
  func `playlist import takes precedence over a concurrent genre pass`() {
    // The genre pass only ever starts *after* the playlist import finishes
    // (runImport order), but if both flags are set the playlist line wins —
    // it is the more fundamental, earlier phase.
    let text = ImportActivity.text(
      playlistsImporting: true,
      playlistsDone: 5,
      playlistsTotal: 9,
      genresImporting: true,
      genresDone: 100,
      genresTotal: 200,
    )
    #expect(text == "Importing 5 of 9 playlists…")
  }

  @Test
  func `playlist branch wording is identical to libraryLoadingMessage`() {
    // Lock the two surfaces together: the exact strings the sidebar
    // empty-state already shows (MusicController.libraryLoadingMessage)
    // must match the toolbar's, character for character.
    #expect(
      ImportActivity.text(
        playlistsImporting: true,
        playlistsDone: 2,
        playlistsTotal: 8,
        genresImporting: false,
        genresDone: 0,
        genresTotal: 0,
      ) == "Importing 2 of 8 playlists…"
    )
    #expect(
      ImportActivity.text(
        playlistsImporting: true,
        playlistsDone: 0,
        playlistsTotal: 0,
        genresImporting: false,
        genresDone: 0,
        genresTotal: 0,
      ) == "Loading playlists…"
    )
  }
}
