import Foundation
import ContextWindow

/// OpenAI **Responses API** adapter (`POST /v1/responses`).
///
/// Conforms to ``ContextWindow/Model``. Unlike the Chat adapter (which sends a
/// structured message array), the Responses adapter follows the spec's
/// "flatten" rule:
///
/// - **Initial request:** the live `[Record]` are flattened into a single
///   newline-delimited string passed as `input`.
/// - **Tool-call continuation:** the next request sends only
///   `function_call_output` items (one per executed tool) plus
///   `previous_response_id`, so server-side state carries the conversation
///   rather than re-sending history.
///
/// The returned `ModelResult.events` contain every `.toolCall`, every
/// `.toolOutput`, and the final `.modelResponse`, exactly like the Chat
/// adapter, so the window persists the whole exchange.
///
/// No network occurs unless the injected transport performs it.
public final class OpenAIResponsesModel: Model, @unchecked Sendable {
    private let model: String
    private let apiKey: String
    private let baseURL: URL
    private let transport: OpenAITransport
    private let toolExecutor: ToolExecutor?
    private let maxToolRoundTrips: Int

    public init(
        model: String,
        apiKey: String? = nil,
        toolExecutor: ToolExecutor? = nil,
        transport: OpenAITransport = URLSessionOpenAITransport(),
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        maxToolRoundTrips: Int = 8
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
    }

    // MARK: Model

    public func call(_ records: [Record]) async throws -> ModelResult {
        let tools = await toolSchemas()

        var collectedEvents: [RecordEvent] = []
        var totalTokens = 0

        // Initial request: flatten the live records to newline-delimited text.
        var input: ResponsesInput = .text(Self.flatten(records))
        var previousResponseID: String? = nil

        for _ in 0...maxToolRoundTrips {
            let response = try await postResponses(
                input: input,
                previousResponseID: previousResponseID,
                tools: tools
            )
            totalTokens += response.usage?.total_tokens ?? 0
            previousResponseID = response.id

            let functionCalls = response.output.filter { $0.type == "function_call" }
            if !functionCalls.isEmpty {
                var outputs: [ResponsesItem] = []
                for fc in functionCalls {
                    let name = fc.name ?? ""
                    let args = fc.arguments ?? "{}"
                    collectedEvents.append(
                        RecordEvent(source: .toolCall, content: "\(name)(\(args))")
                    )

                    let result: String
                    if let executor = toolExecutor {
                        result = try await executor.executeTool(name: name, args: Data(args.utf8))
                    } else {
                        result = "error: no tool executor configured for tool \"\(name)\""
                    }
                    collectedEvents.append(RecordEvent(source: .toolOutput, content: result))

                    outputs.append(
                        ResponsesItem(
                            type: "function_call_output",
                            call_id: fc.call_id,
                            output: result,
                            role: nil,
                            content: nil
                        )
                    )
                }
                // Continuation: send only the function-call outputs; the server
                // carries prior state via `previous_response_id`.
                input = .items(outputs)
                continue
            }

            // Terminal: gather assistant text from output message items.
            let text = Self.assistantText(from: response.output)
            collectedEvents.append(RecordEvent(source: .modelResponse, content: text))
            return ModelResult(events: collectedEvents, tokensUsed: totalTokens)
        }

        throw OpenAIError.toolLoopLimitExceeded(maxToolRoundTrips)
    }

    // MARK: Flatten

    /// Flatten records to a newline-delimited string. Each line is prefixed
    /// with a stable role tag so the model can still tell turns apart.
    static func flatten(_ records: [Record]) -> String {
        records.map { record in
            let tag: String
            switch record.source {
            case .systemPrompt: tag = "system"
            case .prompt: tag = "user"
            case .modelResponse: tag = "assistant"
            case .toolCall: tag = "tool_call"
            case .toolOutput: tag = "tool_output"
            }
            return "\(tag): \(record.content)"
        }
        .joined(separator: "\n")
    }

    static func assistantText(from output: [ResponsesItem]) -> String {
        var parts: [String] = []
        for item in output where item.type == "message" {
            for c in item.content ?? [] where c.type == "output_text" {
                if let t = c.text { parts.append(t) }
            }
        }
        return parts.joined()
    }

    // MARK: Request

    private func postResponses(
        input: ResponsesInput,
        previousResponseID: String?,
        tools: [ResponsesToolWire]
    ) async throws -> ResponsesResponse {
        let request = ResponsesRequest(
            model: model,
            input: input,
            previous_response_id: previousResponseID,
            tools: tools.isEmpty ? nil : tools
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(request)

        let httpRequest = OpenAIHTTPRequest(
            url: baseURL.appendingPathComponent("responses"),
            method: "POST",
            headers: [
                "Content-Type": "application/json",
                "Authorization": "Bearer \(apiKey)"
            ],
            body: body
        )

        let (data, http) = try await transport.send(httpRequest)
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(decoding: data.prefix(2048), as: UTF8.self)
            throw OpenAIError.httpStatus(code: http.statusCode, body: snippet)
        }
        do {
            return try JSONDecoder().decode(ResponsesResponse.self, from: data)
        } catch {
            throw OpenAIError.decoding(String(describing: error))
        }
    }

    private func toolSchemas() async -> [ResponsesToolWire] {
        guard let executor = toolExecutor else { return [] }
        let defs = await executor.registeredTools()
        return defs.map { def in
            ResponsesToolWire(
                type: "function",
                name: def.schema.name,
                description: def.schema.description,
                parameters: def.schema.parameters,
                strict: def.schema.strict ? true : nil
            )
        }
    }
}

// MARK: - Wire types (Responses API)

/// `input` is polymorphic: either a flat string (initial request) or an array
/// of items (function-call-output continuation).
enum ResponsesInput: Encodable, Sendable {
    case text(String)
    case items([ResponsesItem])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let s): try container.encode(s)
        case .items(let items): try container.encode(items)
        }
    }
}

struct ResponsesRequest: Encodable, Sendable {
    var model: String
    var input: ResponsesInput
    var previous_response_id: String?
    var tools: [ResponsesToolWire]?
}

struct ResponsesToolWire: Encodable, Sendable {
    var type: String
    var name: String
    var description: String?
    var parameters: JSONValue
    var strict: Bool?
}

struct ResponsesResponse: Decodable, Sendable {
    var id: String?
    var output: [ResponsesItem]
    var usage: ResponsesUsage?
}

struct ResponsesItem: Codable, Sendable {
    var type: String
    // function_call fields
    var name: String?
    var arguments: String?
    var call_id: String?
    // function_call_output fields
    var output: String?
    // message fields
    var role: String?
    var content: [ResponsesContent]?

    init(
        type: String,
        name: String? = nil,
        arguments: String? = nil,
        call_id: String? = nil,
        output: String? = nil,
        role: String? = nil,
        content: [ResponsesContent]? = nil
    ) {
        self.type = type
        self.name = name
        self.arguments = arguments
        self.call_id = call_id
        self.output = output
        self.role = role
        self.content = content
    }
}

struct ResponsesContent: Codable, Sendable {
    var type: String
    var text: String?
}

struct ResponsesUsage: Decodable, Sendable {
    var input_tokens: Int?
    var output_tokens: Int?
    var total_tokens: Int?
}
