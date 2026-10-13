#!/usr/bin/env bash
# Offline launcher regression suite. Requires Python 3 and Git; never runs Codex.
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/codex-launch.py" "$@"
