import Foundation
import Observation

/// Incremental, case-insensitive node search with ranked matching.
///
/// The headline "type-anywhere" affordance: as the user types over the graph
/// this recomputes the match set every keystroke and ranks it
/// **exact-prefix > word-boundary-prefix > subsequence/fuzzy**. It also tracks
/// the "active" match for `↑/↓` cycling and exposes a *narrow-to-one* signal
/// (exactly one match) so the engine can ease that node to centre.
///
/// `@Observable @MainActor`, owned by `GraphEngine` (the single facade) — it is
/// not the public `@Observable`; the engine reads it and folds the result into
/// the immutable `RenderSnapshot`. Matching is pure and cheap: a single linear
/// pass over the (label, id) pairs scoring each — well under a millisecond on
/// the 1,594-node corpus, so it stays instant per keystroke.
@Observable
@MainActor
final class SearchModel {
    /// How well a candidate matched, best-first. Raw value is the rank key
    /// (lower = better) so sorting is a plain comparison.
    enum MatchKind: Int, Comparable, Sendable {
        /// The query is a case-insensitive prefix of the whole label.
        case exactPrefix = 0
        /// The query is a prefix of some word inside the label
        /// (word = run after a space / `-` / `&` / `/`).
        case wordPrefix = 1
        /// The query characters appear in order but not contiguously.
        case subsequence = 2

        static func < (lhs: MatchKind, rhs: MatchKind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// One ranked hit. `tieBreak` orders within a `kind` (earlier match
    /// position, then shorter label, then label A→Z) so results are stable
    /// and feel sensible as the user keeps typing.
    struct Match: Sendable {
        let id: NodeID
        let kind: MatchKind
        let position: Int
        let labelLength: Int
        let label: String
    }

    /// The live query. Empty ⇒ search inactive (no dimming, no HUD).
    private(set) var query = ""

    /// Ranked matches for the current query (best first). Empty when the
    /// query is empty *or* nothing matched.
    private(set) var matches: [Match] = []

    /// Index into `matches` of the "active" hit `↑/↓` cycles through, or
    /// `nil` when there are no matches. Defaults to the top match.
    private(set) var activeMatchIndex: Int?

    /// Search is "active" (drives dimming + HUD) the moment there is any
    /// query text — even if nothing matches yet, so the HUD can say "0".
    var isActive: Bool { !query.isEmpty }

    /// Exactly one node matched → the engine eases it to centre (it is *not*
    /// auto-selected; centring ≠ relayout, per the interaction spec).
    var narrowedToOne: NodeID? {
        matches.count == 1 ? matches[0].id : nil
    }

    /// The current active match's node id (`Return` selects this; `↑/↓`
    /// re-centres on it).
    var activeMatchID: NodeID? {
        guard let activeMatchIndex, matches.indices.contains(activeMatchIndex) else {
            return nil
        }
        return matches[activeMatchIndex].id
    }

    /// The top-ranked match (what `Return` selects when nothing was cycled).
    var topMatchID: NodeID? { matches.first?.id }

    /// Just the matched ids, for O(1) membership tests while building the
    /// snapshot / dimming edges.
    private(set) var matchIDs: Set<NodeID> = []

    /// The corpus the query runs against: `(id, label, lowercased label)`.
    /// Lowercasing once on rebuild keeps every keystroke allocation-light.
    private struct Candidate {
        let id: NodeID
        let label: String
        let lowerLabel: String
    }

    private var candidates: [Candidate] = []

    // MARK: - Corpus

    /// Refresh the searchable corpus (called when the graph changes). Keeps
    /// the current query but re-evaluates it against the new nodes.
    func setCorpus(ids: [NodeID], labels: [String]) {
        candidates = zip(ids, labels).map {
            Candidate(id: $0, label: $1, lowerLabel: $1.lowercased())
        }
        recompute()
    }

    // MARK: - Query editing

    /// Append a printable character (the type-anywhere fast path).
    func append(_ character: Character) {
        query.append(character)
        recompute()
    }

    /// Backspace: drop the last character. No-op on an empty query.
    func deleteBackward() {
        guard !query.isEmpty else { return }
        query.removeLast()
        recompute()
    }

    /// Replace the whole query (used by `⌘F` paste-style edits / tests).
    func setQuery(_ newQuery: String) {
        guard newQuery != query else { return }
        query = newQuery
        recompute()
    }

    /// `Esc`: clear the query and the match set entirely (no relayout —
    /// the engine just restores full colour).
    func clear() {
        guard !query.isEmpty || !matches.isEmpty else { return }
        query = ""
        matches = []
        matchIDs = []
        activeMatchIndex = nil
    }

    // MARK: - Match cycling (↑/↓)

    /// Advance the active match (wraps). The engine re-centres on the new
    /// active node. No-op with no matches.
    func cycleForward() {
        guard !matches.isEmpty else { return }
        let current = activeMatchIndex ?? -1
        activeMatchIndex = (current + 1) % matches.count
    }

    /// Step the active match backward (wraps).
    func cycleBackward() {
        guard !matches.isEmpty else { return }
        let current = activeMatchIndex ?? 0
        activeMatchIndex = (current - 1 + matches.count) % matches.count
    }

    // MARK: - Matching

    /// Re-rank every candidate for the current query. One linear pass +
    /// one sort; pure and allocation-light so it stays instant per keystroke.
    private func recompute() {
        guard !query.isEmpty else {
            matches = []
            matchIDs = []
            activeMatchIndex = nil
            return
        }
        let needle = query.lowercased()
        var hits: [Match] = []
        hits.reserveCapacity(64)
        for candidate in candidates {
            guard let scored = Self.score(needle: needle, candidate: candidate) else {
                continue
            }
            hits.append(scored)
        }
        hits.sort(by: Self.isBetter)
        matches = hits
        matchIDs = Set(hits.map(\.id))
        activeMatchIndex = hits.isEmpty ? nil : 0
    }

    /// Score one candidate against the (already-lowercased) needle, or `nil`
    /// if it does not match at all. The needle is non-empty.
    private static func score(needle: String, candidate: Candidate) -> Match? {
        let hay = candidate.lowerLabel

        // 1. Exact prefix of the whole label — the strongest signal.
        if hay.hasPrefix(needle) {
            return Match(
                id: candidate.id,
                kind: .exactPrefix,
                position: 0,
                labelLength: hay.count,
                label: candidate.label
            )
        }

        // 2. Prefix of any interior word (after a separator).
        if let wordPos = wordBoundaryPrefix(needle: needle, hay: hay) {
            return Match(
                id: candidate.id,
                kind: .wordPrefix,
                position: wordPos,
                labelLength: hay.count,
                label: candidate.label
            )
        }

        // 3. Subsequence / fuzzy: needle chars appear in order. `position`
        //    is the index of the first needle char so a tighter, earlier
        //    match sorts ahead.
        if let firstPos = subsequencePosition(needle: needle, hay: hay) {
            return Match(
                id: candidate.id,
                kind: .subsequence,
                position: firstPos,
                labelLength: hay.count,
                label: candidate.label
            )
        }

        return nil
    }

    /// A word boundary is the start of the string or any position right after
    /// a space, `-`, `&`, `/`, `_` or `.`. Returns the boundary offset of the
    /// first word the needle prefixes, or `nil`.
    private static func wordBoundaryPrefix(needle: String, hay: String) -> Int? {
        let separators: Set<Character> = [" ", "-", "&", "/", "_", ".", "'"]
        let chars = Array(hay)
        var index = 0
        while index < chars.count {
            let atBoundary = index == 0 || separators.contains(chars[index - 1])
            if atBoundary, !separators.contains(chars[index]) {
                if matchesPrefix(needle: needle, chars: chars, from: index) {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private static func matchesPrefix(
        needle: String,
        chars: [Character],
        from start: Int
    ) -> Bool {
        var hayIndex = start
        for needleChar in needle {
            guard hayIndex < chars.count, chars[hayIndex] == needleChar else {
                return false
            }
            hayIndex += 1
        }
        return true
    }

    /// Index of the first needle character within `hay` for an in-order
    /// (not necessarily contiguous) subsequence match, or `nil`.
    private static func subsequencePosition(needle: String, hay: String) -> Int? {
        var firstPosition: Int?
        var hayChars = hay.makeIterator()
        var index = 0
        var needleChars = needle.makeIterator()
        guard var wanted = needleChars.next() else { return nil }
        while let c = hayChars.next() {
            if c == wanted {
                if firstPosition == nil { firstPosition = index }
                if let nextWanted = needleChars.next() {
                    wanted = nextWanted
                } else {
                    return firstPosition
                }
            }
            index += 1
        }
        return nil
    }

    /// Total order over matches: kind first, then earliest match position,
    /// then shorter label, then label A→Z (stable, intuitive).
    private static func isBetter(_ lhs: Match, _ rhs: Match) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.position != rhs.position { return lhs.position < rhs.position }
        if lhs.labelLength != rhs.labelLength {
            return lhs.labelLength < rhs.labelLength
        }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }
}
