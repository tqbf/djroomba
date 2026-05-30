# AI in DJ Roomba

The umbrella doc for every AI feature in the app. Index + posture +
deferred work. Drill into the per-feature docs (linked below) for the
implementation depth.

## What's in the app today

**One feature — the in-app GPT assistant.** A chat window
(⌥⌘\, separate `Window` scene) where the user talks to an OpenAI
model that can read their library, search Apple Music, and make
app-owned playlists by calling tools.

That's it. There is intentionally no ambient "AI" sprinkled into other
surfaces — no auto-generated playlist art, no inferred-mood badges, no
"you might like…" recommendations on the main view. The assistant is a
discrete surface the user opens deliberately, and every model action is
visible in its transcript.

The genre map's clustering (Louvain communities, Kruskal-MST trunks,
strand inference, TF-IDF labels) is **not** AI in the sense this doc
uses the word — it's pure SQL + graph maths over the user's library, no
model in the loop. It stays under `plans/son-of-genre-map.md`.

## Index

| Doc | Scope |
|-----|-------|
| [openai-gpt.md](openai-gpt.md) | The OpenAI provider integration, the seven tools, the Assistant window, vendoring + `DJROOMBA PATCH 1`, phase plan. The only AI integration that actually ships today. |

(More docs will sit alongside if/when a second AI surface lands.)

## Provider boundary

We talk to OpenAI through **`tqbf/contextwindow-swift`** (vendored at
`Vendor/contextwindow-swift`), specifically its `OpenAIChatModel`
adapter against `POST /v1/chat/completions`. `ContextWindow` is the
durable conversation/tool runtime; `LateBoundToolExecutor` solves the
chicken-and-egg between the model and the window at construction. The
library is the only place the app talks HTTP to OpenAI — the app
itself owns no networking against the provider.

A single `DJROOMBA PATCH 1` lives in
`Vendor/contextwindow-swift/Sources/ContextWindowOpenAI/OpenAIChatModel.swift`:
the per-record `.toolOutput` → `ChatMessage` mapping was losing
`tool_call_id`, so every multi-turn conversation died with HTTP 400 on
the second turn. Fixed with a sequential walker that pairs each tool
output to its preceding tool call. See `openai-gpt.md` for the depth.

Model: hardcoded `gpt-4.1-mini` today. Pulling model choice into
Settings (and considering the `OpenAIResponsesModel` adapter) is a
deferred phase.

## Tools the assistant has

Read + write a single surface area — the local SQLite library + a
catalog search hop through MusicKit. Each is one
`JSONSchemaToolDefinition` + a `ClosureToolRunner`, wrapped in
`LoggedToolRunner` for uniform observability. Cap on every list-shaped
response so the model never sees a 200-row blob.

- `list_playlists` — every playlist or scoped to `library` / `app`.
- `playlist_contents` — tracks in a playlist, capped at 200 with
  `truncated: true` past that.
- `track_genres` — empty args → distinct genres list; with `trackIds`
  → per-track genres.
- `search_apple_music` — `MusicCatalogSearchRequest` + ingest via
  `CatalogIngestService`, returns internal `song.id`s so the output
  feeds straight into `add_tracks_to_playlist`.
- `recently_played` — distinct-by-song, default 25, max 100.
- `create_playlist` — `LibraryStore.createAppPlaylist(named:)`.
- `add_tracks_to_playlist` — refuses library (read-only) playlists.

Read details live in `openai-gpt.md`.

## State, identity, and storage

- **API key.** macOS Keychain, generic-password, namespaced under the
  bundle id. Sandbox-default access group; no `keychain-access-groups`
  entitlement needed. Never written to `UserDefaults`, never logged.
- **Conversation.** Separate SQLite file at
  `~/Library/Application Support/DJRoomba/assistant.sqlite`
  (`SQLiteContextStore`). **Not** the library DB. Same GRDB engine, no
  schema intersection. Re-launches reattach to the same context by
  name (`djroomba-assistant`).
- **System prompt.** Set via `setSystemPrompt` so re-runs deaden any
  prior copy rather than accumulating. Lives in source
  (`GPTService.systemPrompt`); short and specific; tool affordances
  are described in each tool's own schema rather than duplicated here.

## Privacy posture

- The app **never** sends the user's library wholesale to a model. The
  tool boundary is the only thing the model sees, one row-bounded
  response at a time.
- Catalog search runs against the user's own MusicKit account (already
  the case for the existing search sheet) and pays for the ingest
  side-effect: a `search_apple_music` call lands the result rows in
  the local `song` table so the ids can flow into the next tool. The
  user can clean those out via the existing playlist UI; this is
  visible in the transcript.
- All write tools that mutate local state (`create_playlist`,
  `add_tracks_to_playlist`) operate **only** on app-owned playlists.
  Library playlists are read-only. App playlists are local-only and
  never written back to Apple Music — this matches the `PLAN.md`
  "no library mutation" rule.

## Observability

Apple unified logging makes the assistant's behaviour replayable
without screenshots. One `os.Logger` under
`subsystem = org.sockpuppet.djroomba`, `category = openai`. Every
`→ user`, `← assistant`, `→ tool`, `← tool`, `!` is at `.info` so it
persists on disk (not just `log stream`).

```sh
log show --predicate \
  'subsystem == "org.sockpuppet.djroomba" AND category == "openai"' \
  --info --last 5m
```

The API key, the full system prompt, and the un-truncated tool outputs
are never logged. `LoggedToolRunner` wraps every tool at registration
time so the per-tool boundary is uniform — adding a new tool is one
schema + one runner, and it's logged automatically.

PLAN.md also carries this in the top-level `Observability` section.

## What we will not build

These have been considered and explicitly turned down for now. The
list is short on purpose; long enough to keep us honest about the
direction we picked.

- **Ambient AI in the main UI.** No assistant inline in the playlist
  detail, no "smart" autoplay, no recommendation chrome on the sidebar.
  Keeps the playlist-forward, operational shape of the app intact.
- **Local / on-device models.** Not interesting for this product
  surface — the assistant boundary is the user's own library, not
  something a small local model handles better than a hosted one. We
  can revisit if/when first-party models from Apple ship something
  worth wiring up (Apple Intelligence / Foundation Models framework).
- **Streaming UI today.** The model returns the whole reply, then we
  render. Streaming is a Phase-3 polish (see below); the assistant
  feels fine without it for tool-heavy turns because the user sees
  tool rows pile up during the loop.
- **Audio / DSP / fingerprinting.** Out of scope for this app
  entirely (`PLAN.md` non-goal).

## Deferred phases

Tracked in detail in `openai-gpt.md`'s deferred section; mirrored here
so the umbrella stays useful.

- **More tools / state mutation.** Today's surface is read + app-playlist
  writes. Candidates: `play_playlist`, `set_favorite`, rename / delete /
  reorder for app playlists, genre rename + merge (which already exist
  as UI commands and have a clean store-level entry point).
- **Streaming + model picker.** Surface model choice in Settings;
  consider `OpenAIResponsesModel` (already in the vendored package).
  Stream the assistant turn so the transcript reveals progressively.
- **Surface polish.** The assistant lives in its own `Window` today;
  an inspector column on the main library window is a plausible
  future home (per `macos-design`), driven by user feedback rather
  than speculation.
- **A second provider.** No active need. If/when, the
  `contextwindow-swift` `Model` protocol is the seam; nothing in
  `GPTService` is OpenAI-shaped.

## Costs

`gpt-4.1-mini` is the cheap default. The tool loop has the library's
`maxToolRoundTrips: 8` ceiling. We don't track or surface spend yet;
when we add streaming we should also expose `tokenUsage()` (which the
window already accumulates) in the Assistant window or Settings, so
the user can see what their conversation has cost.
