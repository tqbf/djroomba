import Foundation
import Testing
@testable import DJRoomba

/// Phase-2 playlist-folder classifier. Pins the two pieces of pure logic the
/// folder fix rests on:
///
/// 1. The iTunesLibrary ↔ MusicKit id mapping — `MusicKit.Playlist.id.rawValue`
///    is the *signed* decimal of the Music persistent ID's raw 64-bit pattern
///    (`Int64(bitPattern:)`). The Phase-0 signed probe over the real library
///    produced exactly these decimals; the round-trip below reconstructs the
///    persistent ID from those bits and asserts the string is reproduced
///    byte-for-byte, including the negative (high-bit-set) case.
/// 2. `isFolder` set membership — present / absent / empty-set (the
///    graceful-degradation case → never a folder).
struct PlaylistFolderClassifierTests {

  @Test
  func `id mapping reproduces the Phase-0 positive signed decimal`() {
    // 2807883042140459807 < 2^63 → its bit pattern as UInt64 is the same
    // numeric value; the signed decimal is identical.
    let bits = UInt64(2_807_883_042_140_459_807)
    #expect(
      PlaylistFolderClassifier.folderIDString(persistentID: bits) == "2807883042140459807"
    )
  }

  @Test
  func `id mapping reproduces the Phase-0 negative signed decimal`() {
    // -7422005473605192085 is how a high-bit-set persistent ID renders as a
    // signed Int64. Reconstruct the raw bit pattern, then assert the mapping
    // yields the exact negative decimal the probe observed.
    let bits = UInt64(bitPattern: -7_422_005_473_605_192_085)
    #expect(
      PlaylistFolderClassifier.folderIDString(persistentID: bits) == "-7422005473605192085"
    )
  }

  @Test
  func `high bit set maps to A negative decimal`() {
    // Exactly 2^63: the smallest UInt64 with the top bit set → Int64.min.
    let bits: UInt64 = 1 << 63
    #expect(
      PlaylistFolderClassifier.folderIDString(persistentID: bits) == String(Int64.min)
    )
    #expect(PlaylistFolderClassifier.folderIDString(persistentID: bits).hasPrefix("-"))
  }

  @Test
  func `small value maps to A positive decimal`() {
    #expect(PlaylistFolderClassifier.folderIDString(persistentID: 42) == "42")
    #expect(PlaylistFolderClassifier.folderIDString(persistentID: 0) == "0")
  }

  @Test
  func `UInt64 max maps to minus one`() {
    #expect(PlaylistFolderClassifier.folderIDString(persistentID: .max) == "-1")
  }

  @Test
  func `isFolder is true for A present id`() {
    let folders: Set = ["-7422005473605192085", "42"]
    #expect(PlaylistFolderClassifier.isFolder("42", in: folders))
    #expect(PlaylistFolderClassifier.isFolder("-7422005473605192085", in: folders))
  }

  @Test
  func `isFolder is false for an absent id`() {
    let folders: Set = ["-7422005473605192085"]
    #expect(!PlaylistFolderClassifier.isFolder("42", in: folders))
  }

  @Test
  func `isFolder is always false for the empty set`() {
    #expect(!PlaylistFolderClassifier.isFolder("42", in: []))
    #expect(!PlaylistFolderClassifier.isFolder("-1", in: []))
  }

}
