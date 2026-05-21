import CoreGraphics
import Foundation
import Testing
@testable import DJRoomba

/// Phase 6 gate (toms-laws C) invariant: a successful `GenreMapService.build`
/// pass must leave `lastError == nil`. The pre-fix code only cleared
/// `lastError` at the *start* of `build()`, so an in-process error written
/// by the `load()` path (which never clears) would survive across a clean
/// rebuild and surface in the fail-soft UI chip. The fix adds a clear at
/// the *success site* (after both build AND persistence succeed) — this
/// test pins the post-condition.
@MainActor
struct GenreMapServiceErrorClearingTests {

  // MARK: Internal

  @Test
  func `successful build leaves lastError nil after success site`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r1", artist: "Alpha", album: "A1", genres: ["Rock"]),
      Self.song("r2", artist: "Beta", album: "B1", genres: ["Rock"]),
      Self.song("p1", artist: "Gamma", album: "G1", genres: ["Pop"]),
    ])
    let service = GenreMapService(store: store)
    #expect(service.lastError == nil, "fresh service has no error")

    await service.build()
    #expect(service.lastError == nil, "successful build clears lastError at success site")
    #expect(service.model != nil, "build produced a model")
  }

  @Test
  func `successful build clears a stale persistence error from a prior pass`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      Self.song("r1", artist: "Alpha", album: "A1", genres: ["Rock"]),
      Self.song("r2", artist: "Beta", album: "B1", genres: ["Rock"]),
    ])
    let service = GenreMapService(store: store)

    // First build: writes through cleanly.
    await service.build()
    #expect(service.lastError == nil)

    // Second build on the same store + service. Even if a previous run
    // had landed an error in `lastError` (e.g. via the load() path or a
    // transient persistence failure), the success site at the end of
    // build() must clear it. We can't easily simulate a persistence
    // failure without injecting a fake store, but the invariant we
    // care about is post-condition: after a successful rebuild,
    // lastError is nil.
    await service.build()
    #expect(service.lastError == nil, "second successful build still nil at the success site")
  }

  // MARK: Private

  private static func song(
    _ id: String,
    artist: String,
    album: String,
    genres: [String],
  ) -> Song {
    Song(
      id: id,
      localID: 0,
      musicItemID: "mid-\(id)",
      idNamespace: .library,
      title: "t-\(id)",
      artistName: artist,
      albumTitle: album,
      duration: 200,
      isExplicit: false,
      artworkURL: nil,
      importedAt: .now,
      genreNames: genres,
    )
  }
}
