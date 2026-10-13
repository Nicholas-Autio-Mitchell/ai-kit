#!/usr/bin/env bash
set -euo pipefail

# uninstall.sh — remove an ai-kit installation, and only that.
#
# Everything install.sh created is listed in <prefix>/manifest. This script
# removes exactly those entries: each symlink is deleted only if it is still a
# symlink pointing into the prefix, so a name you have since taken over with
# your own tool is reported and left alone. Nothing outside the prefix and the
# recorded links is ever touched.
#
# usage:
#   ./uninstall.sh                 find the installation and remove it
#   ./uninstall.sh --prefix DIR    remove the installation at DIR
#   ./uninstall.sh -y              do not ask
#
# A copy of this script is installed at <prefix>/uninstall.sh, so uninstalling
# does not require keeping the git clone around.

src="${BASH_SOURCE[0]}"
while [ -h "$src" ]; do
  d="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
HERE="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
. "$HERE/agent.d/lib/paths.sh"
. "$HERE/agent.d/lib/platform.sh"
ai_prefer_homebrew

if [ -t 2 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; N=$'\033[0m'
else
  B=""; DIM=""; GRN=""; YLW=""; RED=""; N=""
fi
say()   { printf '%s\n' "$*" >&2; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N" >&2; }
ok()    { printf '  %s✓%s %s\n' "$GRN" "$N" "$*" >&2; }
warn()  { printf '  %s!%s %s\n' "$YLW" "$N" "$*" >&2; }
die()   { printf '\n%serror:%s %s\n\n' "$RED" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
uninstall.sh — remove an ai-kit installation, and only that.

usage:
  ./uninstall.sh                 find the installation and remove it
  ./uninstall.sh --prefix DIR    remove the installation at DIR
  ./uninstall.sh -y              do not ask

Removes exactly what <prefix>/manifest records. A recorded name that is no
longer a symlink into the prefix is reported and left alone.
EOF
}

PREFIX=""; ASSUME_YES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix) [ "$#" -ge 2 ] || die "--prefix needs a directory"; PREFIX="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1  (try --help)" ;;
  esac
done

# Locate the manifest: an explicit --prefix, then this script's own directory
# (the installed copy sits beside it), then the default location.
if [ -z "$PREFIX" ]; then
  if [ -f "$HERE/manifest" ]; then
    PREFIX="$HERE"
  else
    PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/ai-kit"
  fi
fi
case "$PREFIX" in
  "~")   PREFIX="$HOME" ;;
  "~/"*) PREFIX="$HOME/${PREFIX#\~/}" ;;
esac
case "$PREFIX" in /*) ;; *) PREFIX="$PWD/$PREFIX" ;; esac
PREFIX="$(ai_realpath "$PREFIX")"

manifest="$PREFIX/manifest"
[ -f "$manifest" ] || die "no ai-kit manifest at $manifest
       If it is installed elsewhere: ./uninstall.sh --prefix /path/to/ai-kit"

# Trust the manifest's own idea of its prefix over the path we guessed: a moved
# installation should not talk us into deleting the wrong directory.
recorded="$(sed -n 's/^prefix=//p' "$manifest" | head -1)"
[ "$recorded" = "$PREFIX" ] || die "manifest at $manifest records prefix '$recorded'.
       Refusing to act on a mismatch — run with --prefix '$recorded'."
case "$PREFIX" in
  "/"|"$HOME"|"") die "refusing to remove '$PREFIX'" ;;
esac

# owned <path> — still a symlink of ours, i.e. one pointing into the prefix.
# The test is what makes this safe to run long after installing: if you have
# since replaced the name with your own tool, it fails and we leave it be.
owned() {
  local p="$1" t
  [ -L "$p" ] || return 1
  t="$(ai_realpath "$p")" || return 1
  case "$t" in "$PREFIX"/*) return 0 ;; *) return 1 ;; esac
}

links=()
while IFS= read -r l; do
  [ -n "$l" ] && links+=("$l")
done < <(sed -n 's/^link=//p' "$manifest")

head_ "ai-kit — uninstall"
say "  prefix: $PREFIX"
if [ "${#links[@]}" -gt 0 ]; then
  say "  links:  ${links[*]}"
else
  say "  links:  ${DIM}(none recorded)${N}"
fi

if [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
  printf '\n  Remove these? %s[y/N]%s ' "$DIM" "$N" >&2
  IFS= read -r reply || reply=""
  case "$reply" in [yY]*) ;; *) say "  Nothing removed."; exit 0 ;; esac
fi

head_ "Removing"
for l in ${links[@]+"${links[@]}"}; do
  if [ ! -e "$l" ] && [ ! -L "$l" ]; then
    warn "$l — already gone"
  elif owned "$l"; then
    rm -f -- "$l"
    ok "removed $l"
  else
    warn "$l — no longer points into $PREFIX, left alone"
  fi
done

rm -rf -- "$PREFIX"
ok "removed $PREFIX"

say ""
say "  Untouched, because they are yours and not ours:"
say "    ~/.claude/  ~/.codex/   (agent settings and credentials)"
say "    any DEVLOG.md or .claude/agents/ committed in your own repositories"
say ""
