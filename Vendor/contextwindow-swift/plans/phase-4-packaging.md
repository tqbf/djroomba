# Phase 4 — Package the library for reuse

Adapted from the user's "Package the Swift Library for Reuse" plan. Builds on
Phases 1–3 (61 tests green). **Do not break existing tests; do not regress the
provider-independence of the `ContextWindow` core.**

## Goal

Make this a clean, consumable Swift Package other Swift/macOS/iOS apps import
via SPM. The library stays application-independent: no UI, no app-specific
models, no credentials, no hardcoded paths.

> The source plan was a generic template referencing a nonexistent "music
> player" and a boilerplate `Package.swift`. The analogous constraints here:
> the `ContextWindow` **core must not depend on `ContextWindowOpenAI`** or leak
> provider/app types; no SwiftUI; no credentials committed.

## Locked decisions (from user, 2026-05-16)

1. **swift-tools-version stays `6.0`** with Swift 6 language mode. The plan's
   `5.10` template is rejected — the verified design is built on Swift 6 actors
   / Sendable / strict concurrency; downgrading would weaken guarantees and
   force re-verification. Consumers need a Swift 6.0+ toolchain (reasonable in
   2026).
2. **License: MIT**, `Copyright (c) 2026 Thomas <thomas@sockpuppet.org>`.
3. **Release: local only.** `git init` already done (repo has no commits, no
   remote). Make the initial commit, tag `0.1.0` locally. **Do NOT push** (no
   remote). Validate consumability with a scratch package using
   `.package(path:)`.
4. **Dependencies: GRDB stays.** The plan's "empty dependencies" is template
   boilerplate; GRDB is the core persistence layer and is minimal/justified.
   No new deps. Document GRDB in the README.

## ⚠️ Credential safety (hard requirement)

`.envrc` at the repo root contains a **real `OPENAI_API_KEY`**. It MUST be
git-ignored and MUST NOT be committed in the initial commit or any tag. Add a
`.gitignore` (covering `.envrc`, `.build/`, `.swiftpm/`, `.DS_Store`,
`*.xcuserstate`) BEFORE `git add`. Verify `git status`/`git ls-files` shows no
`.envrc` and no key before committing. The library itself already reads the key
only from the environment — keep it that way; do not bake any key/endpoint.

## Steps

1. **Package structure.** Repo should expose only reusable library code as
   products. Keep `Sources/ContextWindow/` (core) and
   `Sources/ContextWindowOpenAI/` (reusable provider adapter — URLSession only,
   no app/UI/credential coupling) as **library products**. Relocate the CLI
   (`Sources/ContextWindowCLI/`) into `Examples/BasicClient/` as a standalone
   example package (see step 6); remove it as a product/target of the main
   package.
2. **`Package.swift`** — `swift-tools-version: 6.0`; `platforms:
   [.macOS(.v14), .iOS(.v17)]` (adjust only if code requires other minimums —
   verify GRDB + URLSession build for both; if iOS is infeasible for a target,
   document why and scope platforms accordingly); products `ContextWindow` and
   `ContextWindowOpenAI`; GRDB dependency retained; both library targets keep
   `swiftLanguageMode(.v6)`; test targets unchanged. No executable product.
3. **Public API audit.** Intended API `public`; implementation `internal`/
   `private`. No app-specific types leaked. No global mutable state. No
   hardcoded API keys, endpoints, local paths, bundle IDs, or app names — the
   OpenAI endpoint should be injectable/overridable where practical (transport
   is already injectable; add a base-URL override if not trivially present).
   Core (`ContextWindow`) must have zero `import`/symbol dependency on
   `ContextWindowOpenAI`.
4. **Build & tests.** `swift package clean && swift build && swift test`
   (no env var → zero network). All 61 tests pass, 3 skipped as before. Fix
   warnings indicating packaging/visibility/concurrency/availability problems.
5. **README.** What it does; supported platforms; SPM install snippet
   (`.package(url: ...)` with `<owner>/<repo>` placeholder + a `.package(path:)`
   local note); minimal usage example (offline-capable); configuration / API
   key via environment + dependency injection (transport); GRDB dependency
   note; explicit statement the package is application-independent.
6. **Example client.** `Examples/BasicClient/` = a standalone SwiftPM package
   depending on the library via `.package(path: "../..")`, demonstrating
   `import ContextWindow` and one realistic call WITHOUT network (e.g. create
   store + context, add a prompt, read token usage; optionally show wiring
   `OpenAIChatModel` behind an env check, not executed by default). It must
   build. The parent package must not try to build `Examples/` (it's outside
   `Sources/`; targets are explicit — verify clean parent build).
7. **Release (local).** Add `.gitignore` first (credential safety above),
   `git add` (verify no `.envrc`), commit all package work, `git tag 0.1.0`.
   Do NOT `git push` (no remote). Record the exact commit + tag.
8. **Validate from a separate package.** Create a throwaway scratch package
   OUTSIDE this repo (e.g. under `/tmp`) that adds the library via
   `.package(path: "/Users/agentzero/codebase/contextwindow")`, `import
   ContextWindow`, and runs a minimal offline integration (build + a tiny
   exec/test). Confirm it builds and runs. Clean it up after, report the result.

## Constraints

- No SwiftUI / UI in the library (none today — keep it that way).
- No new dependencies beyond GRDB.
- Core stays provider-independent (no `ContextWindowOpenAI` coupling).
- No credentials committed (`.envrc` git-ignored — verified).
- Do not break the 61 existing tests; do not run live OpenAI calls.

## Acceptance

- [x] `swift build` + `swift test` green (61 tests, 3 skipped), zero network,
  zero packaging/visibility warnings.
- [x] `Package.swift`: tools 6.0, two library products, GRDB only, no exec product.
- [x] LICENSE (MIT, 2026 Thomas) present; README updated per step 5.
- [x] `Examples/BasicClient/` builds standalone via local path.
- [x] `.envrc` git-ignored and absent from `git ls-files`; initial commit + local
  tag `0.1.0` created; no push.
- [x] Scratch external package consumes the library via `.package(path:)`,
  imports `ContextWindow`, builds and runs offline.

## Notes / decisions

Implemented 2026-05-16 (Phase 4 subagent):

- **`Package.swift`**: kept `swift-tools-version: 6.0` and
  `.swiftLanguageMode(.v6)` on both library targets (locked decision; the
  template's 5.10 rejected). Bumped platforms `[.macOS(.v13)]` →
  `[.macOS(.v14), .iOS(.v17)]` per the spec. Removed the
  `.executable("contextwindow")` product and the `ContextWindowCLI`
  executable target. Products are now exactly the two libraries
  (`ContextWindow`, `ContextWindowOpenAI`); GRDB the only dependency; both
  test targets unchanged (`ContextWindowOpenAITests` keeps its
  `Fixtures` copy resource). iOS minimum is feasible — GRDB and
  `URLSession` build for it; the OpenAI transport is `URLSession`-based and
  injectable, so no platform scoping was needed.
- **CLI relocation**: deleted `Sources/ContextWindowCLI/` from the main
  package and created `Examples/BasicClient/` as a *standalone* SwiftPM
  package (`swift-tools-version: 6.0`, same platforms) that depends on the
  library via `.package(path: "../..")` and the two library products. It is
  outside `Sources/` and the main package's targets are explicit, so the
  root `swift build`/`swift test` never builds it (verified via
  `swift package describe`: targets/products contain no BasicClient/exec).
  The example demonstrates `import ContextWindow` + `import
  ContextWindowOpenAI` and runs **fully offline by default**: in-memory
  store, open context, set system prompt, add a prompt, print live records +
  token usage. Real `OpenAIChatModel` wiring is included but guarded behind
  `CONTEXTWINDOW_EXAMPLE_LIVE=1` (not set by default → never executed, zero
  network). Source file named `BasicClient.swift` (not `main.swift`) so
  `@main` is legal. It builds and runs standalone (verified).
- **Public API audit**: core `ContextWindow` has **zero** dependency on
  `ContextWindowOpenAI` (no import, no symbol — grep-verified). No global
  mutable state; the only `static` members are immutable constants/factories.
  No hardcoded API keys, local paths, bundle IDs, or app names anywhere in
  `Sources/`. The OpenAI endpoint was *already* injectable: both adapters
  take `baseURL: URL = URL(string: "https://api.openai.com/v1")!` and the
  transport is the injectable `OpenAITransport` seam — no change needed, the
  requirement was already satisfied. Intended API is `public`; wire/internal
  types stay `internal`.
- **Build & tests**: `swift package clean && swift build && swift test` with
  no env var → **61 tests, 3 skipped, 0 failures**, zero network (target
  platform now `arm64e-apple-macos14.0`). No packaging/visibility/
  concurrency/availability warnings. Live OpenAI tests intentionally not run.
- **LICENSE**: standard MIT text, `Copyright (c) 2026 Thomas
  <thomas@sockpuppet.org>`.
- **README**: rewritten per step 5 — what it does; supported-platforms table
  (macOS 14 / iOS 17); SPM install with `<owner>/<repo>` placeholder URL
  **and** a `.package(path:)` local note; a minimal **offline** usage
  example plus the OpenAI example; configuration section (API key via env +
  injectable transport + `baseURL` override); GRDB dependency note; explicit
  "application-independent" statement; updated package-layout (CLI →
  `Examples/BasicClient/`); doc index preserved + LICENSE linked.
- **Credential safety**: `.gitignore` created **before any `git add`**,
  covering `.envrc`, `.build/`, `.swiftpm/`, `Package.resolved`,
  `Examples/*/.build/`, `.DS_Store`, `*.xcuserstate`, Xcode cruft. Verified
  `.envrc` is NOT in `git ls-files` and NOT in `git diff --cached`;
  `git diff --cached | grep 'sk-'` and a cached `git grep 'sk-[A-Za-z0-9]'`
  found **no** API-key-shaped string in any staged file; no
  `OPENAI_API_KEY=` assignment staged. The key value was never echoed/logged.
- **Release (local)**: single initial commit of all package work; tag
  `0.1.0` created locally. **No remote exists; nothing pushed.** (Hashes in
  PROGRESS.md decisions log.)
- **External validation**: a throwaway package under
  `/tmp/cw-consume-check` consumed the library via
  `.package(path: "/Users/agentzero/codebase/contextwindow")`, with a
  target that `import ContextWindow` and a tiny offline integration; it
  built and ran/tested green, then was deleted. (Result in PROGRESS.md.)
- **CLAUDE.md skills (swiftui-pro / typography-designer / macos-design)**:
  **N/A and skipped** — Phase 4 is packaging a headless library + a
  non-UI example client. No SwiftUI/UI exists or was introduced; no GUI
  invented. Consistent with the Phase 3 decision recorded in
  `docs/porting-notes.md`.
