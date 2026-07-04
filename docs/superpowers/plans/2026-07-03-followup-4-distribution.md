# Follow-up 4: Distribution - Implementation Plan

> Executed by Codex (gpt-5.5), reviewed by the planner. No git write commands from Codex. Verify with the usual build-for-testing command (CODE_SIGN flags as build settings).

**Goal:** One-command notarized releases: `./scripts/release.sh` produces a stapled, Gatekeeper-passing `dist/Lorelei-<version>.zip`.

**Prereqs (user-side, done/doing):** paid team 93K6RFU8U6, notary keychain profile `lorelei-notary` (stored), Developer ID Application certificate (in progress).

## Task 1: Release pipeline

**Files:** create `scripts/release.sh` (+ `docs/release.md` runbook); modify `Lorelei.xcodeproj/project.pbxproj` Release config only.

**Behavior:**
- Release build settings (Release configuration of the app target only): `ENABLE_HARDENED_RUNTIME = YES`, `CODE_SIGN_IDENTITY = "Developer ID Application"`, `CODE_SIGN_STYLE = Manual`, `DEVELOPMENT_TEAM = 93K6RFU8U6`, `OTHER_CODE_SIGN_FLAGS = "--timestamp"`. Debug config untouched. Entitlements stay as-is (audio-input/camera/network-client are hardened-runtime resource entitlements; app-sandbox stays false).
- `scripts/release.sh` (set -euo pipefail, steps logged):
  1. `xcodebuild -project Lorelei.xcodeproj -scheme Lorelei -configuration Release -derivedDataPath ./DerivedData/Release clean build`
  2. verify signature: `codesign --verify --deep --strict` + assert authority contains "Developer ID Application" (fail fast with a pointer to the cert setup if not)
  3. `ditto -c -k --keepParent <app> dist/Lorelei-<CFBundleShortVersionString>.zip`
  4. `xcrun notarytool submit <zip> --keychain-profile lorelei-notary --wait` (fail with log fetch `notarytool log` on Invalid)
  5. `xcrun stapler staple <app>` then re-zip the stapled app (replace the zip)
  6. `spctl -a -vv <app>` must say "accepted" / "Notarized Developer ID"; print the final artifact path
- `docs/release.md`: 10-line runbook (prereqs incl. recreating the keychain profile, how to run, where artifacts land, how to verify on another Mac).

**Tests:** shell script - no unit tests; reviewer runs the script end-to-end once the Developer ID cert exists. Guard: running without the cert or profile must fail with a clear actionable message (checked by reviewer before cert arrives).
