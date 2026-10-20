#!/usr/bin/env bash
# 1. "KeeMac Dev" (tech.keemac.dev), Apple Development signing, for day-to-day development.
# Extra options go to build_app.sh, e.g. --install (to ~/Applications) or --debug.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/build_app.sh" "$@"
