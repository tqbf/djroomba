import SwiftUI

// MARK: - AssistantPaneView

/// The assistant chat surface — a left sidebar of past conversations,
/// a per-tab header (sidebar toggle + New Request + current
/// conversation title), the transcript, and the composer. Embedded
/// inside the bottom dock pane (`BottomDockPane`), which carries the
/// outer collapse/resize chrome and the shared tab picker between this
/// surface and the Genre Map.
///
/// **Multi-conversation** (Phase 1.5, 2026-05-29 evening). The sidebar
/// lists every conversation in `controller.gpt.conversations`; clicking
/// switches the visible transcript. **New Request** archives the
/// just-finished conversation (kicks off `gpt-5.4-mini` summarization
/// in the background to label it in the sidebar) and mints a fresh
/// empty one. Sidebar visibility is `@SceneStorage`-persisted so the
/// user's preference survives a relaunch.
///
/// State lives on `MusicController.gpt`: switching tabs in the dock or
/// even relaunching the app keeps the same transcript + sidebar feed,
/// because the underlying `ContextWindow` persists to SQLite at
/// `Application Support/DJRoomba/assistant.sqlite`.
struct AssistantPaneView: View {

  // MARK: Internal

  var body: some View {
    HStack(spacing: 0) {
      if sidebarVisible {
        AssistantConversationSidebar(
          conversations: gpt.conversations,
          currentID: gpt.currentConversationID,
          onSelect: { id in
            Task { await gpt.switchConversation(to: id) }
          },
          onDelete: { id in
            Task { await gpt.deleteConversation(id) }
          },
        )
        .frame(width: 220)
        .transition(.move(edge: .leading).combined(with: .opacity))
        Divider()
      }
      chatColumn
    }
    .animation(.easeInOut(duration: 0.18), value: sidebarVisible)
    .task {
      // Populate the sidebar feed + current-conversation pointer
      // directly from `assistant.sqlite`, no API key required — so
      // existing conversations show up the moment the pane appears
      // (the full `ensureSession()` path is still lazy on first send).
      controller.gpt.loadConversationsFromDisk()
      // Pull any persisted transcript for the current conversation
      // into the visible chat (a no-op until a session is built).
      await controller.gpt.refreshTranscript()
    }
  }

  // MARK: Private

  /// Sidebar visibility — view-layer concern, scene-persisted so the
  /// user's "show/hide the conversation list" choice survives relaunch
  /// (scene state must not live inside an `@Observable`). Default `true`
  /// because the sidebar IS the multi-conversation affordance — hiding
  /// it on first run buries the feature.
  @SceneStorage("djroomba.assistant.sidebarVisible") private var sidebarVisible = true

  /// Whether to render `tool` turns in the transcript (the wrench-icon
  /// rows showing the model's tool call + truncated output). Some users
  /// want to see the tool traffic, some find it noisy — make it a
  /// toggle. `@AppStorage` so the preference survives relaunch across
  /// scenes; defaults to `true` because the visibility IS the trust
  /// affordance ("see what the model is doing") for a first-time user.
  @AppStorage("djroomba.assistant.showToolCalls") private var showToolCalls = true

  @Environment(MusicController.self) private var controller
  @State private var draft = ""
  @FocusState private var inputFocused: Bool

  private var gpt: GPTService {
    controller.gpt
  }

  /// The title text shown in the per-pane header — current
  /// conversation's summary, or a placeholder when the summarizer
  /// hasn't run yet.
  private var currentConversationTitle: String {
    guard let id = gpt.currentConversationID else { return "New Conversation" }
    if
      let entry = gpt.conversations.first(where: { $0.id == id }),
      let title = entry.title,
      !title.isEmpty
    {
      return title
    }
    return gpt.messages.contains { $0.role == .user } ? "Untitled" : "New Conversation"
  }

  /// Per-tab header strip: sidebar toggle + New Request + the current
  /// conversation title. Distinct from `BottomDockPane`'s shared header
  /// (which carries the tab picker for the whole dock).
  private var paneHeader: some View {
    HStack(spacing: 10) {
      Button {
        sidebarVisible.toggle()
      } label: {
        Label("Conversations", systemImage: "sidebar.left")
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .help(sidebarVisible ? "Hide conversation list" : "Show conversation list")

      Button {
        Task { await gpt.newConversation() }
      } label: {
        Label("New Request", systemImage: "square.and.pencil")
      }
      .labelStyle(.titleAndIcon)
      .buttonStyle(.borderless)
      .help("Archive this conversation and start a new one")
      .disabled(!gpt.isKeyConfigured)

      // Subtle "Show tool calls" toggle sits to the LEFT of the
      // Spacer so it's visible at every window width — when it lived
      // on the trailing edge a wide window pushed it off-screen,
      // hiding the affordance entirely. Caption font + secondary
      // foreground keep it quiet (the "subtle checkbox" the spec
      // called for).
      Toggle("Show tool calls", isOn: $showToolCalls)
        .toggleStyle(.checkbox)
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Show the model's tool calls + outputs in the transcript")
        .padding(.leading, 8)

      Spacer()

      Text(currentConversationTitle)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  /// Transcript filtered through the `showToolCalls` toggle — when
  /// off, tool calls/outputs collapse so only user prompts + assistant
  /// replies remain. Tool-state in the underlying records is preserved
  /// (the model still sees them on the next turn); this is a view-
  /// only filter.
  private var visibleMessages: [GPTService.Message] {
    if showToolCalls {
      gpt.messages
    } else {
      gpt.messages.filter { $0.role != .tool }
    }
  }

  private var chatColumn: some View {
    VStack(spacing: 0) {
      paneHeader
      Divider()
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
            ForEach(visibleMessages) { message in
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
      .onChange(of: gpt.currentConversationID) { _, _ in
        // Snap to the bottom of the freshly-loaded transcript so a
        // sidebar switch lands on the latest message, not the top.
        if let last = gpt.messages.last?.id {
          proxy.scrollTo(last, anchor: .bottom)
        }
      }
      .onChange(of: showToolCalls) { _, _ in
        // Toggling the filter shrinks/grows the rendered transcript.
        // The ScrollView keeps its old offset, which leaves the user
        // staring at empty space below the new (shorter) content
        // when toggling OFF — looking like the transcript got
        // cleared (it didn't; `gpt.messages` is unchanged, only the
        // filter result is). Re-anchor on the last visible message
        // so the bottom of the chat stays the bottom.
        if let last = visibleMessages.last?.id {
          withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(last, anchor: .bottom)
          }
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
      Text("Ask DJ Roomba about your library.")
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
      .accessibilityLabel("Send message")
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

/// One row in the transcript. Style differs by role — assistant + user
/// are the primary surface, tool calls/outputs are de-emphasised so they
/// read as background telemetry, not the answer.
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

  /// Tool outputs are JSON — truncate so the transcript isn't
  /// dominated by the raw `playlist_contents` blob, but keep it
  /// tappable/selectable.
  private var displayContent: String {
    guard role == .tool, message.content.count > 320 else {
      return message.content
    }
    return String(message.content.prefix(320)) + "…"
  }
}
