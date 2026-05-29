# ContextWindow (Swift)

A named-context + append-only record store with live/dead compaction, token
accounting, a model call loop, summarization, tools, and OpenAI provider
adapters. Swift port of the Go `contextwindow` library.

The SQLite schema is the durable, valuable artifact and is kept shape-stable on
purpose so a future Go build can interoperate with databases this port writes.

**This package is application-independent.** It is a headless, reusable library:
no UI, no SwiftUI, no app-specific models, no bundled credentials, no hardcoded
paths or endpoints. Any Swift / macOS / iOS app can depend on it via SwiftPM.

## Requirements

- Swift 6.0+ toolchain (the library is built with Swift 6 language mode; strict
  concurrency on; all public types `Sendable`)
- macOS 14+ or iOS 17+
- One dependency: [GRDB](https://github.com/groue/GRDB.swift) (SQLite)

## Supported platforms

| Platform | Minimum |
|----------|---------|
| macOS    | 14.0    |
| iOS      | 17.0    |

Both library products (`ContextWindow`, `ContextWindowOpenAI`) build for macOS
and iOS. The OpenAI adapter's networking is `URLSession`-based and injectable,
so it is platform-neutral.

## Installation (Swift Package Manager)

Add the package to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/<repo>.git", from: "0.1.0")
]
```

Then add the product(s) you need to a target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "ContextWindow", package: "<repo>"),
        // Optional: the OpenAI provider adapter
        .product(name: "ContextWindowOpenAI", package: "<repo>")
    ]
)
```

`ContextWindow` is the application-independent core (store, window, model
boundary, tools). `ContextWindowOpenAI` is an optional, reusable provider
adapter (OpenAI Chat + Responses, `URLSession` transport) — the core does not
depend on it.

**Local path (no remote / development):** there is currently no published
remote. To consume the library from a local checkout, use a path dependency:

```swift
.package(path: "/absolute/path/to/contextwindow")
// or relative, e.g. .package(path: "../contextwindow")
```

This is exactly how `Examples/BasicClient/` consumes it
(`.package(path: "../..")`).

## Minimal usage (offline, no network)

The core works with no model and no network at all — useful for tests and for
apps that manage their own model calls:

```swift
import ContextWindow

let store = try SQLiteContextStore.inMemory()          // or .init(path:)
let cw = try ContextWindow(store: store, contextName: "demo")

try await cw.setSystemPrompt("You are a concise assistant.")
try await cw.addPrompt("What is the Go programming language?")

let usage = try await cw.tokenUsage()
print("live tokens:", usage.liveTokens)                // estimated, offline
```

## Usage with the OpenAI adapter

```swift
import ContextWindow
import ContextWindowOpenAI

let store = try SQLiteContextStore(path: "contextwindow.sqlite")
let model = try OpenAIChatModel(model: "gpt-4.1-mini")   // reads OPENAI_API_KEY
let cw = try ContextWindow(store: store, contextName: "default", model: model)

try await cw.setSystemPrompt("You are concise.")
try await cw.addPrompt("What is the Go programming language?")
let reply = try await cw.callModel()
print(reply)
```

## Configuration

- **API key:** `OpenAIChatModel` / `OpenAIResponsesModel` read the API key from
  the `OPENAI_API_KEY` environment variable by default (you may also pass
  `apiKey:` explicitly). The key is never hardcoded and never logged. The
  repo's `.envrc` exports it for local development and is **git-ignored** — it
  is never committed.
- **Injectable transport (cost discipline):** the HTTP boundary is the
  `OpenAITransport` protocol. Production uses `URLSessionOpenAITransport` (the
  only network-capable type). Tests inject a stub that returns canned JSON, so
  the suite makes zero network calls. Inject your own transport to mock,
  record/replay, or route requests.
- **Endpoint override:** `baseURL:` on both adapters defaults to the public
  OpenAI endpoint (`https://api.openai.com/v1`) and can be overridden (e.g. for
  a proxy or an Azure/compatible endpoint).

## Dependency note

The only third-party dependency is [GRDB](https://github.com/groue/GRDB.swift)
(SQLite), used by `SQLiteContextStore` for the durable, shape-stable schema. No
other dependencies are added; the OpenAI adapter uses only `Foundation` /
`URLSession`.

## Example client

`Examples/BasicClient/` is a standalone SwiftPM package that depends on this
library via a local path (`.package(path: "../..")`). It demonstrates
`import ContextWindow` and runs **fully offline by default** (in-memory store,
add a prompt, print token usage). Real `OpenAIChatModel` wiring is shown but
guarded behind an env check that is not satisfied by default:

```sh
cd Examples/BasicClient
swift run BasicClient                                  # offline demo
CONTEXTWINDOW_EXAMPLE_LIVE=1 swift run BasicClient      # opt-in: real call
```

The main package's targets are explicit and live in `Sources/`, so building or
testing the root package never builds `Examples/`.

## Package layout

```text
Sources/ContextWindow/         core: store, window, model boundary, tools
Sources/ContextWindowOpenAI/   OpenAI Chat + Responses adapters, HTTP transport
Tests/ContextWindowTests/      Phase 1–2 tests (45)
Tests/ContextWindowOpenAITests/ adapter + compatibility-harness tests
Examples/BasicClient/          standalone example package (local-path consumer)
Fixtures/go-parity/            committed golden JSON export fixture
```

## Tests & cost discipline

```sh
swift build
swift test                       # all logic, ZERO network (stubbed transport)
```

All adapter logic is exercised offline with an injected stub HTTP transport.
The only network-capable type is `URLSessionOpenAITransport`; the suite never
constructs one. Live OpenAI tests are gated and **skipped by default**:

```sh
CONTEXTWINDOW_LIVE_OPENAI=1 swift test --filter LiveOpenAITests
```

That runs at most two real round trips (one Chat completion; the tool-call
loop is additionally opt-in via `CONTEXTWINDOW_LIVE_OPENAI_TOOLS=1`).

## Documentation

- [docs/porting-notes.md](docs/porting-notes.md) — no-Go-source reality + deviations
- [docs/provider-adapter-contract.md](docs/provider-adapter-contract.md) — how to write a `Model` adapter
- [docs/tool-definition-format.md](docs/tool-definition-format.md) — the neutral tool schema
- [docs/compaction-lifecycle.md](docs/compaction-lifecycle.md) — summarize / accept / reject
- [PLAN.md](PLAN.md) / [PROGRESS.md](PROGRESS.md) — project index + state
- [LICENSE](LICENSE) — MIT
```
