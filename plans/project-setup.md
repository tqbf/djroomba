# Project setup

## Tooling

- **XcodeGen 2.45.4** (`brew install xcodegen`). The project is defined by
  `project.yml` (checked in). The generated `DJRoomba.xcodeproj` is **not**
  checked in — regenerate with `xcodegen generate`.
- Xcode 26.4.1, Swift 6.3.1, macOS 26.4 SDK. Deployment target **macOS 14.0**.

## Regenerate + build

```sh
xcodegen generate                       # (re)create DJRoomba.xcodeproj from project.yml

# Agent / CI build verification (no dev cert needed):
xcodebuild -project DJRoomba.xcodeproj -scheme DJRoomba \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

# Real run (from Xcode, signed into the Apple ID so a Mac Development
# cert + MusicKit profile get provisioned automatically):
#   open DJRoomba.xcodeproj  → Run
```

Only a "Developer ID Application" identity exists in the login keychain, so
plain `xcodebuild ... build` fails with *No "Mac Development" signing
certificate*. That is expected: CLI verification uses `CODE_SIGNING_ALLOWED=NO`
to confirm the code compiles; actual signed runs happen from Xcode where
automatic signing provisions the dev cert. Runtime MusicKit still needs the
App ID to have MusicKit enabled (see Signing below).

`xcodegen generate` must be run after any `project.yml` change or after a fresh
clone, before building or opening in Xcode.

## Signing

- Team: **KK7E9G89GW** (Thomas Ptacek), automatic signing.
- Only a "Developer ID Application" identity is present in the login keychain.
  For local dev runs, Xcode (signed into the Apple ID) provisions an Apple
  Development cert + profile automatically. **MusicKit requires the App ID
  `org.sockpuppet.djroomba` to have the MusicKit App Service enabled** in the
  developer portal. If automatic signing fails on the MusicKit capability,
  enabling MusicKit for that App ID in the portal (or letting Xcode add the
  capability while signed in) is the fix. This is a runtime/signing concern,
  not a build-blocker for the source itself.

## MusicKit requirements

- **Info.plist**: `NSAppleMusicUsageDescription` — user-facing reason for
  Apple Music access. Without it, authorization crashes the app.
- **Entitlements**: App Sandbox is enabled with:
  - `com.apple.security.network.client` (Apple Music is network-backed)
  - no microphone/camera/etc. — this app needs none.
  MusicKit itself does not require a dedicated entitlement key in the
  entitlements file; access is gated by the usage-description prompt + the
  App ID's MusicKit service. Keep the entitlements minimal.

## project.yml shape (summary)

- `name: DJRoomba`
- single app target `DJRoomba`, platform macOS, deploymentTarget `14.0`
- `SWIFT_VERSION` 6.0+ (uses installed Swift 6.3), strict concurrency complete
- `GENERATE_INFOPLIST_FILE: NO` with an explicit `Info.plist` so the MusicKit
  usage string is durable and reviewable
- `CODE_SIGN_STYLE: Automatic`, `DEVELOPMENT_TEAM: KK7E9G89GW`
- entitlements file at `DJRoomba/DJRoomba.entitlements`
- sources: the `DJRoomba/` source tree

## .gitignore

Generated/derived artifacts only: `*.xcodeproj`, `.DS_Store`,
`xcuserdata/`, `DerivedData/`, build output. `project.yml`, `Info.plist`,
`*.entitlements`, and all sources are tracked.

## Open questions / deferred

- App icon + accent asset catalog — placeholder for now, real assets later.
- Sparkle/notarization/distribution — out of scope until the app works.
