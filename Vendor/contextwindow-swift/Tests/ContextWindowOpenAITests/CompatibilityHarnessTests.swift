import XCTest
@testable import ContextWindow

/// Adapted Go-parity harness (no Go binary on this machine — see master plan
/// "Context & deviations"). It guarantees the durable format three ways:
///
/// 1. **Round trip:** Swift writes a SQLite DB then re-opens it and asserts the
///    decoded contexts/records/tools match what was written. (This file.)
/// 2. **Schema shape:** exact table names, index names, and column shape are
///    asserted in ``SchemaShapeTests`` (separate file — needs GRDB).
/// 3. **Golden export:** a normalized JSON export (timestamps → fixed,
///    UUIDs → fixed) is asserted equal to a committed fixture under
///    `Fixtures/go-parity/`. (This file.)
///
/// Entirely offline — temp-file SQLite, no network. This file deliberately does
/// **not** `import GRDB` so the domain `Record`/`Context` types are
/// unambiguous (GRDB ships its own `Record`).
final class CompatibilityHarnessTests: XCTestCase {

    private func tempDBPath() -> String {
        NSTemporaryDirectory() + "cw-compat-\(UUID().uuidString).sqlite"
    }

    // MARK: 1. Round trip — write, re-open, decoded values match

    func testRoundTripWriteReopenDecodesIdentically() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Baseline: what the *persisted* DB holds, read back through the
        // store. (We compare persisted-read vs reopen-read rather than the
        // pre-persist in-memory `insertRecord` returns: SQLite `DATETIME`
        // stores second granularity, so the in-memory `Date()` carries
        // sub-second precision the column drops. The durable-format guarantee
        // is that a *reader* — Swift now, Go later — sees byte-identical data
        // on every open, which is exactly this comparison.)
        let contextID: UUID
        let baselineContext: Context
        let baselineAll: [Record]
        let baselineLive: [Record]
        let baselineTools: [ContextTool]
        let baselineExport: ContextExport
        do {
            let store = try SQLiteContextStore(path: path)
            try store.initialize()
            let created = try store.createContext(name: "compat")
            contextID = created.id
            _ = try store.insertRecord(
                contextID: contextID, source: .systemPrompt,
                content: "be terse", live: true
            )
            _ = try store.insertRecord(
                contextID: contextID, source: .prompt,
                content: "hello there world", live: true
            )
            _ = try store.insertRecord(
                contextID: contextID, source: .modelResponse,
                content: "dead reply", live: false
            )
            try store.upsertContextTool(
                contextID: contextID,
                toolName: "search",
                definition: #"{"name":"search"}"#
            )
            baselineContext = try store.getContext(name: "compat")
            baselineAll = try store.listRecords(contextID: contextID)
            baselineLive = try store.listLiveRecords(contextID: contextID)
            baselineTools = try store.listContextTools(contextID: contextID)
            baselineExport = try store.exportContext(name: "compat")
        }

        // Re-open the *same file* with a fresh store instance: every decoded
        // value must equal the baseline persisted read.
        let reopened = try SQLiteContextStore(path: path)
        XCTAssertEqual(try reopened.listContexts(), [baselineContext])
        XCTAssertEqual(try reopened.listRecords(contextID: contextID), baselineAll)
        XCTAssertEqual(baselineAll.count, 3)
        XCTAssertEqual(
            try reopened.listLiveRecords(contextID: contextID), baselineLive
        )
        XCTAssertEqual(baselineLive.map(\.content), ["be terse", "hello there world"])
        XCTAssertEqual(
            try reopened.listContextTools(contextID: contextID), baselineTools
        )
        XCTAssertEqual(baselineTools, [
            ContextTool(
                contextID: contextID,
                toolName: "search",
                definition: #"{"name":"search"}"#
            )
        ])

        let export = try reopened.exportContext(name: "compat")
        XCTAssertEqual(export, baselineExport)
        XCTAssertEqual(export.context.name, "compat")
        XCTAssertEqual(export.records.count, 3)
    }

    // MARK: 3. Golden JSON export — normalized, equals committed fixture

    /// Build a deterministic export and normalize volatile fields so the JSON
    /// is byte-stable: every UUID → all-zero UUID, every timestamp → epoch,
    /// and `records.id` → 1-based position (independent of the rowid counter).
    private func normalizedExportJSON() throws -> String {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try SQLiteContextStore(path: path)
        try store.initialize()
        let ctx = try store.createContext(name: "golden")
        _ = try store.insertRecord(
            contextID: ctx.id, source: .systemPrompt,
            content: "You are concise.", live: true
        )
        _ = try store.insertRecord(
            contextID: ctx.id, source: .prompt,
            content: "What is the Go programming language?", live: true
        )
        _ = try store.insertRecord(
            contextID: ctx.id, source: .modelResponse,
            content: "A statically typed compiled language.", live: true
        )
        _ = try store.insertRecord(
            contextID: ctx.id, source: .toolCall,
            content: #"search({"q":"go"})"#, live: false
        )
        try store.upsertContextTool(
            contextID: ctx.id,
            toolName: "search",
            definition: #"{"name":"search","strict":false}"#
        )
        let export = try store.exportContext(name: "golden")

        let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let epoch = Date(timeIntervalSince1970: 0)

        let normContext = Context(
            id: zeroUUID, name: export.context.name, startTime: epoch
        )
        let normRecords = export.records.enumerated().map { idx, r in
            Record(
                id: Int64(idx + 1),
                timestamp: epoch,
                source: r.source,
                content: r.content,
                live: r.live,
                estimatedTokens: r.estimatedTokens,
                contextID: zeroUUID
            )
        }
        let normTools = export.tools.map {
            ContextTool(
                contextID: zeroUUID,
                toolName: $0.toolName,
                definition: $0.definition
            )
        }
        let normExport = ContextExport(
            context: normContext, records: normRecords, tools: normTools
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(normExport)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// Regenerates the committed fixture. Skipped unless
    /// `CONTEXTWINDOW_REGEN_FIXTURES=1`; used once to seed/refresh the golden
    /// file. Writes to the source tree, not the test bundle.
    func testRegenerateGoldenFixture() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CONTEXTWINDOW_REGEN_FIXTURES"] == "1",
            "set CONTEXTWINDOW_REGEN_FIXTURES=1 to (re)write the golden fixture"
        )
        let produced = try normalizedExportJSON()
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // (a) the test-bundle resource (Bundle.module reads this) and
        // (b) the canonical committed copy at the repo root, kept in sync.
        let targets = [
            testDir.appendingPathComponent("Fixtures/go-parity/context-export.json"),
            testDir
                .deletingLastPathComponent()      // Tests/
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Fixtures/go-parity/context-export.json"),
        ]
        for target in targets {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try produced.write(to: target, atomically: true, encoding: .utf8)
        }
    }

    func testGoldenExportMatchesCommittedFixture() throws {
        let produced = try normalizedExportJSON()

        guard
            let fixtureURL = Bundle.module.url(
                forResource: "context-export",
                withExtension: "json",
                subdirectory: "Fixtures/go-parity"
            ),
            let expected = try? String(contentsOf: fixtureURL, encoding: .utf8)
        else {
            XCTFail("missing committed fixture Fixtures/go-parity/context-export.json")
            return
        }

        XCTAssertEqual(
            produced, expected,
            "golden export drifted from the committed fixture; if intentional, "
            + "regenerate Fixtures/go-parity/context-export.json"
        )
    }
}
