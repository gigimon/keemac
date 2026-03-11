#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/.build/vendor-src"
VENDOR_DIR="$ROOT_DIR/Vendor"

KISSXML_REPO="https://github.com/robbiehanson/KissXML.git"
KEEPASSKIT_REPO="https://github.com/MacPass/KeePassKit.git"

KISSXML_SRC="$WORK_DIR/KissXML"
KEEPASSKIT_SRC="$WORK_DIR/KeePassKit"
DERIVED_KISSXML="$WORK_DIR/DerivedData/KissXML"
DERIVED_KEEPASSKIT="$WORK_DIR/DerivedData/KeePassKit"

mkdir -p "$WORK_DIR" "$VENDOR_DIR"

clone_or_update() {
  local repo="$1"
  local target="$2"
  if [[ -d "$target/.git" ]]; then
    git -C "$target" fetch --depth 1 origin
    local default_branch
    default_branch="$(git -C "$target" symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@')"
    git -C "$target" checkout "$default_branch"
    git -C "$target" reset --hard "origin/$default_branch"
  else
    git clone --depth 1 "$repo" "$target"
  fi
}

clone_or_update "$KISSXML_REPO" "$KISSXML_SRC"
clone_or_update "$KEEPASSKIT_REPO" "$KEEPASSKIT_SRC"

git -C "$KEEPASSKIT_SRC" submodule update --init --recursive

xcodebuild \
  -project "$KISSXML_SRC/KissXML.xcodeproj" \
  -scheme "KissXML (macOS)" \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_KISSXML" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=15.0 \
  build

mkdir -p "$KEEPASSKIT_SRC/Carthage/Build/Mac"
rsync -a \
  "$DERIVED_KISSXML/Build/Products/Release/KissXML.framework" \
  "$KEEPASSKIT_SRC/Carthage/Build/Mac/"

xcodebuild \
  -project "$KEEPASSKIT_SRC/KeePassKit.xcodeproj" \
  -scheme "KeePassKit macOS" \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED_KEEPASSKIT" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  MACOSX_DEPLOYMENT_TARGET=15.0 \
  build

rm -rf "$VENDOR_DIR/KissXML.xcframework" "$VENDOR_DIR/KeePassKit.xcframework"

xcodebuild -create-xcframework \
  -framework "$DERIVED_KISSXML/Build/Products/Release/KissXML.framework" \
  -output "$VENDOR_DIR/KissXML.xcframework"

xcodebuild -create-xcframework \
  -framework "$DERIVED_KEEPASSKIT/Build/Products/Release/KeePassKit.framework" \
  -output "$VENDOR_DIR/KeePassKit.xcframework"

echo "Updated vendor frameworks:"
echo "- $VENDOR_DIR/KissXML.xcframework"
echo "- $VENDOR_DIR/KeePassKit.xcframework"
