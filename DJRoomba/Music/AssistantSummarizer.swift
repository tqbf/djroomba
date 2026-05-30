import ContextWindow
import ContextWindowOpenAI
import Foundation

// MARK: - AssistantSummarizer

/// Conversation-titler. When the user hits **New Request**, the
/// previously-current conversation is handed here so we can write a
/// short label for the sidebar. Runs against
/// **`gpt-5.4-mini`** — a separate cheap model picked specifically for
/// short, fast, one-shot summarization (no relation to the main chat
/// model `gpt-4.1-mini` used by `GPTService` for the live tool loop).
///
/// Implementation: a single `OpenAIChatModel.call([Record])` with no
/// `toolExecutor`, so the call goes out and back in one shot — no
/// tool loop, no second `ContextWindow` to set up. The synthetic
/// `Record`s passed in are stack-only; the summarizer never writes to
/// `assistant.sqlite`.
enum AssistantSummarizer {

  // MARK: Internal

  /// API model identifier — the cheap mini variant the user picked for
  /// this surface. Kept here (one place) so a future bump is a single
  /// edit. See `WebFetch` lookup against
  /// `developers.openai.com/api/docs/models` (2026-05-29) for the
  /// magic string.
  static let modelName = "gpt-5.4-mini"

  /// Run the model and return a cleaned, 3–6 word title for `messages`.
  /// `messages` is the human + assistant transcript of the just-archived
  /// conversation; tool turns are dropped (they're noisy and don't help
  /// titling). Throws if the model returns nothing useful.
  static func summarize(
    messages: [GPTService.Message],
    apiKey: String,
  ) async throws -> String {
    let transcript = messages
      .filter { $0.role != .tool }
      .map { "\(roleLabel(for: $0.role)): \($0.content)" }
      .joined(separator: "\n\n")

    guard !transcript.isEmpty else {
      throw SummarizerError.emptyTranscript
    }

    // Ad-hoc records: the model only reads `source` + `content`, so a
    // sentinel id / synthetic context UUID are fine — these never reach
    // SQLite (no `insertRecord` call goes through the summarizer path).
    let syntheticContextID = UUID()
    let system = Record(
      id: -1,
      timestamp: .now,
      source: .systemPrompt,
      content: """
        You title chat conversations. Read the transcript the user sends \
        and reply with a short, descriptive title — three to six words, \
        title-case, no quotes, no surrounding punctuation, no leading \
        article ("The", "A"). Reply with **only** the title, no preamble.
        """,
      live: true,
      estimatedTokens: 0,
      contextID: syntheticContextID,
    )
    let userPrompt = Record(
      id: -2,
      timestamp: .now,
      source: .prompt,
      content: "Title this conversation:\n\n\(transcript)",
      live: true,
      estimatedTokens: 0,
      contextID: syntheticContextID,
    )

    let model = try OpenAIChatModel(
      model: modelName,
      apiKey: apiKey,
      toolExecutor: nil,
      transport: URLSessionOpenAITransport(session: GPTService.urlSession),
      serviceTier: GPTService.serviceTier,
    )
    let result = try await model.call([system, userPrompt])
    guard let last = result.events.last?.content else {
      throw SummarizerError.emptyResponse
    }
    return clean(last)
  }

  // MARK: Private

  /// Strip whitespace, surrounding quotes, a trailing period — keeps the
  /// model's occasional `"My Title."` from showing up literally in the
  /// sidebar.
  private static func clean(_ raw: String) -> String {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count >= 2 {
      text = String(text.dropFirst().dropLast())
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    while text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") {
      text = String(text.dropLast())
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func roleLabel(for role: GPTService.Message.Role) -> String {
    switch role {
    case .user: "User"
    case .assistant: "Assistant"
    case .tool: "Tool"
    }
  }
}

// MARK: - SummarizerError

enum SummarizerError: Error, CustomStringConvertible {
  case emptyTranscript
  case emptyResponse

  var description: String {
    switch self {
    case .emptyTranscript: "Nothing to summarize."
    case .emptyResponse: "The summarizer model returned nothing."
    }
  }
}
