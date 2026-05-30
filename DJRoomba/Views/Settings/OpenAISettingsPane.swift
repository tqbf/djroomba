import SwiftUI

/// The **OpenAI** settings pane: store an API key and point the user
/// at the assistant.
///
/// Single concern — credential management. The chat happens in the
/// **DJ Roomba** tab of the main window's bottom dock pane (⌥⌘\), not
/// crammed into a Settings tab; this pane just gates "key configured"
/// status and tells the user where to actually talk to the model.
///
/// Reads `MusicController` from the environment (the app injects it on the
/// `Settings` root so this scene has access). Binding to the controller's
/// shared `GPTService` means a key change here is immediately visible in
/// the DJ Roomba pane — no second instance, no second state.
struct OpenAISettingsPane: View {

  // MARK: Internal

  var body: some View {
    Form {
      apiKeySection
      upNextSection
      assistantSection
    }
    .formStyle(.grouped)
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller

  @State private var keyDraft = ""

  /// Opt-in: when the Up Next queue drains to empty, fire a new
  /// assistant conversation that picks ten more tracks (Phase 5 of
  /// `plans/up-next-queue.md`). Default OFF; the controller's
  /// drain detector gates on this value plus `gpt.isKeyConfigured`.
  /// `@AppStorage` is the right shape here — the toggle's only
  /// consumer outside the view is `UserDefaults.standard.bool(forKey:)`
  /// inside `MusicController`, and `@AppStorage` writes through to
  /// the same store so the two reads always agree.
  @AppStorage("djroomba.upNext.autoFillEnabled") private var autoFillEnabled = false

  private var gpt: GPTService {
    controller.gpt
  }

  private var apiKeySection: some View {
    Section {
      if gpt.isKeyConfigured {
        LabeledContent {
          Button("Remove", role: .destructive) {
            gpt.clearKey()
            keyDraft = ""
          }
        } label: {
          Label("API key stored in Keychain", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        }
      } else {
        SecureField("sk-…", text: $keyDraft)
          .textContentType(.password)
          .onSubmit(saveKey)
        Button("Save Key", action: saveKey)
          .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      if let error = gpt.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .font(.callout)
      }
    } header: {
      Text("OpenAI API Key")
    } footer: {
      Text("""
        OpenAI doesn’t offer a sign-in that issues a key to a desktop app, so \
        paste one you created at platform.openai.com. It’s stored in the \
        macOS Keychain, never in app preferences.
        """)
    }
  }

  private var upNextSection: some View {
    Section {
      Toggle("Auto-fill Up Next when empty", isOn: $autoFillEnabled)
    } header: {
      Text("Up Next")
    } footer: {
      Text("""
        When the queue drains to zero, DJ Roomba starts a new \
        conversation and adds ten more tracks based on what you’ve \
        been playing. Off by default.
        """)
    }
  }

  private var assistantSection: some View {
    Section {
      Button("Show DJ Roomba") {
        controller.showAssistant()
      }
      .disabled(!gpt.isKeyConfigured)
    } header: {
      Text("Assistant")
    } footer: {
      Text("""
        DJ Roomba lives in a tab of the bottom dock pane in the main \
        window (⌥⌘\\ / Playback ▸ Show DJ Roomba). It can list \
        playlists, search Apple Music, read your recently played, and \
        create new playlists for you.
        """)
    }
  }

  private func saveKey() {
    gpt.saveKey(keyDraft)
    keyDraft = ""
  }
}
