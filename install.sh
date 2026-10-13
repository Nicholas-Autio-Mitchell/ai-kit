#!/usr/bin/env bash
set -euo pipefail

# install.sh — install the ai-kit launcher and its subagent team on Linux.
#
# The pattern: a self-contained PAYLOAD directory plus OWNED SYMLINKS.
#
#   <prefix>/                      everything the tool needs, in one versioned dir
#   <bin-dir>/<cmd>  -> <prefix>/ai
#
# Only symlinks ever land in a directory on your PATH, and only ones this script
# recorded in <prefix>/manifest. It refuses to replace anything it does not own,
# so it cannot clobber another tool's binary, and uninstall.sh removes exactly
# what was created and nothing else.
#
# The launcher resolves its own location through symlinks and looks for agent.d/
# beside itself, so the payload works from any prefix and the symlink can be
# named anything you like. That is why the command name is a question rather
# than a constant: if `ai` is taken on your machine, pick another name and
# nothing else changes.
#
# usage:
#   ./install.sh                          interactive (recommended)
#   ./install.sh -y                       non-interactive, all defaults
#   ./install.sh --name aid --shortcuts -y
#   ./install.sh --uninstall
#
# options:
#   --prefix DIR      payload location   (default: $XDG_DATA_HOME/ai-kit)
#   --bin-dir DIR     where the command symlink goes (default: ~/.local/bin)
#   --name NAME       command name       (default: ai)
#   --shortcuts       also install <cmd>-wt, claude-wt, codex-wt
#   --no-shortcuts    do not (the default)
#   -y, --yes         answer nothing, take the defaults
#   --uninstall       hand off to uninstall.sh
#   -h, --help        this text
#
# Targets Linux (developed and tested on Ubuntu). It asserts GNU coreutils and
# bash >= 4 up front rather than degrading quietly on other platforms.

# ---- Where this script lives (payload source) ------------------------------
src="${BASH_SOURCE[0]}"
while [ -h "$src" ]; do
  d="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
REPO="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"

VERSION="$(cat "$REPO/VERSION" 2>/dev/null || echo unknown)"

# ---- Output ----------------------------------------------------------------
if [ -t 2 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; N=$'\033[0m'
else
  B=""; DIM=""; GRN=""; YLW=""; RED=""; N=""
fi
usage() {
  cat <<EOF
install.sh — install the ai-kit launcher and its subagent team (Linux).

usage:
  ./install.sh                       interactive (recommended)
  ./install.sh -y                    non-interactive, all defaults
  ./install.sh --name aid --shortcuts -y
  ./install.sh --uninstall

options:
  --prefix DIR      payload location   (default: \${XDG_DATA_HOME:-~/.local/share}/ai-kit)
  --bin-dir DIR     where the command symlink goes (default: ~/.local/bin)
  --name NAME       command name       (default: ai)
  --shortcuts       also install <cmd>-wt, claude-wt, codex-wt
  --no-shortcuts    do not (the default)
  -y, --yes         answer nothing, take the defaults
  --uninstall       hand off to uninstall.sh
  -h, --help        this text

Installs a self-contained payload under --prefix and a symlink to it in
--bin-dir. Nothing else is touched, and uninstall.sh removes exactly what
was recorded in <prefix>/manifest.
EOF
}

say()  { printf '%s\n' "$*" >&2; }
head_() { printf '\n%s%s%s\n' "$B" "$*" "$N" >&2; }
ok()   { printf '  %s✓%s %s\n' "$GRN" "$N" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$YLW" "$N" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n\n' "$RED" "$N" "$*" >&2; exit 1; }

# ---- Defaults --------------------------------------------------------------
DEFAULT_PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/ai-kit"
DEFAULT_BIN_DIR="$HOME/.local/bin"
DEFAULT_NAME="ai"

PREFIX=""; BIN_DIR=""; CMD=""; SHORTCUTS=""; ASSUME_YES=0

# ---- Arguments -------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)      [ "$#" -ge 2 ] || die "--prefix needs a directory";  PREFIX="$2";  shift 2 ;;
    --bin-dir)     [ "$#" -ge 2 ] || die "--bin-dir needs a directory"; BIN_DIR="$2"; shift 2 ;;
    --name)        [ "$#" -ge 2 ] || die "--name needs a command name"; CMD="$2";     shift 2 ;;
    --shortcuts)   SHORTCUTS=1; shift ;;
    --no-shortcuts) SHORTCUTS=0; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    --uninstall)   shift; exec "$REPO/uninstall.sh" "$@" ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "unknown option: $1  (try --help)" ;;
  esac
done

# Piping into bash (or any non-tty stdin) is not a place to ask questions.
interactive=1
{ [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; } && interactive=0

# ---- Prompt helpers --------------------------------------------------------
# Prompts go to stderr so command substitution captures only the answer.
ask() {  # ask <question> <default>
  local q="$1" default="$2" reply=""
  if [ "$interactive" -eq 0 ]; then printf '%s' "$default"; return 0; fi
  printf '  %s %s[%s]%s ' "$q" "$DIM" "$default" "$N" >&2
  IFS= read -r reply || reply=""
  printf '%s' "${reply:-$default}"
}
ask_yn() {  # ask_yn <question> <y|n default> -> 0 = yes
  local q="$1" default="$2" reply=""
  if [ "$interactive" -eq 0 ]; then [ "$default" = y ]; return; fi
  case "$default" in y) local hint="Y/n" ;; *) local hint="y/N" ;; esac
  printf '  %s %s[%s]%s ' "$q" "$DIM" "$hint" "$N" >&2
  IFS= read -r reply || reply=""
  case "${reply:-$default}" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# abspath <path> — expand a leading ~ and make it absolute WITHOUT requiring the
# path to exist yet (realpath -e would refuse; we are about to create these).
abspath() {
  local p="$1"
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  printf '%s' "${p%/}"
}

# ---- Preflight -------------------------------------------------------------
head_ "ai-kit $VERSION — preflight"

[ "$(uname -s)" = "Linux" ] || die "this package targets Linux (see README.md). Found: $(uname -s)"
ok "Linux ($(uname -m))"

[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] \
  || die "bash 4+ required (found ${BASH_VERSION:-unknown}). On Ubuntu: sudo apt install bash"
ok "bash ${BASH_VERSION%%(*}"

command -v git >/dev/null 2>&1 || die "git not found. On Ubuntu: sudo apt install git"
git_v="$(git --version | awk '{print $3}')"
git_major="${git_v%%.*}"; git_rest="${git_v#*.}"; git_minor="${git_rest%%.*}"
if [ "$git_major" -lt 2 ] || { [ "$git_major" -eq 2 ] && [ "$git_minor" -lt 31 ]; }; then
  die "git >= 2.31 required (found $git_v). The launcher uses
       'git rev-parse --path-format=absolute', added in 2.31.
       On Ubuntu: sudo add-apt-repository ppa:git-core/ppa && sudo apt update && sudo apt install git"
fi
ok "git $git_v"

have_claude=0; have_codex=0
command -v claude >/dev/null 2>&1 && have_claude=1
command -v codex  >/dev/null 2>&1 && have_codex=1
if [ "$have_claude" -eq 1 ]; then ok "claude  $(claude --version 2>/dev/null | head -1)"; fi
if [ "$have_codex"  -eq 1 ]; then ok "codex   $(codex  --version 2>/dev/null | head -1)"; fi
if [ "$have_claude" -eq 0 ] && [ "$have_codex" -eq 0 ]; then
  warn "neither 'claude' nor 'codex' is on your PATH — install at least one:"
  say  "      Claude Code: curl -fsSL https://claude.ai/install.sh | bash"
  say  "      Codex:       npm i -g @openai/codex   (or: brew install codex)"
  say  "    Installing anyway; the launcher will work once a CLI is present."
elif [ "$have_claude" -eq 0 ]; then
  warn "'claude' not found — the default agent will not run. Use '<cmd> codex ...' or install Claude Code."
elif [ "$have_codex" -eq 0 ]; then
  warn "'codex' not found — '<cmd> codex ...' will not run until it is installed."
fi

if command -v python3 >/dev/null 2>&1; then
  ok "python3 $(python3 --version 2>&1 | awk '{print $2}')  (Codex model auto-detect)"
else
  warn "python3 not found — Codex falls back to a pinned model instead of reading its own catalogue."
fi

if command -v direnv >/dev/null 2>&1; then
  ok "direnv $(direnv version 2>/dev/null)  (worktrees inherit the project environment)"
else
  warn "direnv not found — worktree sessions run without your project's environment."
  say  "    Optional. On Ubuntu: sudo apt install direnv"
fi

if git config --get user.email >/dev/null 2>&1 && git config --get user.name >/dev/null 2>&1; then
  ok "git identity: $(git config --get user.name) <$(git config --get user.email)>"
else
  warn "git user.name/user.email not set — the chronicler agent commits, and commits will fail."
  say  "    git config --global user.name  \"Your Name\""
  say  "    git config --global user.email \"you@example.com\""
fi

# ---- Questions -------------------------------------------------------------
# Four, and each one changes the install. Everything else is an environment
# variable at run time (see README) and does not belong in an installer.
if [ "$interactive" -eq 1 ]; then
  head_ "Setup"
else
  head_ "Setup (non-interactive)"
fi

[ -n "$PREFIX" ]  || PREFIX="$(ask  "Install directory for the tool itself?" "$DEFAULT_PREFIX")"
PREFIX="$(abspath "$PREFIX")"

[ -n "$BIN_DIR" ] || BIN_DIR="$(ask "Directory on your PATH for the command?" "$DEFAULT_BIN_DIR")"
BIN_DIR="$(abspath "$BIN_DIR")"

# Command name, with collision detection. This is the question that keeps the
# package from stepping on another tool: 'ai' is a short, popular name.
if [ -z "$CMD" ]; then
  suggested="$DEFAULT_NAME"
  existing="$(command -v "$DEFAULT_NAME" 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "$BIN_DIR/$DEFAULT_NAME" ]; then
    warn "'$DEFAULT_NAME' is already a command on your PATH: $existing"
    suggested="ai-kit"
    say  "    Suggesting '$suggested' instead so nothing is shadowed."
  fi
  CMD="$(ask "Command name?" "$suggested")"
fi
case "$CMD" in
  ""|*/*|*[[:space:]]*) die "invalid command name: '$CMD'" ;;
esac

if [ -z "$SHORTCUTS" ]; then
  if ask_yn "Also install worktree shortcuts ($CMD-wt, claude-wt, codex-wt)?" n; then
    SHORTCUTS=1
  else
    SHORTCUTS=0
  fi
fi

# ---- Work out the links, and refuse to touch anything we do not own --------
links=("$BIN_DIR/$CMD:ai")
if [ "$SHORTCUTS" -eq 1 ]; then
  links+=("$BIN_DIR/$CMD-wt:agent-wt" "$BIN_DIR/claude-wt:claude-wt" "$BIN_DIR/codex-wt:codex-wt")
fi

# owned <path> — true when <path> is a symlink already pointing into our prefix.
# That is the whole ownership test: we replace our own links on upgrade and
# leave everything else strictly alone.
owned() {
  local p="$1" t
  [ -L "$p" ] || return 1
  t="$(readlink -f -- "$p" 2>/dev/null)" || return 1
  case "$t" in "$PREFIX"/*) return 0 ;; *) return 1 ;; esac
}

conflicts=()
for spec in "${links[@]}"; do
  path="${spec%%:*}"
  if [ -e "$path" ] || [ -L "$path" ]; then
    owned "$path" || conflicts+=("$path")
  fi
done

if [ "${#conflicts[@]}" -gt 0 ]; then
  head_ "Conflict"
  say "  These already exist and were not created by ai-kit:"
  for c in "${conflicts[@]}"; do
    say "    $c  ->  $(readlink -- "$c" 2>/dev/null || echo '(not a symlink)')"
  done
  say ""
  say "  Nothing has been changed. Re-run with a different name, e.g.:"
  say "    ./install.sh --name ${CMD}-kit"
  exit 1
fi

# ---- Install ---------------------------------------------------------------
head_ "Installing"

case "$PREFIX" in
  "/"|"$HOME"|"") die "refusing to use '$PREFIX' as the payload directory" ;;
esac

# Upgrade in place: clear only the payload we lay down, never the whole prefix,
# so a manifest or anything else the user parked there survives.
rm -rf -- "$PREFIX/agent.d"
rm -f  -- "$PREFIX/ai" "$PREFIX/agent-wt" "$PREFIX/claude-wt" "$PREFIX/codex-wt"
mkdir -p -- "$PREFIX"

cp -R -- "$REPO/agent.d" "$PREFIX/agent.d"
for f in ai agent-wt claude-wt codex-wt; do
  cp -- "$REPO/bin/$f" "$PREFIX/$f"
done
cp -- "$REPO/uninstall.sh" "$PREFIX/uninstall.sh"
cp -- "$REPO/VERSION" "$PREFIX/VERSION"

# Deterministic modes: a clone inherits the cloner's umask, and a payload that
# is not readable by the launcher is a confusing failure.
find "$PREFIX" -type d -exec chmod 755 {} +
find "$PREFIX" -type f -exec chmod 644 {} +
chmod 755 "$PREFIX"/ai "$PREFIX"/agent-wt "$PREFIX"/claude-wt "$PREFIX"/codex-wt \
          "$PREFIX"/uninstall.sh "$PREFIX"/agent.d/tests/*.sh
ok "payload -> $PREFIX"

mkdir -p -- "$BIN_DIR"
created=()
for spec in "${links[@]}"; do
  path="${spec%%:*}"; target="$PREFIX/${spec##*:}"
  ln -sfn -- "$target" "$path"
  created+=("$path")
  ok "$path -> ${target#"$PREFIX"/}"
done

# Drop links from a previous install that this run did not recreate (e.g. the
# command was renamed, or shortcuts were turned off). Only ever our own.
if [ -f "$PREFIX/manifest" ]; then
  while IFS= read -r old; do
    keep=0
    for c in "${created[@]}"; do [ "$c" = "$old" ] && keep=1 && break; done
    if [ "$keep" -eq 0 ] && owned "$old"; then
      rm -f -- "$old"
      ok "removed stale link $old"
    fi
  done < <(sed -n 's/^link=//p' "$PREFIX/manifest")
fi

{
  echo "# ai-kit install manifest — used by uninstall.sh. Do not edit."
  echo "version=$VERSION"
  echo "installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "prefix=$PREFIX"
  echo "bin_dir=$BIN_DIR"
  echo "command=$CMD"
  for c in "${created[@]}"; do echo "link=$c"; done
} > "$PREFIX/manifest"
chmod 644 "$PREFIX/manifest"

# ---- Post-install ----------------------------------------------------------
head_ "Done"

case ":$PATH:" in
  *":$BIN_DIR:"*) ok "$BIN_DIR is on your PATH" ;;
  *)
    warn "$BIN_DIR is NOT on your PATH. Add it:"
    say  "      echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.bashrc && exec bash"
    ;;
esac

# The one setting that changes real behaviour and is not shipped with the kit.
# Reported, never written: it lives in the user's own Claude config.
if [ "$have_claude" -eq 1 ]; then
  settings="$HOME/.claude/settings.json"
  if [ ! -f "$settings" ] || ! grep -q 'skipDangerousModePermissionPrompt' "$settings" 2>/dev/null; then
    warn "Claude's full-auto disclaimer is accepted once per machine. Until then the"
    say  "    session falls back to --permission-mode dontAsk (still unattended, but"
    say  "    'ask' rules become denials). To accept it up front, add to $settings:"
    say  "      { \"skipDangerousModePermissionPrompt\": true }"
  fi
fi

say ""
say "  Sign in to the agents you use (credentials are per-machine; none ship with this package):"
[ "$have_claude" -eq 1 ] && say "      claude   then /login"
[ "$have_codex"  -eq 1 ] && say "      codex login"
say ""
say "  Try it:"
say "      $CMD --help"
say "      $CMD \"Fix the failing test in tests/test_login.py\"     # in place, current branch"
say "      $CMD wt \"Risky refactor\"                               # isolated worktree"
say ""
say "  Manual:    $PREFIX/agent.d/README.md"
say "  Uninstall: $PREFIX/uninstall.sh"
say ""
