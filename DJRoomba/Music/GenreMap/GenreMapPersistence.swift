import CoreGraphics
import Foundation

// MARK: - GenreMapPersistedState

/// The in-memory shape of the persisted Phase-6 state
/// (`plans/genre-metro-map.md` Phase 6). Built from the `genre_map_state`
/// + `genre_map_strand` tables by `LibraryStore.loadGenreMapState`,
/// fed forward to `GenreMapBuilder.build(..., previousState:)`.
///
/// **Pure.** No SQL knowledge; the store is the only place that talks to
/// GRDB. The builder consumes this without re-reading the DB.
struct GenreMapPersistedState: Equatable, Sendable {
  static let empty = GenreMapPersistedState(
    positions: [:],
    communitiesByGenre: [:],
    strandIDsByGenre: [:],
    strandRowByID: [:],
    revision: 0,
  )

  /// `genre → persisted layout coords`. Initialisation seed for the
  /// force layout (no random scatter when present).
  var positions: [String: CGPoint]
  /// `genre → (coarse, medium, fine)` community id triple. Strings,
  /// because the matching pass mints fresh ids when no high-Jaccard
  /// predecessor exists; strings keep the freshly-minted ids visibly
  /// disjoint from the algorithmic small-int ids the new layout pass
  /// produces inside a single rebuild.
  var communitiesByGenre: [String: GenreMapPersistedCommunityTriple]
  /// `genre → strand ids served` (the persisted Phase-3 strand membership).
  var strandIDsByGenre: [String: [Int]]
  /// Per-strand persisted appearance — colour + label tokens, keyed by
  /// the stable string strand id.
  var strandRowByID: [String: GenreMapPersistedStrandRow]
  /// The revision the persisted rows were written at. The builder bumps
  /// this when it writes the next pass; it is surfaced on the model so
  /// `GenreMapRoutingActor` can invalidate its cache on any rebuild.
  var revision: Int

  var isEmpty: Bool {
    positions.isEmpty && strandRowByID.isEmpty
  }

}

// MARK: - GenreMapPersistedCommunityTriple

/// Persisted community ids at three resolutions for one genre. Strings
/// because matched ids carry the predecessor's algorithmic id stringified
/// (`"42"`), while freshly-minted ids carry a `new-N` prefix; the
/// matching pass routes ids back into the small-int space the builder
/// uses inside a single rebuild.
struct GenreMapPersistedCommunityTriple: Equatable, Hashable, Sendable {
  var coarse: String
  var medium: String
  var fine: String
}

// MARK: - GenreMapPersistedStrandRow

/// One persisted strand's appearance — what the matching pass preserves
/// across rebuilds when member-Jaccard ≥ 0.5.
struct GenreMapPersistedStrandRow: Equatable, Hashable, Sendable {
  var strandID: String
  /// ARGB-packed colour. Stable per strand identity.
  var colour: Int64
  /// TF-IDF label tokens, in rank order.
  var labelTokens: [String]
}

// MARK: - GenreMapPersistence

/// Phase-6 pure logic: community-id matching, strand-id matching, and the
/// initial-position seeding helper the builder consumes
/// (`plans/genre-metro-map.md` Phase 6). All functions are `nonisolated
/// static`, deterministic, free of mutable globals — fully unit-testable
/// on fixtures.
///
/// `MatchThreshold` is the Jaccard cutoff (≥ 0.5 ⇒ reuse predecessor id;
/// below ⇒ mint fresh). Strand matching uses member-set Jaccard — path
/// pairs are not persisted in v9, so the composite weights the spec
/// originally floated never had a path channel to compose against. See
/// `matchStrandsByMembers` for the actual scoring used.
enum GenreMapPersistence {

  /// Member-set Jaccard threshold for community / strand id reuse.
  static let matchThreshold = 0.5

  /// Stability force coefficient `μ` applied to existing nodes only
  /// (Phase 6 step D). The builder applies `μ · (previous_pos −
  /// current_pos)` as an extra restoring force on each step for
  /// previously-known nodes; new nodes are NOT stability-anchored.
  /// Tuned so the layout settles near the persisted positions but
  /// new nodes can still find natural homes around their neighbours.
  static let stabilityForce = 0.05

  /// Match new communities to old by member-set Jaccard at one
  /// resolution. Returns a `newCommunityID -> persistedCommunityID`
  /// map for every new community whose best Jaccard against any old
  /// community at this resolution is ≥ `matchThreshold`. Unmatched
  /// new communities are excluded; the caller mints fresh ids for them.
  ///
  /// "Predecessor" is the *string* persisted id, "successor" is the
  /// algorithmic small-int the new partition produced — keeping the
  /// types disjoint makes the eventual reuse explicit.
  ///
  /// Tie-break: highest Jaccard wins; on ties, the predecessor with
  /// the larger member-set wins; ultimate tie-break is lexicographic
  /// on the predecessor id.
  static func matchCommunities(
    newPartition: [Int: Set<String>],
    oldPartition: [String: Set<String>],
  ) -> [Int: String] {
    var byNewID = [Int: String]()
    // `usedPredecessors` ensures the same persisted community id can't
    // be claimed by two different new communities (the larger new
    // community wins; smaller mints fresh).
    var usedPredecessors = Set<String>()

    let orderedNewIDs = newPartition
      .map { (id: $0.key, members: $0.value) }
      .sorted { lhs, rhs in
        if lhs.members.count != rhs.members.count {
          return lhs.members.count > rhs.members.count
        }
        return lhs.id < rhs.id
      }

    for entry in orderedNewIDs {
      let newMembers = entry.members
      var bestScore = 0.0
      var bestPredecessor: String?
      var bestPredecessorSize = 0
      for (predecessor, oldMembers) in oldPartition {
        if usedPredecessors.contains(predecessor) { continue }
        let score = jaccard(newMembers, oldMembers)
        if score > bestScore {
          bestScore = score
          bestPredecessor = predecessor
          bestPredecessorSize = oldMembers.count
        } else if score == bestScore, let current = bestPredecessor {
          let size = oldMembers.count
          if size > bestPredecessorSize {
            bestPredecessor = predecessor
            bestPredecessorSize = size
          } else if size == bestPredecessorSize, predecessor < current {
            bestPredecessor = predecessor
          }
        }
      }
      if bestScore >= matchThreshold, let predecessor = bestPredecessor {
        byNewID[entry.id] = predecessor
        usedPredecessors.insert(predecessor)
      }
    }

    return byNewID
  }

  /// Match new strands to old by member-set Jaccard. ≥ `matchThreshold`
  /// (0.5) ⇒ reuse the predecessor strand id + colour + label tokens.
  ///
  /// Path-similarity was originally specced as a second channel in a
  /// `0.6 · member + 0.4 · path` composite, but path pairs are not
  /// persisted in v9 (paths are large, re-derived every rebuild). The
  /// only caller never had path pairs to feed in, so the path channel
  /// degenerated to zero. We name it after what it actually computes.
  ///
  /// Tie-break: highest member-Jaccard wins; on ties the predecessor
  /// with the larger member-set wins; ultimate tie-break is lex on the
  /// predecessor id.
  static func matchStrandsByMembers(
    newStrands: [(id: Int, members: Set<String>)],
    oldStrands: [(id: String, members: Set<String>)],
  ) -> [Int: String] {
    var byNewID = [Int: String]()
    var usedPredecessors = Set<String>()

    let ordered = newStrands
      .sorted { lhs, rhs in
        if lhs.members.count != rhs.members.count {
          return lhs.members.count > rhs.members.count
        }
        return lhs.id < rhs.id
      }

    for newStrand in ordered {
      var bestScore = 0.0
      var bestPredecessor: String?
      var bestPredecessorSize = 0
      for old in oldStrands {
        if usedPredecessors.contains(old.id) { continue }
        let score = jaccard(newStrand.members, old.members)
        if score > bestScore {
          bestScore = score
          bestPredecessor = old.id
          bestPredecessorSize = old.members.count
        } else if score == bestScore, let current = bestPredecessor {
          if old.members.count > bestPredecessorSize {
            bestPredecessor = old.id
            bestPredecessorSize = old.members.count
          } else if old.members.count == bestPredecessorSize, old.id < current {
            bestPredecessor = old.id
          }
        }
      }
      if bestScore >= matchThreshold, let predecessor = bestPredecessor {
        byNewID[newStrand.id] = predecessor
        usedPredecessors.insert(predecessor)
      }
    }

    return byNewID
  }

  /// Symmetric set Jaccard. `|A ∩ B| / |A ∪ B|`; zero when both empty.
  static func jaccard<Element: Hashable>(_ lhs: Set<Element>, _ rhs: Set<Element>) -> Double {
    if lhs.isEmpty, rhs.isEmpty { return 0 }
    let intersection = lhs.intersection(rhs).count
    let union = lhs.union(rhs).count
    if union == 0 { return 0 }
    return Double(intersection) / Double(union)
  }

  /// Serialise an array of integer strand ids to the JSON-array shape
  /// the v9 `genre_map_state.strand_ids` column expects.
  static func encodeStrandIDs(_ ids: [Int]) -> String {
    let trimmed = ids.sorted()
    if trimmed.isEmpty { return "[]" }
    let joined = trimmed.map(String.init).joined(separator: ",")
    return "[\(joined)]"
  }

  /// Inverse of `encodeStrandIDs`. Tolerant of whitespace, missing
  /// brackets, and empty arrays. Invalid input ⇒ empty array.
  static func decodeStrandIDs(_ raw: String) -> [Int] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard
      let data = trimmed.data(using: .utf8),
      let ids = try? JSONDecoder().decode([Int].self, from: data)
    else {
      return []
    }
    return ids
  }

  /// Serialise label tokens. Same shape as the `strand_ids` encoder but
  /// for strings.
  static func encodeLabelTokens(_ tokens: [String]) -> String {
    let data = try? JSONEncoder().encode(tokens)
    return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
  }

  static func decodeLabelTokens(_ raw: String) -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard
      let data = trimmed.data(using: .utf8),
      let tokens = try? JSONDecoder().decode([String].self, from: data)
    else {
      return []
    }
    return tokens
  }
}
