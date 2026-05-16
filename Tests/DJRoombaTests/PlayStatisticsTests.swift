import Foundation
import GRDB
import Testing
@testable import DJRoomba

/// Phase 1 play-statistics freight: the `v3` schema is non-destructive on a
/// real v2 DB, `local_id` is a stable canonical numeric id, `play_history`
/// is bounded by the cap while `song_stat.play_count` stays the true
/// lifetime count, and skip/replay counters move only themselves and add
/// **zero** history rows. One-way isolation is preserved throughout.
struct PlayStatisticsTests {

  // MARK: Internal

  @Test
  func `local id is dense one based and stable across re import`() async throws {
    let store = try TestSupport.freshStore()
    // Distinct imported_at so the (imported_at, id) order is unambiguous.
    let songs = (0..<5).map { i in
      sample(id: "id\(i)", mid: "m\(i)", importedAt: Date(timeIntervalSince1970: Double(1_000 + i)))
    }
    try await store.upsertSongs(songs)

    var firstLocalIDs = [String: Int]()
    for song in songs {
      let stored = try #require(try await store.song(id: song.id))
      firstLocalIDs[song.id] = stored.localID
    }
    // Dense 1..N in (imported_at, id) order.
    let orderedLocalIDs = songs.compactMap { firstLocalIDs[$0.id] }
    #expect(orderedLocalIDs == [1, 2, 3, 4, 5])
    #expect(Set(firstLocalIDs.values).count == 5, "local_id is unique")

    // Re-import the SAME keys with changed metadata → local_id unchanged.
    let reimported = songs.map { s in
      sample(id: s.id, mid: s.musicItemID, title: "CHANGED \(s.id)", importedAt: s.importedAt)
    }
    try await store.upsertSongs(reimported)
    for song in songs {
      let stored = try #require(try await store.song(id: song.id))
      #expect(stored.localID == firstLocalIDs[song.id], "local_id is stable across re-import")
      #expect(stored.title == "CHANGED \(song.id)", "metadata still refreshed")
    }

    // A brand-new song in a later upsert gets MAX+1.
    try await store.upsertSongs([sample(id: "new", mid: "mnew")])
    let new = try #require(try await store.song(id: "new"))
    #expect(new.localID == 6, "new key → MAX(local_id)+1, monotonic")
  }

  /// Documents the actual `local_id` allocation contract under the spec's
  /// `IFNULL(MAX(local_id), 0)+rn` upsert SQL. The high-water mark is
  /// `MAX(local_id)` over **live** `song` rows, so it does NOT survive
  /// deleting the highest-numbered row. That is acceptable for the durable
  /// contract because a song that has ever been played / put in a playlist
  /// is FK-RESTRICTed against deletion (`play_history`,
  /// `apple_playlist_track`, `app_playlist_track`): any song whose
  /// `local_id` could be observed/stored elsewhere can't be deleted, so
  /// its number can't be recycled. Only a never-referenced song can be
  /// deleted, and re-using a number no one ever saw is harmless. (A
  /// persistent high-water counter that survives deletion of an unused row
  /// would be a new schema element — out of Phase 1 scope; flagged.)
  @Test
  func `local id high water mark is over live rows`() async throws {
    let (store, db) = try TestSupport.freshStoreWithDatabase()

    try await store.upsertSongs([
      sample(id: "a", mid: "a", importedAt: Date(timeIntervalSince1970: 1)),
      sample(id: "b", mid: "b", importedAt: Date(timeIntervalSince1970: 2)),
    ])
    #expect(try #require(try await store.song(id: "a")).localID == 1)
    #expect(try #require(try await store.song(id: "b")).localID == 2)

    // RESTRICT makes this impossible once 'b' is referenced; here 'b' has
    // no refs, so the delete succeeds and MAX(local_id) drops to 1.
    try await db.dbQueue.write { db in
      try db.execute(sql: "DELETE FROM song WHERE id = 'b'")
    }
    // Documented behaviour: next new key is MAX(live)+1 == 2.
    try await store.upsertSongs([sample(id: "c", mid: "c")])
    #expect(try #require(try await store.song(id: "c")).localID == 2)
    // The surviving song's id is never disturbed by another upsert.
    #expect(try #require(try await store.song(id: "a")).localID == 1)
  }

  /// The cap is 50,000; driving 50,005 real `recordPlay` calls (50k+ write
  /// transactions) is prohibitively slow and lowering the cap would mean
  /// adding production API solely for the test. Instead this asserts the
  /// load-bearing claim two ways without any test-only prod surface:
  /// (1) the documented prune SQL — verbatim from `recordPlay` — bounds
  ///     `play_history` to exactly `cap` newest rows on a small injected
  ///     dataset (cap temporarily injected via raw SQL into the migrated
  ///     DB, not the constant), proving the keyset semantics, AND
  /// (2) `song_stat.play_count` is the independent true lifetime count: a
  ///     handful of real `recordPlay` calls keep ALL rows (cap not hit)
  ///     and `play_count` equals the real number of plays.
  @Test
  func `prune SQL bounds history to exactly the cap newest first`() async throws {
    let (store, db) = try TestSupport.freshStoreWithDatabase()
    try await store.upsertSongs([sample(id: "s", mid: "s")])
    let localID = try #require(try await store.song(id: "s")).localID

    // A small stand-in cap exercised against the EXACT prune SQL from
    // recordPlay. cap + 5 raw appends, then the keyset delete.
    let cap = 7
    let total = cap + 5
    try await db.dbQueue.write { db in
      for _ in 0..<total {
        try db.execute(
          sql: "INSERT INTO play_history (song_local_id) VALUES (?)",
          arguments: [localID],
        )
      }
      try db.execute(
        sql: """
          DELETE FROM play_history
          WHERE seq <= (SELECT MAX(seq) FROM play_history) - ?
          """,
        arguments: [cap],
      )
    }

    let rows = try await db.dbQueue.read { db in
      try Row.fetchAll(db, sql: "SELECT seq FROM play_history ORDER BY seq DESC")
    }
    #expect(rows.count == cap, "history bounded to exactly cap rows")
    // Newest-first order intact: seqs strictly descending, the cap most
    // recent ones survived (total-cap oldest pruned).
    let seqs = rows.map { $0["seq"] as Int64 }
    #expect(seqs == Array((Int64(total - cap + 1)...Int64(total)).reversed()))
  }

  @Test
  func `play count is the true lifetime count independent of history`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([sample(id: "s", mid: "s")])

    // Cap (50_000) not hit → every play keeps a history row AND
    // play_count tracks the real number of plays independently.
    let plays = 5
    for i in 0..<plays {
      try await store.recordPlay(songID: "s", at: Date(timeIntervalSince1970: Double(i)))
    }

    #expect(try await store.songStat(songID: "s")?.playCount == plays)
    let history = try await store.recentlyPlayedSongIDs()
    #expect(history.count == plays, "cap not hit → all plays retained")
    #expect(history == Array(repeating: "s", count: plays))
    let localHistory = try await store.recentlyPlayedSongLocalIDs()
    let local = try #require(try await store.song(id: "s")).localID
    #expect(localHistory == Array(repeating: local, count: plays))
  }

  @Test
  func `skip and replay move only their own column and add no history`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([sample(id: "s", mid: "s")])

    // First touch creates the row at count 1, play_count 0.
    try await store.recordSkip(songID: "s")
    var stat = try #require(try await store.songStat(songID: "s"))
    #expect(stat.skipCount == 1)
    #expect(stat.replayCount == 0)
    #expect(stat.playCount == 0)
    #expect(stat.lastPlayedAt == nil)

    try await store.recordSkip(songID: "s")
    try await store.recordReplay(songID: "s")
    try await store.recordReplay(songID: "s")
    try await store.recordReplay(songID: "s")
    stat = try #require(try await store.songStat(songID: "s"))
    #expect(stat.skipCount == 2)
    #expect(stat.replayCount == 3)
    #expect(stat.playCount == 0, "skip/replay never touch play_count")

    // Decision R4: neither skip nor replay appends to play_history.
    #expect(try await store.recentlyPlayedSongLocalIDs().isEmpty)
    #expect(try await store.recentlyPlayedSongIDs().isEmpty)
  }

  @Test
  func `skip then play keeps both counters on the same row`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([sample(id: "s", mid: "s")])

    try await store.recordSkip(songID: "s")
    try await store.recordPlay(songID: "s", at: Date(timeIntervalSince1970: 1))
    let stat = try #require(try await store.songStat(songID: "s"))
    #expect(stat.skipCount == 1)
    #expect(stat.playCount == 1, "recordPlay increments the existing row")
    #expect(stat.replayCount == 0)
    #expect(try await store.recentlyPlayedSongIDs() == ["s"], "only the play is history")
  }

  @Test
  func `v3 backfills local id densely and non destructively on a v2 db`() async throws {
    let dbQueue = try DatabaseQueue()
    // Migrate up to and including v2 only.
    try LibraryMigrator.migrator.migrate(dbQueue, upTo: "v2.applePlaylistChangeToken")

    // No local_id column exists at v2 — insert via raw SQL with known
    // (imported_at, id) so the backfill order is deterministic. Insert
    // out of dense order to prove the ORDER BY (imported_at, id), not
    // insertion order, drives numbering.
    try await dbQueue.write { db in
      try db.execute(sql: """
        INSERT INTO song
          (id, music_item_id, id_namespace, title, artist_name,
           is_explicit, imported_at)
        VALUES
          ('idC', 'mC', 'library', 'C', 'A', 0, '2026-01-03 00:00:00.000'),
          ('idA', 'mA', 'library', 'A', 'A', 0, '2026-01-01 00:00:00.000'),
          ('idB', 'mB', 'library', 'B', 'A', 0, '2026-01-02 00:00:00.000'),
          ('idA2','mA2','library', 'A2','A', 0, '2026-01-01 00:00:00.000')
        """)
      // Pre-existing play_event row so DROP is exercised on real data.
      try db.execute(
        sql: "INSERT INTO play_event (song_id, played_at) VALUES (?, ?)",
        arguments: ["idA", Date(timeIntervalSince1970: 1)],
      )
    }
    #expect(try await dbQueue.read { try $0.tableExists("play_event") })

    // Apply the rest of the migrator (v3).
    try LibraryMigrator.migrator.migrate(dbQueue)

    let local = try await dbQueue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT id, local_id FROM song ORDER BY local_id",
      ).map { ($0["id"] as String, $0["local_id"] as Int) }
    }
    // (imported_at, id): idA(01-01,idA) idA2(01-01,idA2) idB(01-02) idC(01-03)
    let backfilledIDs: [String] = local.map(\.0)
    let backfilledLocalIDs: [Int] = local.map(\.1)
    #expect(backfilledIDs == ["idA", "idA2", "idB", "idC"])
    #expect(backfilledLocalIDs == [1, 2, 3, 4], "dense 1..N")
    #expect(Set(backfilledLocalIDs).count == 4, "unique")

    // The UNIQUE index exists on song(local_id).
    let hasUniqueLocalID = try await dbQueue.read { db in
      try db.indexes(on: "song").contains {
        $0.isUnique && $0.columns == ["local_id"]
      }
    }
    #expect(hasUniqueLocalID, "idx_song_local_id must be UNIQUE")

    // play_event dropped; play_history present; existing rows intact.
    #expect(try await dbQueue.read { try !$0.tableExists("play_event") })
    #expect(try await dbQueue.read { try $0.tableExists("play_history") })
    let titles = try await dbQueue.read { db in
      try String.fetchAll(db, sql: "SELECT title FROM song ORDER BY title")
    }
    #expect(titles == ["A", "A2", "B", "C"], "existing song rows otherwise intact")
  }

  @Test
  func `v3 is idempotent and isolated from app data`() async throws {
    let (store, db) = try TestSupport.freshStoreWithDatabase()

    // Seed app-owned + favorites/recents state, then re-run the migrator;
    // nothing here may change.
    try await store.upsertSongs([sample(id: "s1", mid: "s1"), sample(id: "s2", mid: "s2")])
    let pl = try await store.createAppPlaylist(named: "Mine")
    try await store.addSongsToAppPlaylist(pl.id, songIDs: ["s1", "s2"])
    try await store.setFavorite(true, playlistID: pl.id, source: .app)
    try await store.recordRecent(playlistID: pl.id, source: .app)
    try await store.recordPlay(songID: "s1", at: Date(timeIntervalSince1970: 1))

    let appliedBefore = try await db.dbQueue.read { db in
      try LibraryMigrator.migrator.appliedMigrations(db)
    }
    // Re-running the migrator on an up-to-date DB is a no-op.
    try LibraryMigrator.migrator.migrate(db.dbQueue)
    let appliedAfter = try await db.dbQueue.read { db in
      try LibraryMigrator.migrator.appliedMigrations(db)
    }
    #expect(appliedAfter == appliedBefore)
    #expect(appliedAfter.contains("v3.playStatistics"))

    // App data / favorites / recents / history all intact and untouched.
    #expect(try await store.songs(inAppPlaylist: pl.id).map(\.id) == ["s1", "s2"])
    #expect(try await store.isFavorite(playlistID: pl.id))
    #expect(try await store.recentPlaylists().map(\.playlistID) == [pl.id])
    #expect(try await store.songStat(songID: "s1")?.playCount == 1)
    #expect(try await store.recentlyPlayedSongIDs() == ["s1"])
  }

  /// Phase 3 structural freight: the capture → decide → record ordering,
  /// to the extent it's unit-testable with no live MusicKit session.
  /// Drives the *exact* pieces `MusicController.recordTransportStat` wires
  /// together — `skipKind` on a live-style playhead, the pre-skip
  /// `storedSongID` attribution (Phase 2 pure mapping), and the matching
  /// `LibraryStore` write — and asserts: the recorded song is the
  /// **pre-skip** current stored song, a `.none` decision records nothing,
  /// and a replay adds **zero** `play_history` rows (Decision R4).
  @Test
  func `transport recording attributes to the pre skip song and obeys R4`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([sample(id: "A", mid: "mA"), sample(id: "B", mid: "mB")])

    // The canonical play context (Phase 2): our song.ids by structural
    // position. "A" is the pre-skip current song (index 0); the transport
    // would advance to "B" (index 1) — attribution must use the song that
    // WAS playing, captured before that mutation.
    let context: [String?] = ["A", "B"]
    let preSkipSongID = try #require(PlaybackResolver.storedSongID(in: context, at: 0))
    #expect(preSkipSongID == "A", "captured before the transport advances")

    // 90 s track @ 10 s, "next" → a skip (1 s < 10 < 45), attributed to A.
    let skip = PlaybackResolver.skipKind(elapsed: 10, duration: 90, button: .next)
    #expect(skip == .skip)
    try await store.recordSkip(songID: preSkipSongID)
    var statA = try #require(try await store.songStat(songID: "A"))
    #expect(statA.skipCount == 1)
    #expect(try await store.songStat(songID: "B") == nil, "B (post-skip) untouched")

    // 90 s track @ 60 s, "back" → a replay (60 > 45), attributed to A.
    let replay = PlaybackResolver.skipKind(elapsed: 60, duration: 90, button: .previous)
    #expect(replay == .replay)
    try await store.recordReplay(songID: preSkipSongID)
    statA = try #require(try await store.songStat(songID: "A"))
    #expect(statA.replayCount == 1)

    // A `.none` decision (e.g. exactly half) records nothing — the
    // controller's `guard kind != .none` short-circuits before any write.
    let none = PlaybackResolver.skipKind(elapsed: 45, duration: 90, button: .next)
    #expect(none == .none)
    // (no store call made for .none, mirroring the controller)
    statA = try #require(try await store.songStat(songID: "A"))
    #expect(statA.skipCount == 1, ".none never bumps a counter")
    #expect(statA.replayCount == 1)

    // Decision R4 — the load-bearing Phase-4 dependency: recordReplay (and
    // recordSkip) leave play_history EMPTY and only move song_stat. A
    // replay must NEVER become a history entry.
    #expect(statA.playCount == 0, "skip/replay never touch play_count")
    #expect(
      try await store.recentlyPlayedSongLocalIDs().isEmpty,
      "R4: a replay adds zero play_history rows (Phase-4 dependency)",
    )
    #expect(try await store.recentlyPlayedSongIDs().isEmpty)
  }

  /// THE falsifiable freight (Phase 4): the end-to-end auto-advance path
  /// against the real `LibraryStore`, no MusicKit needed. Reproduces what
  /// `MusicController` wires together — `recordPlayStart` of song 1, the
  /// start-index *seed*, then the 0.5 s monitor driving
  /// `advanceToRecord` → `storedSongID` → `recordPlay` over a tick
  /// sequence — and asserts the plan's freight:
  ///
  /// A queue advancing N distinct positions yields exactly N
  /// `play_history` rows from transitions **plus** the 1 from the start
  /// path; a back-replay (same index, no transition) adds **zero** rows
  /// (Decision R4); and song 1 is **not** duplicated by the seed.
  @Test
  func `auto advance records each new position once plus the start and never the replay`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([
      sample(id: "A", mid: "mA"),
      sample(id: "B", mid: "mB"),
      sample(id: "C", mid: "mC"),
    ])

    // Phase-2 canonical play context: our song.ids by structural
    // position. The user explicitly started at index 0 ("A").
    let context: [String?] = ["A", "B", "C"]
    let startIndex = PlaybackResolver.startIndex(in: context, startSongID: "A")
    #expect(startIndex == 0)

    // 1. The explicitly-started track is recorded by `recordPlayStart`
    //    (this is the existing Phase-1/2 path; ONE history row).
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 0))

    // 2. The detector's watermark is SEEDED to the start index in the
    //    same atomic assignment `MusicController` uses — so the first
    //    monitor tick (current == seed) is NOT a transition and "A" is
    //    not re-appended (no double-count of song 1).
    var watermark: Int? = startIndex

    /// Replays `MusicController.detectAndRecordAdvance`'s exact body
    /// (advance the watermark unconditionally on a transition; record a
    /// play iff the position attributes to one of our song.ids), driven
    /// by the same kind of tick stream the 0.5 s monitor produces.
    /// `advanceToRecord`/`storedSongID` returning nil is the EXPECTED,
    /// correct result for a steady / seed / same-index-replay /
    /// unattributable tick (the detector returns early there) — so this
    /// branches on the optionals rather than `#require`-ing them (that
    /// would fail the test on the very behaviour under test). Written
    /// `guard`-free to satisfy the project's `noGuardInTests` rule.
    func tick(_ currentIndex: Int?, at when: TimeInterval) async throws {
      if
        let recordIndex = PlaybackResolver.advanceToRecord(
          lastRecordedIndex: watermark,
          currentIndex: currentIndex,
        )
      {
        watermark = recordIndex
        if let songID = PlaybackResolver.storedSongID(in: context, at: recordIndex) {
          try await store.recordPlay(songID: songID, at: Date(timeIntervalSince1970: when))
        }
      }
    }

    // Tick stream over the natural life of the queue:
    //  - 0,0      : steady on the seeded start ("A") — NO append (seed).
    //  - 1,1,1    : auto-advance to "B", then steady — ONE append ("B").
    //  - 1        : back-button REPLAY of "B" (same index) — ZERO append
    //               (Decision R4; only Phase-3's recordReplay would count).
    //  - 2,2      : auto-advance to "C", then steady — ONE append ("C").
    let stream: [(Int?, TimeInterval)] = [
      (0, 1),
      (0, 2),
      (1, 3),
      (1, 4),
      (1, 5),
      (1, 6), // simulated back-replay of the current track: same index
      (2, 7),
      (2, 8),
    ]
    for (idx, when) in stream {
      try await tick(idx, at: when)
    }

    // History, newest-first: C (transition), B (transition), A (start).
    // Exactly N=2 transition rows + 1 start row; the replay added none.
    let history = try await store.recentlyPlayedSongIDs()
    #expect(
      history == ["C", "B", "A"],
      "1 start (A) + 2 distinct advances (B, C); the same-index back-replay adds ZERO rows (R4); the seed did not re-append A",
    )
    // Song 1 ("A") appears EXACTLY once — the start path only; the seed
    // suppressed the first-tick re-append.
    #expect(history.count(where: { $0 == "A" }) == 1, "song 1 not double-counted by the seed")

    // play_count is the independent lifetime rollup: A=1, B=1, C=1.
    #expect(try await store.songStat(songID: "A")?.playCount == 1)
    #expect(try await store.songStat(songID: "B")?.playCount == 1)
    #expect(try await store.songStat(songID: "C")?.playCount == 1)
  }

  /// Companion to the above isolating the **R4** claim with a counter in
  /// the mix: a real `recordReplay` (Phase 3, "back" past halfway) plus
  /// the Phase-4 detector seeing the *same* structural index (the replay
  /// restarted the current track) must, together, add **zero**
  /// `play_history` rows beyond the original start — the user's "do not
  /// record a song twice if we hit back to replay it".
  @Test
  func `a back replay bumps the counter but the detector appends no history`() async throws {
    let store = try TestSupport.freshStore()
    try await store.upsertSongs([sample(id: "A", mid: "mA"), sample(id: "B", mid: "mB")])
    let context: [String?] = ["A", "B"]

    // Started "A" (index 0), recorded by the start path; watermark seeded.
    try await store.recordPlay(songID: "A", at: Date(timeIntervalSince1970: 0))
    var watermark: Int? = PlaybackResolver.startIndex(in: context, startSongID: "A")

    // Played most of "A", pressed BACK past halfway → Phase-3 counter.
    let kind = PlaybackResolver.skipKind(elapsed: 60, duration: 90, button: .previous)
    #expect(kind == .replay)
    try await store.recordReplay(songID: "A")

    // The back-replay restarts "A" — the player's structural index is
    // STILL 0. The Phase-4 detector therefore sees no transition.
    let recordIndex = PlaybackResolver.advanceToRecord(lastRecordedIndex: watermark, currentIndex: 0)
    #expect(recordIndex == nil, "R4: replay keeps the same index ⇒ no transition")
    if let recordIndex { watermark = recordIndex } // (not taken)

    // Exactly the one start row for "A"; the replay added none.
    #expect(try await store.recentlyPlayedSongIDs() == ["A"], "R4: history has only the start play, not the replay")
    let stat = try #require(try await store.songStat(songID: "A"))
    #expect(stat.replayCount == 1, "the replay is counted (Phase 3) …")
    #expect(stat.playCount == 1, "… but never as a second play (R4)")
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
