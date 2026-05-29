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

## Phase 1 — Persistent conversation + tools + Assistant window (✅ 2026-05-29)

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
- **Standalone Assistant `Window` scene** (⌥⌘\\), separate from the
  main library `WindowGroup`. Transcript at top (user / assistant /
  tool turns, each iconified, tool turns muted; JSON outputs truncated
  in the transcript view), composer at bottom (multiline `TextField`,
  arrow-up Send button, error banner above the divider). The Assistant
  reads `controller.gpt` via `@Environment(MusicController.self)`; the
  Settings → OpenAI pane reads the same instance.
- **Settings reshape.** The Phase-0 "Connection Test" section is gone —
  the Assistant window IS the test now. The OpenAI Settings pane keeps
  the API-key field + adds an "Open Assistant Window" button.
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

## Deferred (next phases)

- **Phase 2 — More tools / state mutation.** Today's surface is read +
  app-playlist writes. Future tools: `play_playlist`, `set_favorite`,
  rename/delete/reorder for app playlists, genre rename/merge.
- **Phase 3 — Streaming + model picker.** Today's spike uses the
  Chat-Completions adapter and a hardcoded `gpt-4.1-mini`. Pull model
  choice into Settings; consider the Responses adapter
  (`OpenAIResponsesModel` exists in the same package). Stream the
  assistant turn so the transcript shows the reply progressively rather
  than after the whole loop completes.
- **Phase 4 — Surface polish.** The Assistant lives in its own Window
  today; an inspector column on the main library window is a likely
  future home (per `macos-design`), driven by user feedback.

## Risks carried forward

- **Key handling.** Never log the key; the adapter already redacts (errors
  carry status + body but not the `Authorization` header). The Keychain
  item is `WhenUnlocked` — the app only ever reads it while the user is
  actively driving it.
- **Cost discipline.** `gpt-4.1-mini` for the spike is cheap, but Phase 2's
  tool loop can iterate (`maxToolRoundTrips: 8` default). Surface token
  spend in the UI before any prolonged use.
- **Library DB coupling.** The future `ContextWindow` store **must** be a
  separate SQLite file from `library.sqlite` — GRDB is shared as a transitive
  dep, the *databases* are not.
