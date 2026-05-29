import SwiftUI

/// Stable identifier for the assistant `Window` scene. The Settings pane,
/// menu command, and `openWindow` calls share this id so we don't
/// scatter the string literal.
let AssistantWindowID = "djroomba-assistant"

// MARK: - AssistantWindowView

/// The assistant chat window: a transcript on top, an input row on the
/// bottom, no traffic-light-crowding chrome. Lives in its own
/// `WindowGroup`/`Window` scene rather than a Settings tab — chat is a
/// foreground activity, not a preference, and the user will want it open
/// alongside the main library window.
///
/// State lives on the shared `MusicController.gpt`, so a key rotation in
/// Settings reflects here on the next render, and closing/reopening the
/// window doesn't lose the transcript.
struct AssistantWindowView: View {

  // MARK: Internal

  var body: some View {
    VStack(spacing: 0) {
      transcript
      if let error = gpt.errorMessage {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(.regularMaterial)
      }
      Divider()
      composer
    }
    .frame(minWidth: 480, idealWidth: 620, minHeight: 360, idealHeight: 720)
    .task {
      // Pull any persisted history into the visible transcript on first
      // open. Cheap; idempotent on subsequent opens.
      await controller.gpt.refreshTranscript()
    }
  }

  // MARK: Private

  @Environment(MusicController.self) private var controller
  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  private var gpt: GPTService {
    controller.gpt
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        if !gpt.isKeyConfigured {
          unconfiguredPlaceholder
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        } else if gpt.messages.isEmpty {
          emptyPlaceholder
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        } else {
          LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(gpt.messages) { message in
              MessageRow(message: message)
                .id(message.id)
            }
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 16)
        }
      }
      .onChange(of: gpt.messages.last?.id) { _, newID in
        guard let newID else { return }
        withAnimation(.easeOut(duration: 0.15)) {
          proxy.scrollTo(newID, anchor: .bottom)
        }
      }
    }
  }

  private var unconfiguredPlaceholder: some View {
    VStack(spacing: 8) {
      Image(systemName: "key.fill")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text("Add an OpenAI key to start.")
        .font(.title3)
      Text("Settings → OpenAI (⌘,)")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private var emptyPlaceholder: some View {
    VStack(spacing: 8) {
      Image(systemName: "sparkles")
        .font(.system(size: 28))
        .foregroundStyle(.tertiary)
      Text("Ask about your library.")
        .font(.title3)
      Text("""
        Try: "Make a playlist of my most-played songs", "Find Pink Floyd \
        in the catalog", or "What's in my 80s Hits playlist?"
        """)
      .font(.caption)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .padding(.horizontal, 32)
    }
    .frame(maxWidth: .infinity)
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 8) {
      TextField("Message DJ Roomba…", text: $draft, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1 ... 6)
        .focused($inputFocused)
        .disabled(!gpt.isKeyConfigured || gpt.isSending)
        .onSubmit(send)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
      Button(action: send) {
        if gpt.isSending {
          ProgressView().controlSize(.small)
            .frame(width: 16, height: 16)
        } else {
          Image(systemName: "arrow.up.circle.fill")
            .font(.title2)
        }
      }
      .buttonStyle(.plain)
      .disabled(sendDisabled)
    }
    .padding(12)
    .background(.bar)
  }

  private var sendDisabled: Bool {
    !gpt.isKeyConfigured
      || gpt.isSending
      || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func send() {
    guard !sendDisabled else { return }
    let text = draft
    draft = ""
    Task { await gpt.sendMessage(text) }
  }
}

// MARK: - MessageRow

/// One row in the transcript. Style differs by role — assistant + user are
/// the primary surface, tool calls/outputs are de-emphasised so they read
/// as background telemetry, not the answer.
private struct MessageRow: View {

  // MARK: Internal

  let message: GPTService.Message

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      icon
        .frame(width: 22, height: 22)
      VStack(alignment: .leading, spacing: 4) {
        Text(roleLabel)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Text(displayContent)
          .font(role == .tool ? .caption : .body)
          .foregroundStyle(role == .tool ? .secondary : .primary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  // MARK: Private

  private var role: GPTService.Message.Role {
    message.role
  }

  @ViewBuilder
  private var icon: some View {
    switch role {
    case .user:
      Image(systemName: "person.crop.circle.fill")
        .foregroundStyle(.tint)

    case .assistant:
      Image(systemName: "sparkles")
        .foregroundStyle(.purple)

    case .tool:
      Image(systemName: "wrench.adjustable")
        .foregroundStyle(.secondary)
    }
  }

  private var roleLabel: String {
    switch role {
    case .user:
      "You"
    case .assistant:
      "DJ Roomba"
    case .tool:
      "Tool"
    }
  }

  /// Tool outputs are JSON — truncate so the transcript isn't dominated by
  /// the raw `playlist_contents` blob, but keep it tappable/selectable.
  private var displayContent: String {
    guard role == .tool, message.content.count > 320 else {
      return message.content
    }
    return String(message.content.prefix(320)) + "…"
  }
}
