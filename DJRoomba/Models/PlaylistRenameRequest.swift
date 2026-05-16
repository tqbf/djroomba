import Foundation

/// Drives the modal "Rename Playlist" sheet via `sheet(item:)` (swiftui-pro:
/// prefer `sheet(item:)` over `sheet(isPresented:)` so the optional is safely
/// unwrapped). Carries the target playlist's stable id plus its current name
/// (the field's initial text). `Identifiable` by the playlist id so opening a
/// rename for a different row re-presents cleanly.
///
/// Phase-4 D1: a modal sheet replaced the inline-in-`List` `TextField` rename.
/// The inline editor's `@FocusState` competed with the `List`'s own
/// first-responder/selection handling, so commit-on-blur was inconsistent
/// across triggers. A sheet's `TextField` is the sole first responder and the
/// commit is an explicit, deterministic Rename/Cancel — identical every time.
struct PlaylistRenameRequest: Identifiable, Hashable, Sendable {
  /// `apple_playlist`/`app_playlist` id — the stable app-local key.
  let id: String
  /// The playlist's current name; the rename field starts pre-filled and
  /// fully selected with this so typing replaces it (the Finder idiom).
  let currentName: String
}
