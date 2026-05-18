import Foundation

// MARK: - MetadataUpdate

/// A planned metadata write for one matched target (current-library) song.
/// The values are **already coalesced** (source-wins-only-when-present) so
/// the store applies them verbatim in one batched statement.
///
/// Identity/relations are intentionally absent: `id`, `local_id`,
/// `music_item_id`, `id_namespace`, `imported_at` are never written. That
/// is precisely what keeps every playlist/history foreign key intact — a
/// metadata merge, not a library replace ("I don't want to blitz the
/// library" — `plans/snapshot-export-import.md`).
struct MetadataUpdate: Equatable, Sendable {
  let targetSongID: String
  var title: String
  var artistName: String
  var albumTitle: String?
  var duration: Double?
  var isExplicit: Bool
  var trackNumber: Int?
  var discNumber: Int?
  var genreNames: [String]
  var releaseDate: Date?
  var composerName: String?
  var isrc: String?
  var hasLyrics: Bool?
  var workName: String?
  var movementName: String?
}

// MARK: - SnapshotMergeSummary

/// The pure, user-facing tally of a merge. Lives here (not the view) so the
/// wording is unit-testable with no DB — the codebase's established
/// pure-decider pattern (`ImportActivity.text`, `LibrarySidebarState`).
struct SnapshotMergeSummary: Equatable, Sendable {
  var sourceCount = 0
  var targetCount = 0
  var matchedByISRC = 0
  var matchedByMusicItemID = 0
  var matchedByTitleArtistAlbum = 0
  var matchedByTitleArtist = 0
  /// Matched songs whose metadata actually differed — i.e. `MetadataUpdate`
  /// rows emitted. A matched-but-identical song is not counted here (the
  /// number stays honest).
  var updated = 0

  var matched: Int {
    matchedByISRC + matchedByMusicItemID + matchedByTitleArtistAlbum + matchedByTitleArtist
  }

  var unmatched: Int {
    max(0, targetCount - matched)
  }

  /// One quiet line for the toolbar chip; the popover shows `details`.
  var headline: String {
    "Updated ^[\(updated) song](inflect: true) from the snapshot"
  }

  var details: String {
    """
    Matched \(matched) of \(targetCount) library songs against \
    \(sourceCount) in the snapshot; \(updated) had metadata to update, \
    \(unmatched) were not found.

    By ISRC: \(matchedByISRC) · by Apple id: \(matchedByMusicItemID) · \
    by title/artist/album: \(matchedByTitleArtistAlbum) · \
    by title/artist: \(matchedByTitleArtist).
    """
  }
}

// MARK: - MetadataMatcher

/// Pure, `nonisolated`, no-DB tiered matcher: snapshot songs (**source**)
/// → current-library songs (**target**). The two DBs come from the same
/// Apple Music account on different Macs, so nothing app-minted is shared
/// (`song.id`/`local_id` are per-machine; library `MusicItemID`s are not
/// reliably stable across machines — the D1 finding). Matching is therefore
/// content-based and tiered; first hit wins; fully deterministic.
///
/// Tiers (see `plans/snapshot-export-import.md`):
///  1. ISRC (uppercased/trimmed, both non-empty) — globally stable.
///  2. `music_item_id` (same namespace) — a free true positive when the
///     account's library ids happen to coincide; never the only key.
///  3. normalized (title, artist, album).
///  4. normalized (title, artist) — only when album is absent on **both**
///     sides, so a different pressing's genre can never bleed across an
///     album boundary.
enum MetadataMatcher {

  // MARK: Internal

  /// Normalize a free-text key part: case- and diacritic-insensitive,
  /// trimmed, internal whitespace collapsed. Deliberately conservative —
  /// no remaster/parenthetical stripping (that risks merging genuinely
  /// different recordings; explicitly out of scope).
  static func normalize(_ value: String?) -> String {
    guard let value else { return "" }
    let folded = value.folding(
      options: [.diacriticInsensitive, .caseInsensitive],
      locale: nil,
    )
    return folded
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
  }

  /// Trimmed/uppercased ISRC, or `nil` when empty — only a non-empty ISRC
  /// on **both** sides is a tier-1 match.
  static func normalizedISRC(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .uppercased()
    return trimmed.isEmpty ? nil : trimmed
  }

  /// Plan the merge. Returns the updates to apply (only songs whose
  /// metadata actually changes) plus the tally for the UI.
  static func plan(
    source: [Song],
    target: [Song],
  ) -> (updates: [MetadataUpdate], summary: SnapshotMergeSummary) {
    var summary = SnapshotMergeSummary(
      sourceCount: source.count,
      targetCount: target.count,
    )

    // Source indexes. On a duplicate key keep the "richer" row
    // deterministically so the choice never depends on input order.
    var byISRC = [String: Song]()
    var byMusicItemID = [MusicItemKey: Song]()
    var byTitleArtistAlbum = [TitleKey: Song]()
    var byTitleArtist = [TitleKey: Song]()

    for song in source {
      if let isrc = normalizedISRC(song.isrc) {
        merge(song, into: &byISRC, key: isrc)
      }
      let midKey = MusicItemKey(id: song.musicItemID, namespace: song.idNamespace)
      merge(song, into: &byMusicItemID, key: midKey)

      let title = normalize(song.title)
      let artist = normalize(song.artistName)
      let album = normalize(song.albumTitle)
      merge(
        song,
        into: &byTitleArtistAlbum,
        key: TitleKey(title: title, artist: artist, album: album),
      )
      // Tier 4 index spans ALL source rows keyed by title+artist only
      // (album dimension dropped). The album-boundary guard lives at
      // lookup time (`bestMatch`): tier 4 is consulted only after the
      // exact-album tier 3 misses, and accepted only when album is absent
      // on a side — so two *different named* albums never link, but the
      // same recording album-tagged on one machine and untagged on the
      // other does.
      merge(
        song,
        into: &byTitleArtist,
        key: TitleKey(title: title, artist: artist, album: ""),
      )
    }

    var updates = [MetadataUpdate]()
    updates.reserveCapacity(target.count)

    for targetSong in target {
      guard
        let (sourceSong, tier) = bestMatch(
          for: targetSong,
          byISRC: byISRC,
          byMusicItemID: byMusicItemID,
          byTitleArtistAlbum: byTitleArtistAlbum,
          byTitleArtist: byTitleArtist,
        )
      else { continue }

      switch tier {
      case .isrc: summary.matchedByISRC += 1
      case .musicItemID: summary.matchedByMusicItemID += 1
      case .titleArtistAlbum: summary.matchedByTitleArtistAlbum += 1
      case .titleArtist: summary.matchedByTitleArtist += 1
      }

      let coalesced = coalesce(source: sourceSong, target: targetSong)
      if changes(coalesced, from: targetSong) {
        updates.append(coalesced)
        summary.updated += 1
      }
    }

    return (updates, summary)
  }

  // MARK: Private

  private enum Tier {
    case isrc
    case musicItemID
    case titleArtistAlbum
    case titleArtist
  }

  private struct MusicItemKey: Hashable {
    let id: String
    let namespace: Song.IDNamespace
  }

  private struct TitleKey: Hashable {
    let title: String
    let artist: String
    let album: String
  }

  /// Insert `song` at `key`, or replace an existing entry only if `song`
  /// is the richer record — order-independent so the index is
  /// deterministic regardless of source row order.
  private static func merge<K>(
    _ song: Song,
    into index: inout [K: Song],
    key: K,
  ) {
    guard let existing = index[key] else {
      index[key] = song
      return
    }
    if prefer(song, over: existing) {
      index[key] = song
    }
  }

  /// Deterministic "richer record" order: a row with genres beats one
  /// without; then more populated metadata fields; final tiebreak is
  /// `music_item_id` ascending (stable, and only ever a tiebreaker among
  /// the snapshot's own rows — never used as an app key).
  private static func prefer(_ candidate: Song, over incumbent: Song) -> Bool {
    let candidateHasGenres = !candidate.genreNames.isEmpty
    let incumbentHasGenres = !incumbent.genreNames.isEmpty
    if candidateHasGenres != incumbentHasGenres {
      return candidateHasGenres
    }
    let candidateScore = populatedFieldCount(candidate)
    let incumbentScore = populatedFieldCount(incumbent)
    if candidateScore != incumbentScore {
      return candidateScore > incumbentScore
    }
    return candidate.musicItemID < incumbent.musicItemID
  }

  private static func populatedFieldCount(_ song: Song) -> Int {
    var count = 0
    if !song.genreNames.isEmpty { count += 1 }
    if song.trackNumber != nil { count += 1 }
    if song.discNumber != nil { count += 1 }
    if song.releaseDate != nil { count += 1 }
    if hasText(song.composerName) { count += 1 }
    if normalizedISRC(song.isrc) != nil { count += 1 }
    if song.hasLyrics != nil { count += 1 }
    if hasText(song.workName) { count += 1 }
    if hasText(song.movementName) { count += 1 }
    if hasText(song.albumTitle) { count += 1 }
    if song.duration != nil { count += 1 }
    return count
  }

  private static func bestMatch(
    for target: Song,
    byISRC: [String: Song],
    byMusicItemID: [MusicItemKey: Song],
    byTitleArtistAlbum: [TitleKey: Song],
    byTitleArtist: [TitleKey: Song],
  ) -> (Song, Tier)? {
    if
      let isrc = normalizedISRC(target.isrc),
      let hit = byISRC[isrc]
    {
      return (hit, .isrc)
    }
    if
      let hit = byMusicItemID[
        MusicItemKey(id: target.musicItemID, namespace: target.idNamespace)
      ]
    {
      return (hit, .musicItemID)
    }
    let title = normalize(target.title)
    let artist = normalize(target.artistName)
    let album = normalize(target.albumTitle)
    if
      let hit = byTitleArtistAlbum[
        TitleKey(title: title, artist: artist, album: album)
      ]
    {
      return (hit, .titleArtistAlbum)
    }
    // Tier 4: title+artist, accepted only when album is absent on a side
    // (the target's, or the matched source's). Tier 3 (exact album, where
    // both-absent already agrees as "") has been tried and missed, so two
    // rows that BOTH carry non-empty albums here necessarily have
    // *different* albums and must NOT link — this guard enforces that.
    if
      let hit = byTitleArtist[
        TitleKey(title: title, artist: artist, album: "")
      ],
      album.isEmpty || normalize(hit.albumTitle).isEmpty
    {
      return (hit, .titleArtist)
    }
    return nil
  }

  /// Source-wins-**only-when-present**: a populated source field overrides
  /// the target; an empty source field leaves the target's value intact
  /// (never blanks good data). `isExplicit`/`duration` take the source's
  /// value (the snapshot is the good library) but `duration` falls back to
  /// the target when the source has none.
  private static func coalesce(source: Song, target: Song) -> MetadataUpdate {
    MetadataUpdate(
      targetSongID: target.id,
      title: hasText(source.title) ? source.title : target.title,
      artistName: hasText(source.artistName) ? source.artistName : target.artistName,
      albumTitle: pickText(source.albumTitle, target.albumTitle),
      duration: source.duration ?? target.duration,
      isExplicit: source.isExplicit,
      trackNumber: source.trackNumber ?? target.trackNumber,
      discNumber: source.discNumber ?? target.discNumber,
      genreNames: source.genreNames.isEmpty ? target.genreNames : source.genreNames,
      releaseDate: source.releaseDate ?? target.releaseDate,
      composerName: pickText(source.composerName, target.composerName),
      isrc: pickText(source.isrc, target.isrc),
      hasLyrics: source.hasLyrics ?? target.hasLyrics,
      workName: pickText(source.workName, target.workName),
      movementName: pickText(source.movementName, target.movementName),
    )
  }

  /// True iff applying `update` would change at least one stored column —
  /// so a matched-but-identical song emits no write and isn't counted as
  /// "updated".
  private static func changes(_ update: MetadataUpdate, from song: Song) -> Bool {
    update.title != song.title
      || update.artistName != song.artistName
      || update.albumTitle != song.albumTitle
      || update.duration != song.duration
      || update.isExplicit != song.isExplicit
      || update.trackNumber != song.trackNumber
      || update.discNumber != song.discNumber
      || update.genreNames != song.genreNames
      || update.releaseDate != song.releaseDate
      || update.composerName != song.composerName
      || update.isrc != song.isrc
      || update.hasLyrics != song.hasLyrics
      || update.workName != song.workName
      || update.movementName != song.movementName
  }

  private static func hasText(_ value: String?) -> Bool {
    guard let value else { return false }
    return !value.isEmpty
  }

  private static func pickText(_ source: String?, _ target: String?) -> String? {
    hasText(source) ? source : target
  }
}
