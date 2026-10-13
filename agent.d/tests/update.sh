#!/usr/bin/env bash
# Offline 'ai update' tests; agent CLIs, Homebrew and the network are fakes.
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/update.py" "$@"
