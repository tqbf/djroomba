import Foundation
import Testing
@testable import DJRoomba

/// `SnapshotCodec` — the `.djroomba` container (8-byte magic + zlib). Pins:
/// a clean round trip, and that every malformed input is a typed
/// `DecodeError` (never a crash / partial write), so a non-`.djroomba` or
/// corrupt file is surfaced cleanly upstream.
struct SnapshotCodecTests {

  // MARK: Internal

  @Test
  func `encode then decode round trips arbitrary bytes`() async throws {
    let src = tempURL("sqlite")
    let dst = tempURL("sqlite")
    defer {
      try? FileManager.default.removeItem(at: src)
      try? FileManager.default.removeItem(at: dst)
    }
    // The codec is content-agnostic (it just compresses the file bytes);
    // a non-trivial, partly-incompressible blob is a fair payload.
    var payload = Data((0..<5000).map { UInt8($0 % 251) })
    payload.append(Data((0..<2048).map { _ in UInt8.random(in: 0...255) }))
    try payload.write(to: src)

    let container = try await SnapshotCodec.encode(sqliteAt: src)
    #expect(container.prefix(SnapshotCodec.magic.count) == SnapshotCodec.magic)
    #expect(container.count > SnapshotCodec.magic.count)

    try await SnapshotCodec.decode(container, toSQLiteAt: dst)
    #expect(try Data(contentsOf: dst) == payload)
  }

  @Test
  func `too short input is rejected`() async throws {
    let dst = tempURL("sqlite")
    await #expect(throws: SnapshotCodec.DecodeError.tooShort) {
      try await SnapshotCodec.decode(Data([0x01, 0x02]), toSQLiteAt: dst)
    }
    #expect(!FileManager.default.fileExists(atPath: dst.path))
  }

  @Test
  func `wrong magic is rejected`() async throws {
    let dst = tempURL("sqlite")
    let notOurs = Data("NOTDJRMB plus padding bytes".utf8)
    await #expect(throws: SnapshotCodec.DecodeError.badMagic) {
      try await SnapshotCodec.decode(notOurs, toSQLiteAt: dst)
    }
    #expect(!FileManager.default.fileExists(atPath: dst.path))
  }

  @Test
  func `valid magic but corrupt payload is rejected`() async throws {
    let dst = tempURL("sqlite")
    var bad = Data(SnapshotCodec.magic)
    bad.append(Data("this is not a zlib stream".utf8))
    await #expect(throws: SnapshotCodec.DecodeError.corruptPayload) {
      try await SnapshotCodec.decode(bad, toSQLiteAt: dst)
    }
    #expect(!FileManager.default.fileExists(atPath: dst.path))
  }

  // MARK: Private

  private func tempURL(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory
      .appending(path: "djr-codec-\(UUID().uuidString).\(ext)")
  }

}
