#!/usr/bin/env bash
set -euo pipefail

PROJECT='Lorelei.xcodeproj'
SCHEME='Lorelei'
CONFIGURATION='Release'
DERIVED_DATA='./DerivedData/Release'
APP_PATH="${DERIVED_DATA}/Build/Products/${CONFIGURATION}/Lorelei.app"
DIST_DIR='dist'
TEAM_ID='93K6RFU8U6'
IDENTITY_NAME='Developer ID Application'
NOTARY_PROFILE='lorelei-notary'

log() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf '\nerror: %s\n' "$1" >&2
  exit 1
}

require_developer_id_identity() {
  if ! security find-identity -v -p codesigning | grep -F "${IDENTITY_NAME}" | grep -F "(${TEAM_ID})" >/dev/null; then
    fail "Missing '${IDENTITY_NAME}' signing identity for team ${TEAM_ID}. Install the Developer ID Application certificate in your login keychain, then re-run this script. See docs/release.md."
  fi
}

require_notary_profile() {
  # Ask notarytool itself - keychain item naming is an implementation detail.
  if ! xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1; then
    fail "Missing notary keychain profile '${NOTARY_PROFILE}'. Recreate it with 'xcrun notarytool store-credentials ${NOTARY_PROFILE} --team-id ${TEAM_ID} --apple-id <apple-id> --password <app-specific-password>'. See docs/release.md."
  fi
}

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

log "Checking release signing prerequisites"
require_developer_id_identity
require_notary_profile

log "Building ${SCHEME} ${CONFIGURATION}"
xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED_DATA}" \
  clean build

[[ -d "${APP_PATH}" ]] || fail "Build completed but ${APP_PATH} was not found."

log "Verifying Developer ID signature"
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"
authority="$(codesign -dv --verbose=4 "${APP_PATH}" 2>&1 | awk -F= '/^Authority=/{print $2}')"
if ! grep -F "${IDENTITY_NAME}" <<<"${authority}" >/dev/null; then
  printf '%s\n' "${authority}" >&2
  fail "Signature authority does not include '${IDENTITY_NAME}'. Check the Release signing settings and installed certificate. See docs/release.md."
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
[[ -n "${version}" ]] || fail "Could not read CFBundleShortVersionString from ${APP_PATH}/Contents/Info.plist."

mkdir -p "${DIST_DIR}"
ZIP_PATH="${DIST_DIR}/Lorelei-${version}.zip"
rm -f "${ZIP_PATH}"

log "Creating notarization archive ${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

notary_output="$(mktemp)"
trap 'rm -f "${notary_output}"' EXIT

notarize_and_wait() {
  local artifact_path="$1"

  log "Submitting $(basename "${artifact_path}") to Apple notary service"
  set +e
  xcrun notarytool submit "${artifact_path}" \
    --keychain-profile "${NOTARY_PROFILE}" \
    --wait \
    --output-format plist >"${notary_output}"
  local submit_status=$?
  set -e

  local submission_id notary_status
  submission_id="$(plist_value id "${notary_output}")"
  notary_status="$(plist_value status "${notary_output}")"

  if [[ ${submit_status} -ne 0 || "${notary_status}" == 'Invalid' ]]; then
    cat "${notary_output}" >&2
    if [[ -n "${submission_id}" ]]; then
      printf '\nNotary log for submission %s:\n' "${submission_id}" >&2
      xcrun notarytool log "${submission_id}" --keychain-profile "${NOTARY_PROFILE}" >&2 || true
    fi
    fail "Notarization failed. Resolve the notary issues above, then re-run this script."
  fi

  [[ "${notary_status}" == 'Accepted' ]] || fail "Unexpected notarization status '${notary_status:-unknown}'. See the notary output above."
}

notarize_and_wait "${ZIP_PATH}"

log "Stapling notarization ticket"
xcrun stapler staple "${APP_PATH}"

log "Repacking stapled app"
rm -f "${ZIP_PATH}"
ditto -c -k --keepParent "${APP_PATH}" "${ZIP_PATH}"

log "Verifying Gatekeeper acceptance"
spctl_output="$(spctl -a -vv "${APP_PATH}" 2>&1)"
printf '%s\n' "${spctl_output}"
if ! grep -F 'accepted' <<<"${spctl_output}" >/dev/null || ! grep -F 'Notarized Developer ID' <<<"${spctl_output}" >/dev/null; then
  fail "Gatekeeper verification did not report 'accepted' from 'Notarized Developer ID'."
fi

DMG_PATH="${DIST_DIR}/Lorelei-${version}.dmg"
rm -f "${DMG_PATH}"

log "Creating disk image ${DMG_PATH}"
dmg_staging="$(mktemp -d)"
trap 'rm -f "${notary_output}"; rm -rf "${dmg_staging}"' EXIT
ditto "${APP_PATH}" "${dmg_staging}/Lorelei.app"
ln -s /Applications "${dmg_staging}/Applications"
hdiutil create \
  -volname 'Lorelei' \
  -srcfolder "${dmg_staging}" \
  -ov \
  -format UDZO \
  "${DMG_PATH}"

log "Signing disk image"
codesign --force --sign "${IDENTITY_NAME}: Taishi Kato (${TEAM_ID})" --timestamp "${DMG_PATH}"

notarize_and_wait "${DMG_PATH}"

log "Stapling notarization ticket to disk image"
xcrun stapler staple "${DMG_PATH}"

log "Verifying Gatekeeper acceptance of the disk image"
dmg_spctl_output="$(spctl -a -t open --context context:primary-signature -vv "${DMG_PATH}" 2>&1)"
printf '%s\n' "${dmg_spctl_output}"
if ! grep -F 'accepted' <<<"${dmg_spctl_output}" >/dev/null || ! grep -F 'Notarized Developer ID' <<<"${dmg_spctl_output}" >/dev/null; then
  fail "Gatekeeper verification did not report the disk image as 'accepted' from 'Notarized Developer ID'."
fi

printf '\nRelease artifacts:\n  %s\n  %s\n' "${DMG_PATH}" "${ZIP_PATH}"
