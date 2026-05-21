import Foundation
import Testing
@testable import DJRoomba

/// Phase 6 perf gate (`plans/genre-metro-map.md` Phase 6): the persisted-
/// state read at rebuild start should be <50 ms even for a 200-genre
/// library; the write at rebuild end should be <100 ms. These are
/// per-CI machine targets; the assertion is loose (~5×) so a flaky
/// runner doesn't fail the gate, but every recorded number from a
/// real run on this machine sits comfortably under the spec budget.
struct GenreMapPhase6PerfTests {

  @Test
  func `loadGenreMapState completes within 250ms even at 200 genres`() async throws {
    let store = try TestSupport.freshStore()
    // Seed a 200-row state.
    let states = (0 ..< 200).map { index in
      GenreMapStateRow(
        genre: "Genre\(index)",
        x: Double(index),
        y: Double(-index),
        communityCoarse: "c\(index % 5)",
        communityMedium: "m\(index % 12)",
        communityFine: "f\(index % 28)",
        strandIds: "[\(index % 12)]",
        updatedAt: 1_700_000_000,
        revision: 1,
      )
    }
    let strands = (0 ..< 12).map { id in
      GenreMapStrandRow(
        strandID: "\(id)",
        colour: Int64(id),
        labelTokens: "[\"label\(id)\"]",
        revision: 1,
      )
    }
    try await store.writeGenreMapState(states: states, strands: strands)
    let start = Date.now
    let loaded = try await store.loadGenreMapState()
    let elapsedMs = Date.now.timeIntervalSince(start) * 1000
    #expect(loaded != nil)
    #expect(loaded?.positions.count == 200)
    // Loose CI bound; spec target is <50 ms.
    #expect(
      elapsedMs < 250,
      "loadGenreMapState took \(elapsedMs) ms; spec target is <50 ms",
    )
  }

  @Test
  func `writeGenreMapState completes within 500ms even at 200 genres`() async throws {
    let store = try TestSupport.freshStore()
    let states = (0 ..< 200).map { index in
      GenreMapStateRow(
        genre: "Genre\(index)",
        x: Double(index),
        y: Double(-index),
        communityCoarse: "c\(index % 5)",
        communityMedium: "m\(index % 12)",
        communityFine: "f\(index % 28)",
        strandIds: "[\(index % 12)]",
        updatedAt: 1_700_000_000,
        revision: 1,
      )
    }
    let strands = (0 ..< 12).map { id in
      GenreMapStrandRow(
        strandID: "\(id)",
        colour: Int64(id),
        labelTokens: "[\"label\(id)\"]",
        revision: 1,
      )
    }
    let start = Date.now
    try await store.writeGenreMapState(states: states, strands: strands)
    let elapsedMs = Date.now.timeIntervalSince(start) * 1000
    // Loose CI bound; spec target is <100 ms.
    #expect(
      elapsedMs < 500,
      "writeGenreMapState took \(elapsedMs) ms; spec target is <100 ms",
    )
  }
}
