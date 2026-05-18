import Foundation

/// The `.djroomba` container codec: an 8-byte ASCII magic/version tag
/// followed by a zlib (DEFLATE) stream of a SQLite database file.
///
/// Pure and `nonisolated`; the compress/decompress CPU work is exposed
/// `async` so callers run it OFF the main actor. `LibraryStore` is a plain
/// `Sendable` value (not `@MainActor`) and these are `nonisolated`, so a
/// `@MainActor` caller's `await` suspends and the body runs on the
/// cooperative pool — the compression never janks the UI. No third-party
/// dependency: Foundation's `NSData.compressed`/`.decompressed`
/// ("just a compressed sqlite, for now" — `plans/snapshot-export-import.md`).
enum SnapshotCodec {

  enum DecodeError: Error, Equatable {
    /// Fewer bytes than the magic — not a `.djroomba` file.
    case tooShort
    /// Leading bytes are not `magic` — wrong file type / version.
    case badMagic
    /// Magic was fine but the zlib payload would not decompress.
    case corruptPayload
  }

  /// 8-byte ASCII magic. Doubles as the format version (`…01`): a future
  /// format change bumps the trailing digits and branches on decode. Any
  /// other leading bytes are rejected (`badMagic`) — never mis-parsed.
  static let magic = Data("DJRMBA01".utf8)

  /// Read the SQLite file at `sqliteURL`, zlib-compress it, and prepend
  /// the magic. The whole file is held in memory once — fine at this
  /// scale (a few MB; tens of MB worst case). Off-main (see type doc).
  nonisolated static func encode(sqliteAt sqliteURL: URL) async throws -> Data {
    let raw = try Data(contentsOf: sqliteURL, options: .mappedIfSafe)
    let compressed = try (raw as NSData).compressed(using: .zlib) as Data
    var container = Data(magic)
    container.append(compressed)
    return container
  }

  /// Validate the magic, decompress the remainder, and write the SQLite
  /// bytes atomically to `sqliteURL`. Throws a `DecodeError` for a
  /// non-`.djroomba` or corrupt file so the caller surfaces it cleanly
  /// (never a crash, never a half-applied merge). Off-main (see type doc).
  nonisolated static func decode(
    _ container: Data,
    toSQLiteAt sqliteURL: URL,
  ) async throws {
    guard container.count >= magic.count else { throw DecodeError.tooShort }
    guard container.prefix(magic.count) == magic else { throw DecodeError.badMagic }
    // `suffix(from:)` over `Data` keeps non-zero indices; copy into a
    // fresh `Data` so `NSData` sees a 0-based buffer.
    let payload = Data(container.suffix(from: magic.count))
    let raw: Data
    do {
      raw = try (payload as NSData).decompressed(using: .zlib) as Data
    } catch {
      throw DecodeError.corruptPayload
    }
    try raw.write(to: sqliteURL, options: .atomic)
  }
}
