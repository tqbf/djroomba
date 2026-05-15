# Problems & challenges (live risk register)

Everything working against this project, with impact, mitigation, and status.
Keep current — a future agent should trust this to know where the landmines
are. Severity: 🔴 blocking · 🟠 significant · 🟡 manageable · ⚪ noise.

## Access, signing & identity

**🔴 Xcode has no Apple ID account / no Mac Development cert.**
Only a "Developer ID Application" cert is in the keychain; `xcodebuild`
automatic provisioning fails ("No Accounts"). Impact: cannot produce a
MusicKit-entitled signed build from the agent side. Mitigation: user adds
their ADC Apple ID in Xcode → Settings → Accounts; we then flip `project.yml`
to automatic signing (team `KK7E9G89GW`). Status: **open, user action.**

**🔴 MusicKit App Service must be enabled for `org.sockpuppet.djroomba`.**
Native MusicKit library/playback needs the App ID to carry the MusicKit
entitlement via provisioning. An ad-hoc build authorizes but reads an empty
library with no error. Mitigation: user confirms MusicKit enabled for the
App ID in the dev portal (they've used MusicKit before). Status: **open,
user action.** This is the Phase 1 gate.

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

**🟠 Empty/failure modes are silent.**
MusicKit returns an empty collection rather than throwing in several
"not really available" cases, so we can't cleanly distinguish "no playlists"
vs "not synced" vs "not entitled". Mitigation: Phase 5 smarter empty states;
cross-check `MusicSubscription`/cloud status to infer cause.

## Core architecture risk

**🔴 (unproven) id store-then-re-resolve round trip.**
Local-first stores `MusicItemID` and re-resolves to a playable item at play
time. Library vs catalog id namespaces are **not** interchangeable; some
items (user uploads, region/catalog-removed, DRM edge cases) may not
re-resolve. The entire SQLite design depends on this working. Mitigation:
**Phase 1 explicitly validates the round trip before any data-layer work.**
Status: open until Phase 1.

**🟠 Imported snapshot drift.**
One-way import means the local Apple-playlist snapshot goes stale when the
upstream changes/disappears; dedupe + transactional replace must be correct,
and must never touch app-owned playlists/play-counts. Mitigation: replace
apple_playlist snapshots transactionally; app data isolated in separate
tables; full re-import acceptable for v1.

## Playback

**🟠 Full-track playback only via Apple's player.**
No raw stream access (also spec-forbidden). Requires an active Apple Music
subscription; catalog/region gating can make individual tracks unplayable.
Mitigation: existing `MusicSubscription` capability check + disabled-Play
reasoning; tolerate per-track failures (don't break the queue).

**🟡 Now-playing elapsed time uses a ~0.5s polling task.**
MusicKit player state isn't cleanly Observation-bridgeable; deliberate
simplicity tradeoff (documented in `plans/musickit-notes.md`). Acceptable;
revisit if it causes churn.

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
other option (heavier). Status: open — addressed in roadmap Phase 5.

**🟠 MusicKit App Service IS likely required for distribution builds.**
Dev signing didn't need it for library read on macOS, but a Developer
ID/notarized build that uses the MusicKit framework needs the App ID's
MusicKit App Service enabled so the embedded entitlement is valid. So
"Step 3" is *deferred, not eliminated*. Validate when building the
distribution artifact.

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

**🟠 No automated tests yet.**
Core logic (LibraryStore, ImportService, PlaybackResolver, filtering) is
untested; flagged repeatedly by swiftui-pro hygiene. Mitigation: Phase 2 adds
a test target + store/migration tests; expand through Phase 5.

**🟡 Spec divergence / scope creep.**
The local-first pivot supersedes parts of the original spec ("no DB early",
extension-point-first). Risk of future-agent confusion. Mitigation: PLAN.md
states the pivot up front; milestone-1/2 docs marked historical; roadmap.md
is the forward source of truth.

**🟡 Large-library performance.** Thousands of tracks: import time, SQLite
write batching, sidebar/table virtualization. Mitigation: paging already in
import; Phase 5 performance pass; `ValueObservation` if needed.

**⚪ SourceKit stale-index noise.** Recurring false "cannot find type" /
"main attribute" diagnostics whenever files are added before `xcodegen
generate`. Not real — every actual `swiftc` build has passed. Don't chase
these; trust the build.
