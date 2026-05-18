import Foundation
import iTunesLibrary
import os

/// The single, isolated bridge to `iTunesLibrary.framework` used to discover
/// which library playlists are actually **folders** (Music.app's hierarchical
/// containers — see `PlaylistFolderClassifier` and `plans/playlist-folders.md`).
///
/// Why a separate file from the classifier: this is the *only* place a
/// non-`Sendable` `iTunesLibrary` type is touched. `ITLibrary` /
/// `ITLibPlaylist` never escape — the function returns a `Set<String>`
/// (`Sendable`), so it can be called from `ImportService`'s `@MainActor`
/// context and the result can cross actor boundaries freely under Swift 6
/// strict concurrency.
///
/// Sandbox note (Phase-1 A2): a sandboxed signed build needs the
/// `com.apple.security.assets.music.read-only` entitlement (added to
/// `DJRoomba.entitlements`) to instantiate `ITLibrary` and read playlists
/// without a user prompt. Even with the entitlement this is treated as a
/// best-effort, never-fatal input — see the graceful-degradation contract on
/// the function below.
enum PlaylistFolderSource {

  // MARK: Internal

  /// The MusicKit raw-id strings of every library playlist that
  /// `iTunesLibrary` classifies as a **folder**, ready for O(1) membership
  /// testing against the `Playlist.id.rawValue`s `ImportService` already
  /// fetches.
  ///
  /// **Graceful degradation (the A2 make-or-break contract).** This function
  /// never throws and never crashes. If `ITLibrary` init throws, the
  /// framework is unavailable, or anything else goes wrong, it logs the
  /// localized error and returns an **empty set** — i.e. import then proceeds
  /// with no folder exclusion, exactly today's behavior and zero regression.
  /// A folder is a *correctness* nuisance, never worth aborting an import for.
  ///
  /// Reading `iTunesLibrary` here is a strict classification input at the
  /// import boundary; SQLite remains the only source of truth and Apple stays
  /// import-only.
  ///
  /// Runs the (potentially slow — it opens & parses the whole Music library
  /// DB) `ITLibrary` read on a detached task so it never stalls the
  /// `@MainActor` at import start. The non-`Sendable` `ITLibrary` /
  /// `ITLibPlaylist` values stay strictly inside the closure; only the
  /// `Sendable` `Set<String>` crosses back out, so Swift 6 strict
  /// concurrency and the file-header isolation contract both hold.
  static func libraryFolderIDs() async -> Set<String> {
    await Task.detached(priority: .userInitiated) {
      let library: ITLibrary
      do {
        // Throwing init; `apiVersion` "1.1" is the documented current version.
        library = try ITLibrary(apiVersion: "1.1")
      } catch {
        log.error(
          "iTunesLibrary unavailable; importing with no playlist-folder exclusion: \(error.localizedDescription, privacy: .public)"
        )
        return []
      }

      var folderIDs = Set<String>()
      for playlist in library.allPlaylists where playlist.kind == .folder {
        // `persistentID` is an `NSNumber`; its `.uint64Value` is the raw
        // 64-bit pattern. The classifier reinterprets it as the signed
        // decimal MusicKit uses for `MusicItemID.rawValue`.
        let id = PlaylistFolderClassifier.folderIDString(
          persistentID: playlist.persistentID.uint64Value
        )
        folderIDs.insert(id)
      }
      return folderIDs
    }.value
  }

  // MARK: Private

  private static let log = Logger(
    subsystem: "org.sockpuppet.djroomba",
    category: "import",
  )

}
