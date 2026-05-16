import Foundation
import Testing
@testable import DJRoomba

/// Scaled, **unsigned, no-MusicKit** benchmark of the import *write path* —
/// the only part of import we can change (`ImportService.writePlaylist`'s
/// app-side work: build `songsByKey`/`orderedKeys`, `upsertSongs`,
/// `songIDsByKey`, expand to ordered ids, `replaceApplePlaylistSnapshot`).
/// It deliberately does NOT touch MusicKit: `fetchTracks` /
/// `playlist.with([.tracks])` is the signing-gated part documented as the
/// unfixable bottleneck — this isolates whether there is *any* reducible
/// app-side cost (hypotheses H2/H3 in `plans/profiling.md`).
///
/// Faithful to the real importer: a **file-backed** `AppDatabase` (the real
/// import uses `AppDatabase.live()`, not in-memory), synthetic data at the
/// measured library scale (~270 playlists / ~8200 unique songs) with a
/// realistic size skew (many small playlists, a few very large) and
/// cross-playlist song reuse.
///
/// Inert in the normal `swift test` gate: only runs when
/// `DJROOMBA_IMPORT_PERF=1`. Run / profile it with:
///
///   DJROOMBA_IMPORT_PERF=1 swift test --filter ImportPerfBench
///
/// (sample the `swift test` process while it runs — see the
/// swift-profiling skill / `plans/profiling.md`).
struct ImportPerfBench {
  // `.enabled(if:)` (not a `guard`/`#expect` skip) so the normal `swift
  // test` gate cleanly *skips* this — and so SwiftFormat's `noGuardInTests`
  // rule can't rewrite the gate into a failing assertion.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DJROOMBA_IMPORT_PERF"] == "1"))
  func `import write path at library scale`() async throws {
    let songPool = 8200
    let playlistCount = 270
    // Size skew: ~5 huge, ~15 medium, rest small — songs are reused
    // across playlists, as in a real library.
    var sizes = [Int]()
    for i in 0..<playlistCount {
      switch i {
      case 0..<5: sizes.append(Int.random(in: 800...2000))
      case 5..<20: sizes.append(Int.random(in: 100...400))
      default: sizes.append(Int.random(in: 5...50))
      }
    }

    let dbPath = NSTemporaryDirectory() + "djroomba-importperf-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let store = LibraryStore(database: try AppDatabase(path: dbPath))

    // Song pool built once — fixture cost, excluded from the timed region.
    // Fields bound to locals first: a single `Song(...)` with this many
    // string interpolations trips the Swift type-checker timeout.
    let importedAt = Date.now
    let pool: [Song] = (0..<songPool).map { n -> Song in
      let artistIndex = n % 500
      let albumIndex = n % 900
      let duration = Double(120 + (n % 240))
      let explicit = n % 7 == 0
      return Song(
        id: UUID().uuidString,
        musicItemID: "perf.\(n)",
        idNamespace: .library,
        title: "Track \(n)",
        artistName: "Artist \(artistIndex)",
        albumTitle: "Album \(albumIndex)",
        duration: duration,
        isExplicit: explicit,
        artworkURL: nil,
        importedAt: importedAt,
      )
    }

    let clock = ContinuousClock()
    var mapTime = Duration.zero
    var upsertTime = Duration.zero
    var lookupTime = Duration.zero
    var snapshotTime = Duration.zero
    var referencedPoolIndices = Set<Int>()
    let started = clock.now

    for (index, size) in sizes.enumerated() {
      var tracks = [Song]()
      tracks.reserveCapacity(size)
      for s in 0..<size {
        let poolIndex = (index * 37 + s * 13) % songPool
        referencedPoolIndices.insert(poolIndex)
        tracks.append(pool[poolIndex])
      }

      // --- mirrors ImportService.writePlaylist, byte for byte ---
      let t0 = clock.now
      var songsByKey = [LibraryStore.SongKey: Song]()
      var orderedKeys = [LibraryStore.SongKey]()
      for song in tracks {
        let key = LibraryStore.SongKey(
          musicItemID: song.musicItemID,
          namespace: song.idNamespace,
        )
        if songsByKey[key] == nil { songsByKey[key] = song }
        orderedKeys.append(key)
      }
      mapTime += clock.now - t0

      let t1 = clock.now
      try await store.upsertSongs(Array(songsByKey.values))
      upsertTime += clock.now - t1

      let t2 = clock.now
      let idByKey = try await store.songIDsByKey(
        songsByKey.keys.map { ($0.musicItemID, $0.namespace) }
      )
      lookupTime += clock.now - t2

      let songIDs = orderedKeys.compactMap { idByKey[$0] }
      let record = ApplePlaylist(
        id: "perf-pl-\(index)",
        name: "Perf Playlist \(index)",
        artworkURL: nil,
        curator: nil,
        lastImportedAt: .now,
      )
      let t3 = clock.now
      try await store.replaceApplePlaylistSnapshot(record, songIDs: songIDs)
      snapshotTime += clock.now - t3
    }

    let total = clock.now - started
    let count = try await store.songCount()
    let slots = sizes.reduce(0, +)
    // swiftlint:disable:next no_direct_standard_out_logs
    print(
      """

      ── import write-path benchmark (unsigned, no MusicKit) ──
      playlists:            \(playlistCount)
      track slots written:  \(slots)
      unique songs stored:  \(count) (pool \(songPool))
      db:                   file-backed
      ──────────────────────────────────────────────
      map tracks→keys:      \(mapTime)
      upsertSongs:          \(upsertTime)
      songIDsByKey:         \(lookupTime)
      snapshot replace:     \(snapshotTime)
      ──────────────────────────────────────────────
      TOTAL write path:     \(total)
      (vs the ~90–120 s full real import incl. MusicKit fetch)
      ──────────────────────────────────────────────
      """
    )
    // Real invariant: the batched UPSERT dedupes on
    // (music_item_id, id_namespace) across all 270 playlists, so the stored
    // song count equals exactly the number of *distinct* pool songs that
    // were referenced anywhere (≤ pool size, since reuse means not every
    // pool entry lands in some playlist).
    #expect(count == referencedPoolIndices.count)
  }
}
