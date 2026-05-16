import SwiftUI

/// The modal "Rename Playlist" sheet (Phase-4 D1). A deterministic,
/// trigger-independent rename: a sheet's `TextField` is the sole first
/// responder — unlike the previous inline-in-`List` editor whose
/// `@FocusState` competed with the `List`'s own selection/first-responder
/// handling, making commit-on-blur inconsistent across triggers. Every
/// rename now ends with exactly one explicit, identical outcome: Rename
/// commits and dismisses, Cancel / Escape dismisses with no change.
///
/// macos-design: a small modal rename panel is a standard, fully native
/// macOS pattern (the common fallback Mac apps use for sidebar rename when
/// inline is unreliable); correctness over the inline aesthetic, since the
/// inline path proved timing-fragile in a `List`.
struct RenamePlaylistSheet: View {

  // MARK: Internal

  let request: PlaylistRenameRequest
  /// Persist a new name. Empty / unchanged is ignored by the controller
  /// (and pre-guarded here so the default button disables).
  let onCommit: (String) -> Void
  /// Dismiss with no change (Cancel / Escape / after a commit).
  let onCancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Rename Playlist")
        .font(.headline)

      TextField("Playlist Name", text: $draftName)
        .textFieldStyle(.roundedBorder)
        .focused($fieldFocused)
        .onSubmit(commit)

      HStack {
        Spacer()
        Button("Cancel", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Rename", action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(!canCommit)
      }
    }
    .padding(20)
    .frame(width: 320)
    .task {
      // The sheet's `TextField` is the only focusable control here, so
      // focus is deterministic (no `List` competing for first
      // responder — the D1 root cause). Yield once so the field's
      // `.focused` binding is registered before we request focus
      // (structured concurrency only — no GCD / `asyncAfter`), then
      // pre-select the whole name so typing replaces it, the Finder /
      // Music.app rename idiom (macos-design).
      draftName = request.currentName
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

  /// The default ("Rename") action is meaningless for an empty name.
  private var canCommit: Bool {
    !trimmedName.isEmpty
  }

  /// Commit once, only when there's a usable name. The controller still
  /// ignores an unchanged name, so re-typing the same name is a safe no-op.
  private func commit() {
    guard canCommit else { return }
    onCommit(trimmedName)
  }

  /// Select the whole field so typing replaces the name (the Finder rename
  /// idiom). macOS 14 has no SwiftUI text-selection API; we ask the key
  /// window's field editor — the editor this sheet's `TextField` uses — to
  /// select all. Deterministic here because the sheet owns first responder
  /// (the inline-in-`List` version's fragility was the `List` competing).
  /// `@MainActor`-only AppKit, no representable, no GCD.
  @MainActor
  private func selectAllText() {
    guard
      let window = NSApp.keyWindow,
      let editor = window.fieldEditor(false, for: nil)
    else { return }
    editor.selectAll(nil)
  }
}
