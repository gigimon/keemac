#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="KeeMacApp"
PROXY_SCHEME="keemac-proxy"
CONFIGURATION="Release"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="$ROOT_DIR/.build/Derived"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_NAME="KeeMac"
INSTALL_TO_USER_APPS="false"
# dev: "KeeMac Dev" (tech.keemac.dev), app: "KeeMac" (tech.keemac.app), uitests: ad-hoc test build.
VARIANT="dev"
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
# shellcheck source=resolve_version.sh
source "$ROOT_DIR/scripts/resolve_version.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/build_app.sh [options]

Builds "KeeMac Dev" (tech.keemac.dev) by default, so development never touches the
installed app's settings and Touch ID keychain item.

Options:
  --release          The installed app: "KeeMac" (tech.keemac.app)
  --debug            Build Debug configuration (default: Release)
  --install          Install built app to ~/Applications
  --clean            Remove previous DerivedData and dist output before build
  --ui-testing       Debug build for the UI tests: bundle ID com.keemac.uitests, output in .build/uitest-dist, ad-hoc signed
  -h, --help         Show this help

Signing: with an "Apple Development" or "Developer ID Application" certificate in the keychain and a
provisioning profile for the bundle ID in ~/Library/Developer/Xcode/UserData/Provisioning Profiles,
the app is signed with it (keychain entitlements, hardened runtime); otherwise ad-hoc.

Environment overrides:
  BUNDLE_IDENTIFIER  CFBundleIdentifier (default: by variant)
  SIGN_IDENTITY      Certificate name or SHA-1 to sign with (default: found in the keychain)
  APP_VERSION        CFBundleShortVersionString (default: X.Y.Z when HEAD is at tag vX.Y.Z,
                     otherwise the short commit hash)
  BUILD_NUMBER       CFBundleVersion (default: number of commits up to HEAD)
USAGE
}

clean_outputs() {
  rm -rf "$DERIVED_DATA_PATH" "$DIST_DIR"
}

copy_required() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "$src" ]]; then
    echo "Missing required build artifact: $src" >&2
    exit 1
  fi
  cp -R "$src" "$dst"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug)
      CONFIGURATION="Debug"
      shift
      ;;
    --release)
      CONFIGURATION="Release"
      VARIANT="app"
      shift
      ;;
    --install)
      INSTALL_TO_USER_APPS="true"
      shift
      ;;
    --clean)
      clean_outputs
      shift
      ;;
    --ui-testing)
      CONFIGURATION="Debug"
      VARIANT="uitests"
      DIST_DIR="$ROOT_DIR/.build/uitest-dist"
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

case "$VARIANT" in
  dev)
    DEFAULT_BUNDLE_IDENTIFIER="tech.keemac.dev"
    DISPLAY_NAME="KeeMac Dev"
    ;;
  app)
    DEFAULT_BUNDLE_IDENTIFIER="tech.keemac.app"
    DISPLAY_NAME="KeeMac"
    ;;
  uitests)
    DEFAULT_BUNDLE_IDENTIFIER="com.keemac.uitests"
    DISPLAY_NAME="KeeMac"
    ;;
esac
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-$DEFAULT_BUNDLE_IDENTIFIER}"
APP_DIR="$DIST_DIR/$DISPLAY_NAME.app"

echo "Building $APP_NAME $APP_VERSION ($BUILD_NUMBER, $CONFIGURATION)..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

xcodebuild \
  -scheme "$PROXY_SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"

APP_BINARY="$PRODUCTS_DIR/KeeMacApp"
PROXY_BINARY="$PRODUCTS_DIR/keemac-proxy"
RESOURCE_BUNDLE="$PRODUCTS_DIR/KeeMac_App.bundle"
UI_RESOURCE_BUNDLE="$PRODUCTS_DIR/KeeMac_UI.bundle"
DOMAIN_RESOURCE_BUNDLE="$PRODUCTS_DIR/KeeMac_Domain.bundle"
KEEPASSKIT_FRAMEWORK="$PRODUCTS_DIR/KeePassKit.framework"
KISSXML_FRAMEWORK="$PRODUCTS_DIR/KissXML.framework"
APP_ICON="$ROOT_DIR/Sources/App/Resources/AppIcon.icns"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/lib"

copy_required "$APP_BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
copy_required "$PROXY_BINARY" "$APP_DIR/Contents/MacOS/keemac-proxy"
copy_required "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
copy_required "$UI_RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
copy_required "$DOMAIN_RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
copy_required "$ROOT_DIR/LICENSE" "$APP_DIR/Contents/Resources/LICENSE.txt"
copy_required "$KEEPASSKIT_FRAMEWORK" "$APP_DIR/Contents/lib/"
copy_required "$KISSXML_FRAMEWORK" "$APP_DIR/Contents/lib/"
copy_required "$APP_ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
# The app's own languages: macOS localizes system menus and offers the per-app language setting from these.
for language in en ru; do
  mkdir -p "$APP_DIR/Contents/Resources/$language.lproj"
  printf '"CFBundleDisplayName" = "%s";\n' "$DISPLAY_NAME" > "$APP_DIR/Contents/Resources/$language.lproj/InfoPlist.strings"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>ru</string>
  </array>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>KeeMacCommit</key>
  <string>$BUILD_COMMIT</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# A valid, unexpired profile in PROFILES_DIR whose App ID is TEAM.<bundle ID>; prints its path.
find_profile() {
  local profile plist app_id expires
  [[ -d "$PROFILES_DIR" ]] || return 1
  plist="$(mktemp)"
  for profile in "$PROFILES_DIR"/*.provisionprofile; do
    [[ -e "$profile" ]] || continue
    security cms -D -i "$profile" > "$plist" 2>/dev/null || continue
    app_id="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$plist" 2>/dev/null || true)"
    expires="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null || true)"
    if [[ "${app_id#*.}" == "$BUNDLE_IDENTIFIER" ]] && [[ -n "$expires" ]] \
      && [[ "$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$expires" +%s 2>/dev/null || echo 0)" -gt "$(date +%s)" ]]; then
      rm -f "$plist"
      echo "$profile"
      return 0
    fi
  done
  rm -f "$plist"
  return 1
}

# The first certificate of this kind that codesign can use.
find_identity() {
  security find-identity -v -p codesigning 2>/dev/null | awk -v kind="$1" -F '"' 'index($2, kind) == 1 { print $2; exit }'
}

PROFILE=""
IDENTITY="${SIGN_IDENTITY:-}"
if [[ "$VARIANT" != "uitests" ]]; then
  PROFILE="$(find_profile || true)"
  if [[ -n "$PROFILE" && -z "$IDENTITY" ]]; then
    IDENTITY="$(find_identity "Apple Development")"
    [[ -n "$IDENTITY" ]] || IDENTITY="$(find_identity "Developer ID Application")"
  fi
fi

if [[ -n "$PROFILE" && -n "$IDENTITY" ]]; then
  PROFILE_PLIST="$(mktemp)"
  ENTITLEMENTS="$(mktemp)"
  security cms -D -i "$PROFILE" > "$PROFILE_PLIST"
  TEAM_ID="$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$PROFILE_PLIST")"
  rm -f "$PROFILE_PLIST"
  # The keychain group lets Touch ID items live in the data protection keychain, tied to this app and team.
  cat > "$ENTITLEMENTS" <<ENTITLEMENTS_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$TEAM_ID.$BUNDLE_IDENTIFIER</string>
  <key>com.apple.developer.team-identifier</key>
  <string>$TEAM_ID</string>
  <key>keychain-access-groups</key>
  <array>
    <string>$TEAM_ID.$BUNDLE_IDENTIFIER</string>
  </array>
</dict>
</plist>
ENTITLEMENTS_PLIST
  cp "$PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
  echo "Signing with \"$IDENTITY\" and $(basename "$PROFILE")"
  for framework in "$APP_DIR"/Contents/lib/*.framework; do
    codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$framework"
  done
  codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP_DIR/Contents/MacOS/keemac-proxy"
  codesign --force --options runtime --timestamp=none --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"
  rm -f "$ENTITLEMENTS"
else
  if [[ "$VARIANT" != "uitests" ]]; then
    echo "warning: no signing certificate or provisioning profile for $BUNDLE_IDENTIFIER; signing ad-hoc (Touch ID falls back to the legacy keychain)" >&2
  fi
  codesign --force --sign - "$APP_DIR/Contents/MacOS/keemac-proxy"
  codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

echo "Built app: $APP_DIR"

if [[ "$INSTALL_TO_USER_APPS" == "true" ]]; then
  USER_APPS_DIR="$HOME/Applications"
  mkdir -p "$USER_APPS_DIR"
  rm -rf "$USER_APPS_DIR/$DISPLAY_NAME.app"
  cp -R "$APP_DIR" "$USER_APPS_DIR/"
  echo "Installed app: $USER_APPS_DIR/$DISPLAY_NAME.app"
fi
