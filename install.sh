#!/usr/bin/env bash
set -euo pipefail

# install.sh — install the ai-kit launcher and its subagent team (Linux/macOS).
#
# Lays down a self-contained payload and one symlink to it:
#
#   <prefix>/                      ai, agent.d/, uninstall.sh, VERSION, manifest
#   <bin-dir>/<name>  -> <prefix>/ai
#
# The link is recorded in <prefix>/manifest. Nothing that is not already an
# ai-kit link is ever replaced. Re-running upgrades in place and removes recorded
# links it no longer creates; uninstall.sh removes exactly what is recorded.
#
# Options: ./install.sh --help (usage() below).
# Supports Linux and macOS, including Apple's bundled Bash 3.2 and BSD utilities.

# ---- Where this script lives (payload source) ------------------------------
src="${BASH_SOURCE[0]}"
while [ -h "$src" ]; do
  d="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
  src="$(readlink "$src")"
  case "$src" in /*) ;; *) src="$d/$src" ;; esac
done
REPO="$(cd -P "$(dirname "$src")" >/dev/null 2>&1 && pwd)"
. "$REPO/agent.d/lib/paths.sh"

VERSION="$(cat "$REPO/VERSION" 2>/dev/null || echo unknown)"

# ---- Output ----------------------------------------------------------------
if [ -t 2 ]; then
  B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RED=$'\033[31m'; N=$'\033[0m'
else
  B=""; DIM=""; GRN=""; YLW=""; RED=""; N=""
fi
usage() {
  cat <<EOF
install.sh — install the ai-kit launcher and its subagent team (Linux/macOS).

usage: ./install.sh [options]

Asks for each setting not given as an option, unless -y is set or stdin is not
a terminal. Re-running upgrades in place: an existing install's settings become
the defaults, so after a git pull, ./install.sh -y is all an upgrade needs.

options:
  --prefix DIR    payload directory (default: the existing install's, else
                  \${XDG_DATA_HOME:-~/.local/share}/ai-kit)
  --bin-dir DIR   directory on your PATH for the command symlink (default: the
                  existing install's, else ~/.local/bin)
  --name NAME     command name (default: the existing install's, else ai)
  -y, --yes       ask nothing; use the default for each setting not given
  --uninstall     run uninstall.sh with the options that follow (--prefix DIR, -y)
  -h, --help      show this help

ai-kit runs the claude (default) or codex on your PATH; install, update and log in to
at least one yourself. direnv is used if present and never installed.
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

PREFIX=""; BIN_DIR=""; CMD=""; ASSUME_YES=0

# ---- Arguments -------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --prefix)      [ "$#" -ge 2 ] || die "--prefix needs a directory";  PREFIX="$2";  shift 2 ;;
    --bin-dir)     [ "$#" -ge 2 ] || die "--bin-dir needs a directory"; BIN_DIR="$2"; shift 2 ;;
    --name)        [ "$#" -ge 2 ] || die "--name needs a command name"; CMD="$2";     shift 2 ;;
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

# abspath <path> — expand a leading ~ and make it absolute WITHOUT requiring the
# path to exist yet (realpath -e would refuse; we are about to create these).
abspath() {
  local p="$1"
  case "$p" in
    "~")   p="$HOME" ;;
    "~/"*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  ai_realpath "$p"
}

# ---- Preflight -------------------------------------------------------------
head_ "ai-kit $VERSION — preflight"

platform="$(uname -s)"
case "$platform" in
  Linux) platform_label=Linux; git_install_hint="Install git with your distribution's package manager." ;;
  Darwin) platform_label=macOS; git_install_hint="Install Apple Command Line Tools (xcode-select --install), or brew install git." ;;
  *) die "supported platforms are Linux and macOS. Found: $platform" ;;
esac
ok "$platform_label ($(uname -m))"

{ [ "${BASH_VERSINFO[0]:-0}" -gt 3 ] || \
  { [ "${BASH_VERSINFO[0]:-0}" -eq 3 ] && [ "${BASH_VERSINFO[1]:-0}" -ge 2 ]; }; } \
  || die "bash 3.2+ required (found ${BASH_VERSION:-unknown})."
ok "bash ${BASH_VERSION%%(*}"

command -v git >/dev/null 2>&1 || die "git not found. $git_install_hint"
git_v="$(git --version | awk '{print $3}')"
git_major="${git_v%%.*}"; git_rest="${git_v#*.}"; git_minor="${git_rest%%.*}"
if [ "$git_major" -lt 2 ] || { [ "$git_major" -eq 2 ] && [ "$git_minor" -lt 31 ]; }; then
  die "git >= 2.31 required (found $git_v). The launcher uses
       'git rev-parse --path-format=absolute', added in 2.31.
       $git_install_hint"
fi
ok "git $git_v"

have_claude=0; have_codex=0
command -v claude >/dev/null 2>&1 && have_claude=1
command -v codex  >/dev/null 2>&1 && have_codex=1
if [ "$have_claude" -eq 1 ]; then ok "claude  $(claude --version 2>/dev/null | head -1)"; fi
if [ "$have_codex"  -eq 1 ]; then ok "codex   $(codex  --version 2>/dev/null | head -1)"; fi
agents_note="ai-kit runs the 'claude' (default) or 'codex' on your PATH; install, update and log in to them yourself."
if [ "$have_claude" -eq 1 ] || [ "$have_codex" -eq 1 ]; then say "  $agents_note"; else warn "$agents_note"; fi

if command -v python3 >/dev/null 2>&1; then
  ok "python3 $(python3 --version 2>&1 | awk '{print $2}')  (Codex supported-effort detection)"
else
  warn "python3 not found — Codex uses known effort defaults (GPT-6 Astra: ultra) instead of its catalogue."
fi

# Optional, and never installed. The launcher reads `direnv status --json`
# (2.33+); an older direnv cannot load the project .envrc for the agent.
if command -v direnv >/dev/null 2>&1; then
  direnv_v="$(direnv version 2>/dev/null || true)"
  if direnv version 2.33.0 >/dev/null 2>&1; then
    ok "direnv $direnv_v  (loads the project .envrc for the agent)"
  else
    warn "direnv ${direnv_v:-(no version)} is older than 2.33; ai-kit will not load .envrc with it."
  fi
else
  say "  direnv not found (optional; used to load the project .envrc for the agent)"
fi

if git config --get user.email >/dev/null 2>&1 && git config --get user.name >/dev/null 2>&1; then
  ok "git identity: $(git config --get user.name) <$(git config --get user.email)>"
else
  warn "git user.name/user.email not set — the chronicler agent commits, and commits will fail."
  say  "    git config --global user.name  \"Your Name\""
  say  "    git config --global user.email \"you@example.com\""
fi

# ---- Questions -------------------------------------------------------------
# Three, and each one changes the install. Everything else is an environment
# variable at run time (see README) and does not belong in an installer.
if [ "$interactive" -eq 1 ]; then
  head_ "Setup"
else
  head_ "Setup (non-interactive)"
fi

# ---- Previous install ------------------------------------------------------
# Re-running after a `git pull` must upgrade the install that is already there,
# not lay a second one down with the built-in defaults (or rename its command).
# Its manifest records the three settings; each one not given as an option
# defaults to the recorded value.

# install_at <dir> — true when <dir> is an ai-kit install of this user's: the
# directory and its manifest are theirs, and the manifest records <dir> as its
# own prefix (a moved or copied manifest is not trusted, as in uninstall.sh).
install_at() {
  [ -d "$1" ] && [ -O "$1" ] && [ -f "$1/manifest" ] && [ ! -L "$1/manifest" ] \
    && [ -O "$1/manifest" ] && grep -qs '^# ai-kit install manifest' "$1/manifest" \
    && [ "$(sed -n 's/^prefix=//p' "$1/manifest" | head -1)" = "$1" ]
}
# install_behind <path> — print the prefix of the install a command link at
# <path> points into; false when it is not an ai-kit link. `command -v` prints
# a bare name for a function or builtin, which is never one.
install_behind() {
  local t
  case "$1" in /*) ;; *) return 1 ;; esac
  [ -L "$1" ] || return 1
  t="$(ai_realpath "$1")" || return 1
  install_at "${t%/*}" && printf '%s\n' "${t%/*}"
}
# find_install — print the prefix of the existing install. The command link is
# what the user actually runs, so links come first: by name (the one given, the
# default, and the alternative this installer suggests) where the command goes
# and on PATH. Then the default prefix, and last, as a fallback for a custom
# name, the links in the command directory: every distinct install they lead
# to, one per line, so that a caller never has to guess between two.
find_install() {
  local bin name f p seen=""
  bin="$(abspath "${BIN_DIR:-$DEFAULT_BIN_DIR}")"
  for name in ${CMD:+"$CMD"} "$DEFAULT_NAME" ai-kit; do
    install_behind "$bin/$name" && return 0
    install_behind "$(command -v -- "$name" 2>/dev/null || true)" && return 0
  done
  f="$(abspath "$DEFAULT_PREFIX")"
  install_at "$f" && { printf '%s\n' "$f"; return 0; }
  for f in "$bin"/*; do
    p="$(install_behind "$f")" || continue
    case "$seen" in *"
$p
"*) continue ;; esac
    seen="$seen
$p
"
    printf '%s\n' "$p"
  done
}
# manifest_value <dir> <key> — a recorded value, without control characters.
manifest_value() {
  sed -n "s/^$2=//p" "$1/manifest" | head -1 | tr -d '[:cntrl:]'
}

# An explicit --prefix is the only candidate.
found=""
if [ -n "$PREFIX" ]; then
  PREFIX="$(abspath "$PREFIX")"
  if install_at "$PREFIX"; then
    found="$PREFIX"
  elif grep -qs '^# ai-kit install manifest' "$PREFIX/manifest"; then
    warn "$PREFIX/manifest records the prefix '$(manifest_value "$PREFIX" prefix)', or is not"
    say  "    yours; its command directory and name are not reused."
  fi
else
  found="$(find_install)" || found=""
  case "$found" in
    *"
"*)
      warn "the command directory holds the commands of several ai-kit installs:"
      printf '%s\n' "$found" | while IFS= read -r p; do say "      $p"; done
      die "choose the one to upgrade with --prefix DIR." ;;
  esac
fi

prev_cmd=""
if [ -n "$found" ]; then
  prev_bin_dir="$(manifest_value "$found" bin_dir)"
  prev_cmd="$(manifest_value "$found" command)"
  DEFAULT_PREFIX="$found"
  case "$prev_bin_dir" in /*) DEFAULT_BIN_DIR="$prev_bin_dir" ;; esac
  DEFAULT_NAME="${prev_cmd:-$DEFAULT_NAME}"
  ok "upgrading ai-kit $(manifest_value "$found" version) -> $VERSION at $found"
  say "    Reusing its command, $DEFAULT_BIN_DIR/$DEFAULT_NAME; an option overrides it."
elif [ -z "$PREFIX" ]; then
  say "  No existing install found: installing fresh. (To upgrade one this did not"
  say "  find, re-run with --prefix DIR.)"
fi

[ -n "$PREFIX" ]  || PREFIX="$(ask  "Install directory for the tool itself?" "$DEFAULT_PREFIX")"
PREFIX="$(abspath "$PREFIX")"

[ -n "$BIN_DIR" ] || BIN_DIR="$(ask "Directory on your PATH for the command?" "$DEFAULT_BIN_DIR")"
BIN_DIR="$(abspath "$BIN_DIR")"
case "$BIN_DIR" in
  *:*) die "the command directory cannot contain ':' (PATH could never hold it): '$BIN_DIR'" ;;
esac

# Command name, with collision detection. This is the question that keeps the
# package from stepping on another tool: 'ai' is a short, popular name. A name
# the previous install recorded stays the default; a clash is only reported.
if [ -z "$CMD" ]; then
  suggested="$DEFAULT_NAME"
  existing="$(command -v "$DEFAULT_NAME" 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "$BIN_DIR/$DEFAULT_NAME" ] \
     && [ "$(install_behind "$existing" || true)" != "$PREFIX" ]; then
    warn "'$DEFAULT_NAME' is already a command on your PATH: $existing"
    if [ -z "$prev_cmd" ]; then
      suggested="ai-kit"
      say  "    Suggesting '$suggested' instead so nothing is shadowed."
    fi
  fi
  CMD="$(ask "Command name?" "$suggested")"
fi
case "$CMD" in
  ""|*/*|*:*|*[[:space:]]*) die "invalid command name: '$CMD'" ;;
esac

# ---- Work out the links, and refuse to touch anything we do not own --------
links=("$BIN_DIR/$CMD:ai")

# owned <path> — true when <path> is a symlink already pointing into our prefix.
# That is the whole ownership test: we replace our own links on upgrade and
# leave everything else strictly alone.
owned() {
  local p="$1" t
  [ -L "$p" ] || return 1
  t="$(ai_realpath "$p")" || return 1
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
  other=""
  for c in "${conflicts[@]}"; do
    if owner="$(install_behind "$c")"; then
      say "  $c is the command of the ai-kit install at $owner."
      other="$owner"
    else
      say "  $c already exists and was not created by ai-kit:"
      say "    $c  ->  $(readlink "$c" 2>/dev/null || echo '(not a symlink)')"
    fi
  done
  say ""
  say "  Nothing has been changed."
  if [ -n "$other" ]; then
    say "  To upgrade that install:  ./install.sh --prefix $(printf '%q' "$other")"
    say "  To move it, remove it first ($(printf '%q' "$other")/uninstall.sh), then install again."
  else
    say "  Re-run with a different name, e.g.:"
    say "    ./install.sh --name ${CMD}-kit"
  fi
  exit 1
fi

# ---- Install ---------------------------------------------------------------
head_ "Installing"

case "$PREFIX" in
  "/"|"$HOME"|"") die "refusing to use '$PREFIX' as the payload directory" ;;
esac
# uninstall.sh removes the prefix whole, so it must be ai-kit's alone: an
# existing install (or the payload of an interrupted one), or a new or empty
# directory.
if [ -d "$PREFIX" ] && ! grep -qs '^# ai-kit install manifest' "$PREFIX/manifest"; then
  for entry in "$PREFIX"/* "$PREFIX"/.[!.]* "$PREFIX"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    case "${entry##*/}" in
      agent.d|ai|uninstall.sh|VERSION|manifest) ;;
      *) die "'$PREFIX' is not empty and is not an ai-kit install; choose a new or empty directory." ;;
    esac
  done
fi
mkdir -p -- "$BIN_DIR" 2>/dev/null && [ -w "$BIN_DIR" ] \
  || die "cannot write to '$BIN_DIR'; choose a directory you own with --bin-dir."

# Upgrade in place: replace only the payload we lay down, never the whole prefix.
rm -rf -- "$PREFIX/agent.d"
rm -f  -- "$PREFIX/ai" "$PREFIX/agent-wt" "$PREFIX/claude-wt" "$PREFIX/codex-wt"  # older launchers
mkdir -p -- "$PREFIX"

cp -R -- "$REPO/agent.d" "$PREFIX/agent.d"
cp -- "$REPO/bin/ai" "$PREFIX/ai"
cp -- "$REPO/uninstall.sh" "$PREFIX/uninstall.sh"
cp -- "$REPO/VERSION" "$PREFIX/VERSION"

# Deterministic modes on the payload only: a clone inherits the cloner's umask,
# and a payload that is not readable by the launcher is a confusing failure.
chmod 755 "$PREFIX"
find "$PREFIX/agent.d" -type d -exec chmod 755 {} +
find "$PREFIX/agent.d" -type f -exec chmod 644 {} +
find "$PREFIX/agent.d" -type f -name '*.sh' -exec chmod 755 {} +
chmod 644 "$PREFIX/VERSION"
chmod 755 "$PREFIX/ai" "$PREFIX/uninstall.sh"
ok "payload -> $PREFIX"

mkdir -p -- "$BIN_DIR"
created=()
for spec in "${links[@]}"; do
  path="${spec%%:*}"; target="$PREFIX/${spec##*:}"
  ln -sfn -- "$target" "$path"
  created+=("$path")
  ok "$path -> ${target#"$PREFIX"/}"
done

# Drop links a previous install recorded that this run did not recreate (e.g. a
# renamed command, or extra links an older version made). Only ever our own.
same_entry() {  # same_entry A B — true when A and B name the same directory entry
  [ "$1" = "$2" ] && return 0
  local da db
  da="$(cd -P -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  db="$(cd -P -- "$(dirname -- "$2")" 2>/dev/null && pwd -P)" || return 1
  [ "$da/$(basename -- "$1")" = "$db/$(basename -- "$2")" ]
}
if [ -f "$PREFIX/manifest" ]; then
  while IFS= read -r old; do
    keep=0
    for c in "${created[@]}"; do same_entry "$c" "$old" && keep=1 && break; done
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
    login_shell="${SHELL:-}"
    case "${login_shell##*/}" in
      zsh)  shell_rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
      bash) if [ "$platform" = Darwin ]; then shell_rc="$HOME/.bash_profile"; else shell_rc="$HOME/.bashrc"; fi ;;
      *)    shell_rc="your shell's startup file" ;;
    esac
    say  "      export PATH=$(printf '%q' "$BIN_DIR"):\$PATH"
    say  "    Put that line in $shell_rc, then open a new terminal."
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
say "  Try it:"
say "      $CMD --help"
say "      $CMD \"Fix the failing test in tests/test_login.py\"     # in place, current branch"
say "      $CMD wt \"Risky refactor\"                               # isolated worktree"
say "      $CMD wt codex \"Fix the failing test\"                   # worktree, Codex"
say ""
say "  Uninstall: $PREFIX/uninstall.sh"
say ""
