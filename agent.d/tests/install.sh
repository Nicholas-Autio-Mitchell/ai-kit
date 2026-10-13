#!/usr/bin/env bash
# Offline installation tests; requires Python 3 and Git, never installs packages.
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/install.py" "$@"
