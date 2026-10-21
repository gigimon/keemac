#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="KeeMac"
DIST_DIR="$ROOT_DIR/.build/dist"
RELEASE_DIR="$ROOT_DIR/.build/release"
NOTARIZE="false"
STAPLE_ONLY="false"
# shellcheck source=resolve_version.sh
source "$ROOT_DIR/scripts/resolve_version.sh"
ARCHIVE_PATH="$RELEASE_DIR/${APP_NAME}-${APP_VERSION}-macOS.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

usage() {
  cat <<'USAGE'
Usage: scripts/make_release_archive.sh [--notarize | --staple]

Builds KeeMac.app (build_app.sh --release) and packs .build/release/KeeMac-<version>-macOS.zip.

  --notarize   Also notarize the Developer ID signed app with Apple and staple the ticket, so it
               opens without Gatekeeper warnings on any Mac. Needs an App Store Connect API key:
                 KEEMAC_NOTARY_KEY_ID, KEEMAC_NOTARY_ISSUER, KEEMAC_NOTARY_KEY (path to the .p8)
               from the environment or ~/.appstoreconnect/keemac-notary.env.
  --staple     When Apple took longer than the wait: once the submission is Accepted, staples the
               ticket to the already built .build/dist/KeeMac.app and packs the archive (no rebuild).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize)
      NOTARIZE="true"
      shift
      ;;
    --staple)
      STAPLE_ONLY="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$NOTARIZE" == "true" ]]; then
  NOTARY_ENV="$HOME/.appstoreconnect/keemac-notary.env"
  if [[ -z "${KEEMAC_NOTARY_KEY_ID:-}" && -f "$NOTARY_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$NOTARY_ENV"
  fi
  for variable in KEEMAC_NOTARY_KEY_ID KEEMAC_NOTARY_ISSUER KEEMAC_NOTARY_KEY; do
    if [[ -z "${!variable:-}" ]]; then
      echo "error: $variable is not set (see --help)" >&2
      exit 1
    fi
  done
  if [[ ! -f "$KEEMAC_NOTARY_KEY" ]]; then
    echo "error: API key not found: $KEEMAC_NOTARY_KEY" >&2
    exit 1
  fi
fi

mkdir -p "$RELEASE_DIR"

if [[ "$STAPLE_ONLY" != "true" ]]; then
  "$ROOT_DIR/scripts/build_app.sh" --clean --release
fi

APP_PATH="$DIST_DIR/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle was not produced: $APP_PATH" >&2
  exit 1
fi

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"

if [[ "$NOTARIZE" == "true" ]]; then
  SIGNATURE="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
  if [[ "$SIGNATURE" != *"Authority=Developer ID Application"* ]]; then
    echo "error: $APP_PATH isn't signed with Developer ID; notarization needs it" >&2
    exit 1
  fi
  SUBMISSION="$RELEASE_DIR/${APP_NAME}-notarization.zip"
  ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION"
  echo "Submitting to Apple's notary service..."
  NOTARY_AUTH=(--key "$KEEMAC_NOTARY_KEY" --key-id "$KEEMAC_NOTARY_KEY_ID" --issuer "$KEEMAC_NOTARY_ISSUER")
  RESULT="$(xcrun notarytool submit "$SUBMISSION" "${NOTARY_AUTH[@]}" --wait --timeout 30m --output-format json || true)"
  rm -f "$SUBMISSION"
  STATUS="$(plutil -extract status raw -o - - <<< "$RESULT" 2>/dev/null || true)"
  SUBMISSION_ID="$(plutil -extract id raw -o - - <<< "$RESULT" 2>/dev/null || true)"
  echo "Notarization $SUBMISSION_ID: ${STATUS:-still in progress}"
  if [[ -z "$STATUS" || "$STATUS" == "In Progress" ]]; then
    echo "Apple is still processing it. When this shows Accepted:" >&2
    echo "  xcrun notarytool wait $SUBMISSION_ID --key \"\$KEEMAC_NOTARY_KEY\" --key-id \$KEEMAC_NOTARY_KEY_ID --issuer \$KEEMAC_NOTARY_ISSUER" >&2
    echo "run: scripts/make_release_archive.sh --staple" >&2
    exit 1
  fi
  if [[ "$STATUS" != "Accepted" ]]; then
    [[ -n "$SUBMISSION_ID" ]] && xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" >&2
    exit 1
  fi
fi

if [[ "$NOTARIZE" == "true" || "$STAPLE_ONLY" == "true" ]]; then
  xcrun stapler staple "$APP_PATH"
  spctl --assess --type execute -vv "$APP_PATH"
fi

ditto -c -k --keepParent "$APP_PATH" "$ARCHIVE_PATH"
# Just the file name, so `shasum -c` works next to the downloaded archive.
(cd "$RELEASE_DIR" && shasum -a 256 "$(basename "$ARCHIVE_PATH")") > "$CHECKSUM_PATH"

echo "Archive: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
