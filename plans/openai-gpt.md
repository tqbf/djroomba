# OpenAI GPT integration

A separate workstream from the music functionality: give the app a path to
talk to OpenAI's GPT models, with tool calls later wiring the model into
SQLite-backed library actions. Built on **`tqbf/contextwindow-swift`** (the
named-context record store + provider-neutral model loop + OpenAI adapter
the user already maintains), pinned in `Package.swift` at `0.1.0`. The
adapter we use is `ContextWindowOpenAI.OpenAIChatModel` — a `Sendable`
`Model` over `POST /v1/chat/completions` with a built-in tool-call loop;
the substrate's `ContextWindow` actor is the durable conversation/tool
runtime the later phases plug into.

## Identity — "signin" reality

OpenAI does **not** offer an OAuth / "Sign in with OpenAI" that hands a
native desktop app an API key. Keys are minted by hand at
`platform.openai.com`. The honest native equivalent is the paste-once flow
this spike implements: the user pastes a key into a `SecureField` and we
stash it in the macOS Keychain. The pane's footer says exactly that so
nobody is surprised. (If OpenAI ever ships an OAuth → key issuance flow,
that becomes a follow-up phase; nothing in the current code assumes it.)

## Phase 0 — Feature spike (✅ 2026-05-29)

Smallest end-to-end proof: store a key + send one message + see the reply.

- **`DJRoomba/Support/KeychainItem.swift`** — small `Sendable` value
  (`service` + `account`) wrapping the three `SecItem*` calls
  (`SecItemCopyMatching` / `SecItemUpdate` / `SecItemAdd` / `SecItemDelete`).
  Generic-password class, `kSecAttrAccessibleWhenUnlocked`. A sandboxed
  app is automatically granted a keychain access group keyed to the
  application-identifier, so no `keychain-access-groups` entitlement is
  required.
- **`DJRoomba/Music/GPTService.swift`** — `@MainActor @Observable` service
  matching the project's state rules. Holds `isKeyConfigured`, `isSending`,
  `lastResponse`, `errorMessage`; `saveKey` / `clearKey` / `send(prompt:)`.
  `send(prompt:)` constructs an `OpenAIChatModel(model: "gpt-4.1-mini",
  apiKey: …)` and `await`s `model.call([Record])` with a single `.prompt`
  record. The model's `call(_:)` is non-isolated, so the network I/O hops
  off the `MainActor` and the result republishes back here. No
  `ContextWindow` / SQLite store yet — the spike doesn't need persistence.
- **`DJRoomba/Views/Settings/OpenAISettingsPane.swift`** — new **OpenAI**
  tab in the existing tabbed `Settings` scene (alongside **Advanced**).
  Two `Form` `Section`s: API Key (`SecureField` + Save when empty; status
  row + Remove once configured) and Connection Test (prompt prefilled
  `"Hi"`, `Send`, response area, error label). Owns its own `GPTService`
  via `@State` — Settings doesn't get the `MusicController` environment,
  matching `GenreAnalysisAdvancedPane`'s self-contained pattern.
  `SettingsView` bumped to `520 × 440` to comfortably show a response.
- **Entitlements:** unchanged. `com.apple.security.network.client` was
  already present (for MusicKit / artwork). No new entitlement needed for
  Keychain in a sandboxed app.

### Verified
`swift build`, `swiftformat --lint`, `swiftlint --strict`, signed
`make build` all clean. Live round-trip confirmed on the real app via
computer-use: opened **Settings → OpenAI**, pasted a key, sent `"Hi"`,
saw GPT's reply in the Response area.

## Phase 1 — Persistent conversation + tools + Assistant surface (✅ 2026-05-29)

Phase 1 collapsed what had been planned as three sub-phases into one
landing because the substrate matured cleanly together.

- **Persistent `ContextWindow`.** `GPTService` now holds a
  `SQLiteContextStore(path:)` at `Application Support/DJRoomba/
  assistant.sqlite` (separate file from `library.sqlite`; same GRDB
  engine, no schema intersection). Built lazily on the first send.
  Idempotent system prompt (`setSystemPrompt` deadens prior ones), so a
  re-launch reattaches to the same conversation. Transcript is rebuilt
  from `window.allRecords()` on every turn — cheap, single read.
- **`LateBoundToolExecutor`.** Solves the chicken-and-egg between
  `OpenAIChatModel(toolExecutor:)` and `ContextWindow(model:)`: build
  the executor first, hand it to the model, build the window with the
  model, then `executor.bind(window)`. The pattern is upstream's
  canonical (used by `LiveOpenAITests.testLiveChatToolCallLoopOptional`).
- **Seven tools** (`DJRoomba/Music/GPTToolRegistration.swift`):
  - `list_playlists` — every playlist or scoped to `library` / `app`.
  - `playlist_contents` — tracks in a playlist (library OR app), capped
    at 200 with `truncated: true` past that.
  - `track_genres` — empty args list every distinct genre; with
    `trackIds`, returns `[{id, title, genres}]` per track.
  - `search_apple_music` — `MusicCatalogSearchRequest`, ingest results
    via `CatalogIngestService`, returns internal `song.id`s so the
    output can flow straight into `add_tracks_to_playlist`.
  - `recently_played` — `LibraryStore.recentlyPlayedPage(beforeSeq: nil,
    limit:)`. Default 25, max 100.
  - `create_playlist` — `LibraryStore.createAppPlaylist(named:)`.
  - `add_tracks_to_playlist` — `LibraryStore.addSongsToAppPlaylist(_:
    songIDs:)` after asserting the target is an app (writable) playlist.
  Every runner is wrapped in `LoggedToolRunner` so each tool call + its
  output is observable via `log show` (see PLAN.md → Observability).
- **Assistant surface** (⌥⌘\\). Originally shipped 2026-05-29 morning
  as a standalone `Window("DJ Roomba Assistant", id: AssistantWindowID)`
  scene; later that day the user asked it to share the bottom dock
  pane with the genre map via tabs, so the standalone window was
  retired and `AssistantPaneView` now lives in the **DJ Roomba** tab
  of `BottomDockPane`. Transcript at top (user / assistant / tool
  turns, each iconified, tool turns muted; JSON outputs truncated
  in the transcript view), composer at bottom (multiline `TextField`,
  arrow-up Send button, error banner above the divider). Reads
  `controller.gpt` via `@Environment(MusicController.self)`; the
  Settings → OpenAI pane reads the same instance.
- **Settings reshape.** The Phase-0 "Connection Test" section is gone —
  the assistant surface IS the test now. The OpenAI Settings pane
  keeps the API-key field + a "Show DJ Roomba" button that calls
  `controller.showAssistant()` to expand the bottom dock onto the
  DJ Roomba tab.
- **MusicController.gpt** — one canonical instance, constructed in
  `MusicController.init` with the `LibraryStore` + `CatalogIngestService`
  it needs. No retain cycle (the dependencies are values / @MainActor
  classes, captured weakly by the tool runners).

### Vendoring + `DJROOMBA PATCH 1` (2026-05-29)

Phase 1 caught a real bug in `tqbf/contextwindow-swift 0.1.0`:
`OpenAIChatModel.message(for:)`'s mapping for `.toolOutput` records
sets `tool_call_id: nil`. That's fine **inside** a single tool-loop turn
(the loop's `messages.append(...)` branch sets the id locally), but
breaks the very next turn — `cw.callModel()` reloads every live record
and re-runs the mapper, and OpenAI rejects the resulting tool message
with HTTP 400 `messages.[i].tool_call_id`. So every multi-turn
conversation with tools breaks once the loop completes.

The fix: vendor the library under `Vendor/contextwindow-swift` (same
shape as the `Vendor/ForceGraph` pattern), and replace the per-record
`map(Self.message(for:))` with a sequential walker
`messages(from: [Record])` that pairs each `.toolOutput` with its
preceding `.toolCall` and emits the same synthetic
`call_<recordID>` on both sides. Adjacency is sufficient because the
in-loop persistence path always writes a `.toolCall` immediately
followed by its `.toolOutput`, so a single-slot pairing is correct for
multi-tool-call assistant turns. The patch is tagged
`DJROOMBA PATCH 1` in `Sources/ContextWindowOpenAI/OpenAIChatModel.swift`;
the old `message(for:)` is kept for callers that still want the
per-record entry point. Live-verified end-to-end across two turns via
`log show` — see the PROGRESS.md top entry for the exact trace.

`Package.swift` now points at the vendored path
(`.package(path: "Vendor/contextwindow-swift")`). The remote 0.1.0
dependency is gone.

## Phase 1.5 — Multi-conversation sidebar + gpt-5.4-mini titles (✅ 2026-05-29)

Hours after Phase 1 shipped the single-context Assistant, the user
asked for a sidebar with past conversations, save-on-restart, a
**New Request** button that archives the current chat off, and
`gpt-5.4-mini` to label them.

- **Library multi-context is the substrate.** `ContextWindow` already
  supports `listContexts` / `switchContext` / `createContext` /
  `deleteContext` on one actor sharing one `SQLiteContextStore`. Each
  conversation = one library `Context`. No second SQLite file.
- **`AssistantConversationStore`** is the app-side title storage —
  the library has no title concept, so titles + last-activity +
  current-context pointer live in `UserDefaults` (one read, one write
  per change, fully recoverable on wipe).
- **`AssistantSummarizer.modelName = "gpt-5.4-mini"`** (looked up via
  WebFetch against `developers.openai.com/api/docs/models` —
  confirmed available). Single `OpenAIChatModel(toolExecutor: nil)`
  per archive event; no `ContextWindow` (synthetic `Record`s on the
  stack). Strips quotes / trailing punctuation before writing.
- **`AssistantConversationSidebar`** is the new view. Per-conversation
  avatar discs (one of 8 hues, hash-keyed on the context id so each
  conversation owns its colour across relaunches), a cream → lavender
  vertical wash background (NSColor-backed, flips in dark mode),
  count chip in the header. Hideable via a per-tab toggle
  (`@SceneStorage("djroomba.assistant.sidebarVisible")`).
- **`loadConversationsFromDisk()`** on `GPTService` populates the
  sidebar feed + current-conversation pointer the moment the pane
  appears — `ensureSession()` is otherwise lazy and only runs on the
  first send.

## Phase 1.6 — More tools (✅ 2026-05-29)

Six more tools landed alongside the original seven, bringing the
total to **13**. All MainActor-hop through `Task { @MainActor … }`
since `MusicController` is main-actor-isolated.

- **`play_playlist` / `play_track`** dispatch `MusicCommand.playPlaylist`
  / `playTrack` through the existing `MusicController.handle(_:)` path
  — same code the sidebar Play button uses. `play_track` falls back
  to `controller.selectedPlaylistID` when no `playlistId` is given.
- **`add_genre_to_tracks` / `rename_genre`** wrap
  `LibraryStore.addGenre` / `renameGenre` (the existing
  one-way-isolated, pure-SQLite paths used by the genre editor UI).
- **`sql_query`** runs read-only `SELECT` / `WITH … SELECT` against
  `library.sqlite` via `database.dbQueue.read { db in Row.fetchAll … }`.
  Pre-flight `validateSelectOnly(_:)` rejects multi-statement strings
  and DDL/DML keywords with a clean error; GRDB's read block is the
  engine-level second line of defence. Cap 200 rows. Tool
  description embeds the schema summary inline and tells the model
  to `SELECT sql FROM sqlite_master WHERE type IN ('table','view')`
  for the full DDL — live verified the model can write a JOIN
  against `song_stat` + `song` and return top-played artists
  without an `sqlite_master` round-trip first.
- **`app_state`** reads `controller.selectedSummary` /
  `controller.playback.snapshot` / `controller.currentStoredSongID`
  and returns `{ selectedPlaylist, nowPlaying }`. Lets the model
  answer "what's selected / playing" without guessing — verified by
  the chain `app_state → play_playlist` on "play what's selected".

`GPTService` got `weak var hostController: MusicController?` + an
`attach(controller:)` method called from `MusicController.init` so
the controller is wired in without a retain cycle. A
`ControllerProvider = @Sendable @MainActor () -> MusicController?`
typealias plumbs the weak reference through to tool runners.

## Phase 1.7 — gpt-5.4 + service_tier:"flex" + DJROOMBA PATCH 2 (✅ 2026-05-29)

Per user direction: bump the chat model from `gpt-4.1-mini` to
**`gpt-5.4`**, opt into the cheaper / higher-latency **`flex`**
tier (the assistant is user-initiated but not latency-sensitive),
and surface the tool-call transcript as a togglable subtle checkbox
(some users want the trace, some find it noisy).

- **`DJROOMBA PATCH 2`** in `Vendor/contextwindow-swift/Sources/
  ContextWindowOpenAI/OpenAIChatModel.swift`: `OpenAIChatModel.init`
  gains a `serviceTier: String?` parameter; `ChatCompletionRequest`
  gains a `service_tier: String?` wire field. `nil` ⇒ omitted from
  the JSON body, server default applies; `"flex"` opts in.
  Sequenced alongside PATCH 1 (the multi-turn `tool_call_id` fix);
  same vendor + future-upstream story.
- **`GPTService.modelName = "gpt-5.4"`**; new `nonisolated static
  let serviceTier = "flex"` + `static let urlSession` configured
  with `timeoutIntervalForRequest = 900s` /
  `timeoutIntervalForResource = 1800s` so the flex tier's queue
  waits don't trip the default 60s `URLSession` timeout. Both the
  chat model and `AssistantSummarizer` (`gpt-5.4-mini`) ride the
  same session + tier.
- **Tool-call transcript toggle**
  (`@AppStorage("djroomba.assistant.showToolCalls") = true`): a
  caption-font, secondary-foreground `Toggle("…").toggleStyle(.checkbox)`
  in the per-tab header. When off, `visibleMessages` strips tool
  turns from the rendered transcript while the underlying records
  are preserved (the model still sees them on the next turn).
- **Live verified**: "Hi, say 'hello' so I can confirm gpt-5.4 +
  flex is working." → DJ Roomba replied "hello" — full chat
  round-trip on `gpt-5.4` + `service_tier: flex` succeeded.

## Phase 1.8 — Delete conversations (✅ 2026-05-29)

Sidebar swipe-left + right-click delete; the canonical macOS
trackpad gesture path plus a parallel mouse-friendly affordance.

- **`GPTService.deleteConversation(_ id:)`** dispatches
  `ContextWindow.deleteContext(name:)`, clears the app-side title
  + last-activity caches, and when the deleted conversation was
  current, reads `await session.window.currentContext.name` (the
  library's auto-switch picks the earliest remaining, or mints a
  fresh one) and adopts that as the new pointer — re-applying the
  system prompt + reloading the transcript.
- **`AssistantConversationSidebar`** converted from
  `ScrollView + LazyVStack` to `List` so `.swipeActions(edge:
  .trailing, allowsFullSwipe: false)` works. `.listStyle(.plain)` +
  `.scrollContentBackground(.hidden)` + zeroed row insets preserve
  the custom row treatment (avatars + gradient).
- **Parallel `.contextMenu`** with the same Delete action for mouse
  / accessibility users (and the only path verifiable via
  computer-use, since simulated mouse drags don't trigger trackpad
  swipe).

## Deferred (next phases)

- **Phase 3 — Streaming + model picker.** Pull model choice into
  Settings. Consider the Responses adapter (`OpenAIResponsesModel`
  already in the vendored package). Stream the assistant turn so the
  transcript reveals progressively.
- **Phase 4 — Tool surface polish.** A one-shot single-song queue
  path so `play_track` doesn't need a playlist context. Token spend
  surfaced in the Assistant pane / Settings (the `ContextWindow`
  metrics actor already accumulates this).
- **Phase 5 — Vendoring graduation.** Send PATCH 1 + PATCH 2
  upstream to `tqbf/contextwindow-swift`, retire `Vendor/
  contextwindow-swift`.

## Risks carried forward

- **Key handling.** Never log the key; the adapter already redacts (errors
  carry status + body but not the `Authorization` header). The Keychain
  item is `WhenUnlocked` — the app only ever reads it while the user is
  actively driving it.
- **Cost discipline.** `gpt-5.4` is materially more expensive per token
  than `gpt-4.1-mini`; the flex tier blunts but does not erase that.
  The 8-round-trip tool loop cap (`maxToolRoundTrips`) is unchanged
  from Phase 0; consider lowering it to 4 if observed runs cluster
  high. Surface token spend in the UI before any prolonged use —
  `ContextWindow.tokenUsage()` is already accumulating.
- **Library DB coupling.** The `ContextWindow` store stays a separate
  SQLite file from `library.sqlite` — GRDB is shared as a transitive
  dep, the *databases* are not. The `sql_query` tool reads
  `library.sqlite` only (`store.database.dbQueue.read`); the
  assistant's own SQLite (`assistant.sqlite`) is not exposed.
