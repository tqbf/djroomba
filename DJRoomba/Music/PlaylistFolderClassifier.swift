import Foundation

/// Pure, `nonisolated`, dependency-free folder classification logic.
///
/// ## Why this exists
///
/// Music.app's library has hierarchical **playlist folders** (containers of
/// other playlists, e.g. "AAA ME"). MusicKit's `MusicLibraryRequest<Playlist>`
/// surfaces a folder as an ordinary `Playlist` value that is *byte-for-byte
/// indistinguishable* from a real playlist — the Phase-0 signed probe over the
/// real 270-playlist library proved there is **no** MusicKit-public folder /
/// parent / `isFolder` / `kind` discriminator (nil `kind`, nil `curatorName`,
/// nil `lastModifiedDate`, identical `Mirror` children, identical
/// `String(reflecting:)`). See `plans/musickit-notes.md` →
/// "Playlist folders — no discriminator" and `plans/playlist-folders.md`.
///
/// Folder detection therefore has to come from an external source. The chosen
/// mechanism (Phase-1 decision gate, resolved Option A) is
/// `iTunesLibrary.framework`'s `ITLibPlaylist.kind == .folder`, joined back to
/// the MusicKit playlists we already fetch by a *free, exact* id mapping (see
/// below). The iTunesLibrary read itself lives in `PlaylistFolderSource`; this
/// file is the pure, signing-free, fully unit-tested core of the join.
///
/// ## The id-mapping core (`folderIDString`)
///
/// Phase-0's probe library ids came back as **signed 64-bit decimals**
/// (e.g. `2807883042140459807`, `-7422005473605192085`). That is exactly how a
/// 64-bit Music *persistent ID* renders when reinterpreted as a signed `Int64`
/// — i.e. `MusicKit.Playlist.id.rawValue` is the decimal string of
/// `Int64(bitPattern:)` applied to the same persistent ID that
/// `iTunesLibrary` exposes as `ITLibPlaylist.persistentID` (an `NSNumber`
/// whose `.uint64Value` is the raw 64-bit pattern). The mapping is exact and
/// requires no extra fetch: build the folder-id `Set<String>` once from
/// `iTunesLibrary` and membership-test the MusicKit `rawValue` strings.
///
/// `Int64(bitPattern:)` is the precise reinterpretation: it preserves all 64
/// bits and flips only how the high bit is *read* (unsigned magnitude vs.
/// two's-complement sign), so a persistent ID with the top bit set renders as
/// a negative decimal — matching the probe's negative ids — and `UInt64.max`
/// maps to `"-1"`.
///
/// ## Recorded fallback (not implemented)
///
/// Option B (a post-fetch content heuristic: a folder is the union/superset of
/// its child playlists' tracks) is the documented escape hatch if the
/// sandbox/entitlement risk had blocked Option A. It is deliberately **not**
/// implemented here: Option A degrades safely — if `iTunesLibrary` is
/// unavailable the source returns an empty set and import simply proceeds with
/// no folder exclusion (exactly today's behavior, zero regression), so there
/// is no correctness cliff that would force the heuristic. See
/// `plans/playlist-folders.md` Phase 1 / Phase 2.
enum PlaylistFolderClassifier {

  /// Maps a Music **persistent ID** (raw unsigned 64-bit pattern, as
  /// `iTunesLibrary` exposes it via `ITLibPlaylist.persistentID.uint64Value`)
  /// to the MusicKit `MusicItemID.rawValue` string for the same playlist.
  ///
  /// The MusicKit raw id is the *signed* decimal of the same bits, so the
  /// conversion is `Int64(bitPattern:)` → `String`. This is total, lossless,
  /// and the sole point where the iTunesLibrary ↔ MusicKit id namespaces are
  /// reconciled (Phase-0 evidence; see the type doc).
  static func folderIDString(persistentID: UInt64) -> String {
    String(Int64(bitPattern: persistentID))
  }

  /// Whether `musicItemID` (a MusicKit `MusicItemID.rawValue`) names a
  /// playlist that `iTunesLibrary` classified as a folder.
  ///
  /// `folderIDs` is the set produced by mapping every
  /// `ITLibPlaylistKind.folder` playlist's persistent ID through
  /// ``folderIDString(persistentID:)``. An empty set (the graceful-degradation
  /// case — iTunesLibrary unavailable) makes this always `false`, so import
  /// proceeds with no exclusion. O(1) membership; no fetch.
  static func isFolder(_ musicItemID: String, in folderIDs: Set<String>) -> Bool {
    folderIDs.contains(musicItemID)
  }

}
