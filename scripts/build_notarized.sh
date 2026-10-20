#!/usr/bin/env bash
# 3. "KeeMac" (tech.keemac.app), Developer ID signed, notarized and stapled, packed as
# .build/release/KeeMac-<version>-macOS.zip for the website. --staple finishes a notarization
# that Apple completed after the script stopped waiting.
set -euo pipefail
if [[ "${1:-}" == "--staple" ]]; then
  exec "$(dirname "${BASH_SOURCE[0]}")/make_release_archive.sh" --staple
fi
exec "$(dirname "${BASH_SOURCE[0]}")/make_release_archive.sh" --notarize "$@"
