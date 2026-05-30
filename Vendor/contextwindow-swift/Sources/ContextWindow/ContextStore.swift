import Foundation
import GRDB

/// Persistence boundary for contexts, records, and tool hints.
///
/// All operations are synchronous and `throws`. The SQLite schema this is
/// implemented against (`contexts`, `records`, `context_tools` plus the
/// live-record and timestamp indexes) is the durable, shape-stable artifact —
/// see `plans/swift-port-plan.md`.
public protocol ContextStore: Sendable {
    /// Create the schema if it does not exist. Idempotent.
    func initialize() throws

    /// Create a new context with a unique `name`. Throws
    /// ``ContextWindowError/contextNameAlreadyExists(_:)`` on collision.
    func createContext(name: String) throws -> Context

    /// All contexts, ordered by start time ascending.
    func listContexts() throws -> [Context]

    /// Fetch a context by name. Throws
    /// ``ContextWindowError/contextNotFound(_:)`` if absent.
    func getContext(name: String) throws -> Context

    /// Delete a context and all of its records/tools.
    func deleteContext(name: String) throws

    /// Append a record. `live` records participate in token usage and the
    /// pre-model read path. Token count is computed here, at insert time.
    func insertRecord(
        contextID: UUID,
        source: RecordType,
        content: String,
        live: Bool
    ) throws -> Record

    /// Live records for a context, timestamp ascending. Primary pre-model
    /// read path.
    func listLiveRecords(contextID: UUID) throws -> [Record]

    /// All records (live and dead) for a context, timestamp ascending.
    func listRecords(contextID: UUID) throws -> [Record]

    /// Mark every record of `source` for `contextID` as dead (`live = false`).
    /// Used by system-prompt deadening.
    func deadenRecords(contextID: UUID, source: RecordType) throws

    /// Atomically deaden a specific set of records *and* insert a replacement
    /// record, in a single transaction. Used by summary acceptance: the
    /// originals go dead and the summary becomes live as one indivisible unit
    /// (either all or nothing on failure).
    ///
    /// - Parameters:
    ///   - deadenIDs: record `id`s to mark dead (`live = false`).
    ///   - contextID: context the replacement record belongs to.
    ///   - source: source of the replacement record.
    ///   - content: content of the replacement record.
    ///   - live: liveness of the replacement record.
    /// - Returns: the inserted replacement ``Record``.
    @discardableResult
    func replaceRecords(
        deadenIDs: [Int64],
        contextID: UUID,
        source: RecordType,
        content: String,
        live: Bool
    ) throws -> Record

    /// Register/replace a tool hint for a context.
    func upsertContextTool(contextID: UUID, toolName: String, definition: String) throws

    /// Tool hints registered against a context, ordered by name.
    func listContextTools(contextID: UUID) throws -> [ContextTool]

    /// Full export: context + all records + all tool hints.
    func exportContext(name: String) throws -> ContextExport
}

// MARK: - GRDB row models

/// GRDB row type for `contexts`.
private struct ContextRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "contexts"
    var id: String
    var name: String
    var start_time: Date
}

/// GRDB row type for `records`. `id` is omitted on insert (autoincrement).
private struct RecordRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "records"
    var id: Int64?
    var timestamp: Date
    var source: Int
    var content: String
    var live: Bool
    var est_tokens: Int
    var context_id: String
}

/// GRDB row type for `context_tools`.
private struct ContextToolRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "context_tools"
    var context_id: String
    var tool_name: String
    var definition: String
}

// MARK: - SQLite implementation

/// GRDB-backed ``ContextStore``.
///
/// Backed by a `DatabaseQueue` (serialized access; safe to share). Pass a file
/// path for persistence or use ``inMemory()`` for tests.
public final class SQLiteContextStore: ContextStore, Sendable {
    private let dbQueue: DatabaseQueue
    private let tokenCounter: TokenCounting

    /// Open (or create) a store at `path`.
    public init(path: String, tokenCounter: TokenCounting = WhitespaceTokenCounter()) throws {
        self.dbQueue = try DatabaseQueue(path: path)
        self.tokenCounter = tokenCounter
    }

    private init(dbQueue: DatabaseQueue, tokenCounter: TokenCounting) {
        self.dbQueue = dbQueue
        self.tokenCounter = tokenCounter
    }

    /// An ephemeral, in-memory store (per-process, deterministic; for tests).
    public static func inMemory(
        tokenCounter: TokenCounting = WhitespaceTokenCounter()
    ) throws -> SQLiteContextStore {
        let queue = try DatabaseQueue()
        return SQLiteContextStore(dbQueue: queue, tokenCounter: tokenCounter)
    }

    // MARK: Schema

    public func initialize() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS contexts (
                    id TEXT PRIMARY KEY NOT NULL,
                    name TEXT NOT NULL,
                    start_time DATETIME NOT NULL
                );
                """)

            try db.execute(sql: """
                CREATE UNIQUE INDEX IF NOT EXISTS idx_contexts_name
                    ON contexts (name);
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS records (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    timestamp DATETIME NOT NULL,
                    source INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    live BOOLEAN NOT NULL,
                    est_tokens INTEGER NOT NULL,
                    context_id TEXT NOT NULL
                        REFERENCES contexts(id) ON DELETE CASCADE
                );
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_records_live
                    ON records (context_id, live);
                """)

            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_records_timestamp
                    ON records (context_id, timestamp);
                """)

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS context_tools (
                    context_id TEXT NOT NULL
                        REFERENCES contexts(id) ON DELETE CASCADE,
                    tool_name TEXT NOT NULL,
                    definition TEXT NOT NULL,
                    PRIMARY KEY (context_id, tool_name)
                );
                """)
        }
    }

    // MARK: Contexts

    public func createContext(name: String) throws -> Context {
        let context = Context(id: UUID(), name: name, startTime: Date())
        do {
            try dbQueue.write { db in
                try ContextRow(
                    id: context.id.uuidString,
                    name: context.name,
                    start_time: context.startTime
                ).insert(db)
            }
        } catch let error as DatabaseError where error.isUniquenessViolation {
            throw ContextWindowError.contextNameAlreadyExists(name)
        }
        return context
    }

    public func listContexts() throws -> [Context] {
        try dbQueue.read { db in
            try ContextRow
                .order(Column("start_time").asc, Column("id").asc)
                .fetchAll(db)
                .map(Self.toContext)
        }
    }

    public func getContext(name: String) throws -> Context {
        try dbQueue.read { db in
            guard let row = try ContextRow
                .filter(Column("name") == name)
                .fetchOne(db)
            else {
                throw ContextWindowError.contextNotFound(name)
            }
            return Self.toContext(row)
        }
    }

    public func deleteContext(name: String) throws {
        try dbQueue.write { db in
            guard let row = try ContextRow
                .filter(Column("name") == name)
                .fetchOne(db)
            else {
                throw ContextWindowError.contextNotFound(name)
            }
            // ON DELETE CASCADE handles records + context_tools; we also delete
            // explicitly so behavior is independent of the foreign_keys pragma.
            try db.execute(
                sql: "DELETE FROM records WHERE context_id = ?",
                arguments: [row.id]
            )
            try db.execute(
                sql: "DELETE FROM context_tools WHERE context_id = ?",
                arguments: [row.id]
            )
            _ = try ContextRow.deleteOne(db, key: ["id": row.id])
        }
    }

    // MARK: Records

    public func insertRecord(
        contextID: UUID,
        source: RecordType,
        content: String,
        live: Bool
    ) throws -> Record {
        let timestamp = Date()
        let tokens = tokenCounter.count(content)
        let inserted: Int64 = try dbQueue.write { db in
            let row = RecordRow(
                id: nil,
                timestamp: timestamp,
                source: source.rawValue,
                content: content,
                live: live,
                est_tokens: tokens,
                context_id: contextID.uuidString
            )
            let saved = try row.insertAndFetch(db)
            return saved.id ?? db.lastInsertedRowID
        }
        return Record(
            id: inserted,
            timestamp: timestamp,
            source: source,
            content: content,
            live: live,
            estimatedTokens: tokens,
            contextID: contextID
        )
    }

    public func listLiveRecords(contextID: UUID) throws -> [Record] {
        try dbQueue.read { db in
            try RecordRow
                .filter(Column("context_id") == contextID.uuidString)
                .filter(Column("live") == true)
                .order(Column("timestamp").asc, Column("id").asc)
                .fetchAll(db)
                .map(Self.toRecord)
        }
    }

    public func listRecords(contextID: UUID) throws -> [Record] {
        try dbQueue.read { db in
            try RecordRow
                .filter(Column("context_id") == contextID.uuidString)
                .order(Column("timestamp").asc, Column("id").asc)
                .fetchAll(db)
                .map(Self.toRecord)
        }
    }

    public func deadenRecords(contextID: UUID, source: RecordType) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE records SET live = 0
                    WHERE context_id = ? AND source = ?
                    """,
                arguments: [contextID.uuidString, source.rawValue]
            )
        }
    }

    public func replaceRecords(
        deadenIDs: [Int64],
        contextID: UUID,
        source: RecordType,
        content: String,
        live: Bool
    ) throws -> Record {
        let timestamp = Date()
        let tokens = tokenCounter.count(content)
        // `DatabaseQueue.write` is itself a single transaction: if any
        // statement throws, GRDB rolls the whole block back, so the deaden
        // and the insert are all-or-nothing.
        let inserted: Int64 = try dbQueue.write { db in
            for id in deadenIDs {
                try db.execute(
                    sql: """
                        UPDATE records SET live = 0
                        WHERE id = ? AND context_id = ?
                        """,
                    arguments: [id, contextID.uuidString]
                )
            }
            let row = RecordRow(
                id: nil,
                timestamp: timestamp,
                source: source.rawValue,
                content: content,
                live: live,
                est_tokens: tokens,
                context_id: contextID.uuidString
            )
            let saved = try row.insertAndFetch(db)
            return saved.id ?? db.lastInsertedRowID
        }
        return Record(
            id: inserted,
            timestamp: timestamp,
            source: source,
            content: content,
            live: live,
            estimatedTokens: tokens,
            contextID: contextID
        )
    }

    // MARK: Tools

    public func upsertContextTool(
        contextID: UUID,
        toolName: String,
        definition: String
    ) throws {
        try dbQueue.write { db in
            try ContextToolRow(
                context_id: contextID.uuidString,
                tool_name: toolName,
                definition: definition
            ).upsert(db)
        }
    }

    public func listContextTools(contextID: UUID) throws -> [ContextTool] {
        try dbQueue.read { db in
            try ContextToolRow
                .filter(Column("context_id") == contextID.uuidString)
                .order(Column("tool_name").asc)
                .fetchAll(db)
                .map(Self.toContextTool)
        }
    }

    // MARK: Export

    public func exportContext(name: String) throws -> ContextExport {
        try dbQueue.read { db in
            guard let row = try ContextRow
                .filter(Column("name") == name)
                .fetchOne(db)
            else {
                throw ContextWindowError.contextNotFound(name)
            }
            let context = Self.toContext(row)
            let records = try RecordRow
                .filter(Column("context_id") == row.id)
                .order(Column("timestamp").asc, Column("id").asc)
                .fetchAll(db)
                .map(Self.toRecord)
            let tools = try ContextToolRow
                .filter(Column("context_id") == row.id)
                .order(Column("tool_name").asc)
                .fetchAll(db)
                .map(Self.toContextTool)
            return ContextExport(context: context, records: records, tools: tools)
        }
    }

    // MARK: Mapping

    private static func toContext(_ row: ContextRow) -> Context {
        Context(
            id: UUID(uuidString: row.id) ?? UUID(),
            name: row.name,
            startTime: row.start_time
        )
    }

    private static func toRecord(_ row: RecordRow) -> Record {
        Record(
            id: row.id ?? 0,
            timestamp: row.timestamp,
            source: RecordType(rawValue: row.source) ?? .prompt,
            content: row.content,
            live: row.live,
            estimatedTokens: row.est_tokens,
            contextID: UUID(uuidString: row.context_id) ?? UUID()
        )
    }

    private static func toContextTool(_ row: ContextToolRow) -> ContextTool {
        ContextTool(
            contextID: UUID(uuidString: row.context_id) ?? UUID(),
            toolName: row.tool_name,
            definition: row.definition
        )
    }
}

// MARK: - DatabaseError helpers

private extension DatabaseError {
    var isUniquenessViolation: Bool {
        resultCode == .SQLITE_CONSTRAINT_UNIQUE
            || extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE
            || resultCode == .SQLITE_CONSTRAINT
    }
}
