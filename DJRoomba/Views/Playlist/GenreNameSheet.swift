import SwiftUI

/// The modal genre-name sheet — renaming a browsed genre, or naming a new
/// genre for the selected tracks. Same proven shape as
/// `RenamePlaylistSheet`: a sheet's `TextField` is the sole first
/// responder (deterministic focus/commit, no `List`/`Table` competing for
/// first responder), pre-filled + fully selected so typing replaces it
/// (the Finder/Music idiom), ⏎ commits, ⎋ cancels. macos-design: a small
/// modal name panel is a standard native pattern.
struct GenreNameSheet: View {

  // MARK: Internal

  let request: GenreNameRequest
  /// Commit a non-empty, trimmed name (the controller still no-ops an
  /// unchanged rename / empty selection).
  let onCommit: (String) -> Void
  /// Dismiss with no change (Cancel / Escape).
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(request.title)
        .font(.headline)

      TextField(request.prompt, text: $draftName)
        .textFieldStyle(.roundedBorder)
        .focused($fieldFocused)
        .onSubmit(commit)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(!canCommit)
      }
    }
    .padding(20)
    .frame(width: 320)
    .task {
      // Only focusable control here ⇒ deterministic focus. Yield once so
      // the `.focused` binding is registered before requesting focus
      // (structured concurrency only — no GCD), then select-all so typing
      // replaces the name.
      draftName = request.initialText
      await Task.yield()
      guard !Task.isCancelled else { return }
      fieldFocused = true
      selectAllText()
    }
  }

  // MARK: Private

  @State private var draftName = ""
  @FocusState private var fieldFocused: Bool

  private var trimmedName: String {
    draftName.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var canCommit: Bool {
    !trimmedName.isEmpty
  }

  private func commit() {
    guard canCommit else { return }
    onCommit(trimmedName)
  }

  /// Select the whole field so typing replaces the seed (Finder idiom).
  /// macOS 14 has no SwiftUI text-selection API; ask the key window's
  /// field editor (the one this sheet's `TextField` uses) to select all —
  /// deterministic because the sheet owns first responder. `@MainActor`
  /// AppKit only, no representable, no GCD. Same approach as
  /// `RenamePlaylistSheet`.
  @MainActor
  private func selectAllText() {
    guard
      let window = NSApp.keyWindow,
      let editor = window.fieldEditor(false, for: nil)
    else { return }
    editor.selectAll(nil)
  }
}
