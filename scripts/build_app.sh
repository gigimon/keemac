#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SCHEME="KeeMacApp"
CONFIGURATION="Release"
DESTINATION="platform=macOS"
DERIVED_DATA_PATH="$ROOT_DIR/.build/Derived"
DIST_DIR="$ROOT_DIR/.build/dist"
APP_NAME="KeeMac"
APP_DIR="$DIST_DIR/$APP_NAME.app"
INSTALL_TO_USER_APPS="false"

BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.keemac.local}"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

usage() {
  cat <<'USAGE'
Usage: scripts/build_app.sh [options]

Options:
  --debug            Build Debug configuration (default: Release)
  --release          Build Release configuration
  --install          Install built app to ~/Applications
  --clean            Remove previous DerivedData and dist output before build
  -h, --help         Show this help

Environment overrides:
  BUNDLE_IDENTIFIER  CFBundleIdentifier (default: com.keemac.local)
  APP_VERSION        CFBundleShortVersionString (default: 0.1.0)
  BUILD_NUMBER       CFBundleVersion (default: 1)
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

echo "Building $APP_NAME ($CONFIGURATION)..."
xcodebuild \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

PRODUCTS_DIR="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION"

APP_BINARY="$PRODUCTS_DIR/KeeMacApp"
RESOURCE_BUNDLE="$PRODUCTS_DIR/KeeMac_App.bundle"
KEEPASSKIT_FRAMEWORK="$PRODUCTS_DIR/KeePassKit.framework"
KISSXML_FRAMEWORK="$PRODUCTS_DIR/KissXML.framework"
APP_ICON="$ROOT_DIR/Sources/App/Resources/AppIcon.icns"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/lib"

copy_required "$APP_BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
copy_required "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/"
copy_required "$KEEPASSKIT_FRAMEWORK" "$APP_DIR/Contents/lib/"
copy_required "$KISSXML_FRAMEWORK" "$APP_DIR/Contents/lib/"
copy_required "$APP_ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
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
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

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
