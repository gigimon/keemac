#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="KeeMac"
DIST_DIR="$ROOT_DIR/.build/dist"
RELEASE_DIR="$ROOT_DIR/.build/release"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
ARCHIVE_PATH="$RELEASE_DIR/${APP_NAME}-${APP_VERSION}-macOS.zip"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"

mkdir -p "$RELEASE_DIR"

"$ROOT_DIR/scripts/build_app.sh" --clean --release

if [[ ! -d "$DIST_DIR/$APP_NAME.app" ]]; then
  echo "Expected app bundle was not produced: $DIST_DIR/$APP_NAME.app" >&2
  exit 1
fi

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"

ditto -c -k --keepParent "$DIST_DIR/$APP_NAME.app" "$ARCHIVE_PATH"
shasum -a 256 "$ARCHIVE_PATH" > "$CHECKSUM_PATH"

echo "Archive: $ARCHIVE_PATH"
echo "Checksum: $CHECKSUM_PATH"
