import Foundation
import Testing
@testable import DJRoomba

/// `GenreImportService.resolvedGenres` — the pure precedence that fixes the
/// confirmed cross-OS bug where the bulk `MusicLibraryRequest<Album>`
/// implicit projection omits genre on macOS 14.4 (empty for all 5,156
/// albums), so trusting it skipped every album and tagged nothing.
/// `GenreImportService` is `@MainActor @Observable` and drives live
/// MusicKit, so it isn't unit-testable directly (same constraint as
/// `ImportService`); this `nonisolated`, dependency-free helper carries the
/// genre-resolution decision and is deterministic, so it is unit-tested
/// here (the MusicKit signals themselves are signed-run verification).
///
/// Precedence under test, first non-empty wins:
/// 1. `bulk` — the bulk projection (newer-OS fast path).
/// 2. `detailedRelationship` — `album.with([.genres])` → `Album.genres`.
/// 3. `detailedGenreNames` — the detailed album's own `genreNames`.
/// All-empty → `[]`; every source whitespace-trimmed and order-preserving
/// de-duplicated.
struct GenreResolutionTests {

  @Test
  func `bulk wins when present — the newer-OS fast path`() {
    #expect(
      GenreImportService.resolvedGenres(
        bulk: ["Alt/Goth/Industrial"],
        detailedRelationship: ["Rock"],
        detailedGenreNames: ["Pop"],
      ) == ["Alt/Goth/Industrial"]
    )
  }

  @Test
  func `relationship used when bulk empty — the macOS-14_4 path`() {
    #expect(
      GenreImportService.resolvedGenres(
        bulk: [],
        detailedRelationship: ["Electronic", "House"],
        detailedGenreNames: ["Pop"],
      ) == ["Electronic", "House"]
    )
  }

  @Test
  func `detailed genreNames is the last resort`() {
    #expect(
      GenreImportService.resolvedGenres(
        bulk: [],
        detailedRelationship: [],
        detailedGenreNames: ["Alternative"],
      ) == ["Alternative"]
    )
  }

  @Test
  func `all sources empty resolves to empty — a genre-less album`() {
    #expect(
      GenreImportService.resolvedGenres(
        bulk: [],
        detailedRelationship: [],
        detailedGenreNames: [],
      ) == []
    )
  }

  @Test
  func `a source of only blank strings is treated as empty and falls through`() {
    // Whitespace-only entries are not a real tag — precedence must skip
    // past this source to the next non-empty one.
    #expect(
      GenreImportService.resolvedGenres(
        bulk: ["  ", "\n", "\t"],
        detailedRelationship: ["Rock"],
        detailedGenreNames: [],
      ) == ["Rock"]
    )
  }

  @Test
  func `names are whitespace-trimmed`() {
    #expect(
      GenreImportService.resolvedGenres(
        bulk: ["  Alt/Indie  ", "\tPunk\n"],
        detailedRelationship: [],
        detailedGenreNames: [],
      ) == ["Alt/Indie", "Punk"]
    )
  }

  @Test
  func `duplicates are removed preserving first-seen order`() {
    #expect(
      GenreImportService.resolvedGenres(
        bulk: ["Rock", "Pop", "Rock", "  Pop  ", "Jazz"],
        detailedRelationship: [],
        detailedGenreNames: [],
      ) == ["Rock", "Pop", "Jazz"]
    )
  }

  @Test
  func `the chosen source is the only one normalized`() {
    // Once `bulk` is non-empty it wins outright; the detailed inputs are
    // never consulted, even if they would also be non-empty.
    #expect(
      GenreImportService.resolvedGenres(
        bulk: [" Metal "],
        detailedRelationship: ["Classical"],
        detailedGenreNames: ["Folk"],
      ) == ["Metal"]
    )
  }
}
