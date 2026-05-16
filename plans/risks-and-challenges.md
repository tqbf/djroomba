# Problems & challenges (live risk register)

Everything working against this project, with impact, mitigation, and status.
Keep current — a future agent should trust this to know where the landmines
are. Severity: 🔴 blocking · 🟠 significant · 🟡 manageable · ⚪ noise.

## Access, signing & identity

**⚪→retired: Xcode automatic provisioning / "No Accounts".**
Was 🔴 under XcodeGen/`xcodebuild` automatic signing. Moot now: the build
system is mdv-cloned (SwiftPM + `build.sh`) and signs directly with the
keychain identity `Apple Development: Thomas Ptacek (7F2QE7P59D)` — no
Xcode-Accounts, no automatic provisioning, no `project.yml` flip. Phase 1
produced a working signed build. Status: **retired.** See
[build-system.md](build-system.md).

**🟡 (was 🔴) MusicKit App Service for `org.sockpuppet.djroomba`.**
An ad-hoc build authorizes but reads an empty library with no error.
Phase 1 proved a real **Apple Development** signature alone is sufficient
for **library read/playback** — no MusicKit-App-Service profile needed
there. The Phase 3 corrective leans into this: import + playback +
artwork are now **entirely** library-namespace (provenance), re-resolved
via `MusicLibraryRequest` only, so the dev signature with no MusicKit
entitlement covers the whole shipping path; the `MusicCatalogResource
Request` branch is dormant (no catalog ids imported). Remaining open part:
whether a **notarized Developer ID** build needs the App ID's MusicKit App
Service / an embedded provisioning profile (pre-wired as the
`PROVISION_PROFILE` hook) — and that only matters if/when the dormant
catalog branch is ever activated. Status: **dev path resolved & now the
sole runtime path; catalog/distribution path open — Phase 5.**

**🟠 Native MusicKit identity = the Mac's system Apple Account.**
No in-app login; cannot target an arbitrary Apple ID (the web/token model was
considered and rejected — Option A chosen). Impact: the library/playback the
app sees is whatever that system account exposes on this Mac. Mitigation:
accepted by design. Status: decided. See [[djroomba-musickit-identity-reality]].

**🔴→🟡 Library not present on this Mac.**
`MusicLibraryRequest` reads the *on-device* library; if Apple Music/Sync
Library was never used here, it's genuinely empty (silently — empty, not an
error). Caused the original "no playlists" surprise. Mitigation: user enables
Sync Library + signs into Apple Music on this Mac; Phase 1 validates. Status:
**open, user action**, then resolved.

**🟠→🟢 (RESOLVED in code — Phase 5; signed gate pending) Empty/failure
modes are silent.**
MusicKit returns an empty collection rather than throwing in several
"not really available" cases, so a blanket "No Playlists" couldn't
distinguish "no playlists" vs "not synced" vs "not entitled". **Phase 5
fix:** the pure, unit-tested `LibrarySidebarState.resolve(...)` cross-checks
`MusicSubscription.hasCloudLibraryEnabled` (the decisive signal — present on
the macOS 26.4 SDK) + `canPlayCatalogContent`/`canBecomeSubscriber` + auth +
the import/store problem + summary counts and yields the specific cause
(`.libraryNotSynced` / `.subscriptionNeeded` / `.noImportedPlaylists` /
`.error` / `.loading` / `.populated`). `SidebarUnavailableView` renders the
matching native, non-modal `ContentUnavailableView` with the action that
fixes it. Status: **logic RESOLVED + tested; the MusicKit-signal branches
are signed-run verification** (the agent can't put the Mac into a
not-synced / no-subscription state).

## Core architecture risk

**🔴→🟢 (RESOLVED for imported playlists; verified on a signed run) id
store-then-re-resolve round trip.**
**The signed-build gate FIRED this risk twice** — exactly why it exists. (1)
The original Phase-3 string classifier (`i.`→library / bare-numeric→catalog)
degenerated to *integer sign* on real macOS ids → nothing played. (2) The
first corrective (store the underlying `Song` id; re-resolve via
`MusicLibraryRequest<Song>.filter(\.id,memberOf:)`) **still failed the
gate**. A temporary diagnostic probe (roadmap-sanctioned; removed after)
found the true cause: a stored `music_item_id` is the playlist **Track**
id, *not* the library `Song` id — `MusicLibraryRequest<Song>` returns the
correct songs but keyed by their own `i.` ids, so song-level reassembly by
the stored id matches **zero**. **Final fix (verified live):**
`PlaybackResolver.resolvePlaylist` re-resolves the Apple playlist by its
stored library `MusicItemID` → `.with([.tracks])` (paged) → plays the live
tracks (ids+order align 1:1 with the snapshot — proven), which is exactly
Phase 1's proven path. Confirmed on a signed run: "90s Alt" (137 tracks)
played real audio, elapsed advanced, OS now-playing engaged. Silent
failures are gone (visible inline `MusicController.playbackProblem`).
Status for **imported Apple playlists: RESOLVED, runtime-verified.**

**🟠→🟢 (RESOLVED — runtime-verified on a signed build) per-song
re-resolution for app-playlists.**
The Track-id≠Song-id finding means an *arbitrary* stored song id does not
1:1 re-resolve via **batch** `MusicLibraryRequest<Song>.filter(\.id,
memberOf:)` (the returned Song carries a different `i.` id, so the
query→result correspondence is lost). Imported-playlist playback sidesteps
this at *playlist* granularity; app-playlists have no backing Apple playlist.
**Phase-4 resolution (code-complete):** the Phase-3 probe established that
the **per-id** form `MusicLibraryRequest<Song>.filter(matching:\.id,
equalTo: storedID)` *does* preserve correspondence (it's the single-id query,
not batch). `PlaybackResolver.resolveAppPlaylist` issues one such request per
**unique** stored id through a **bounded** `TaskGroup` (window of 8;
structured concurrency, no GCD, doesn't flood MusicKit), keys the result by
the **stored** id, and `reassemble`s in playlist order tolerating misses
(reported via the inline `playbackProblem`). No add-time identifier capture
was needed (so **no schema change**). The disproven batch path was removed;
the kept `groupByNamespace`/`reassemble` helpers + tests now back the
working path; a new test covers the app-playlist reassembly contract.
Status: **RESOLVED.** Signed-run verified: an app playlist played real
audio via this path; play_event/song_stat recorded. The per-id `equalTo`
re-resolve round trip works.

**🟠→🟡 Imported snapshot drift.**
One-way import means the local Apple-playlist snapshot goes stale when the
upstream changes/disappears; dedupe + transactional replace must be correct,
and must never touch app-owned playlists/play-counts. **Phase 3:**
`ImportService` does a full re-import per Refresh; `replaceApplePlaylistSnapshot`
is transactional and the store provably writes only `apple_playlist*`/`song`
(Phase 2 test `snapshotReplaceDoesNotTouchAppDataOrStats` still green); a
disappeared playlist clears the selection silently. **Phase 5 (corrected):**
the import loop is **strictly serial** (a bounded-parallel `TaskGroup` was
tried and measured ineffective — the cost is MusicKit-bound, not concurrency-
limited — and reverted; see "Large-library import cost" below). The **write
path is byte-for-byte unchanged**, so the isolation tests
(`AppPlaylistCRUDTests` invariant + `SnapshotReplaceTests` +
`BatchImportTests`) still hold; full re-import is kept (it's the correct,
non-stale behavior). **Incremental import was investigated and deliberately
deferred:** `Playlist.lastModifiedDate` exists on the SDK but on the
macOS-14 library is in the frequently-nil metadata category — skipping a
re-import on a mis-read would silently ship a stale snapshot (a correctness
regression of the verified one-way import, scope-forbidden). Status:
**mechanism in place; full re-import is the intentional v1 choice; staleness
window acceptable.**

**🟡 Large-library import cost (honest measured finding — Phase-5
corrective).** A full re-import of a ~270-playlist / ~8200-track library is
**~90–120 s**, dominated by **MusicKit's own per-playlist track resolution
on macOS** (`playlist.with([.tracks])` + `nextBatch()` paging — CPU-bound
and internally serialized; one very large library playlist alone is an
indivisible long task). It is **not** SQLite (the batch write idioms are
correct and tested) and **not** fixable by app-side parallelism: a
bounded-parallel `TaskGroup` (window of 6) was shipped in the first Phase-5
pass with an *unmeasured* "~88 s → ~20–35 s" estimate, then **measured on
the signed build at ~119 s — no improvement, slightly worse, plus
instability** (concurrent `with([.tracks])` calls contend on MusicKit's
internal machinery instead of overlapping). The ineffective parallelism was
**reverted to the simple serial loop**; only the "Importing N of M
playlists…" progress affordance is kept. The false "20–35 s" estimate is
struck from every doc and **not** restated with any new unmeasured number.
Status: **accepted v1 cost** — one-time / Refresh-only, mitigated only by
the progress UI; not a defect, an irreducible MusicKit-on-macOS reality.

## Playback

**🟠 Full-track playback only via Apple's player.**
No raw stream access (also spec-forbidden). Requires an active Apple Music
subscription; catalog/region gating can make individual tracks unplayable.
Mitigation: existing `MusicSubscription` capability check + disabled-Play
reasoning; tolerate per-track failures (don't break the queue).

**🟡 Now-playing elapsed time uses a ~0.5s polling task.**
MusicKit player state isn't cleanly Observation-bridgeable; deliberate
simplicity tradeoff (documented in `plans/musickit-notes.md`). Acceptable;
revisit if it causes churn. **Phase 4:** play-recording no longer depends on
this lagged poll — it waits on the player's *own* `state.playbackStatus`
reaching `.playing` via a short bounded loop (`confirmPlaybackStarted`), so
the Phase-3 "plays never recorded" follow-up is fixed at the trigger.
**Phase 5 (auto-start polish — code-complete, signed-gate pending):** the
"playback started paused; ▶ at 0:05 until the transport was pressed"
follow-up is fixed: `setQueueAndPlay` re-issues `play()` once (bounded,
idempotent) if `confirmPlaybackStarted` didn't see `.playing` (the macOS
queue-still-loading case), and `confirmPlaybackStarted` publishes a fresh
snapshot the instant it observes `.playing` so the UI flips immediately
without waiting for the next 0.5 s tick. Recording still gates on the
confirmed start (not regressed).

**🟡 Seek reliability uncertain on macOS MusicKit.** Treated best-effort.

## Toolchain & language

**🟠 Swift 6 strict concurrency vs un-audited MusicKit.**
`ApplicationMusicPlayer` is not Sendable and its async transport is
`nonisolated`; required `nonisolated(unsafe)` (sound here — MainActor-
serialized). Adding GRDB + actors/`DatabaseQueue` may surface more friction.
Mitigation: keep services `@MainActor`, DB work via GRDB async off-main;
revisit isolation if errors appear. Status: ongoing.

**🟡 Partial / missing MusicKit metadata.**
`trackCount`, `isEditable`, playlist `description`, artwork frequently nil on
macOS 14. UI already tolerates nil; some columns show "—".

**🟡 MusicKit macOS rough edges.** Many samples are iOS-first; API
shape/availability differ. We target macOS 14 but build on the macOS 26 SDK.
Verify each API at use site.

**🟡 Third-party dependency: GRDB.** Approved by user delegation. Pin a major
version (`from: 7.0.0`); never edit shipped migrations; keep concurrency
integration explicit. Supply-chain surface to keep in mind.

## Distribution (giving the app to other people)

**🟠 Current builds are development-signed — won't run for others as-is.**
The validated build is "Apple Development" + a dev provisioning profile
(device-locked to the developer's registered devices). End users do **not**
need an Apple Developer account, but a *dev* build will not launch on a
stranger's Mac. Distribution requires a **Developer ID-signed + notarized**
build (the user has a "Developer ID Application" cert; notarization uses the
developer's ADC account — one-time, not the users'). Mac App Store is the
other option (heavier). **Phase 5 review:** the `make dist` pipeline
(`check-version → clean → release → sign[Developer ID + --options runtime +
--timestamp + entitlements] → zip-notary → notarize → staple → zip-release →
checksum → verify-release`) is internally consistent; the two-zip dance
(notary zip pre-staple, distributed zip post-staple) is correct for offline
Gatekeeper; `notary-setup` correctly refuses non-interactive shells;
entitlements (`app-sandbox` + `network.client`) + `NSAppleMusicUsage
Description` are distribution-correct for the library-only MusicKit path.
**The agent did NOT and MUST NOT run `make dist`/`notarize`/`notary-setup`**
(needs the user's interactive setup + a `vX.Y.Z` tag + Apple credentials).
Status: **pipeline reviewed & ready; the notarize run is a USER step
(below).**

**🟠→🟡 MusicKit App Service for distribution builds — analyzed, most
likely NOT required for the library-only path.**
Dev signing didn't need it for library read on macOS (Phase 1 fact,
re-confirmed Phase 5: the dev build signs with no embedded profile and works).
**Phase 5 analysis:** the MusicKit App Service / a `com.apple.developer.
musickit` entitlement gates **Apple Music *catalog* APIs** and the
**developer-token web/JS flow** — *neither* of which DJ Roomba's shipping
path exercises (it is entirely library-namespace by provenance:
`MusicAuthorization` + `MusicLibraryRequest` + `ApplicationMusicPlayer`, the
catalog branch dormant). So the most likely answer is that a **notarized
Developer ID** build of the library-only path needs **no embedded
provisioning profile either**, consistent with the dev finding. This is
**not yet runtime-proven for a Developer-ID/notarized build** (different
cert chain; notarization validates capabilities against the App ID), so it
stays a 🟡, with the pre-wired escape valve unchanged: if the notarized
build fails to read the library, enable the MusicKit App Service for App ID
`org.sockpuppet.djroomba` in the Developer portal, generate a
`.provisionprofile`, and `make dist PROVISION_PROFILE=/path/to.profile`
(`build.sh` embeds it at `Contents/embedded.provisionprofile` + the sign
step re-signs against it). No code or signing-identity change is needed —
it's a portal + one-flag step. Status: **analyzed; most-likely-not-required;
escape valve pre-wired; final confirmation is the USER's notarized run.**

**🟡 Each end user needs their own active Apple Music subscription** to play
full tracks (library browse may still work; the app already explains disabled
playback). Per-user, unavoidable, not something the developer provides. Each
user also sees *their own* system-account library (Option A by design).

## Process & verification

**🟠 Agent can't fully verify runtime.**
Agent builds are signing-disabled; ad-hoc runs lack MusicKit; computer-use
eval is limited to UI/states until a Phase 1 signed build exists. Mitigation:
be explicit in PROGRESS.md about what was vs wasn't exercised; never claim
verified playback that wasn't run.

**🟠→🟡 Automated test coverage.**
Phase 2 added the test target + store/migration tests (20). Phase 3 added
the import-provenance + resolver grouping/reassembly + legacy-migration
tests. Phase 4 added 11 more: `AppPlaylistCRUDTests` (create/rename/delete/
add/remove/reorder, chunk-boundary correctness, the delete cascade, the
stats LEFT JOIN, **and the one-way-isolation invariant** — every app edit
leaves `apple_playlist*`/song/stat/history untouched) + an app-playlist
reassembly-contract test. **46 tests / 10 suites green.** Honest gap: the
MusicKit-session parts
(actual library read, catalog/library re-fetch, audio) are *not* unit
tested — they can't be without a live account, and faking MusicKit was
explicitly disallowed. Those are signed-run verification, not test gaps.
Filtering/UI logic coverage remains a Phase 5 expansion item.

**🟡 Spec divergence / scope creep.**
The local-first pivot supersedes parts of the original spec ("no DB early",
extension-point-first). Risk of future-agent confusion. Mitigation: PLAN.md
states the pivot up front; milestone-1/2 docs marked historical; roadmap.md
is the forward source of truth.

**🟡 Large-library performance.** Thousands of tracks: import time, SQLite
write batching, sidebar/table virtualization. Mitigation: paging already in
import; Phase 5 performance pass; `ValueObservation` if needed.

**⚪ SourceKit stale-index noise.** Recurring false "cannot find type" /
"main attribute" / "No such module 'PackageDescription'" diagnostics from
the editor's index, especially right after adding files or editing
`Package.swift`. Not real — every actual `swift build` has passed. Don't
chase these; trust `make check`.
