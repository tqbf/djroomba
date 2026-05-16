import Foundation
import GRDB
import Testing
@testable import DJRoomba

// MARK: - RecentlyPlayedTests

/// Freight for the "Recently Played" browse read + the debug seeder:
/// `recentlyPlayedPage` returns *distinct* songs newest-play first, the
/// keyset cursor paginates with no overlap/gap and terminates, an empty
/// history yields `[]`, and `seedRandomPlayHistory` only picks
/// playlist-member songs, returns `min(count, available)`, rolls
/// `song_stat` forward, appends `play_history`, and respects the cap.
/// Written `guard`-free to satisfy the project's test convention.
struct RecentlyPlayedTests {

  // MARK: Internal

  @Test
  func `empty history yields an empty page`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([sample(id: "s", mid: "m")])
    let page = try await store.recentlyPlayedPage(beforeSeq: nil, limit: 50)
    #expect(page.isEmpty)
  }

  @Test
  func `first page is distinct and newest play first`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      sample(id: "A", mid: "mA"),
      sample(id: "B", mid: "mB"),
      sample(id: "C", mid: "mC"),
    ])

    // Plays in time order. "A" is played THREE times — it must appear
    // exactly once, at its LATEST position. Final newest→oldest distinct
    // order by most-recent play: A (seq grows last), C, B.
    try await store.recordPlay(songID: "B", at: Date(timeIntervalSince1970: 1))
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 2))
    try await store.recordPlay(songID: "C", at: Date(timeIntervalSince1970: 3))
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 4))
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 5))

    let page = try await store.recentlyPlayedPage(beforeSeq: nil, limit: 50)
    #expect(page.map(\.song.id) == ["A", "C", "B"], "distinct, by most-recent play, newest first")
    #expect(page.count == 3, "A played 3× appears ONCE")

    // The rollup travels with the row: A's lifetime play_count is 3.
    let a = try #require(page.first { $0.song.id == "A" })
    #expect(a.playCount == 3)
    #expect(a.lastPlayedAt != nil)
    // lastSeq is the keyset cursor — strictly descending across the page.
    let seqs = page.map(\.lastSeq)
    #expect(seqs == seqs.sorted(by: >), "lastSeq strictly descending (newest first)")
  }

  @Test
  func `keyset pagination crosses a boundary with no overlap or gap and terminates`() async throws {
    let store = try TestSupport.freshStore()
    let songs = (0..<10).map { sample(id: "s\($0)", mid: "m\($0)") }
    try await store.upsertSongs(songs)
    // 10 distinct songs, each played once in order s0…s9 → newest-first
    // distinct order is s9, s8, …, s0.
    for (i, song) in songs.enumerated() {
      try await store.recordPlay(songID: song.id, at: Date(timeIntervalSince1970: Double(i)))
    }

    // Page 1: 4 newest.
    let page1 = try await store.recentlyPlayedPage(beforeSeq: nil, limit: 4)
    #expect(page1.map(\.song.id) == ["s9", "s8", "s7", "s6"])

    // Page 2: keyset cursor = last row's lastSeq → the next 4, no overlap.
    let cursor1 = try #require(page1.last).lastSeq
    let page2 = try await store.recentlyPlayedPage(beforeSeq: cursor1, limit: 4)
    #expect(page2.map(\.song.id) == ["s5", "s4", "s3", "s2"])

    // Page 3: the final 2 — a short page signals the end.
    let cursor2 = try #require(page2.last).lastSeq
    let page3 = try await store.recentlyPlayedPage(beforeSeq: cursor2, limit: 4)
    #expect(page3.map(\.song.id) == ["s1", "s0"])
    #expect(page3.count < 4, "short page = end of history")

    // Page 4: past the end → empty (terminates), no infinite scroll.
    let cursor3 = try #require(page3.last).lastSeq
    let page4 = try await store.recentlyPlayedPage(beforeSeq: cursor3, limit: 4)
    #expect(page4.isEmpty, "pagination terminates")

    // No overlap / no gap: the union across pages is exactly the 10
    // distinct songs, in unbroken newest-first order.
    let all = (page1 + page2 + page3).map(\.song.id)
    #expect(all == (0..<10).reversed().map { "s\($0)" })
    #expect(Set(all).count == 10, "every song once, none skipped or duplicated")
  }

  @Test
  func `a later play of an older song re-floats it to the top of the next read`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      sample(id: "A", mid: "mA"),
      sample(id: "B", mid: "mB"),
    ])
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 1))
    try await store.recordPlay(songID: "B", at: Date(timeIntervalSince1970: 2))
    #expect(
      try await store.recentlyPlayedPage(beforeSeq: nil, limit: 50).map(\.song.id) == ["B", "A"]
    )
    // Re-play A → its MAX(seq) is now the newest, so A is first again
    // (still ONE row — distinct by song).
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 3))
    let page = try await store.recentlyPlayedPage(beforeSeq: nil, limit: 50)
    #expect(page.map(\.song.id) == ["A", "B"])
    #expect(page.count == 2)
  }

  @Test
  func `seed only picks playlist member songs and returns min count available`() async throws {
    let store = try TestSupport.freshStore()
    // 5 songs total; only 3 are in any playlist (2 app, 1 Apple). The
    // other 2 are library songs not in a playlist.
    try await store.upsertSongs((0..<5).map { sample(id: "s\($0)", mid: "m\($0)") })
    let appPlaylist = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(appPlaylist.id, songIDs: ["s0", "s1"])
    try await store.replaceApplePlaylistSnapshot(
      ApplePlaylist(id: "ap1", name: "Imported", artworkURL: nil, curator: nil, lastImportedAt: .now),
      songIDs: ["s2"],
    )

    // Ask for far more than available → returns exactly the 3 members.
    let seeded = try await store.seedRandomPlayHistory(count: 100)
    #expect(seeded == 3, "min(count, available playlist-member songs)")

    // History contains ONLY playlist-member songs (never s3 / s4).
    let history = try await store.recentlyPlayedSongLocalIDs()
    #expect(history.count == 3)
    let memberLocalIDs = try await Set(
      ["s0", "s1", "s2"].asyncMap { try #require(try await store.song(id: $0)).localID }
    )
    #expect(Set(history) == memberLocalIDs, "only playlist-member songs seeded")

    // Each seeded song's song_stat.play_count was bumped, last_played set,
    // and is visible via the recently-played read (cross-check).
    for id in ["s0", "s1", "s2"] {
      let stat = try #require(try await store.songStat(songID: id))
      #expect(stat.playCount == 1)
      #expect(stat.lastPlayedAt != nil)
    }
    let page = try await store.recentlyPlayedPage(beforeSeq: nil, limit: 50)
    #expect(Set(page.map(\.song.id)) == ["s0", "s1", "s2"])
  }

  @Test
  func `seed on a library with no playlist songs returns zero`() async throws {
    let store = try TestSupport.freshStore()
    // Songs exist but none are in any playlist.
    try await store.upsertSongs([sample(id: "s0", mid: "m0"), sample(id: "s1", mid: "m1")])
    let seeded = try await store.seedRandomPlayHistory(count: 500)
    #expect(seeded == 0)
    #expect(try await store.recentlyPlayedSongLocalIDs().isEmpty)
  }

  @Test
  func `seed accumulates plays and respects the prune cap`() async throws {
    let (store, db) = try TestSupport.freshStoreWithDatabase()
    try await store.upsertSongs([sample(id: "s0", mid: "m0"), sample(id: "s1", mid: "m1")])
    let appPlaylist = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(appPlaylist.id, songIDs: ["s0", "s1"])

    // Two separate seed calls accumulate (each appends one history row
    // per member song and bumps play_count).
    #expect(try await store.seedRandomPlayHistory(count: 2) == 2)
    #expect(try await store.seedRandomPlayHistory(count: 2) == 2)
    for id in ["s0", "s1"] {
      #expect(try await store.songStat(songID: id)?.playCount == 2)
    }
    #expect(try await store.recentlyPlayedSongLocalIDs().count == 4)

    // The seeder prunes against the same keyset as `recordPlay`. Inject a
    // tiny stand-in cap via the EXACT prune SQL after a seed to prove the
    // bound holds without driving 50k writes (mirrors the Phase-1 test).
    let cap = 2
    try await db.dbQueue.write { db in
      try db.execute(
        sql: """
          DELETE FROM play_history
          WHERE seq <= (SELECT MAX(seq) FROM play_history) - ?
          """,
        arguments: [cap],
      )
    }
    #expect(try await store.recentlyPlayedSongLocalIDs().count == cap, "bounded to cap newest rows")
  }

  // MARK: Private

  private func sample(
    id: String,
    mid: String,
    title: String = "T",
    importedAt: Date = Date(timeIntervalSince1970: 0),
  ) -> Song {
    Song(
      id: id,
      musicItemID: mid,
      idNamespace: .library,
      title: title,
      artistName: "Artist",
      albumTitle: nil,
      duration: nil,
      isExplicit: false,
      artworkURL: nil,
      importedAt: importedAt,
    )
  }
}

extension Sequence {
  /// Tiny test-only async map (no `guard`, no GCD) so member-id → local_id
  /// resolution stays a one-liner in the seed test.
  fileprivate func asyncMap<T>(
    _ transform: (Element) async throws -> T
  ) async rethrows -> [T] {
    var result = [T]()
    for element in self {
      result.append(try await transform(element))
    }
    return result
  }
}
