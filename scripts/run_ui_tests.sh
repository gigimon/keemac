#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/.build/uitest-dist/KeeMac.app"
DERIVED_DATA_PATH="$ROOT_DIR/.build/UITestsDerived"
RESULT_BUNDLE="$ROOT_DIR/.build/UITests.xcresult"
BUILD_APP="true"
ONLY_TESTING=()

usage() {
  cat <<'USAGE'
Usage: scripts/run_ui_tests.sh [options]

Builds the UI test app (scripts/build_app.sh --ui-testing), generates
UITests/KeeMacUITests.xcodeproj with XcodeGen and runs the XCUITest suite.
A failed test is retried up to two more times before it counts as failed.

Options:
  --skip-build           Reuse .build/uitest-dist/KeeMac.app
  --only <Class[/test]>  Run only these tests (repeatable)
  -h, --help             Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      BUILD_APP="false"
      shift
      ;;
    --only)
      ONLY_TESTING+=("-only-testing:KeeMacUITests/$2")
      shift 2
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

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen is required: brew install xcodegen" >&2
  exit 1
fi

if [[ "$BUILD_APP" == "true" ]]; then
  "$ROOT_DIR/scripts/build_app.sh" --ui-testing
fi

xcodegen generate --quiet --spec "$ROOT_DIR/UITests/project.yml" --project "$ROOT_DIR/UITests"

rm -rf "$RESULT_BUNDLE"
xcodebuild test \
  -project "$ROOT_DIR/UITests/KeeMacUITests.xcodeproj" \
  -scheme KeeMacUITests \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -resultBundlePath "$RESULT_BUNDLE" \
  -retry-tests-on-failure \
  -test-iterations 3 \
  ${ONLY_TESTING[@]+"${ONLY_TESTING[@]}"} \
  TEST_RUNNER_KEEMAC_APP_PATH="$APP_PATH"
