# Project setup

> **Build system lives in [build-system.md](build-system.md).** This file
> covers the MusicKit/signing/plist specifics that sit on top of it.

## Tooling

- **No XcodeGen, no `.xcodeproj`, no `xcodebuild`, no Xcode IDE.** SwiftPM
  (`Package.swift`) + `build.sh` + `Makefile`, cloned from tqbf/mdv. Full
  detail and target list: [build-system.md](build-system.md).
- Xcode 26.x / Swift 6.3.x as the **toolchain** (`swift`, `codesign`,
  `xcrun notarytool`, `xcrun stapler`). Deployment target **macOS 14.0**.

## Build (the short version)

```sh
make            # debug build → signed build/DJRoomba.app
make run        # build + launch
make check      # compile only, no sign — agent / CI gate
make dist       # tagged Developer ID + notarized release
```

`make check` replaces the retired
`xcodebuild … CODE_SIGNING_ALLOWED=NO build` verification.

## Signing

- Team **KK7E9G89GW** (Thomas Ptacek). Two identities in the login
  keychain, both used by the build:
  - **Dev builds** → `Apple Development: Thomas Ptacek (7F2QE7P59D)`
    (set by `build.sh`; override `SIGN_IDENTITY` / `make DEV_IDENTITY=`).
    This is the Phase-1-verified recipe — adhoc would read an empty
    MusicKit library.
  - **`make dist`** → `Developer ID Application: Thomas Ptacek
    (KK7E9G89GW)` + hardened runtime + timestamp + notarization.
- **No provisioning profile is required for library read/playback**
  (Phase 1 fact). The open question of whether a notarized Developer ID
  build needs a MusicKit-App-Service profile for *catalog* APIs is
  pre-wired as the `PROVISION_PROFILE` hook — see
  [build-system.md](build-system.md) and the risk register.

## MusicKit requirements

- **Info.plist**: `NSAppleMusicUsageDescription` — user-facing reason for
  Apple Music access. Without it, authorization crashes the app. The plist
  now uses **literal** values (no `$(…)` Xcode build vars — SwiftPM does
  not expand them and a literal `$(PRODUCT_BUNDLE_IDENTIFIER)` would break
  MusicKit's App ID match).
- **Entitlements** (`DJRoomba/DJRoomba.entitlements`, applied at every
  codesign step): App Sandbox + `com.apple.security.network.client`. No
  microphone/camera. MusicKit needs no dedicated entitlement key; access
  is gated by the usage-description prompt + the App ID's MusicKit service.

## What's tracked vs ignored

Tracked: `Package.swift`, `build.sh`, `Makefile`, `DJRoomba/Info.plist`,
`DJRoomba/*.entitlements`, all sources, `PLAN.md`/`PROGRESS.md`/`plans/`.
Ignored (`.gitignore`): `build/`, `dist/`, `.build/`, `.swiftpm/`,
`DerivedData/`, `.DS_Store`, and `*.xcodeproj` (kept as a guard so a stray
Xcode-generated project never lands in git).

## Open questions / deferred

- App icon + asset catalog — none yet; `build.sh` ships no icon. Add an
  `.icns` + an `icon` Makefile target later (mdv has a template).
- Notarized-build MusicKit-catalog provisioning — open Phase 2/3 risk,
  pre-wired (`PROVISION_PROFILE`), not solved.
