# Release Runbook
1. Install the Developer ID Application certificate for team `93K6RFU8U6` in the login keychain.
2. Recreate the notary profile with `xcrun notarytool store-credentials lorelei-notary --team-id 93K6RFU8U6 --apple-id <apple-id> --password <app-specific-password>`.
3. Confirm `security find-identity -v -p codesigning` lists that identity and `security find-generic-password -s com.apple.gke.notary.tool -a lorelei-notary` succeeds.
4. Run `./scripts/release.sh` from the repository root.
5. The script builds `Lorelei.xcodeproj` scheme `Lorelei` with the `Release` configuration.
6. The script verifies the Developer ID signature, notarizes the zip, staples the app, and verifies Gatekeeper acceptance.
7. Artifacts land in `dist/Lorelei-<CFBundleShortVersionString>.zip`.
8. To verify on another Mac, unzip the artifact and run `spctl -a -vv Lorelei.app`.
9. The expected verification result includes `accepted` and `source=Notarized Developer ID`.
