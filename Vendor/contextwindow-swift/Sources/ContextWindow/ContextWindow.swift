import Foundation

/// The central coordinator: owns the current context, the store, the token
/// counter, and metrics.
///
/// An `actor` because Swift 6 strict concurrency is on and the window holds
/// mutable state (the current context, registered tools) shared across async
/// callers. Phase 2 wires the model call loop, summarization, tools and
/// middleware on top of the Phase 1 persistence spine.
public actor ContextWindow {
    private let store: ContextStore
    private let tokenCounter: TokenCounting

    /// Token-usage metrics for model calls. Each ``ModelResult/tokensUsed``
    /// from ``callModel()`` (and summarization) is accumulated here.
    public let metrics: Metrics

    /// The model the call loop drives. Optional: a persistence-only window
    /// (Phase 1 style) leaves this `nil`; `callModel()` then throws.
    private let model: Model?

    /// The summarizer used by ``summarizeLiveContext()``. Optional;
    /// summarization throws ``ModelError/noSummarizerConfigured`` if absent.
    private let summarizer: Summarizer?

    /// Optional observer fired around tool execution.
    private let middleware: Middleware?

    /// Registered tools, keyed by name (last registration wins, matching the
    /// `context_tools` upsert).
    private var tools: [String: ToolDefinition] = [:]

    /// The context currently targeted by reads/writes.
    private(set) public var currentContext: Context

    /// Default name used when no context name is supplied and none exist, or
    /// when the current context is deleted and nothing else remains.
    private static let defaultContextNamePrefix = "context"

    // MARK: Init

    /// Create a window bound to a **named** context.
    ///
    /// If a context with `contextName` exists it is adopted; otherwise it is
    /// created. Creating a duplicate name elsewhere surfaces
    /// ``ContextWindowError/contextNameAlreadyExists(_:)``.
    public init(
        store: ContextStore,
        contextName: String,
        model: Model? = nil,
        summarizer: Summarizer? = nil,
        middleware: Middleware? = nil,
        tokenCounter: TokenCounting = WhitespaceTokenCounter(),
        metrics: Metrics = Metrics()
    ) throws {
        try store.initialize()
        self.store = store
        self.tokenCounter = tokenCounter
        self.metrics = metrics
        self.model = model
        self.summarizer = summarizer
        self.middleware = middleware

        if let existing = try? store.getContext(name: contextName) {
            self.currentContext = existing
        } else {
            self.currentContext = try store.createContext(name: contextName)
        }
    }

    /// Create a window with an **unnamed** context.
    ///
    /// A UUID-based name is generated so the context is still uniquely
    /// addressable and name-uniqueness invariants hold.
    public init(
        store: ContextStore,
        model: Model? = nil,
        summarizer: Summarizer? = nil,
        middleware: Middleware? = nil,
        tokenCounter: TokenCounting = WhitespaceTokenCounter(),
        metrics: Metrics = Metrics()
    ) throws {
        try store.initialize()
        self.store = store
        self.tokenCounter = tokenCounter
        self.metrics = metrics
        self.model = model
        self.summarizer = summarizer
        self.middleware = middleware
        self.currentContext = try store.createContext(
            name: Self.generatedContextName()
        )
    }

    /// A UUID-ish generated context name for unnamed windows.
    static func generatedContextName() -> String {
        "\(defaultContextNamePrefix)-\(UUID().uuidString.lowercased())"
    }

    // MARK: Context management

    public func listContexts() throws -> [Context] {
        try store.listContexts()
    }

    /// Switch the current context to an existing one by name.
    public func switchContext(name: String) throws {
        currentContext = try store.getContext(name: name)
    }

    /// Create a new context and make it current.
    @discardableResult
    public func createContext(name: String) throws -> Context {
        let context = try store.createContext(name: name)
        currentContext = context
        return context
    }

    /// Delete a context by name.
    ///
    /// If the deleted context is the current one, the window switches to
    /// another existing context (the earliest by start time); if none remain,
    /// a fresh default context is created and adopted.
    public func deleteContext(name: String) throws {
        let deletingCurrent = (name == currentContext.name)
        try store.deleteContext(name: name)
        guard deletingCurrent else { return }

        let remaining = try store.listContexts()
        if let next = remaining.first {
            currentContext = next
        } else {
            currentContext = try store.createContext(
                name: Self.generatedContextName()
            )
        }
    }

    // MARK: Records

    /// Append a prompt record (live) to the current context.
    @discardableResult
    public func addPrompt(_ text: String) throws -> Record {
        try store.insertRecord(
            contextID: currentContext.id,
            source: .prompt,
            content: text,
            live: true
        )
    }

    /// Append a tool-call record (live) to the current context.
    ///
    /// `name` and `args` are joined into the record content as `name(args)`
    /// so the durable record is self-describing without a structured column.
    @discardableResult
    public func addToolCall(name: String, args: String) throws -> Record {
        try store.insertRecord(
            contextID: currentContext.id,
            source: .toolCall,
            content: "\(name)(\(args))",
            live: true
        )
    }

    /// Append a tool-output record (live) to the current context.
    @discardableResult
    public func addToolOutput(_ output: String) throws -> Record {
        try store.insertRecord(
            contextID: currentContext.id,
            source: .toolOutput,
            content: output,
            live: true
        )
    }

    /// Insert a new system-prompt record and deaden all prior system prompts
    /// for the current context (so only the latest system prompt is live).
    @discardableResult
    public func setSystemPrompt(_ text: String) throws -> Record {
        try store.deadenRecords(
            contextID: currentContext.id,
            source: .systemPrompt
        )
        return try store.insertRecord(
            contextID: currentContext.id,
            source: .systemPrompt,
            content: text,
            live: true
        )
    }

    /// Append an arbitrary record to the current context.
    @discardableResult
    public func insertRecord(
        source: RecordType,
        content: String,
        live: Bool = true
    ) throws -> Record {
        try store.insertRecord(
            contextID: currentContext.id,
            source: source,
            content: content,
            live: live
        )
    }

    /// Live records for the current context, timestamp ascending.
    /// Primary pre-model read path.
    public func liveRecords() throws -> [Record] {
        try store.listLiveRecords(contextID: currentContext.id)
    }

    /// All records (live + dead) for the current context, timestamp ascending.
    public func allRecords() throws -> [Record] {
        try store.listRecords(contextID: currentContext.id)
    }

    // MARK: Model call loop

    /// Run the configured model against the current context's live records.
    ///
    /// Exact order (do not reorder — this is the spec):
    /// 1. resolve the current context ID
    /// 2. load its live records (timestamp ascending)
    /// 3. call the model with exactly those records
    /// 4. add `tokensUsed` to ``metrics``
    /// 5. insert **every** returned event as a record, preserving
    ///    `source`/`content`/`live`
    /// 6. return the **last** event's content
    ///
    /// Does **not** auto-summarize (matches the Go behavior). Throws
    /// ``ModelError/noModelConfigured`` if no model was supplied, and
    /// ``ModelError/emptyModelResult`` if the model returns no events.
    @discardableResult
    public func callModel() async throws -> String {
        guard let model else { throw ModelError.noModelConfigured }

        // (1) resolve current context ID
        let contextID = currentContext.id
        // (2) load live records
        let live = try store.listLiveRecords(contextID: contextID)
        // (3) call model
        let result = try await model.call(live)
        // (4) add tokens used to metrics
        await metrics.addModelTokens(result.tokensUsed)
        // (5) insert every returned event as a record
        guard !result.events.isEmpty else {
            throw ModelError.emptyModelResult
        }
        for event in result.events {
            _ = try store.insertRecord(
                contextID: contextID,
                source: event.source,
                content: event.content,
                live: event.live
            )
        }
        // (6) return the last event content
        return result.events[result.events.count - 1].content
    }

    // MARK: Summarization

    /// Propose a compaction of the current context's live records.
    ///
    /// Prepends a synthetic summarizer-prompt record to the live records,
    /// calls the configured ``Summarizer``, and takes the **last** returned
    /// event as the summary. Does **not** mutate storage — pass the result to
    /// ``acceptSummary(_:)`` or ``rejectSummary(_:)``.
    ///
    /// Throws ``ModelError/noSummarizerConfigured`` if no summarizer is set.
    public func summarizeLiveContext(
        prompt: String = SummarizerPrompt.default
    ) async throws -> SummaryResult {
        guard let summarizer else {
            throw ModelError.noSummarizerConfigured
        }

        let contextID = currentContext.id
        let live = try store.listLiveRecords(contextID: contextID)

        // A synthetic, non-persisted instruction record prepended to the live
        // set. id 0 / now timestamp — it never touches the store.
        let promptRecord = Record(
            id: 0,
            timestamp: Date(),
            source: .systemPrompt,
            content: prompt,
            live: true,
            estimatedTokens: tokenCounter.count(prompt),
            contextID: contextID
        )

        let result = try await summarizer.call([promptRecord] + live)
        await metrics.addModelTokens(result.tokensUsed)
        guard let last = result.events.last else {
            throw ModelError.emptyModelResult
        }

        let originalTokens = live.reduce(0) { $0 + $1.estimatedTokens }
        return SummaryResult(
            summary: last.content,
            replaced: live,
            originalTokenCount: originalTokens,
            summaryTokenCount: result.tokensUsed
        )
    }

    /// Accept a proposed summary: atomically deaden the replaced records and
    /// insert the summary as a **live** `modelResponse`, in one DB transaction
    /// (all-or-nothing).
    public func acceptSummary(_ result: SummaryResult) throws {
        try store.replaceRecords(
            deadenIDs: result.replaced.map(\.id),
            contextID: currentContext.id,
            source: .modelResponse,
            content: result.summary,
            live: true
        )
    }

    /// Reject a proposed summary. No storage effect whatsoever.
    public func rejectSummary(_ result: SummaryResult) {
        _ = result
    }

    // MARK: Tools

    /// Register a tool: store its runner in-memory and persist its neutral
    /// schema as a `context_tools` hint on the current context. Re-registering
    /// the same name replaces both (matching the hint upsert).
    public func registerTool(_ tool: ToolDefinition) throws {
        tools[tool.name] = tool
        let json = try Self.encodeSchema(tool.schema)
        try store.upsertContextTool(
            contextID: currentContext.id,
            toolName: tool.name,
            definition: json
        )
    }

    /// Convenience: register a tool from a schema + runner.
    public func registerTool(
        schema: JSONSchemaToolDefinition,
        runner: ToolRunner
    ) throws {
        try registerTool(ToolDefinition(schema: schema, runner: runner))
    }

    /// The currently registered tools, ordered by name.
    public func registeredTools() -> [ToolDefinition] {
        tools.values.sorted { $0.name < $1.name }
    }

    /// Execute a registered tool by name with raw JSON `args`.
    ///
    /// Fires `middleware.onToolCall` before running and
    /// `middleware.onToolResult` after. Throws
    /// ``ModelError/toolNotRegistered(_:)`` for unknown names.
    @discardableResult
    public func executeTool(name: String, args: Data) async throws -> String {
        guard let tool = tools[name] else {
            throw ModelError.toolNotRegistered(name)
        }
        await middleware?.onToolCall(name: name, args: args)
        let output = try await tool.runner.run(args: args)
        await middleware?.onToolResult(name: name, output: output)
        return output
    }

    /// Register/replace a raw tool hint against the current context.
    ///
    /// Retained from Phase 1 for callers that only want the durable hint
    /// without an executable runner.
    public func registerToolHint(name: String, definition: String) throws {
        try store.upsertContextTool(
            contextID: currentContext.id,
            toolName: name,
            definition: definition
        )
    }

    private static func encodeSchema(
        _ schema: JSONSchemaToolDefinition
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(schema)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Export & usage

    /// Export the current context (or a named one) with all records + tools.
    public func export(name: String? = nil) throws -> ContextExport {
        try store.exportContext(name: name ?? currentContext.name)
    }

    /// Token usage for the current context = sum of `estimatedTokens` over
    /// its live records.
    public func tokenUsage() throws -> TokenUsage {
        let live = try store.listLiveRecords(contextID: currentContext.id)
        let total = live.reduce(0) { $0 + $1.estimatedTokens }
        return TokenUsage(liveTokens: total)
    }
}

// MARK: - ToolExecutor conformance

/// The window *is* the tool executor a provider adapter drives during a
/// tool-call loop. Actor isolation satisfies both the `Sendable` and `async`
/// requirements of ``ToolExecutor``.
extension ContextWindow: ToolExecutor {}
