#!/usr/bin/env bash
# Offline dependency-install tests; package managers are always local fakes.
set -euo pipefail
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$here/dependencies.py" "$@"
