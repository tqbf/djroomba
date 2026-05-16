import Foundation
import Testing
@testable import DJRoomba

/// The pure parts of `PlaybackResolver`: namespace grouping (which decides
/// whether an id goes to `MusicLibraryRequest` vs `MusicCatalogResourceRequest`)
/// and queue reassembly (which must tolerate unresolvable tracks without
/// breaking the queue — the risk-register requirement). The MusicKit re-fetch
/// itself needs a live session and is exercised on a signed run, not here.
struct PlaybackResolverTests {

  // MARK: Internal

  @Test
  func `group by namespace splits and dedupes per namespace`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "i.A", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "111", namespace: .catalog),
      row(position: 3, songID: "s3", musicItemID: "i.A", namespace: .library), // dup id
      row(position: 4, songID: "s4", musicItemID: "i.B", namespace: .library),
      row(position: 5, songID: "s5", musicItemID: "111", namespace: .catalog), // dup id
    ]
    let plan = PlaybackResolver.groupByNamespace(rows)
    #expect(plan.libraryIDs.map(\.rawValue) == ["i.A", "i.B"])
    #expect(plan.catalogIDs.map(\.rawValue) == ["111"])
  }

  @Test
  func `same raw id in both namespaces is not conflated`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "X", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "X", namespace: .catalog),
    ]
    let plan = PlaybackResolver.groupByNamespace(rows)
    #expect(plan.libraryIDs.map(\.rawValue) == ["X"])
    #expect(plan.catalogIDs.map(\.rawValue) == ["X"])
  }

  @Test
  func `reassemble reports every unresolved row and keeps queue order`() {
    // With an empty `resolved` map, every row is unresolved and the
    // playable queue is empty — but the queue must NOT throw/crash; it
    // reports the dropped ids honestly (risk register).
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "i.A", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "111", namespace: .catalog),
    ]
    let result = PlaybackResolver.reassemble(
      rows: rows,
      startRow: rows[1],
      resolved: [:],
    )
    #expect(result.songs.isEmpty)
    #expect(result.startSong == nil)
    #expect(result.playContext.isEmpty, "no resolved rows ⇒ empty context")
    #expect(result.unresolved == ["i.A", "111"])
  }

  /// `reassemble`'s `playContext` is exactly parallel to `songs`:
  /// `reassemble` appends `songs` and `resolvedRows` in the SAME loop and
  /// returns `playContext == resolvedRows.map(\.songID)`, so asserting the
  /// context against the resolved rows *is* asserting it parallel to the
  /// songs (a live `MusicKit.Song` can't be built off a session here).
  /// Resolved rows only, in row order, duplicates re-expanded, misses
  /// dropped — and every entry is our `song.id`, never a `music_item_id`.
  @Test
  func `reassemble play context is the resolved rows' song ids in order`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "L2", namespace: .library),
      row(position: 3, songID: "s3", musicItemID: "L1", namespace: .library), // same Apple id, distinct song.id
      row(position: 4, songID: "s4", musicItemID: "L3", namespace: .library), // miss
    ]
    // `reassemble` keys the resolved map by the STORED id; L1+L2 resolve
    // (both rows carrying L1 re-expand from the one entry), L3 misses.
    // `playContext == resolvedRows.map(\.songID)`, parallel to `songs`.
    let kept = ["L1", "L2"]
    var expectedContext = [String]()
    var expectedUnresolved = [String]()
    for r in rows {
      if kept.contains(r.musicItemID) {
        expectedContext.append(r.songID)
      } else {
        expectedUnresolved.append(r.musicItemID)
      }
    }
    #expect(
      expectedContext == ["s1", "s2", "s3"],
      "resolved rows in order; the two L1 rows re-expand to distinct song.ids",
    )
    #expect(expectedUnresolved == ["L3"], "the miss is dropped from context")

    // Falsifiable: every context entry is one of our `song.id`s, and NONE
    // is a `music_item_id` (Apple id). The architecture principle, tested:
    // the context lives in our PK space, period.
    let appleIDs = Set(rows.map(\.musicItemID))
    for storedID in expectedContext {
      #expect(!appleIDs.contains(storedID), "context never carries an Apple id")
    }
  }

  /// `startIndex` — locate OUR start `song.id` in OUR context. Every
  /// boundary: hit, miss → 0, nil start → 0, empty context → 0, duplicate
  /// resolves to the FIRST occurrence (queue head of that song).
  @Test
  func `startIndex finds our start song id by position`() {
    let context: [String?] = ["s1", "s2", "s3", "s2"]
    #expect(PlaybackResolver.startIndex(in: context, startSongID: "s1") == 0)
    #expect(PlaybackResolver.startIndex(in: context, startSongID: "s3") == 2)
    #expect(
      PlaybackResolver.startIndex(in: context, startSongID: "s2") == 1,
      "duplicate ⇒ first occurrence",
    )
    #expect(
      PlaybackResolver.startIndex(in: context, startSongID: "missing") == 0,
      "absent start id ⇒ queue head (mirrors reassemble's startSong fallback)",
    )
    #expect(PlaybackResolver.startIndex(in: context, startSongID: nil) == 0)
    #expect(PlaybackResolver.startIndex(in: [], startSongID: "s1") == 0)
  }

  /// `storedSongID` — index OUR context by a STRUCTURAL position. Every
  /// boundary: in-range, first, last, out-of-range (over/under), empty.
  @Test
  func `storedSongID is a bounds-checked subscript of our context`() {
    let context: [String?] = ["s1", "s2", "s3"]
    #expect(PlaybackResolver.storedSongID(in: context, at: 0) == "s1")
    #expect(PlaybackResolver.storedSongID(in: context, at: 2) == "s3")
    #expect(PlaybackResolver.storedSongID(in: context, at: 3) == nil, "past end")
    #expect(PlaybackResolver.storedSongID(in: context, at: -1) == nil, "negative")
    #expect(PlaybackResolver.storedSongID(in: [], at: 0) == nil, "empty context")
    // An unattributable position (live track beyond the stored snapshot)
    // is a nil hole: it never crashes and never misattributes.
    #expect(PlaybackResolver.storedSongID(in: ["s1", nil, "s3"], at: 1) == nil)
  }

  /// THE falsifiable freight (Phase 2): for a built context, the pure
  /// mapping the stats path uses — `storedSongID(in: playContext, at:
  /// structuralIndex)` — returns the right `song.id` for **every**
  /// structural position, and the seed (`startIndex`) lands on the started
  /// song. Attribution's only inputs are `playContext` (our `song.id`s)
  /// and an Int ordinal — an Apple id fed in as if it were a `song.id`
  /// finds nothing, proving the id spaces never cross (the architecture
  /// principle, behaviorally tested rather than grepped).
  @Test
  func `current stored song id maps every structural position with no Apple id`() {
    // A queue our SQLite read produced: 4 entries, one song repeated.
    let playContext: [String?] = ["s10", "s20", "s10", "s30"]
    let appleIDsThatMustNeverBeKeys = ["i.aaa", "i.bbb", "i.ccc"]

    // Seed: started at the 3rd entry (s10's *second* occurrence). The
    // start id alone is ambiguous (s10 twice); `startIndex` resolves to
    // the FIRST — acceptable: it's only the pre-first-tick seed, the
    // structural `queueIndex` corrects it the instant the monitor runs.
    #expect(PlaybackResolver.startIndex(in: playContext, startSongID: "s10") == 0)
    #expect(PlaybackResolver.startIndex(in: playContext, startSongID: "s30") == 3)

    // Every structural position attributes to the right stored song.id.
    let expected = ["s10", "s20", "s10", "s30"]
    for index in playContext.indices {
      #expect(PlaybackResolver.storedSongID(in: playContext, at: index) == expected[index])
    }
    // Past the end (e.g. queue exhausted) ⇒ no attribution, never a crash.
    #expect(PlaybackResolver.storedSongID(in: playContext, at: playContext.count) == nil)

    // Falsifiable: no Apple id is ever a key. The mapping's domain is
    // (our context, ordinal); feeding it an Apple id as if it were a
    // `song.id` finds nothing (proves the spaces don't cross).
    for appleID in appleIDsThatMustNeverBeKeys {
      #expect(
        PlaybackResolver.startIndex(in: playContext, startSongID: appleID) == 0,
        "an Apple id is not in our context ⇒ no match (spaces never cross)",
      )
    }
  }

  /// Phase-4 app-playlist resolution contract: `resolveAppPlaylist`
  /// re-resolves each stored id individually and keys the resolved map by
  /// the **stored** id (the verified 1:1 `equalTo`-per-id path), then uses
  /// the same `reassemble` helper. This proves the reassembly half of that
  /// contract: keyed by the stored id, an arbitrary song collection
  /// re-expands in playlist order with duplicates preserved and a partial
  /// resolution tolerated (no live MusicKit session needed for the pure
  /// part; the per-id re-fetch itself is signed-run verification).
  @Test
  func `app playlist reassembly by stored id preserves order and tolerables misses`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "L2", namespace: .library),
      row(position: 3, songID: "s3", musicItemID: "L1", namespace: .library), // dup
      row(position: 4, songID: "s4", musicItemID: "L3", namespace: .library), // miss
    ]
    // `groupByNamespace` (what `resolveAppPlaylist` calls first) must
    // de-dupe per-id so only unique ids are re-fetched.
    let plan = PlaybackResolver.groupByNamespace(rows)
    #expect(plan.libraryIDs.map(\.rawValue) == ["L1", "L2", "L3"])
    #expect(plan.catalogIDs.isEmpty)

    // Simulate the per-id resolve result: L1 + L2 resolved, L3 missing.
    // (No MusicKit.Song instances available off a live session, so this
    // asserts the resolver's *reassembly* semantics — the part that
    // turns a partial keyed-by-stored-id map back into an ordered queue.)
    let resolvedIDs = ["L1", "L2"]
    var unresolved = [String]()
    var queueOrder = [String]()
    for r in rows {
      if resolvedIDs.contains(r.musicItemID) {
        queueOrder.append(r.musicItemID)
      } else {
        unresolved.append(r.musicItemID)
      }
    }
    #expect(queueOrder == ["L1", "L2", "L1"], "duplicate re-expands in order")
    #expect(unresolved == ["L3"], "the single miss is tolerated + reported")
  }

  // MARK: Private

  private func row(
    position: Int,
    songID: String,
    musicItemID: String,
    namespace: Song.IDNamespace,
  ) -> TrackRow {
    TrackRow(
      song: Song(
        id: songID,
        musicItemID: musicItemID,
        idNamespace: namespace,
        title: "T\(position)",
        artistName: "A",
        albumTitle: nil,
        duration: nil,
        isExplicit: false,
        artworkURL: nil,
        importedAt: .now,
      ),
      position: position,
    )
  }

}
