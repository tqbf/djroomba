import Foundation

/// Pure, no-DB genre-list transforms — the codebase's established
/// pure-decider pattern (`DetailNavStack`, `ImportActivity`,
/// `MetadataMatcher`). `LibraryStore` reads the affected songs, applies
/// these in Swift, and batch-writes only the rows that changed.
///
/// Genres are **literal tag matches** the way the genre graph / browser
/// already treat them: the genre query is `TRIM(je.value) = ?`, so all
/// comparison here is trim-based to match exactly. This is why **rename
/// merges for free** — there is no genre entity, only the tag string, so
/// renaming `A → B` on a song that already has `B` and then de-duplicating
/// is the merge.
enum GenreEdit {

  // MARK: Internal

  /// Rewrite `names`: every element trimming-equal to `from` becomes the
  /// trimmed `to`, then the list is de-duplicated **preserving
  /// first-occurrence order** and emptied entries dropped. Returns the new
  /// list, or `nil` when it is unchanged (so the store writes only changed
  /// rows and the "N updated" count stays honest).
  ///
  /// Merge case: a song carrying both `from` and `to` collapses to a
  /// single `to` — exactly the union the post-rename genre query returns.
  static func renaming(
    _ names: [String],
    from: String,
    to: String,
  ) -> [String]? {
    let fromKey = trimmed(from)
    let toValue = trimmed(to)
    guard !fromKey.isEmpty, !toValue.isEmpty else { return nil }

    let rewritten = names.map { trimmed($0) == fromKey ? toValue : $0 }
    let result = dedupedPreservingOrder(rewritten)
    return result == names ? nil : result
  }

  /// Append the trimmed `genre` unless an element already trims-equal to
  /// it (idempotent — assigning a genre a song already has is a no-op).
  /// Returns the new list, or `nil` when unchanged.
  static func adding(_ names: [String], _ genre: String) -> [String]? {
    let value = trimmed(genre)
    guard !value.isEmpty else { return nil }
    guard !names.contains(where: { trimmed($0) == value }) else { return nil }
    return names + [value]
  }

  // MARK: Private

  private static func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Drop empty/whitespace-only entries and keep the first occurrence of
  /// each (by trimmed value), in order. Mirrors the trim-compare the genre
  /// query uses so a deduped list and the query agree.
  private static func dedupedPreservingOrder(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var result = [String]()
    result.reserveCapacity(names.count)
    for name in names {
      let key = trimmed(name)
      guard !key.isEmpty, seen.insert(key).inserted else { continue }
      result.append(name)
    }
    return result
  }
}
