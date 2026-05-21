import Foundation
import Testing
@testable import DJRoomba

/// Phase 1 (`plans/catalog-playlists.md`): pure mapping tests for
/// `CatalogIngestService.song(fromCatalogFields:…)` — the catalog mirror of
/// `ImportService.song(from:)`. `MusicKit.Song` is not constructible in
/// tests, so the field-taking variant is what we exercise (same
/// factor-for-testability idiom `ImportService.underlyingItemID(of:)`
/// uses); the live-`MusicKit.Song` overload is a one-liner that forwards.
///
/// Invariants pinned:
///
/// - Provenance is hard-coded `.catalog` — never inferred from id shape.
/// - Every v4 "free metadata" field round-trips verbatim.
/// - `isExplicit` derives only from the caller's boolean — the service
///   doesn't see `contentRating` directly.
/// - `artworkURL` is `nil` (Phase 4 owns artwork).
/// - The stable `song.id` is a fresh UUID per call (the UPSERT preserves
///   it on conflict in the store layer — see `SongUpsertTests`).
struct CatalogIngestMappingTests {

  @Test
  func `maps every catalog field with namespace fixed to catalog`() {
    let release = Date(timeIntervalSince1970: 1_500_000_000)
    let importedAt = Date(timeIntervalSince1970: 2_000_000_000)

    let song = CatalogIngestService.song(
      fromCatalogFields: "1440650711",
      title: "Bohemian Rhapsody",
      artistName: "Queen",
      albumTitle: "A Night at the Opera (Deluxe Edition)",
      duration: 354.0,
      isExplicit: false,
      importedAt: importedAt,
      trackNumber: 11,
      discNumber: 1,
      genreNames: ["Rock", "Classic Rock", "Album Rock"],
      releaseDate: release,
      composerName: "Freddie Mercury",
      isrc: "GBUM71029604",
      hasLyrics: true,
      workName: nil,
      movementName: nil,
    )

    // Provenance — the load-bearing invariant of this service.
    #expect(song.idNamespace == .catalog)
    // Catalog `MusicItemID.rawValue` is copied verbatim — catalog ids are
    // globally stable so storing them at ingest time is enough.
    #expect(song.musicItemID == "1440650711")
    // Display fields.
    #expect(song.title == "Bohemian Rhapsody")
    #expect(song.artistName == "Queen")
    #expect(song.albumTitle == "A Night at the Opera (Deluxe Edition)")
    #expect(song.duration == 354.0)
    // isExplicit comes from the caller's boolean — the service doesn't
    // see `contentRating` directly.
    #expect(song.isExplicit == false)
    // Artwork is owned by Phase 4 — never stored at ingest.
    #expect(song.artworkURL == nil)
    #expect(TestSupport.datesMatch(song.importedAt, importedAt))
    // v4 free metadata — every field passes through verbatim.
    #expect(song.trackNumber == 11)
    #expect(song.discNumber == 1)
    #expect(song.genreNames == ["Rock", "Classic Rock", "Album Rock"])
    #expect(TestSupport.datesMatch(song.releaseDate, release))
    #expect(song.composerName == "Freddie Mercury")
    #expect(song.isrc == "GBUM71029604")
    #expect(song.hasLyrics == true)
    #expect(song.workName == nil)
    #expect(song.movementName == nil)
    // Stable `song.id` minted fresh.
    #expect(!song.id.isEmpty)
  }

  @Test
  func `isExplicit is the boolean the caller passes`() {
    let explicit = CatalogIngestService.song(
      fromCatalogFields: "id-explicit",
      title: "T",
      artistName: "A",
      albumTitle: nil,
      duration: nil,
      isExplicit: true,
      importedAt: .now,
      trackNumber: nil,
      discNumber: nil,
      genreNames: [],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    #expect(explicit.isExplicit == true)

    let clean = CatalogIngestService.song(
      fromCatalogFields: "id-clean",
      title: "T",
      artistName: "A",
      albumTitle: nil,
      duration: nil,
      isExplicit: false,
      importedAt: .now,
      trackNumber: nil,
      discNumber: nil,
      genreNames: [],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    #expect(clean.isExplicit == false)
  }

  @Test
  func `sparse catalog song reads back with nil and empty defaults`() {
    // A minimum catalog payload — every optional `nil`, no genres, no
    // classical fields. The shape `Song` is happy to store as NULL/[]
    // (mirrors a sparse macOS library song; catalog usually populates
    // more, but the mapping must tolerate any combination).
    let song = CatalogIngestService.song(
      fromCatalogFields: "id-sparse",
      title: "Minimal",
      artistName: "Nobody",
      albumTitle: nil,
      duration: nil,
      isExplicit: false,
      importedAt: .now,
      trackNumber: nil,
      discNumber: nil,
      genreNames: [],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    #expect(song.idNamespace == .catalog)
    #expect(song.albumTitle == nil)
    #expect(song.duration == nil)
    #expect(song.trackNumber == nil)
    #expect(song.discNumber == nil)
    #expect(song.genreNames == [])
    #expect(song.releaseDate == nil)
    #expect(song.composerName == nil)
    #expect(song.isrc == nil)
    #expect(song.hasLyrics == nil)
    #expect(song.workName == nil)
    #expect(song.movementName == nil)
    #expect(song.artworkURL == nil)
  }

  @Test
  func `each call mints a fresh stable song id`() {
    // The minted UUID is the app-stable `song.id`. Two consecutive calls
    // with the same MusicKit id must differ — the store's UPSERT on the
    // composite unique key is what *preserves* a stable id on conflict
    // (see `SongUpsertTests`); the mapping itself never reuses.
    let a = CatalogIngestService.song(
      fromCatalogFields: "shared",
      title: "T",
      artistName: "A",
      albumTitle: nil,
      duration: nil,
      isExplicit: false,
      importedAt: .now,
      trackNumber: nil,
      discNumber: nil,
      genreNames: [],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    let b = CatalogIngestService.song(
      fromCatalogFields: "shared",
      title: "T",
      artistName: "A",
      albumTitle: nil,
      duration: nil,
      isExplicit: false,
      importedAt: .now,
      trackNumber: nil,
      discNumber: nil,
      genreNames: [],
      releaseDate: nil,
      composerName: nil,
      isrc: nil,
      hasLyrics: nil,
      workName: nil,
      movementName: nil,
    )
    #expect(!a.id.isEmpty)
    #expect(!b.id.isEmpty)
    #expect(a.id != b.id)
    // …but the import key is identical, which is exactly what the
    // store's UPSERT relies on to merge them onto one row.
    #expect(a.musicItemID == b.musicItemID)
    #expect(a.idNamespace == b.idNamespace)
  }
}
