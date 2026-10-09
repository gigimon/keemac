#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT_DIR/.build/vendor-src"
VENDOR_DIR="$ROOT_DIR/Vendor"

KISSXML_REPO="https://github.com/robbiehanson/KissXML.git"
KEEPASSKIT_REPO="https://github.com/MacPass/KeePassKit.git"

# Pinned revisions of the vendored binaries. KeePassKit is GPLv3: the source for
# Vendor/KeePassKit.xcframework is exactly this commit. Keep in sync with
# Sources/UI/AboutLicenses.swift when updating.
KISSXML_REF="${KISSXML_REF:-990cdef080213b5a3f0d9709b845d553bd3ddb97}"
KEEPASSKIT_REF="${KEEPASSKIT_REF:-b5cf50ee4ebd67cb355792d7813965fe3ac7125e}"

KISSXML_SRC="$WORK_DIR/KissXML"
KEEPASSKIT_SRC="$WORK_DIR/KeePassKit"
DERIVED_KISSXML="$WORK_DIR/DerivedData/KissXML"
DERIVED_KEEPASSKIT="$WORK_DIR/DerivedData/KeePassKit"

mkdir -p "$WORK_DIR" "$VENDOR_DIR"

checkout_revision() {
  local repo="$1"
  local target="$2"
  local ref="$3"
  if [[ ! -d "$target/.git" ]]; then
    git init -q "$target"
    git -C "$target" remote add origin "$repo"
  fi
  git -C "$target" fetch --depth 1 origin "$ref"
  git -C "$target" checkout -q --force FETCH_HEAD
}

checkout_revision "$KISSXML_REPO" "$KISSXML_SRC" "$KISSXML_REF"
checkout_revision "$KEEPASSKIT_REPO" "$KEEPASSKIT_SRC" "$KEEPASSKIT_REF"

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

echo "Updated vendor frameworks (KissXML $KISSXML_REF, KeePassKit $KEEPASSKIT_REF):"
echo "- $VENDOR_DIR/KissXML.xcframework"
echo "- $VENDOR_DIR/KeePassKit.xcframework"
