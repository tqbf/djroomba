import Foundation

// MARK: - GenreTreeListenPicker

/// Pure track picker for the Phase D "Listen to this" affordance
/// (`plans/son-of-genre-map.md` Phase D). Given a candidate list of
/// `song_genre`-joined songs for a single genre, returns a short
/// deterministic playlist suitable either for a transient queue or a
/// saved "Genre Tree: <name>" app playlist.
///
/// **Algorithm.**
///
/// 1. Sort candidates by `playCount` descending (heaviest-played
///    first). Ties broken by `lastPlayedAt` descending (newer first),
///    then by `title` ascending for deterministic order.
/// 2. Walk the sorted list and admit each song while respecting an
///    **artist-diversity cap**: no single artist may contribute more
///    than `maxPerArtist` songs to the picked list. Songs over the
///    cap are skipped, not pushed to the end — by then the user has
///    already heard plenty of that artist.
/// 3. Stop when `targetCount` songs have been admitted or candidates
///    are exhausted.
///
/// Returned in admission order (heavy-and-diverse first), so a queue
/// built from the result feels front-loaded — the first track is the
/// one the user is most likely to recognise as "this genre."
///
/// Pure, `nonisolated`, no I/O. The caller (panel) fetches the
/// candidates via the existing `LibraryStore.songsWithStats(matching
/// Genre:)` read and hands them in.
enum GenreTreeListenPicker {

  /// One picked row. Holds only what the caller needs to wire
  /// playback (the SQLite `song.id`) and rendering (a display string +
  /// the per-genre rank). Sendable so it can be passed across actor
  /// boundaries to the picker UI without conversion.
  struct PickedSong: Equatable, Sendable {
    var songID: String
    var title: String
    var artistName: String
    var playCount: Int
  }

  /// One input row. A struct of just the fields the picker needs,
  /// so tests can drive the algorithm without standing up the full
  /// `Song` GRDB record.
  struct Candidate: Equatable, Sendable {

    // MARK: Lifecycle

    init(
      songID: String,
      title: String,
      artistName: String,
      playCount: Int,
      lastPlayedAt: Date? = nil,
    ) {
      self.songID = songID
      self.title = title
      self.artistName = artistName
      self.playCount = playCount
      self.lastPlayedAt = lastPlayedAt
    }

    // MARK: Internal

    var songID: String
    var title: String
    var artistName: String
    var playCount: Int
    var lastPlayedAt: Date?

  }

  /// Default playlist length per the plan's Phase D defaults.
  /// Front-loads enough variety to feel like a curated listen without
  /// becoming an album-length commitment.
  static let defaultTargetCount = 30

  /// Default per-artist cap. Three keeps a single prolific artist
  /// from monopolising the picked list while still letting a heavily-
  /// played artist contribute their best three tracks.
  static let defaultMaxPerArtist = 3

  /// Deterministic top-N pick with artist-diversity cap. Pure.
  static func pick(
    from candidates: [Candidate],
    targetCount: Int = defaultTargetCount,
    maxPerArtist: Int = defaultMaxPerArtist,
  ) -> [PickedSong] {
    guard targetCount > 0, maxPerArtist > 0 else { return [] }
    let sorted = candidates.sorted { lhs, rhs in
      if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
      switch (lhs.lastPlayedAt, rhs.lastPlayedAt) {
      case (let l?, let r?):
        if l != r { return l > r }
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        break
      }
      if lhs.title != rhs.title { return lhs.title < rhs.title }
      return lhs.songID < rhs.songID
    }
    var perArtist = [String: Int]()
    var picks = [PickedSong]()
    picks.reserveCapacity(min(targetCount, sorted.count))
    for candidate in sorted {
      if picks.count >= targetCount { break }
      let artistKey = candidate.artistName.lowercased()
      let used = perArtist[artistKey, default: 0]
      if used >= maxPerArtist { continue }
      perArtist[artistKey] = used + 1
      picks.append(PickedSong(
        songID: candidate.songID,
        title: candidate.title,
        artistName: candidate.artistName,
        playCount: candidate.playCount,
      ))
    }
    return picks
  }
}
