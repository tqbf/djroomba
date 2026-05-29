import Foundation
import ContextWindow
import ContextWindowOpenAI

// BasicClient — a standalone example of consuming the ContextWindow library
// via SwiftPM (see Package.swift: `.package(path: "../..")`).
//
// By default this runs FULLY OFFLINE: it creates an in-memory store, opens a
// context, sets a system prompt, adds a user prompt, and prints token usage.
// No network, no API key required.
//
// The OpenAI wiring below is shown for documentation only and is guarded by an
// env check that is NOT satisfied by default, so `swift run` never makes a
// network call unless a human explicitly opts in.
//
//   swift run BasicClient                         # offline demo (default)
//   CONTEXTWINDOW_EXAMPLE_LIVE=1 swift run BasicClient   # opt-in: real call

@main
struct BasicClient {
    static func main() async {
        do {
            try await runOfflineDemo()

            if ProcessInfo.processInfo.environment["CONTEXTWINDOW_EXAMPLE_LIVE"] == "1" {
                try await runLiveDemo()
            } else {
                print("---")
                print("(set CONTEXTWINDOW_EXAMPLE_LIVE=1 with OPENAI_API_KEY to make a real model call)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Offline path: no model, no network. Demonstrates the core API surface.
    static func runOfflineDemo() async throws {
        // In-memory SQLite store — nothing is written to disk.
        let store = try SQLiteContextStore.inMemory()
        let cw = try ContextWindow(store: store, contextName: "demo")

        try await cw.setSystemPrompt("You are a concise assistant.")
        try await cw.addPrompt("What is the Go programming language?")

        let live = try await cw.liveRecords()
        let usage = try await cw.tokenUsage()

        print("context: \(await cw.currentContext.name)")
        print("live records: \(live.count)")
        for record in live {
            print("  [\(record.source)] \(record.content)")
        }
        print("estimated live tokens: \(usage.liveTokens)")
    }

    /// Opt-in path: wires a real `OpenAIChatModel`. Only reached when
    /// `CONTEXTWINDOW_EXAMPLE_LIVE=1` (and `OPENAI_API_KEY`) are set, so the
    /// default build/run is network-free.
    static func runLiveDemo() async throws {
        let store = try SQLiteContextStore.inMemory()
        // Key comes from OPENAI_API_KEY in the environment — never hardcoded.
        let model = try OpenAIChatModel(model: "gpt-4.1-mini")
        let cw = try ContextWindow(store: store, contextName: "demo-live", model: model)

        try await cw.setSystemPrompt("You are a concise assistant.")
        try await cw.addPrompt("In one sentence: what is the Go programming language?")

        let reply = try await cw.callModel()
        let total = await cw.metrics.totalModelTokens

        print("---")
        print(reply)
        print("model tokens (this process): \(total)")
    }
}
