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

BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.keemac.local}"
# shellcheck source=resolve_version.sh
source "$ROOT_DIR/scripts/resolve_version.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/build_app.sh [options]

Options:
  --debug            Build Debug configuration (default: Release)
  --release          Build Release configuration
  --install          Install built app to ~/Applications
  --clean            Remove previous DerivedData and dist output before build
  --ui-testing       Debug build for the UI tests: bundle ID com.keemac.uitests, output in .build/uitest-dist
  -h, --help         Show this help

Environment overrides:
  BUNDLE_IDENTIFIER  CFBundleIdentifier (default: com.keemac.local)
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
      BUNDLE_IDENTIFIER="com.keemac.uitests"
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

APP_DIR="$DIST_DIR/$APP_NAME.app"

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
  printf '"CFBundleDisplayName" = "%s";\n' "$APP_NAME" > "$APP_DIR/Contents/Resources/$language.lproj/InfoPlist.strings"
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
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_IDENTIFIER</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
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

codesign --force --sign - "$APP_DIR/Contents/MacOS/keemac-proxy"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "Built app: $APP_DIR"

if [[ "$INSTALL_TO_USER_APPS" == "true" ]]; then
  USER_APPS_DIR="$HOME/Applications"
  mkdir -p "$USER_APPS_DIR"
  rm -rf "$USER_APPS_DIR/$APP_NAME.app"
  cp -R "$APP_DIR" "$USER_APPS_DIR/"
  echo "Installed app: $USER_APPS_DIR/$APP_NAME.app"
fi
