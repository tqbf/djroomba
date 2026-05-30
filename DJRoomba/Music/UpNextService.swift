import Foundation
import MusicKit
import Observation

/// The **ephemeral "play these next" queue** (`plans/up-next-queue.md`).
/// In-memory only — lost on quit by design; the user's "I just relaunched"
/// case is Phase 5's auto-fill toggle's job. Peer of
/// `RecentlyPlayedService`: `@MainActor @Observable final class`, pure
/// synchronous mutators (no I/O), and views bind to `entries` directly so
/// Observation tracks the array reads and invalidates on mutation.
///
/// Two parallel arrays in / one denormalised `Entry` out: callers hand us
/// `(songs, musicItemIDs)` already paired at the call site — the resolved
/// `MusicItemID` is captured *once at add-time* and never re-derived from a
/// SQLite round trip at play time (the catalog re-resolution boundary
/// `[[canonicalize-not-apple-ids]]` warns against). Each `Entry` carries
/// the full `Song` snapshot it needs to render (title, artist, album,
/// artwork ref), so the queue table renders without a per-row store fetch
/// and is unaffected by mid-queue library mutation. Position arithmetic
/// is **1-based** everywhere — matches `TrackRow.position` and the
/// `up_next_get(start, end)` GPT tool's contract.
@MainActor
@Observable
final class UpNextService {

  // MARK: Lifecycle

  init() { }

  // MARK: Internal

  /// A single queued track. `id: UUID` is stable for `ForEach` /
  /// `Set` selection across mutations (the same song re-added at a
  /// different position is a different entry); `song` is the denormalised
  /// snapshot taken at add-time; `musicItemID` is the resolved MusicKit
  /// id we hand straight to the playback resolver (avoids a SQLite
  /// round-trip per play).
  struct Entry: Identifiable, Hashable {
    init(song: Song, musicItemID: MusicItemID, id: UUID = UUID()) {
      self.id = id
      self.song = song
      self.musicItemID = musicItemID
    }

    let id: UUID
    let song: Song
    let musicItemID: MusicItemID

  }

  private(set) var entries = [Entry]()

  var count: Int {
    entries.count
  }

  var isEmpty: Bool {
    entries.isEmpty
  }

  /// Push to tail. Paired arrays — `songs[k]` is paired with
  /// `musicItemIDs[k]`. Empty input is a harmless no-op; mismatched
  /// counts is a programmer error (the call site builds both arrays in
  /// the same loop and must keep them aligned).
  func append(_ songs: [Song], musicItemIDs: [MusicItemID]) {
    precondition(
      songs.count == musicItemIDs.count,
      "UpNextService.append: songs (\(songs.count)) and musicItemIDs (\(musicItemIDs.count)) must be paired",
    )
    guard !songs.isEmpty else { return }
    entries.append(contentsOf: makeEntries(songs: songs, musicItemIDs: musicItemIDs))
  }

  /// 1-based insert; `position` is clamped to `[1, count + 1]` (so `1`
  /// is "push to head", `count + 1` is "push to tail", and any
  /// out-of-range value collapses to whichever bound is closer rather
  /// than throwing). Empty input is a no-op. Paired arrays.
  func insert(_ songs: [Song], musicItemIDs: [MusicItemID], at position: Int) {
    precondition(
      songs.count == musicItemIDs.count,
      "UpNextService.insert: songs (\(songs.count)) and musicItemIDs (\(musicItemIDs.count)) must be paired",
    )
    guard !songs.isEmpty else { return }
    let clamped = clampInsertPosition(position)
    let newEntries = makeEntries(songs: songs, musicItemIDs: musicItemIDs)
    entries.insert(contentsOf: newEntries, at: clamped - 1)
  }

  /// 1-based removal. Dedup + sort-descending so a multi-row remove is
  /// index-stable (removing from the tail first means earlier indices
  /// stay valid). Out-of-range positions are silently skipped — a noisy
  /// `precondition` here would punish a stale UI selection set, which
  /// is the common case (the user multi-selected, the queue mutated,
  /// the selection refers to since-removed rows).
  func remove(at positions: [Int]) {
    guard !entries.isEmpty else { return }
    let descending = Set(positions).sorted(by: >)
    let valid = 1...entries.count
    for position in descending where valid.contains(position) {
      entries.remove(at: position - 1)
    }
  }

  func clear() {
    guard !entries.isEmpty else { return }
    entries.removeAll()
  }

  /// 1-based "move these positions to the head", preserving the
  /// **relative order** of the picked rows. Dedup + sort ascending so
  /// the picked rows land in their existing order even when the caller
  /// hands us an unsorted/duplicated `Set`. Out-of-range positions are
  /// silently skipped (same tolerance as `remove`); no-op on an empty
  /// queue or when nothing valid was picked. Cheap on the queue's
  /// expected scale (~10 entries) — single in-place rearrange.
  func moveToTop(positions: [Int]) {
    guard !entries.isEmpty else { return }
    let valid = 1...entries.count
    let ascending = Set(positions).sorted().filter { valid.contains($0) }
    guard !ascending.isEmpty, ascending.count < entries.count else {
      // Either nothing selected or every entry selected — both no-op.
      return
    }
    let pickedIndices = ascending.map { $0 - 1 }
    let pickedIndexSet = Set(pickedIndices)
    let picked = pickedIndices.map { entries[$0] }
    let rest = entries.enumerated()
      .compactMap { pickedIndexSet.contains($0.offset) ? nil : $0.element }
    entries = picked + rest
  }

  /// Remove + return the head entry (1-based position 1). Used by the
  /// playback-dominance hook: end-of-song / Next pops the head and
  /// starts a one-song queue with it.
  func popHead() -> Entry? {
    guard !entries.isEmpty else { return nil }
    return entries.removeFirst()
  }

  /// Remove `[1...position]` (1-based, inclusive) and return the entry
  /// at `position` — the "user clicked queue row #5" semantics: play
  /// #5, drop #1–#5 in one shot so what's *visible* in the queue
  /// always matches what's about to play next. Out-of-range `position`
  /// (≤ 0 or > count) returns `nil` and mutates nothing.
  func consumeThrough(position: Int) -> Entry? {
    guard !entries.isEmpty, (1...entries.count).contains(position) else { return nil }
    let picked = entries[position - 1]
    entries.removeFirst(position)
    return picked
  }

  /// Slice of `entries` over the 1-based inclusive range `[start, end]`,
  /// clamped to the live queue. Out-of-range or swapped args collapse
  /// to `[]` rather than throwing — the GPT `up_next_get` tool reads
  /// untrusted indices from the model and the natural response to a
  /// nonsense range is "no entries" plus the queue's true count.
  func range(_ start: Int, _ end: Int) -> [Entry] {
    guard !entries.isEmpty, start <= end else { return [] }
    let lower = max(1, start)
    let upper = min(entries.count, end)
    guard lower <= upper else { return [] }
    return Array(entries[(lower - 1)...(upper - 1)])
  }

  // MARK: Private

  /// Build the `Entry` value array from the paired input. Single
  /// place mapping so `append` and `insert` can't drift on how they
  /// mint ids / pair fields.
  private func makeEntries(songs: [Song], musicItemIDs: [MusicItemID]) -> [Entry] {
    zip(songs, musicItemIDs).map { song, musicItemID in
      Entry(song: song, musicItemID: musicItemID)
    }
  }

  /// 1-based insert position clamped to `[1, count + 1]`. `count + 1`
  /// is the legal "append to tail" sentinel, so an empty queue accepts
  /// `1` exactly — which `clampInsertPosition` also returns for any
  /// non-positive input.
  private func clampInsertPosition(_ position: Int) -> Int {
    min(max(position, 1), entries.count + 1)
  }
}
