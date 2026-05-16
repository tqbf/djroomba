# Build system

DJ Roomba uses the **tqbf/mdv build environment**, cloned. The whole point:
**Xcode is only a toolchain provider, never the build system.** No
`.xcodeproj`, no XcodeGen, no `xcodebuild`, no IDE. You build with `make`;
only `make dist` reaches into Xcode-supplied tools (`codesign`,
`xcrun notarytool`, `xcrun stapler`).

## Files (all checked in)

| File | Role |
|------|------|
| `Package.swift` | SwiftPM manifest. `executableTarget` over `DJRoomba/`, macOS 14, Swift 6 language mode (== strict concurrency complete). GRDB gets added here in Phase 3. |
| `build.sh` | `swift build` → hand-assemble `build/DJRoomba.app` → codesign. Mirrors mdv's; the signing identity differs (see below). |
| `Makefile` | The only entry point. `make`, `run`, `check`, `install`, `clean`, and the full `dist` release pipeline. |
| `DJRoomba/Info.plist` | De-templated to **literal** values. The old `$(PRODUCT_BUNDLE_IDENTIFIER)`-style vars were Xcode build-setting substitutions; SwiftPM does not expand them, and a literal `$(...)` as `CFBundleIdentifier` breaks MusicKit's App ID match. |
| `DJRoomba/DJRoomba.entitlements` | Unchanged: `app-sandbox` + `network.client`. Applied at every codesign step. |

`project.yml` and `DJRoomba.xcodeproj/` were **deleted**. `.gitignore` keeps
the `*.xcodeproj` rule so a stray Xcode-generated project never lands in git.

## Targets

```
make            # debug build → signed build/DJRoomba.app
make run        # build + open
make check      # swift build only — no bundle, no sign (agent / CI gate)
make release    # release build → signed build/DJRoomba.app
make install    # copy to /Applications + lsregister
make clean      # rm build/ .build/ dist/
make dist       # tagged release: clean → release → Developer ID sign →
                #   notarize → staple → zip → sha256 → spctl verify
make github-release  # upload dist/ zip + .sha256 to a GitHub release
```

`make check` **replaces** the retired
`xcodebuild … CODE_SIGNING_ALLOWED=NO build` agent/CI verification — it is
just `swift build`, no signing involved.

## Signing — the one real deviation from mdv

mdv adhoc-signs (`codesign -s -`). **DJ Roomba cannot.** Roadmap Phase 1
proved an adhoc-signed MusicKit build authorizes but reads an **empty
library, no error**. The Phase-1-verified recipe is:

- **Dev builds** (`make`, `make run`, `make release`):
  `Apple Development: Thomas Ptacek (7F2QE7P59D)` + the sandbox entitlements
  + `NSAppleMusicUsageDescription`. **No provisioning profile needed** for
  library read/playback (Phase 1 fact). Override with
  `SIGN_IDENTITY=…` / `make DEV_IDENTITY=…` if the cert rotates.
- **Distribution** (`make dist`): `Developer ID Application: Thomas Ptacek
  (KK7E9G89GW)` + `--options runtime` + `--timestamp` + entitlements,
  then `xcrun notarytool submit --wait`, `xcrun stapler staple`,
  re-zip-after-staple, `spctl --assess`. Identical to mdv's pipeline.

Both certs are present in the login keychain. `make dist` requires a git
tag `vX.Y.Z` (the `check-version` guard) and a stored notary keychain
profile. Populate the profile once with:

```sh
make notary-setup            # or: make notary-setup APPLE_ID=you@example.com
```

It's interactive — `notarytool` prompts (hidden) for the app-specific
password (create one at https://appleid.apple.com → Sign-In and Security →
App-Specific Passwords). The password is never passed on the command line.
Re-run to rotate.

## Open risk wired as a one-flag hook: `PROVISION_PROFILE`

Phase 1 proved **library read/playback needs no embedded provisioning
profile**. Whether a *notarized Developer ID* build needs a
MusicKit-App-Service profile for Apple Music **catalog** APIs is the open
Phase-2/3 risk (see `risks-and-challenges.md` → Distribution). It is **not
solved here** and does not block the build-system swap.

It is pre-wired: set `PROVISION_PROFILE=/path/to/profile.provisionprofile`
and `build.sh` embeds it at `Contents/embedded.provisionprofile` and the
`sign` step signs against it. Until that path is validated, leave it unset
(no-op). Generating the profile itself is a one-time Apple Developer portal
artifact — `make` cannot conjure it.

## Why this works here

`swift build` compiles the full Swift 6 strict-concurrency SwiftUI tree
cleanly (verified). The app is a single `@main` SwiftUI `App` with no asset
catalog, no bundled resources — so `build.sh` only copies the binary +
Info.plist, exactly like mdv. SPM dependencies work in this model (mdv
ships three); GRDB slots into `Package.swift` in Phase 3 with no build-system
changes.
