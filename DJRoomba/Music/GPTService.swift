import ContextWindow
import ContextWindowOpenAI
import Foundation
import Observation

// MARK: - GPTService

/// The OpenAI / GPT integration's view-model and boundary.
///
/// Owns the chat session as a single `ContextWindow` actor backed by a
/// `SQLiteContextStore` in `Application Support/DJRoomba/assistant.sqlite`
/// (separate file from the library DB — same GRDB engine, no schema
/// intersection). The window is built lazily on first send so a launch with
/// no API key never touches the disk. The `OpenAIChatModel` is wired with a
/// `LateBoundToolExecutor` that points back at the same window — that's the
/// canonical pattern from `ContextWindowOpenAI.LiveOpenAITests`.
///
/// Tools dispatch to ``MusicController`` through a `weak` reference handed in
/// at app bootstrap (`attach(host:)`). The host is the @MainActor surface
/// over the library / playback / catalog services; the tool closure
/// captures it weakly so this service has no ownership opinion on the
/// controller and avoids a retain cycle (the controller owns this).
///
/// `@MainActor @Observable` per the project's state rules. `ContextWindow`'s
/// async methods run on its own actor; we `await` them from here, which
/// frees the main actor during network I/O and re-enters it for tool calls.
@MainActor
@Observable
final class GPTService {

  // MARK: Lifecycle

  init(store: LibraryStore? = nil, catalogIngest: CatalogIngestService? = nil) {
    self.store = store
    self.catalogIngest = catalogIngest
    let storedKey = (try? keychain.read()) ?? nil
    isKeyConfigured = storedKey != nil
  }

  // MARK: Internal

  /// One rendered turn in the chat transcript.
  struct Message: Identifiable, Equatable, Sendable {
    enum Role: Sendable, Equatable {
      case user
      case assistant
      /// A tool call or tool output — surfaced italicised in the UI so the
      /// user can see what the model decided to fetch.
      case tool
    }

    let id: Int64
    let role: Role
    let content: String
    let timestamp: Date
  }

  /// Whether an API key is stored in the Keychain.
  private(set) var isKeyConfigured: Bool

  /// Visible chat transcript (user / assistant / tool turns). System prompts
  /// are filtered out — they're for the model, not the user.
  private(set) var messages = [Message]()

  /// True while a `callModel()` is in flight.
  private(set) var isSending = false

  /// Human-readable error from the last save / send, if any.
  private(set) var errorMessage: String?

  /// Persist (or overwrite) the API key. Trims whitespace; ignores empty.
  /// A key rotation tears down the active session so the next send rebuilds
  /// with the new credential.
  func saveKey(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    do {
      try keychain.save(trimmed)
      isKeyConfigured = true
      errorMessage = nil
      session = nil
    } catch {
      errorMessage = "Couldn’t save the key — \(error)"
    }
  }

  /// Forget the stored key, drop the in-memory session, and clear the
  /// rendered transcript. Underlying SQLite records remain on disk; a
  /// future re-add reopens the same context. (Deliberate — the user can
  /// rotate a key without losing history.)
  func clearKey() {
    do {
      try keychain.delete()
      isKeyConfigured = false
      session = nil
      messages = []
      errorMessage = nil
    } catch {
      errorMessage = "Couldn’t remove the key — \(error)"
    }
  }

  /// Append `text` to the conversation and drive `callModel()`. Tool calls
  /// fire inside the model's loop and are persisted as records; the
  /// transcript refresh at the tail surfaces everything.
  func sendMessage(_ text: String) async {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    isSending = true
    errorMessage = nil
    defer { isSending = false }

    AssistantLog.logger.info("→ user: \(AssistantLog.truncate(trimmed), privacy: .public)")

    do {
      let session = try await ensureSession()
      try await session.window.addPrompt(trimmed)
      // Optimistic refresh so the user sees their own message immediately.
      await refreshTranscript(window: session.window)
      let reply = try await session.window.callModel()
      AssistantLog.logger.info("← assistant: \(AssistantLog.truncate(reply), privacy: .public)")
      await refreshTranscript(window: session.window)
    } catch {
      AssistantLog.logger.error("! send failed: \(String(describing: error), privacy: .public)")
      errorMessage = "\(error)"
      if let session {
        await refreshTranscript(window: session.window)
      }
    }
  }

  /// Re-pull the transcript from the underlying context window. Cheap on
  /// modest chat lengths (an indexed read on one context id); we lean on
  /// this rather than tracking model events twice.
  func refreshTranscript() async {
    guard let session else { return }
    await refreshTranscript(window: session.window)
  }

  // MARK: Private

  /// Per-app-launch chat session. Owns the window + the late-bound executor
  /// (the executor is bound to the window at construction time).
  private struct Session {
    let window: ContextWindow
    let executor: LateBoundToolExecutor
  }

  /// The chat model — small, fast, inexpensive. Pulling this into Settings
  /// is a Phase-4 follow-up; for now everything assumes one model.
  private static let modelName = "gpt-4.1-mini"

  /// Stable per-app name in the context store — re-launches reattach to
  /// the same conversation rather than starting fresh.
  private static let contextName = "djroomba-assistant"

  /// The system prompt that grounds the model in this app's surface. Kept
  /// short and specific; tool affordances are described in each tool's own
  /// schema, not duplicated here.
  private static let systemPrompt = """
    You are the assistant inside DJ Roomba, a Mac app that manages the \
    user's Apple Music library through a local SQLite store. You can read \
    playlists and tracks, search Apple Music's catalog, see recently \
    played history, and create new app-owned playlists. Prefer calling \
    tools over guessing. When you list tracks back to the user, keep \
    replies short and use plain prose, not large tables.
    """

  @ObservationIgnored private var session: Session?
  @ObservationIgnored private let store: LibraryStore?
  @ObservationIgnored private let catalogIngest: CatalogIngestService?

  @ObservationIgnored private let keychain = KeychainItem(
    service: "org.sockpuppet.djroomba",
    account: "openai-api-key",
  )

  /// Map one `Record` to a visible `Message`. System prompts are hidden.
  private static func message(from record: Record) -> Message? {
    let role: Message.Role
    switch record.source {
    case .prompt:
      role = .user

    case .modelResponse:
      role = .assistant

    case .toolCall,
         .toolOutput:
      role = .tool

    case .systemPrompt:
      return nil
    }
    return Message(
      id: record.id,
      role: role,
      content: record.content,
      timestamp: record.timestamp,
    )
  }

  /// `~/Library/Application Support/DJRoomba/assistant.sqlite`, mirroring
  /// `AppDatabase.defaultURL()` but in its own file.
  private static func contextStoreURL() throws -> URL {
    let directory = URL.applicationSupportDirectory
      .appending(path: "DJRoomba", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
    )
    return directory.appending(
      path: "assistant.sqlite",
      directoryHint: .notDirectory,
    )
  }

  /// Build the session on first use. Idempotent — a successful call caches.
  /// Re-runs after a key rotation (`session = nil` in `saveKey`).
  private func ensureSession() async throws -> Session {
    if let session { return session }
    guard let key = (try? keychain.read()) ?? nil, !key.isEmpty else {
      throw GPTServiceError.noAPIKey
    }

    let url = try Self.contextStoreURL()
    let contextStore = try SQLiteContextStore(path: url.path)
    let executor = LateBoundToolExecutor()
    let model = try OpenAIChatModel(
      model: Self.modelName,
      apiKey: key,
      toolExecutor: executor,
    )
    let window = try ContextWindow(
      store: contextStore,
      contextName: Self.contextName,
      model: model,
    )
    executor.bind(window)

    // System prompt is idempotent — `setSystemPrompt` deadens the previous
    // one so re-running doesn't accumulate them.
    try await window.setSystemPrompt(Self.systemPrompt)

    for tool in GPTToolRegistration.tools(store: store, catalogIngest: catalogIngest) {
      try await window.registerTool(tool)
    }

    let session = Session(window: window, executor: executor)
    self.session = session
    await refreshTranscript(window: window)
    return session
  }

  private func refreshTranscript(window: ContextWindow) async {
    do {
      let records = try await window.allRecords()
      messages = records.compactMap { Self.message(from: $0) }
    } catch {
      // A transcript refresh can't surface usefully — the underlying error
      // would have been raised by the action that just ran.
    }
  }

}

// MARK: - GPTServiceError

/// Errors surfaced from `GPTService`'s own boundary (provider errors are
/// passed through verbatim from `ContextWindowOpenAI`).
enum GPTServiceError: Error, CustomStringConvertible {
  case noAPIKey

  var description: String {
    switch self {
    case .noAPIKey:
      "No API key is configured."
    }
  }
}
