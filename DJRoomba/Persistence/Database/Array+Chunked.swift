import Foundation

extension Array {
  /// Split into consecutive sub-arrays of at most `size` elements, order
  /// preserved. Used by `LibraryStore`'s batched multi-row SQL so a single
  /// statement never exceeds SQLite's bound-parameter limit. `size` must be
  /// positive; a non-positive size yields the whole array as one chunk
  /// (degenerate, but never a crash or empty result).
  func chunked(into size: Int) -> [[Element]] {
    guard size > 0 else { return isEmpty ? [] : [self] }
    return stride(from: 0, to: count, by: size).map {
      Array(self[$0 ..< Swift.min($0 + size, count)])
    }
  }
}
