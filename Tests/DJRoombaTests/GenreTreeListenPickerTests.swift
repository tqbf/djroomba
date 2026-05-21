import Foundation
import Testing
@testable import DJRoomba

/// Pure-logic invariants for the Phase D "Listen to this" track
/// picker (`plans/son-of-genre-map.md` Phase D). Fixture-driven; no
/// SQLite, no MusicKit — the picker is pure over its `Candidate`
/// rows.
struct GenreTreeListenPickerTests {

  static func candidate(
    _ id: String,
    title: String? = nil,
    artist: String,
    playCount: Int,
    lastPlayed: Date? = nil,
  ) -> GenreTreeListenPicker.Candidate {
    GenreTreeListenPicker.Candidate(
      songID: id,
      title: title ?? "Title-\(id)",
      artistName: artist,
      playCount: playCount,
      lastPlayedAt: lastPlayed,
    )
  }

  @Test
  func `Empty candidate list returns an empty pick`() {
    let picks = GenreTreeListenPicker.pick(from: [])
    #expect(picks.isEmpty)
  }

  @Test
  func `Top-N sorts by play count descending`() {
    let candidates = [
      Self.candidate("s1", artist: "A1", playCount: 1),
      Self.candidate("s2", artist: "A2", playCount: 9),
      Self.candidate("s3", artist: "A3", playCount: 5),
      Self.candidate("s4", artist: "A4", playCount: 3),
    ]
    let picks = GenreTreeListenPicker.pick(from: candidates, targetCount: 3)
    #expect(picks.map(\.songID) == ["s2", "s3", "s4"])
  }

  @Test
  func `Artist diversity cap blocks a single artist from monopolising`() {
    var candidates = [GenreTreeListenPicker.Candidate]()
    for index in 0..<10 {
      candidates.append(Self.candidate(
        "s\(index)",
        artist: "Heavy",
        playCount: 100 - index,
      ))
    }
    candidates.append(Self.candidate("alt1", artist: "Other", playCount: 50))
    let picks = GenreTreeListenPicker.pick(
      from: candidates,
      targetCount: 10,
      maxPerArtist: 3,
    )
    let heavyCount = picks.count(where: { $0.artistName == "Heavy" })
    #expect(heavyCount == 3, "max-per-artist cap of 3 enforced")
    // "Other" should be admitted (only one with that name, well under cap).
    #expect(picks.contains(where: { $0.artistName == "Other" }))
  }

  @Test
  func `Picker respects the target-count cap`() {
    let candidates = (0..<100).map { index in
      Self.candidate("s\(index)", artist: "Artist\(index)", playCount: 100 - index)
    }
    let picks = GenreTreeListenPicker.pick(from: candidates, targetCount: 30)
    #expect(picks.count == 30)
  }

  @Test
  func `Default N = 30 and default max-per-artist = 3`() {
    #expect(GenreTreeListenPicker.defaultTargetCount == 30)
    #expect(GenreTreeListenPicker.defaultMaxPerArtist == 3)
  }

  @Test
  func `Identical inputs produce identical pick order`() {
    let candidates = [
      Self.candidate("z", artist: "Ax", playCount: 5),
      Self.candidate("a", artist: "Ay", playCount: 5),
      Self.candidate("m", artist: "Az", playCount: 5),
    ]
    let first = GenreTreeListenPicker.pick(from: candidates, targetCount: 3)
    let second = GenreTreeListenPicker.pick(from: candidates, targetCount: 3)
    #expect(first == second)
  }

  @Test
  func `Ties on play count broken by lastPlayed descending then title ascending`() {
    let newer = Date(timeIntervalSince1970: 1_700_000_000)
    let older = Date(timeIntervalSince1970: 1_600_000_000)
    let candidates = [
      Self.candidate("c", title: "Cba", artist: "A1", playCount: 5, lastPlayed: older),
      Self.candidate("a", title: "Abc", artist: "A2", playCount: 5, lastPlayed: newer),
      Self.candidate("b", title: "Bbb", artist: "A3", playCount: 5, lastPlayed: newer),
    ]
    let picks = GenreTreeListenPicker.pick(from: candidates, targetCount: 3)
    // Both `a` and `b` have the newer date; among them title-ascending → `a` first then `b`.
    // `c` (older date) comes last.
    #expect(picks.map(\.songID) == ["a", "b", "c"])
  }

  @Test
  func `Songs with no lastPlayed sort after songs with one when play counts tie`() {
    let played = Date(timeIntervalSince1970: 1_700_000_000)
    let candidates = [
      Self.candidate("never", title: "X", artist: "A1", playCount: 3, lastPlayed: nil),
      Self.candidate("played", title: "Y", artist: "A2", playCount: 3, lastPlayed: played),
    ]
    let picks = GenreTreeListenPicker.pick(from: candidates, targetCount: 2)
    #expect(picks.map(\.songID) == ["played", "never"])
  }

  @Test
  func `Zero or negative bounds produce an empty pick`() {
    let candidates = [Self.candidate("a", artist: "A1", playCount: 1)]
    #expect(GenreTreeListenPicker.pick(from: candidates, targetCount: 0).isEmpty)
    #expect(GenreTreeListenPicker.pick(from: candidates, maxPerArtist: 0).isEmpty)
  }

  @Test
  func `Artist diversity uses case-insensitive matching`() {
    let candidates = [
      Self.candidate("s1", artist: "The Beatles", playCount: 10),
      Self.candidate("s2", artist: "THE BEATLES", playCount: 9),
      Self.candidate("s3", artist: "the beatles", playCount: 8),
      Self.candidate("s4", artist: "The Beatles", playCount: 7),
      Self.candidate("s5", artist: "Other", playCount: 6),
    ]
    let picks = GenreTreeListenPicker.pick(
      from: candidates,
      targetCount: 10,
      maxPerArtist: 3,
    )
    // Three slots for the Beatles, regardless of case spelling; "Other" rounds out.
    let beatlesCount = picks.count(where: { $0.artistName.lowercased() == "the beatles" })
    #expect(beatlesCount == 3)
    #expect(picks.contains(where: { $0.songID == "s5" }))
  }

  @Test
  func `Picks return in admission order, not just sorted by play count after cap`() {
    let candidates = [
      Self.candidate("a", artist: "Heavy", playCount: 100),
      Self.candidate("b", artist: "Heavy", playCount: 90),
      Self.candidate("c", artist: "Heavy", playCount: 80),
      Self.candidate("d", artist: "Heavy", playCount: 70),
      Self.candidate("e", artist: "Light", playCount: 60),
    ]
    let picks = GenreTreeListenPicker.pick(
      from: candidates,
      targetCount: 5,
      maxPerArtist: 3,
    )
    #expect(picks.map(\.songID) == ["a", "b", "c", "e"], "d skipped over cap")
  }
}
