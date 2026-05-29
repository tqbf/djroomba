import Foundation
import ContextWindow

/// OpenAI **Chat Completions** adapter (`POST /v1/chat/completions`).
///
/// Conforms to ``ContextWindow/Model``: it is handed the context's live
/// `[Record]`, translates them to chat messages, calls the API through the
/// injected ``OpenAITransport``, and returns a typed ``ModelResult`` whose
/// `events` are persisted by `ContextWindow.callModel()`.
///
/// ### Record → message mapping (spec)
/// | RecordType      | Chat message                                   |
/// |-----------------|------------------------------------------------|
/// | `.systemPrompt` | `{role: system}`                               |
/// | `.prompt`       | `{role: user}`                                 |
/// | `.modelResponse`| `{role: assistant}`                            |
/// | `.toolCall`     | `{role: assistant, tool_calls: [...]}` (legacy)|
/// | `.toolOutput`   | `{role: tool}`                                 |
///
/// ### Tool-call loop
/// If the assistant responds with `tool_calls`, each is executed through the
/// injected ``ToolExecutor`` (`executeTool(name:args:)`), the call **and** its
/// output are appended both to the wire conversation and to the returned
/// `events`, and the request is re-issued — repeating until the assistant
/// returns a plain message (or `maxToolRoundTrips` is hit). The returned
/// `ModelResult.events` therefore contain every `.toolCall`, every
/// `.toolOutput`, and the final `.modelResponse`, so the window persists the
/// whole exchange.
///
/// No network occurs unless the injected transport performs it; the default
/// test suite injects a stub.
public final class OpenAIChatModel: Model, @unchecked Sendable {
    private let model: String
    private let apiKey: String
    private let baseURL: URL
    private let transport: OpenAITransport
    private let toolExecutor: ToolExecutor?
    private let maxToolRoundTrips: Int
    private let temperature: Double?

    /// - Parameters:
    ///   - model: the model name (e.g. `gpt-4.1`, `gpt-4.1-mini`).
    ///   - apiKey: API key. Defaults to the `OPENAI_API_KEY` environment
    ///     variable; never hardcode and never logged.
    ///   - toolExecutor: drives the tool-call loop. Pass the `ContextWindow`
    ///     actor (it conforms to ``ToolExecutor``). `nil` disables tools.
    ///   - transport: the HTTP boundary. Defaults to `URLSession`; tests inject
    ///     a stub so the suite is offline.
    ///   - baseURL: API base. Defaults to the public OpenAI endpoint.
    ///   - maxToolRoundTrips: safety cap on tool-call iterations.
    ///   - temperature: optional sampling temperature.
    public init(
        model: String,
        apiKey: String? = nil,
        toolExecutor: ToolExecutor? = nil,
        transport: OpenAITransport = URLSessionOpenAITransport(),
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        maxToolRoundTrips: Int = 8,
        temperature: Double? = nil
    ) throws {
        guard let key = apiKey ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
            throw OpenAIError.missingAPIKey
        }
        self.model = model
        self.apiKey = key
        self.transport = transport
        self.toolExecutor = toolExecutor
        self.baseURL = baseURL
        self.maxToolRoundTrips = maxToolRoundTrips
        self.temperature = temperature
    }

    // MARK: Model

    public func call(_ records: [Record]) async throws -> ModelResult {
        // DJROOMBA PATCH 1 (2026-05-29): pair `.toolOutput` records to their
        // preceding `.toolCall` so a replayed conversation carries
        // `tool_call_id` on every tool message. The previous per-record
        // `message(for:)` map produced `tool_call_id: nil` on `.toolOutput`,
        // and the chat API rejects that with HTTP 400 `messages.[i].tool_call_id`
        // on the *next* turn (the in-loop turn was fine because that branch
        // already set the id locally). Behaviour-preserving for one-turn
        // conversations and live-tested against `gpt-4.1-mini`.
        var messages = Self.messages(from: records)
        let tools = await toolSchemas()

        var collectedEvents: [RecordEvent] = []
        var totalTokens = 0

        for _ in 0...maxToolRoundTrips {
            let response = try await postChatCompletion(messages: messages, tools: tools)
            totalTokens += response.usage?.total_tokens ?? 0

            guard let choice = response.choices.first else {
                throw OpenAIError.emptyResponse
            }
            let assistant = choice.message

            if let toolCalls = assistant.tool_calls, !toolCalls.isEmpty {
                // Record the assistant turn that requested the tool calls so the
                // wire conversation stays valid for the continuation request.
                messages.append(
                    ChatMessage(
                        role: "assistant",
                        content: assistant.content,
                        tool_calls: toolCalls,
                        tool_call_id: nil,
                        name: nil
                    )
                )

                for toolCall in toolCalls {
                    let fn = toolCall.function
                    // Persist the call as a self-describing `name(args)` record,
                    // matching `ContextWindow.addToolCall`.
                    collectedEvents.append(
                        RecordEvent(
                            source: .toolCall,
                            content: "\(fn.name)(\(fn.arguments))"
                        )
                    )

                    let output: String
                    if let executor = toolExecutor {
                        let argsData = Data(fn.arguments.utf8)
                        output = try await executor.executeTool(name: fn.name, args: argsData)
                    } else {
                        output = "error: no tool executor configured for tool \"\(fn.name)\""
                    }

                    collectedEvents.append(RecordEvent(source: .toolOutput, content: output))
                    messages.append(
                        ChatMessage(
                            role: "tool",
                            content: output,
                            tool_calls: nil,
                            tool_call_id: toolCall.id,
                            name: fn.name
                        )
                    )
                }
                continue // re-issue the request with tool outputs appended
            }

            // Plain assistant message: terminal turn.
            let content = assistant.content ?? ""
            collectedEvents.append(RecordEvent(source: .modelResponse, content: content))
            return ModelResult(events: collectedEvents, tokensUsed: totalTokens)
        }

        throw OpenAIError.toolLoopLimitExceeded(maxToolRoundTrips)
    }

    // MARK: Request construction

    private func postChatCompletion(
        messages: [ChatMessage],
        tools: [ChatToolWire]
    ) async throws -> ChatCompletionResponse {
        let requestBody = ChatCompletionRequest(
            model: model,
            messages: messages,
            tools: tools.isEmpty ? nil : tools,
            temperature: temperature
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(requestBody)

        let request = OpenAIHTTPRequest(
            url: baseURL.appendingPathComponent("chat/completions"),
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)"
            ],
            body: body
        )

        let (data, http) = try await transport.send(request)
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(decoding: data.prefix(2048), as: UTF8.self)
            throw OpenAIError.httpStatus(code: http.statusCode, body: snippet)
        }
        do {
            return try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw OpenAIError.decoding(String(describing: error))
        }
    }

    private func toolSchemas() async -> [ChatToolWire] {
        guard let executor = toolExecutor else { return [] }
        let defs = await executor.registeredTools()
        return defs.map { def in
            ChatToolWire(
                type: "function",
                function: ChatFunctionWire(
                    name: def.schema.name,
                    description: def.schema.description,
                    parameters: def.schema.parameters,
                    strict: def.schema.strict ? true : nil
                )
            )
        }
    }

    // MARK: Record → message mapping

    /// DJROOMBA PATCH 1 (2026-05-29): walk records in order, pairing each
    /// `.toolOutput` with its most recent unmatched `.toolCall` so the
    /// emitted tool message carries a `tool_call_id` matching the assistant
    /// message that requested it. Per the in-loop persistence pattern, a
    /// `.toolCall` is always immediately followed by its `.toolOutput`, so a
    /// single-slot pairing is sufficient and correct for multi-call assistant
    /// turns. The per-record `message(for:)` is preserved (the previous
    /// public entrypoint) for callers that want it.
    static func messages(from records: [Record]) -> [ChatMessage] {
        var out = [ChatMessage]()
        out.reserveCapacity(records.count)
        var pendingToolCallID: String?
        for record in records {
            switch record.source {
            case .systemPrompt:
                out.append(ChatMessage(role: "system", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil))
            case .prompt:
                out.append(ChatMessage(role: "user", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil))
            case .modelResponse:
                out.append(ChatMessage(role: "assistant", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil))
            case .toolCall:
                let (name, args) = parseToolCallContent(record.content)
                let syntheticID = "call_\(record.id)"
                pendingToolCallID = syntheticID
                out.append(
                    ChatMessage(
                        role: "assistant",
                        content: nil,
                        tool_calls: [
                            ChatToolCall(
                                id: syntheticID,
                                type: "function",
                                function: ChatFunctionCall(name: name, arguments: args)
                            )
                        ],
                        tool_call_id: nil,
                        name: nil
                    )
                )
            case .toolOutput:
                let id = pendingToolCallID ?? "call_orphan_\(record.id)"
                pendingToolCallID = nil
                out.append(ChatMessage(role: "tool", content: record.content, tool_calls: nil, tool_call_id: id, name: nil))
            }
        }
        return out
    }

    static func message(for record: Record) -> ChatMessage {
        switch record.source {
        case .systemPrompt:
            return ChatMessage(role: "system", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil)
        case .prompt:
            return ChatMessage(role: "user", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil)
        case .modelResponse:
            return ChatMessage(role: "assistant", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil)
        case .toolCall:
            // Legacy representation: a `.toolCall` record is content
            // `name(args)`; surface it as an assistant message carrying a
            // synthetic `tool_calls` entry so the wire history is coherent.
            let (name, args) = Self.parseToolCallContent(record.content)
            return ChatMessage(
                role: "assistant",
                content: nil,
                tool_calls: [
                    ChatToolCall(
                        id: "call_\(record.id)",
                        type: "function",
                        function: ChatFunctionCall(name: name, arguments: args)
                    )
                ],
                tool_call_id: nil,
                name: nil
            )
        case .toolOutput:
            return ChatMessage(role: "tool", content: record.content, tool_calls: nil, tool_call_id: nil, name: nil)
        }
    }

    /// Split a `name(args)` tool-call record back into `(name, args)`.
    /// Tolerant of args that themselves contain parentheses.
    static func parseToolCallContent(_ content: String) -> (name: String, args: String) {
        guard let open = content.firstIndex(of: "("), content.hasSuffix(")") else {
            return (content, "{}")
        }
        let name = String(content[content.startIndex..<open])
        let argsStart = content.index(after: open)
        let argsEnd = content.index(before: content.endIndex)
        guard argsStart <= argsEnd else { return (name, "{}") }
        let args = String(content[argsStart..<argsEnd])
        return (name, args.isEmpty ? "{}" : args)
    }
}

// MARK: - Wire types (Chat Completions)

struct ChatCompletionRequest: Encodable, Sendable {
    var model: String
    var messages: [ChatMessage]
    var tools: [ChatToolWire]?
    var temperature: Double?
}

struct ChatMessage: Codable, Sendable, Equatable {
    var role: String
    var content: String?
    var tool_calls: [ChatToolCall]?
    var tool_call_id: String?
    var name: String?
}

struct ChatToolCall: Codable, Sendable, Equatable {
    var id: String
    var type: String
    var function: ChatFunctionCall
}

struct ChatFunctionCall: Codable, Sendable, Equatable {
    var name: String
    var arguments: String
}

struct ChatToolWire: Encodable, Sendable {
    var type: String
    var function: ChatFunctionWire
}

struct ChatFunctionWire: Encodable, Sendable {
    var name: String
    var description: String?
    var parameters: JSONValue
    var strict: Bool?
}

struct ChatCompletionResponse: Decodable, Sendable {
    var choices: [ChatChoice]
    var usage: ChatUsage?
}

struct ChatChoice: Decodable, Sendable {
    var message: ChatMessage
    var finish_reason: String?
}

struct ChatUsage: Decodable, Sendable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
}
