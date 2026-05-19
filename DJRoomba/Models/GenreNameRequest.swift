import Foundation

/// Drives the single modal genre-name `.sheet(item:)` (swiftui-pro: prefer
/// `sheet(item:)` over `sheet(isPresented:)` so the optional is safely
/// unwrapped — the same pattern as `PlaylistRenameRequest`). One request
/// type covers both genre edits; the controller switches on `action` at
/// commit. `Identifiable` by a fresh `id` so re-presenting (e.g. assign to
/// a different selection) always re-opens cleanly.
struct GenreNameRequest: Identifiable, Hashable, Sendable {

  /// What committing the typed name does.
  enum Action: Hashable, Sendable {
    /// Rename the genre currently shown in the top pane (the controller
    /// resolves which one — it owns `selectedGenre`). Merge is implicit.
    case renameBrowsedGenre
    /// Assign the typed name to these `song.id`s (idempotent append).
    case assignToSongs([String])
  }

  let id = UUID()
  /// Sheet heading ("Rename Genre" / "Assign Genre").
  let title: String
  /// The text field's placeholder.
  let prompt: String
  /// Field's initial text — pre-filled + fully selected so typing
  /// replaces it (the Finder/Music rename idiom). Empty for a new genre.
  let initialText: String
  let action: Action
}
