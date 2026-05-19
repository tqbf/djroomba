# Catalog playlists — adding Apple Music *catalog* tracks

Status: **planned, not started.** Scope expansion (the original spec is
library-first, "never opens into catalog search" — a deliberate non-goal).
The data model was built namespace-aware from day one, so this is a clean
addition, not a refactor. **No web service / developer-token / Apple Music
REST API is involved** — native `MusicKit` on macOS authenticates as the
user and runs catalog search + playback in-process.

## Subscription assumption (load-bearing simplification)

**This app may assume the user has an active Apple Music subscription.**
It is a single-user app for the owner (an Apple Music subscriber). So:

- No preview-only / 30-second-clip mode, no "subscribe to continue"
  upsell flows, no degraded no-subscription UX. Catalog features assume
  full playback is available.
- The existing subscription gating (`MusicSubscriptionService`,
  `canPlayCatalogContent`, `playbackUnavailableReason`, the
  "Subscription Needed" empty state) is **kept as a thin, already-built
  safety net** — it costs nothing and correctly degrades if a
  subscription genuinely lapses or the account changes — but it is **not
  a design driver**. Don't invest in elaborate unsubscribed journeys.

(Also recorded in PLAN.md → Key design decisions, and the auto-memory.)

## The access question, answered

Native `MusicKit` (the Swift framework, `import MusicKit`) does catalog
**search** (`MusicCatalogSearchRequest`), **resource fetch**
(`MusicCatalogResourceRequest`) and **playback**
(`ApplicationMusicPlayer`) entirely on-device using the user's authorized
session. The developer-token JWT + `api.music.apple.com` + a key-signing
server is the **MusicKit JS / web** path and is **not needed** here.

Required Apple-side setup (portal only, no entitlements-file change —
native MusicKit has no client entitlement key):

1. developer.apple.com → Certificates, Identifiers & Profiles →
   Identifiers → App ID `org.sockpuppet.djroomba` (Team KK7E9G89GW) →
   enable the **MusicKit** App Service → save.
2. No MusicKit `.p8` key / Media ID / Key ID (JS/REST only — skip).
3. Manual `codesign` flow: the service is enforced server-side by
   bundle-id + team; `make build` + run signed. Regenerate any
   development provisioning profile so it reflects the updated App-ID
   services.
4. `NSAppleMusicUsageDescription` already in `Info.plist`; sandbox +
   `com.apple.security.network.client` already cover the network.

**Unproven for THIS App ID.** Phase-1 only ever proved the *library*
path on the dev-signed build. "Catalog works natively, no server" is true
of MusicKit generally, but is empirically unverified here until a signed
run issues a catalog request — hence Phase 0 is a hard gate (the
project's "access-validation gate" convention, like roadmap Phase 1).

## What already exists (designed for this)

- `song.id_namespace` = `library | catalog`; import dedupe key is
  `(music_item_id, id_namespace)`. A catalog track coexists with a
  library track even on a colliding id. `upsertSongs` is already
  namespace-safe.
- `app_playlist*` references our `song.id` (app UUID), not Apple ids —
  fully namespace-agnostic. "Make a playlist from these tracks" works the
  instant catalog tracks are `song` rows; **no Phase-4 changes**.
- `PlaybackResolver` already has a **dormant, wired** catalog branch
  (`MusicCatalogResourceRequest<Song>`); pure group/reassemble logic is
  shared with the library path.
- Catalog identity is *easier*: catalog `MusicItemID`s are globally
  stable (unlike library ids and the D1 round-trip saga).
- Library import / prune / album-genre passes are all `.library`-scoped,
  so catalog rows are isolated by construction (verify with a test
  mirroring the existing one-way-isolation tests).

## Phased plan

**Phase 0 — Access gate (BLOCKING).** Enable the MusicKit App Service
(steps above). Signed run: a hardcoded `MusicCatalogSearchRequest` for a
known song returns results AND one resulting catalog `Song` plays via
`ApplicationMusicPlayer`. Nothing else proceeds until this is green.
Records the empirical finding in PROGRESS (the Phase-1 analogue for
catalog).

**Phase 1 — Catalog → `song` ingest.** A `CatalogIngestService` /
`Song(fromCatalog:)` mapping that mints `idNamespace: .catalog`
(provenance-fixed, the mirror of `ImportService.song(from:)`'s `.library`
rule). Reuse `upsertSongs` unchanged. Pure mapping unit-tested. No schema
change. One-way-isolation test: catalog rows survive a library
import/prune untouched; a library re-import never clobbers a `.catalog`
row (different unique key).

**Phase 2 — Catalog search surface.** A deliberately **subordinate**
search (sheet or a clearly secondary pane — the app never *opens* into
it; playlists stay first). `MusicCatalogSearchRequest` paged with the
proven M1-style capped loop; tolerate-and-surface per-page failures like
the import loop. A debounced query (pure debounce/decider unit-tested).
Results reuse the **existing** add-to-app-playlist affordances (the
"Add to Playlist ▸" context submenu + drag-to-sidebar) and the new
"Add to Genre ▸" — they're namespace-agnostic already.

**Phase 3 — Playback (signed-gated).** Flip the dormant
`PlaybackResolver` catalog branch on; verify reassembly of a **mixed**
library+catalog queue; the start-id attribution + play-recording paths
are namespace-agnostic (keyed on our `song.id`) so stats "just work".
Subscription is assumed (above); the existing gate stays as the safety
net only.

**Phase 4 — Artwork.** Add a catalog branch to `ArtworkProvider`
(`MusicCatalogResourceRequest<Song>` re-resolve). Easier than library —
catalog artwork is a public URL, not the private `musicKit://` scheme.

## Cross-cutting invariants / risks

- No write-back to Apple — unchanged. Catalog tracks live only in our
  SQLite + app playlists; nothing is pushed to the user's Apple library.
- Rate limiting: catalog requests are Apple-rate-limited → page
  conservatively, tolerate-and-surface (the import loop's posture).
- Region/availability: a catalog track unavailable in the storefront →
  the resolver already drops-and-reports unresolved rows; no queue break.
- Catalog id stability is a strength, not a risk (globally stable).
- `make`-build is debug-config; catalog is **signed-gated** end to end
  (Phases 0 & 3) like every MusicKit-touching feature.

## Out of scope

Charts / recommendations / full browse; downloading or offline; any
Apple-library mutation; the JS/REST/developer-token path (explicitly
unnecessary — see "access question").
