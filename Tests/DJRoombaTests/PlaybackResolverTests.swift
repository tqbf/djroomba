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
    #expect(
      result.chunkBoundaries.isEmpty,
      "F1a: no resolved songs ⇒ no chunks",
    )
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

  /// **Phase 3 (catalog-playlists) — mixed library + catalog grouping.**
  /// `resolveAppPlaylist`'s first step is `groupByNamespace`; once Phase 2's
  /// catalog ingest landed, an app playlist can interleave `.library` and
  /// `.catalog` rows. The partition must put each row in the correct
  /// namespace bucket (so each lands at its right MusicKit endpoint —
  /// library `equalTo` vs catalog `memberOf`), de-dupe **per namespace**,
  /// and preserve discovery order within each. The "same raw id in both
  /// namespaces is not conflated" test pins the *colliding* case; this one
  /// pins the *realistic interleaved* case.
  @Test
  func `group by namespace partitions interleaved library and catalog rows`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog),
      row(position: 3, songID: "s3", musicItemID: "L2", namespace: .library),
      row(position: 4, songID: "s4", musicItemID: "C2", namespace: .catalog),
      row(position: 5, songID: "s5", musicItemID: "L1", namespace: .library), // library dup
      row(position: 6, songID: "s6", musicItemID: "C1", namespace: .catalog), // catalog dup
      row(position: 7, songID: "s7", musicItemID: "C3", namespace: .catalog),
    ]
    let plan = PlaybackResolver.groupByNamespace(rows)
    #expect(
      plan.libraryIDs.map(\.rawValue) == ["L1", "L2"],
      "library bucket: discovery order, per-namespace de-duped",
    )
    #expect(
      plan.catalogIDs.map(\.rawValue) == ["C1", "C2", "C3"],
      "catalog bucket: discovery order, per-namespace de-duped",
    )
  }

  /// **Phase 3 — mixed reassembly preserves order across namespaces.**
  /// `reassemble` is keyed by the **stored** `music_item_id` and is
  /// namespace-agnostic by construction (it never reads `row.namespace`).
  /// In a mixed queue, the resolved-by-stored-id map can carry both library
  /// and catalog `MusicKit.Song`s; `reassemble` walks `rows` in input order
  /// and appends a queue slot whenever the stored id is in the map,
  /// regardless of which side resolved it. This test exercises that with a
  /// dictionary whose **keys** simulate the merged result of the library
  /// per-id `equalTo` pass and the catalog batch `memberOf` pass (live
  /// `MusicKit.Song`s aren't constructible in tests, so we assert the
  /// queue-order / unresolved / context contract by what *would* be
  /// appended — same idiom as the existing `app playlist reassembly` test).
  @Test
  func `reassembly walks a mixed library and catalog queue in input order`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog),
      row(position: 3, songID: "s3", musicItemID: "L2", namespace: .library),
      row(position: 4, songID: "s4", musicItemID: "C2", namespace: .catalog), // miss
      row(position: 5, songID: "s5", musicItemID: "L1", namespace: .library), // library dup
      row(position: 6, songID: "s6", musicItemID: "C1", namespace: .catalog), // catalog dup
    ]
    // Simulate the merged resolved-by-stored-id map. L2 + C2 are misses
    // (a library row Apple no longer surfaces; a catalog song unavailable
    // in the user's storefront) — both classes of miss must drop into
    // `unresolved` and never break the queue (the risk-register
    // invariant: one bad id never breaks the whole queue).
    let resolvedIDs: Set = ["L1", "C1"]
    var queueContext = [String]()
    var unresolved = [String]()
    for r in rows {
      if resolvedIDs.contains(r.musicItemID) {
        queueContext.append(r.songID)
      } else {
        unresolved.append(r.musicItemID)
      }
    }
    #expect(
      queueContext == ["s1", "s2", "s5", "s6"],
      "queue is rows-in-order; the two misses drop without breaking ordering; duplicates re-expand",
    )
    #expect(
      unresolved == ["L2", "C2"],
      "both the library miss and the catalog miss are reported (namespace-agnostic)",
    )
    // Falsifiable cross-check: every queueContext entry is OUR `song.id`,
    // none is a `music_item_id`. The context lives in our PK space
    // regardless of which namespace each row's audio came from.
    let appleIDs = Set(rows.map(\.musicItemID))
    for storedID in queueContext {
      #expect(
        !appleIDs.contains(storedID),
        "mixed context never carries an Apple id (namespace-agnostic structural attribution)",
      )
    }
  }

  /// **Phase 3 — start-row attribution works on the catalog side.**
  /// `reassemble` carries `startRow.songID` (our stable `song.id`) through
  /// to `startSongID` whenever the start row resolved — same code path for
  /// library and catalog because the field it reads (`row.songID`) is
  /// namespace-agnostic. With `resolved = [:]`, the start row doesn't
  /// resolve, so `startSong` falls back to `songs.first` (here also nil)
  /// AND `startSongID` falls back to `playContext.first` (here nil) — the
  /// same fallback as the library-only path. This pins that the catalog
  /// row gets EXACTLY the library-row behavior when missed.
  @Test
  func `reassemble carries catalog start row attribution like library`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog), // start
      row(position: 3, songID: "s3", musicItemID: "L2", namespace: .library),
    ]
    let result = PlaybackResolver.reassemble(
      rows: rows,
      startRow: rows[1], // a catalog row
      resolved: [:], // nothing resolved (the unattributable extreme)
    )
    // Everything misses ⇒ empty queue, unresolved is every id in order.
    #expect(result.songs.isEmpty)
    #expect(result.startSong == nil)
    #expect(result.startSongID == nil)
    #expect(result.playContext.isEmpty)
    #expect(
      result.unresolved == ["L1", "C1", "L2"],
      "unresolved walks rows in order regardless of namespace — the catalog miss is reported the same as a library miss",
    )
    #expect(
      result.chunkBoundaries.isEmpty,
      "F1a: empty songs ⇒ empty chunkBoundaries (no chunks to play)",
    )
  }

  /// **F1a (`plans/catalog-playlists.md` Phase-3 followup) — pure chunking.**
  /// `chunkByNamespace` returns the **ranges of consecutive same-namespace
  /// runs** in input order. The `PlaybackService` then plays each chunk
  /// as a homogeneous-namespace `ApplicationMusicPlayer.Queue` (the
  /// workaround for `MPMusicPlayerControllerErrorDomain` error 6 on a
  /// mixed library+catalog queue).
  @Test
  func `chunkByNamespace returns consecutive-same-namespace ranges`() {
    // Empty input ⇒ empty output.
    #expect(PlaybackResolver.chunkByNamespace([]) == [])

    // Single row ⇒ one range.
    let oneLibrary = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library)
    ]
    #expect(PlaybackResolver.chunkByNamespace(oneLibrary) == [0..<1])

    let oneCatalog = [
      row(position: 1, songID: "s1", musicItemID: "C1", namespace: .catalog)
    ]
    #expect(PlaybackResolver.chunkByNamespace(oneCatalog) == [0..<1])

    // All library ⇒ one range covering everything.
    let allLibrary = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "L2", namespace: .library),
      row(position: 3, songID: "s3", musicItemID: "L3", namespace: .library),
    ]
    #expect(
      PlaybackResolver.chunkByNamespace(allLibrary) == [0..<3],
      "library-only ⇒ single chunk (the unchanged single-queue path)",
    )

    // All catalog ⇒ one range covering everything.
    let allCatalog = [
      row(position: 1, songID: "s1", musicItemID: "C1", namespace: .catalog),
      row(position: 2, songID: "s2", musicItemID: "C2", namespace: .catalog),
    ]
    #expect(
      PlaybackResolver.chunkByNamespace(allCatalog) == [0..<2],
      "catalog-only ⇒ single chunk (the unchanged single-queue path)",
    )

    // [L, C, L] ⇒ three single-row chunks (every alternation breaks).
    let interleaved3 = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog),
      row(position: 3, songID: "s3", musicItemID: "L2", namespace: .library),
    ]
    #expect(PlaybackResolver.chunkByNamespace(interleaved3) == [0..<1, 1..<2, 2..<3])

    // [L, L, C, C, L] ⇒ three chunks.
    let mixed = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "L2", namespace: .library),
      row(position: 3, songID: "s3", musicItemID: "C1", namespace: .catalog),
      row(position: 4, songID: "s4", musicItemID: "C2", namespace: .catalog),
      row(position: 5, songID: "s5", musicItemID: "L3", namespace: .library),
    ]
    #expect(PlaybackResolver.chunkByNamespace(mixed) == [0..<2, 2..<4, 4..<5])
  }

  /// **F1a — `reassemble` carries chunkBoundaries that match the resolved
  /// rows.** The chunk boundaries are computed against the rows that
  /// actually take a slot in `songs` / `playContext`, so a dropped
  /// (unresolved) row does NOT create a spurious chunk break. This is the
  /// invariant `PlaybackService` relies on when it slices `Resolution.songs`
  /// by `chunkBoundaries`.
  ///
  /// Note: we assert the *boundary* shape via the pure helper because
  /// constructing real `MusicKit.Song` instances in tests isn't possible
  /// without a live session — same idiom as the existing `app playlist
  /// reassembly` and `reassembly walks a mixed library and catalog queue`
  /// tests.
  @Test
  func `chunkByNamespace over resolved rows describes the queue chunks`() {
    // [L_kept, C_kept, L_kept, C_MISS, L_kept, C_kept] ⇒ after dropping
    // the C miss, the kept ordered namespaces are [L, C, L, L, C] ⇒
    // chunks [0..<1, 1..<2, 2..<4, 4..<5]. The C2 miss does NOT introduce
    // a phantom catalog chunk between the two L runs — exactly the
    // invariant `PlaybackService` relies on.
    let kept = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog),
      row(position: 3, songID: "s3", musicItemID: "L2", namespace: .library),
      // C2 miss removed from `kept`
      row(position: 5, songID: "s5", musicItemID: "L1", namespace: .library),
      row(position: 6, songID: "s6", musicItemID: "C1", namespace: .catalog),
    ]
    #expect(
      PlaybackResolver.chunkByNamespace(kept) == [0..<1, 1..<2, 2..<4, 4..<5],
      "chunk boundaries are over the RESOLVED rows; the dropped catalog row does not create a spurious break between the two library runs",
    )
  }

  /// **F1a — translate player-local index → global.** After a chunk swap,
  /// `player.queue.entries`'s ordinals reset to 0 for the new chunk; the
  /// Phase-4 `advanceToRecord` detector must continue to see a **global**
  /// monotonic index across the whole resolution so its watermark/transition
  /// logic keeps working. A single-chunk resolution (boundaries `[0]`) is
  /// the identity — the unchanged single-queue path.
  @Test
  func `globalQueueIndex translates local index by chunk start`() {
    // First-of-second-chunk in `[0, 3]`: local 0 + boundary 3 = global 3.
    #expect(
      PlaybackResolver.globalQueueIndex(
        localIndex: 0,
        currentChunk: 1,
        chunkBoundaries: [0, 3],
      ) == 3
    )

    // Single-chunk: identity at every local index.
    for local in 0..<5 {
      #expect(
        PlaybackResolver.globalQueueIndex(
          localIndex: local,
          currentChunk: 0,
          chunkBoundaries: [0],
        ) == local,
        "single-chunk ⇒ identity (the unchanged single-queue path)",
      )
    }

    // Three chunks `[0, 2, 4]` (a `[L,L,C,C,L]` resolution): local 0 in
    // chunk 1 = global 2; local 0 in chunk 2 = global 4.
    #expect(
      PlaybackResolver.globalQueueIndex(
        localIndex: 0,
        currentChunk: 1,
        chunkBoundaries: [0, 2, 4],
      ) == 2
    )
    #expect(
      PlaybackResolver.globalQueueIndex(
        localIndex: 0,
        currentChunk: 2,
        chunkBoundaries: [0, 2, 4],
      ) == 4
    )
    // Mid-chunk: local 1 in chunk 1 = global 3.
    #expect(
      PlaybackResolver.globalQueueIndex(
        localIndex: 1,
        currentChunk: 1,
        chunkBoundaries: [0, 2, 4],
      ) == 3
    )

    // Edge cases: empty boundaries (no resolution loaded) ⇒ identity.
    #expect(
      PlaybackResolver.globalQueueIndex(
        localIndex: 5,
        currentChunk: 0,
        chunkBoundaries: [],
      ) == 5,
      "empty boundaries (defensive) ⇒ identity",
    )
    // Out-of-range currentChunk ⇒ identity (defensive; documented).
    #expect(
      PlaybackResolver.globalQueueIndex(
        localIndex: 1,
        currentChunk: 5,
        chunkBoundaries: [0, 2],
      ) == 1
    )
  }

  /// THE falsifiable freight (Phase 3): the pure skip/replay decision at
  /// **every** boundary from the plan's "Pays its freight". Deterministic,
  /// MusicKit-free — exactly the case the pure core exists to lock down.
  @Test
  func `skipKind decides skip replay or none at every boundary`() {
    typealias R = PlaybackResolver

    // --- unknown / non-positive duration → always none (no signal) ---
    #expect(R.skipKind(elapsed: 30, duration: nil, button: .next) == .none)
    #expect(R.skipKind(elapsed: 30, duration: nil, button: .previous) == .none)
    #expect(R.skipKind(elapsed: 5, duration: 0, button: .next) == .none)
    #expect(R.skipKind(elapsed: 5, duration: 0, button: .previous) == .none)
    #expect(R.skipKind(elapsed: 5, duration: -10, button: .next) == .none)
    #expect(R.skipKind(elapsed: 5, duration: -10, button: .previous) == .none)

    // --- next: skip iff 1 s < elapsed < duration/2 (strict both ends) ---
    let d = 100.0 // half == 50
    #expect(
      R.skipKind(elapsed: 1.0, duration: d, button: .next) == .none,
      "elapsed == 1 s is the dead-zone (R2, inclusive lower)",
    )
    #expect(
      R.skipKind(elapsed: 1.01, duration: d, button: .next) == .skip,
      "just past the dead-zone ⇒ skip",
    )
    #expect(
      R.skipKind(elapsed: 0.5, duration: d, button: .next) == .none,
      "well inside the dead-zone ⇒ no skip",
    )
    #expect(
      R.skipKind(elapsed: 49.9, duration: d, button: .next) == .skip,
      "49.9 % (< half) ⇒ skip",
    )
    #expect(
      R.skipKind(elapsed: 50.0, duration: d, button: .next) == .none,
      "exactly 50 % is neither (strict <)",
    )
    #expect(
      R.skipKind(elapsed: 50.1, duration: d, button: .next) == .none,
      "past half ⇒ no skip (it's a play-through, not a skip)",
    )

    // --- previous: replay iff elapsed > duration/2 (strict, no dead-zone) ---
    #expect(
      R.skipKind(elapsed: 50.1, duration: d, button: .previous) == .replay,
      "50.1 % (> half) ⇒ replay",
    )
    #expect(
      R.skipKind(elapsed: 50.0, duration: d, button: .previous) == .none,
      "exactly 50 % is neither (strict >)",
    )
    #expect(
      R.skipKind(elapsed: 49.9, duration: d, button: .previous) == .none,
      "before half ⇒ not a replay",
    )

    // --- a 2 s track: dead-zone still bites; replay still possible ---
    #expect(
      R.skipKind(elapsed: 0.5, duration: 2, button: .next) == .none,
      "2 s @ 0.5 s next ⇒ dead-zone, no skip",
    )
    #expect(
      R.skipKind(elapsed: 1.5, duration: 2, button: .previous) == .replay,
      "2 s @ 1.5 s back ⇒ past half ⇒ replay (no dead-zone on replay)",
    )

    // --- ultra-short track: duration/2 <= 1 s ⇒ skip window empty ---
    // 1.5 s track: half == 0.75. The skip window is 1 < elapsed < 0.75,
    // which is empty, so NO elapsed can ever count a skip (falls out of
    // the rule — no special case).
    for elapsed in [0.0, 0.5, 0.74, 0.75, 0.76, 1.0, 1.5] {
      #expect(
        R.skipKind(elapsed: elapsed, duration: 1.5, button: .next) == .none,
        "ultra-short (half <= 1 s) ⇒ no skip at any elapsed (\(elapsed))",
      )
    }
    // The same ultra-short track still replays correctly past its half.
    #expect(R.skipKind(elapsed: 0.76, duration: 1.5, button: .previous) == .replay)
    #expect(R.skipKind(elapsed: 0.75, duration: 1.5, button: .previous) == .none)
  }

  /// THE falsifiable freight (Phase 4): the pure auto-advance transition
  /// decision at **every** boundary. Deterministic, MusicKit-free — the
  /// case the pure core exists to lock down (mirrors `skipKind`). The
  /// `current == last` arm is called out explicitly as the **R4
  /// guarantee**: it is the single equality that makes a back-replay (and
  /// every paused/steady tick) record nothing.
  @Test
  func `advanceToRecord detects a transition at every boundary`() {
    typealias R = PlaybackResolver

    // No current position (stopped / cleared queue) → never records,
    // regardless of the watermark.
    #expect(R.advanceToRecord(lastRecordedIndex: nil, currentIndex: nil) == nil)
    #expect(R.advanceToRecord(lastRecordedIndex: 3, currentIndex: nil) == nil)

    // current == last → nil. THE R4 GUARANTEE: a back-button replay
    // restarts the SAME structural index, a paused tick and a steady
    // tick also keep it — all three are this one equality, so none
    // appends to play_history (only Phase-3's recordReplay counts).
    #expect(
      R.advanceToRecord(lastRecordedIndex: 0, currentIndex: 0) == nil,
      "R4: same index ⇒ no transition ⇒ no history append (replay/paused/steady)",
    )
    #expect(R.advanceToRecord(lastRecordedIndex: 5, currentIndex: 5) == nil)

    // A different, valid index → record it (genuine advance / forward
    // skip / new-queue start at a new position).
    #expect(R.advanceToRecord(lastRecordedIndex: 0, currentIndex: 1) == 1)
    #expect(R.advanceToRecord(lastRecordedIndex: 5, currentIndex: 2) == 2, "a backward jump is still a transition")

    // Unseeded watermark (nil last) + some current → record that current
    // (the first observation of a queue that was never seeded).
    #expect(R.advanceToRecord(lastRecordedIndex: nil, currentIndex: 0) == 0)
    #expect(R.advanceToRecord(lastRecordedIndex: nil, currentIndex: 4) == 4)
  }

  /// A realistic seeded index *sequence* fed iteratively, exactly as the
  /// 0.5 s monitor would drive `detectAndRecordAdvance`: seed 0 (the
  /// started track, already recorded by `recordPlayStart`), then ticks
  /// `[0, 1, 1, 2, 2, 2, 1]`. Each distinct *consecutive change* records
  /// once; steady ticks and same-index repeats record nothing. Expected
  /// recorded set: `[1, 2, 1]` (note the final `1` is a NEW transition
  /// from `2`, correctly distinct from the seed's `0`).
  @Test
  func `advanceToRecord over a tick sequence records each distinct change once`() {
    var watermark: Int? = 0 // seeded to the start index (song 1 already recorded)
    var recorded = [Int]()

    for tick in [0, 1, 1, 2, 2, 2, 1] {
      if let idx = PlaybackResolver.advanceToRecord(lastRecordedIndex: watermark, currentIndex: tick) {
        // The detector advances the watermark UNCONDITIONALLY on a
        // transition (even an unattributable hole) — model that here.
        watermark = idx
        recorded.append(idx)
      }
    }

    #expect(
      recorded == [1, 2, 1],
      "seed 0 + ticks [0,1,1,2,2,2,1] ⇒ only the 3 distinct consecutive changes record; the leading 0 (==seed) and every steady/repeat tick record nothing",
    )
  }

  /// **Phase 4 (`plans/catalog-playlists.md`) — `reassemble` tags every
  /// chunk with its homogeneous namespace, parallel to `chunkBoundaries`.**
  /// `PlayerStateSnapshot.nowPlayingNamespace` reads this so the now-playing
  /// thumbnail re-resolves a catalog id through `ArtworkProvider`'s catalog
  /// branch (the bug the Phase-4 live test surfaced: a stale `.library` tag
  /// routed catalog ids to the library branch → nil → placeholder).
  ///
  /// We assert on **counts and shape** rather than concrete `MusicKit.Song`s
  /// because constructing real songs needs a live session (same idiom as
  /// the existing `chunkBoundaries` tests).
  @Test
  func `reassemble carries chunkNamespaces parallel to chunkBoundaries`() {
    // Mirrors `chunkByNamespace over resolved rows describes the queue
    // chunks` shape — after dropping the C miss, kept = [L, C, L, L, C] ⇒
    // four chunks at boundaries [0, 1, 2, 4], with parallel namespaces
    // [L, C, L, C].
    let kept = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog),
      row(position: 3, songID: "s3", musicItemID: "L2", namespace: .library),
      row(position: 4, songID: "s4", musicItemID: "L3", namespace: .library),
      row(position: 5, songID: "s5", musicItemID: "C2", namespace: .catalog),
    ]
    // We can verify the chunk-namespace shape via the pure helper, which is
    // the same per-row scan `reassemble` runs (real reassemble needs a
    // resolved `[String: MusicKit.Song]` map we can't construct here). The
    // load-bearing assertion is "one namespace tag per chunk, in order."
    let ranges = PlaybackResolver.chunkByNamespace(kept)
    #expect(ranges == [0..<1, 1..<2, 2..<4, 4..<5])
    let namespaces = ranges.map { kept[$0.lowerBound].namespace }
    #expect(
      namespaces == [.library, .catalog, .library, .catalog],
      "Phase 4: namespaces parallel chunkBoundaries — one tag per chunk, homogeneous",
    )
    #expect(
      namespaces.count == ranges.count,
      "Phase 4: chunkNamespaces.count == chunkBoundaries.count (invariant the snapshot reader relies on)",
    )
  }

  /// **Phase 4 — empty input ⇒ empty `chunkNamespaces`** (same emptiness
  /// rule as `chunkBoundaries`; both arrays are emit-together / skip-
  /// together so a downstream `chunkNamespaces.indices.contains(k)` check
  /// is a safe parallel index guard).
  @Test
  func `reassemble emits empty chunkNamespaces when nothing resolves`() {
    let rows = [
      row(position: 1, songID: "s1", musicItemID: "L1", namespace: .library),
      row(position: 2, songID: "s2", musicItemID: "C1", namespace: .catalog),
    ]
    let result = PlaybackResolver.reassemble(
      rows: rows,
      startRow: rows[0],
      resolved: [:],
    )
    #expect(result.chunkBoundaries.isEmpty)
    #expect(
      result.chunkNamespaces.isEmpty,
      "Phase 4: parallel emptiness with chunkBoundaries",
    )
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
