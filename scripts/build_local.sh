#!/usr/bin/env bash
# 2. "KeeMac" (tech.keemac.app), Developer ID signed but not notarized, installed to ~/Applications
# for testing the production app on this Mac. Extra options go to build_app.sh.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/build_app.sh" --release --install "$@"
