import Foundation
import Testing
@testable import DJRoomba

/// `MetadataMatcher` — the pure, no-DB tiered snapshot→library matcher
/// (`plans/snapshot-export-import.md`). Pins: tier precedence
/// (ISRC > music_item_id > title/artist/album > title/artist),
/// conservative normalization, source-wins-only-when-present coalescing
/// (never blanks good data), "emit only on a real change", the tier-4
/// album-boundary safety, deterministic dedupe of duplicate source keys,
/// and the summary tally. Entirely deterministic — no MusicKit, no DB, no
/// signing (the codebase's pure-decider test pattern).
struct MetadataMatcherTests {

  // MARK: Internal

  @Test
  func `isrc wins over every weaker key and copies genres`() {
    // Source matches the target by ISRC even though title/artist differ.
    let source = [
      song(
        id: "src",
        mid: "OTHER",
        title: "wrong title",
        artist: "wrong artist",
        album: "wrong album",
        genres: ["Industrial"],
        isrc: "usrc17600001",
      )
    ]
    let target = [
      song(id: "tgt", mid: "MID", title: "Real", artist: "Band", album: "LP", isrc: "USRC17600001")
    ]
    let (updates, summary) = MetadataMatcher.plan(source: source, target: target)
    #expect(summary.matchedByISRC == 1)
    #expect(summary.matched == 1)
    #expect(updates.count == 1)
    #expect(updates[0].targetSongID == "tgt")
    #expect(updates[0].genreNames == ["Industrial"])
    // Identity/relations are never in an update; only metadata.
    #expect(updates[0].title == "wrong title") // source-wins (non-empty)
  }

  @Test
  func `music item id matches only within the same namespace`() {
    let source = [song(id: "s", mid: "SHARED", namespace: .library, genres: ["Jazz"])]
    let sameNS = [song(id: "t1", mid: "SHARED", namespace: .library, title: "x", artist: "y", album: "z")]
    let otherNS = [song(id: "t2", mid: "SHARED", namespace: .catalog, title: "x", artist: "y", album: "z")]

    let hit = MetadataMatcher.plan(source: source, target: sameNS)
    #expect(hit.summary.matchedByMusicItemID == 1)
    #expect(hit.updates.first?.genreNames == ["Jazz"])

    let miss = MetadataMatcher.plan(source: source, target: otherNS)
    #expect(miss.summary.matched == 0)
    #expect(miss.updates.isEmpty)
  }

  @Test
  func `title artist album matches case diacritic and whitespace insensitively`() {
    let source = [
      song(id: "s", mid: "A", title: "Café  DEL   Mar", artist: "Énnio", album: "Ibiza", genres: ["Chillout"])
    ]
    let target = [
      song(id: "t", mid: "B", title: "cafe del mar", artist: "ennio", album: "IBIZA")
    ]
    let (updates, summary) = MetadataMatcher.plan(source: source, target: target)
    #expect(summary.matchedByTitleArtistAlbum == 1)
    #expect(updates.first?.genreNames == ["Chillout"])
  }

  @Test
  func `both album absent matches at the exact-album tier`() {
    // Both album-less → normalized album "" == "" → tier 3 (exact) catches
    // it; tier 4 is never reached. Still a correct match + genre copy.
    let source = [song(id: "s", mid: "A", title: "Single", artist: "Act", album: nil, genres: ["Pop"])]
    let target = [song(id: "t", mid: "B", title: "Single", artist: "Act", album: nil)]
    let result = MetadataMatcher.plan(source: source, target: target)
    #expect(result.summary.matchedByTitleArtistAlbum == 1)
    #expect(result.summary.matchedByTitleArtist == 0)
    #expect(result.updates.first?.genreNames == ["Pop"])
  }

  @Test
  func `tier four bridges an album presence mismatch`() {
    // Same recording: album-tagged on the good machine, untagged on the
    // macOS-14 one (or vice versa). Tier 3 (exact album) misses; tier 4
    // (title+artist, one side album-absent) bridges it.
    let source = [song(id: "s", mid: "A", title: "Alive", artist: "PJ", album: "Ten", genres: ["Alt"])]
    let target = [song(id: "t", mid: "B", title: "Alive", artist: "PJ", album: nil)]
    let result = MetadataMatcher.plan(source: source, target: target)
    #expect(result.summary.matchedByTitleArtist == 1)
    #expect(result.updates.first?.genreNames == ["Alt"])
  }

  @Test
  func `two different named albums never link`() {
    // Both carry a non-empty *different* album → tier 3 misses and tier 4
    // is blocked (no album-absent side). A live take's genre must not
    // bleed onto a studio cut.
    let source = [song(id: "s", mid: "A", title: "Song", artist: "Act", album: "Live 1995", genres: ["X"])]
    let target = [song(id: "t", mid: "B", title: "Song", artist: "Act", album: "Studio")]
    let result = MetadataMatcher.plan(source: source, target: target)
    #expect(result.summary.matched == 0)
    #expect(result.updates.isEmpty)
  }

  @Test
  func `coalesce is source wins only when present and never blanks`() throws {
    let source = [
      song(
        id: "s",
        mid: "A",
        title: "Song",
        artist: "Artist",
        album: "Album",
        genres: [], // empty → must NOT blank the target's genres
        isrc: "USX",
        composer: nil, // nil → must NOT blank target composer
      )
    ]
    let target = [
      song(
        id: "t",
        mid: "A",
        title: "Song",
        artist: "Artist",
        album: "Album",
        track: 7,
        genres: ["Rock"],
        isrc: nil,
        composer: "J. Doe",
      )
    ]
    let (updates, _) = MetadataMatcher.plan(source: source, target: target)
    // Only isrc differs (source has it, target doesn't) → exactly one
    // update, and the good target genres/composer are preserved.
    #expect(updates.count == 1)
    let u = try #require(updates.first)
    #expect(u.genreNames == ["Rock"]) // preserved (source empty)
    #expect(u.composerName == "J. Doe") // preserved (source nil)
    #expect(u.isrc == "USX") // filled from source
    #expect(u.trackNumber == 7) // preserved (source nil)
  }

  @Test
  func `a matched but identical song emits no update`() {
    let identical = song(id: "x", mid: "M", title: "T", artist: "A", album: "Al", genres: ["G"], isrc: "I")
    let source = [identical]
    let target = [song(id: "y", mid: "M", title: "T", artist: "A", album: "Al", genres: ["G"], isrc: "I")]
    let (updates, summary) = MetadataMatcher.plan(source: source, target: target)
    #expect(summary.matched == 1) // it WAS matched (by ISRC)
    #expect(summary.updated == 0) // …but nothing changed
    #expect(updates.isEmpty)
  }

  @Test
  func `duplicate source keys deterministically prefer the richer row`() {
    // Two source rows share the ISRC; the one WITH genres must win
    // regardless of input order.
    let withGenres = song(id: "rich", mid: "Z1", genres: ["Soul"], isrc: "DUP")
    let without = song(id: "bare", mid: "Z2", genres: [], isrc: "DUP")
    let target = [song(id: "t", mid: "Q", title: "x", artist: "y", album: "z", isrc: "DUP")]

    let a = MetadataMatcher.plan(source: [withGenres, without], target: target)
    let b = MetadataMatcher.plan(source: [without, withGenres], target: target)
    #expect(a.updates.first?.genreNames == ["Soul"])
    #expect(b.updates.first?.genreNames == ["Soul"])
  }

  @Test
  func `summary tallies matched updated and unmatched`() {
    let source = [
      song(id: "s1", mid: "M1", title: "A", artist: "X", album: "L", genres: ["Pop"]),
      song(id: "s2", mid: "M2", title: "B", artist: "Y", album: "L", genres: ["Rock"]),
    ]
    let target = [
      song(id: "t1", mid: "M1", title: "A", artist: "X", album: "L"), // match, changes
      song(id: "t2", mid: "M2", title: "B", artist: "Y", album: "L", genres: ["Rock"]), // match, no change
      song(id: "t3", mid: "M9", title: "Z", artist: "Q", album: "L"), // unmatched
    ]
    let (_, summary) = MetadataMatcher.plan(source: source, target: target)
    #expect(summary.sourceCount == 2)
    #expect(summary.targetCount == 3)
    #expect(summary.matched == 2)
    #expect(summary.updated == 1)
    #expect(summary.unmatched == 1)
  }

  // MARK: Private

  private func song(
    id: String,
    mid: String = UUID().uuidString,
    namespace: Song.IDNamespace = .library,
    title: String = "Title",
    artist: String = "Artist",
    album: String? = "Album",
    duration: Double? = nil,
    isExplicit: Bool = false,
    track: Int? = nil,
    disc: Int? = nil,
    genres: [String] = [],
    isrc: String? = nil,
    composer: String? = nil,
  ) -> Song {
    Song(
      id: id,
      musicItemID: mid,
      idNamespace: namespace,
      title: title,
      artistName: artist,
      albumTitle: album,
      duration: duration,
      isExplicit: isExplicit,
      importedAt: .now,
      trackNumber: track,
      discNumber: disc,
      genreNames: genres,
      composerName: composer,
      isrc: isrc,
    )
  }

}
