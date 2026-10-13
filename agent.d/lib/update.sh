# update.sh — the implementation of '<cmd> update': check, and optionally
# perform, upgrades of the agent CLIs (claude, codex).
#
# This file is SOURCED LAZILY by bin/ai, only once the argument grammar has
# already decided that this run is an 'update' subcommand. That is deliberate and
# load-bearing: bin/ai runs under `set -euo pipefail`, so a truncated or
# syntactically broken lib sourced eagerly (platform.sh's pattern) would abort
# every agent launch. Sourced here it can only ever degrade '<cmd> update'.
# The grammar itself — ai_update_form, the update) parser case, the guards —
# therefore lives in bin/ai and must never move in here.
#
# EXACTLY TWO installation methods are upgraded. Everything else is detected,
# named, and left alone:
#
#   brew-cask / brew-formula -> we run `brew upgrade --cask|--formula <token>`
#   standalone (the CLIs' own installers) -> `claude update` / `codex update`
#   unsupported              -> detected and named (e.g. an npm global), reported
#                               with the command the user can run, never touched
#   unknown / broken / missing -> reported with the manual command, never touched
#
# Why those two and no more: they are the two we can drive correctly and verify.
# Every other manager would need its own global root, its own upgrade verb and
# its own failure modes, and getting any of that wrong installs a SECOND copy of
# the CLI beside the one the user has. Reporting is cheap and cannot do that.
#
# Why we drive Homebrew rather than delegate to the CLI: Claude Code under
# Homebrew answers `claude update` with "Claude is up to date!" and does nothing,
# and Codex's own updater detects Homebrew as
# `is_macos && exe_path.starts_with("/opt/homebrew" | "/usr/local")`, so a
# Linuxbrew or non-default-prefix install falls through to "could not detect the
# installation method" and bails.
#
# `claude install` is forbidden anywhere in this file: it lays down a second,
# native installation beside a package-managed one.
#
# THE `npm` BINARY IS NEVER INVOKED and node is never required. The one npm-shaped
# thing here is an HTTPS read of registry.npmjs.org's dist-tags document, which is
# a public JSON endpoint used purely as a VERSION ORACLE — see ai_update_latest.
# Do not mistake it for npm support and do not grow one from it.
#
# No sudo, ever, not even offered. Homebrew refuses to run under it, npm's global
# root is user-owned in any sane install, and both native installers are per-user
# under $HOME. Where privileges would be needed we refuse and print the command.
#
# Environment
#   AGENT_UPDATE_TIMEOUT  900  seconds for a mutating upgrade (0 = no clock). A
#                              non-default Homebrew prefix cannot use bottles and
#                              builds from source, which legitimately exceeds the
#                              default; AGENT_UPDATE_TIMEOUT=0 is the answer.
#   AGENT_UPDATE_CHANNEL  ""   force claude's channel: stable | latest
#   AI_UPDATE_FETCH_CMD   ""   replaces curl/wget; "<cmd> <url>" -> body on stdout
#   AI_UPDATE_OFFLINE     0    1 = never touch the network; every lookup -> unknown
#   AI_KIT_CLAUDE_BINARY  ""   inspect and upgrade THIS binary instead of the one
#   AI_KIT_CODEX_BINARY   ""   `command -v` finds. A set-but-unusable override is
#                              a hard error for that tool, never a fallback: a
#                              user who names one binary must not get another
#                              upgraded. (AI_KIT_ prefix, not AGENT_, by request.)
#   HOMEBREW_PREFIX       -    READ ONLY, never set. First candidate in brew
#                              discovery, and the only one that copes with an
#                              arbitrary no-root prefix.
#
# Inputs set by bin/ai's parser: update_check, update_tool, update_via.

# bin/ai sources only platform.sh, so paths.sh has to be pulled in here.
# ai_realpath is the ONLY resolver allowed: `readlink -f` and `realpath` are
# GNU-isms, and the test suite installs a `readlink` shim that rejects options
# outright to keep that honest.
if ! command -v ai_realpath >/dev/null 2>&1; then
  _ai_update_paths="${BASH_SOURCE[0]%/*}/paths.sh"
  if [ -f "$_ai_update_paths" ]; then . "$_ai_update_paths"; fi
  unset _ai_update_paths
fi

# ---- Small helpers ---------------------------------------------------------

# The ceiling on anything read from outside this script: a fetched body, and the
# input to ai_update_trim. The bodies are 7 bytes (the release pointer) and ~3 KB
# (dist-tags), so 64 KB is two orders of magnitude of headroom and still bounds
# the damage — with no cap, `curl --max-time 10` happily accepted 35.7 GB inside
# its ten seconds on loopback, and every byte would have landed in a variable.
_AI_UPDATE_MAX_BODY=65536

# ai_update_trim <string> — strip surrounding whitespace, CR included. The
# version endpoints answer with no trailing newline today, but that is not a
# contract, and a stray CR silently turns "2.1.296" into a string equal to
# nothing at all.
#
# One regex, not the obvious `while ...; do s="${s#?}"; done` pair: that idiom is
# O(n^2) in bash, and this function sits directly on the body of a NETWORK fetch,
# where n is whatever the far end chose to send. Measured on bash 3.2, 20 KB cost
# 2.5 s and 60 KB cost 21 s — and it burns that in the CALLER's process, after
# the fetch's own watchdog has already retired, so nothing can interrupt it.
#
# The input is capped before any of that, at the same ceiling ai_update_fetch
# applies to a body, so the two cannot drift: anything this is asked to trim is
# either a short value (a version, a brew prefix) or a document that already came
# through the fetch cap. Measured at that ceiling the regex costs 11 ms, so the
# cap is a bound on the pathological case, not a working limit — it must stay
# comfortably above a `brew outdated --json=v2` document, which IS trimmed whole.
ai_update_trim() {
  local s="${1:0:$_AI_UPDATE_MAX_BODY}"
  if [[ "$s" =~ ^[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then s="${BASH_REMATCH[1]}"; fi
  printf '%s' "$s"
}

# ai_update_clean <string> — <string> with every control character removed, for
# text that reaches the screen but is NOT a pasteable command (those get %q).
#
# The strings this guards are path-derived: a Caskroom directory name, a
# node_modules package, the resolved path itself. A checkout whose node_modules
# is on PATH — ordinary under direnv's PATH_add — can therefore put an escape
# sequence into the VIA column, and ESC[2K + CR rewrites the row we just printed.
# Stripping also keeps the table's width arithmetic honest, since a control
# character costs bytes but no columns.
ai_update_clean() {
  printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177'
}

# ai_update_fit <width> <string> — <string> shortened to at most <width> columns,
# with "..." taking out of the MIDDLE. Both ends identify a VIA cell — the head
# is the method ('npm-global', 'brew-formula'), the tail is the package — so the
# middle is the only part that can be spared. Nothing is lost by it: every VIA
# that is long enough to be cut is repeated in full in the explanation below the
# table, which is where the pasteable command lives.
ai_update_fit() {
  local w="$1" s="$2" head tail off
  if [ "${#s}" -le "$w" ]; then printf '%s' "$s"; return 0; fi
  if [ "$w" -le 4 ]; then printf '%s' "${s:0:$w}"; return 0; fi
  head=$(( (w - 3 + 1) / 2 )); tail=$(( w - 3 - head )); off=$(( ${#s} - tail ))
  printf '%s...%s' "${s:0:$head}" "${s:$off}"
}

# ai_update_valid <string> — the gate every LATEST version must pass. Three-part
# on purpose: an HTML error page, a region block and a login redirect all contain
# digits somewhere, and a loose "find a version anywhere" scan would happily mine
# one out of them and report it as a release. The official installer uses the same
# guard. Only ever call this inside a condition — it returns non-zero by design,
# which `set -e` would act on at a bare call.
#
# Anchored at BOTH ends, and only ever looking at the first line, because the
# start anchor alone guards nothing past the digits: "2.1.296 junk",
# "2.1.296<html>" and a multi-line "2.1.296\n<!-- cached -->" all passed, and the
# whole body then landed in the LATEST column verbatim. A body is attacker-chosen
# text, so that column could be made to carry newlines and ANSI escapes — enough
# to print extra table rows and a convincing "Everything is up to date." under a
# report whose entire promise is that you see the real plan before anything runs.
ai_update_valid() {
  local v="${1%%$'\n'*}"
  v="${v%$'\r'}"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)?$ ]]
}

# ai_update_json_field <blob> <key> — one string field out of a flat JSON object.
# No jq, no python3: the documents read here are dist-tags maps and brew's
# --json=v2, their values are semver, and nothing in them can contain an escaped
# quote. <key> is only ever a literal we chose, so it is safe inside the regex.
ai_update_json_field() {
  printf '%s\n' "$1" |
    LC_ALL=C sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
    head -1 || true
}

# ai_update_json_complete <blob> — rc 0 only if every { and [ in <blob> is
# matched. The proof that a document ARRIVED WHOLE, which matters because an
# incomplete one is not merely unparseable here, it is MISREADABLE: brew states
# "this package is not outdated" by sending a complete document with no
# current_version in it, so a document the watchdog cut off carries exactly the
# same evidence as the good news. "Ends in }" is necessary and nowhere near
# sufficient — a cut landing just after an inner brace passes it, and the caller
# then reports the installed version as the latest, prints "Everything is up to
# date" and exits 0. That is the `update --check && deploy` going green on a
# plane that exit 3 exists to prevent.
#
# Counting totals, not nesting order: a truncation always leaves more opens than
# closes, which is the only failure being proven here. Safe because these
# documents are `brew outdated --json=v2` output, whose string values are package
# names and versions and hold no braces or brackets of their own.
#
# One awk, not the pure-bash `o="${blob//[^\{]/}"` idiom that reads so much
# better: that one is quadratic in the number of characters it DELETES, which for
# a JSON document is nearly all of them. Measured on bash 3.2 — 1 KB 0.17 s,
# 4 KB 6.8 s, 8 KB 52 s — and it runs in the caller's shell where no watchdog can
# reach it. awk is O(n): 15 KB in 0.026 s on both bash 3.2 and 5.3.
ai_update_json_complete() {
  printf '%s' "$1" | LC_ALL=C awk '
    { o += gsub(/\{/, "{"); c += gsub(/\}/, "}")
      a += gsub(/\[/, "["); b += gsub(/\]/, "]") }
    END { exit (o > 0 && o == c && a == b) ? 0 : 1 }'
}

# The report's two line shapes. "claude:" is 7 columns, so %-7s lines "codex:" up
# with it and continuation lines indent to the same 8.
ai_update_label() { printf '%-7s %s\n' "$1:" "$2"; }
ai_update_cont()  { printf '        %s\n' "$1"; }

# ai_update_timeout_secs — AGENT_UPDATE_TIMEOUT, sanitised. One function so the
# clock the watchdog uses and the number the timeout message quotes cannot drift.
#
# The length cap is the non-obvious half. All-digits is not enough: 20 digits is
# all-digits, and `[ 99999999999999999999 -gt 0 ]` is not false, it is an ERROR
# ("integer expression expected") that bash reports and the `if` then treats as
# false — so the watchdog is never started and the clock silently disappears,
# which is the one outcome AGENT_UPDATE_TIMEOUT exists to make explicit. Nine
# digits is ~31 years, so nothing legitimate is lost.
ai_update_timeout_secs() {
  local secs="${AGENT_UPDATE_TIMEOUT:-900}"
  case "$secs" in
    ''|*[!0-9]*) secs=900 ;;
    ??????????*) secs=900 ;;
  esac
  printf '%s' "$secs"
}

# ---- Process control -------------------------------------------------------

# ai_update_kill_tree <signal> <pid> — signal <pid> and every descendant of it,
# parents first. Used ONLY by the watchdog, and only in the no-job-control mode
# (a terminal is attached), where the child deliberately shares OUR process group
# and `kill -- -PGID` would therefore take the launcher down with it. Killing the
# direct child alone leaves the tree behind: measured on a pty, the watchdog
# reported "TIMED OUT", we returned, and a grandchild of the killed command was
# still running three minutes later. The real shape of that is a `brew upgrade`
# whose clock expires while its own children keep writing to the Cellar after we
# have told the user nothing was changed.
#
# One `ps` fork, paid only when the watchdog actually fires. `pkill -P` would be
# shorter but reaches one generation and is not everywhere; the EXIT trap keeps
# its cheap single-pid kill, because that path runs on every ordinary return too.
ai_update_kill_tree() {
  local sig="$1" root="$2" p pp pid snapshot seen="|$2|"
  local -a frontier=("$root") next=() all=("$root")
  snapshot="$(ps -eo pid=,ppid= 2>/dev/null || true)"
  if [ -z "$snapshot" ]; then kill "-$sig" "$root" 2>/dev/null || true; return 0; fi
  while [ "${#frontier[@]}" -gt 0 ]; do
    next=()
    while read -r p pp; do
      case "$p" in ''|*[!0-9]*) continue ;; esac
      # Each pid is enqueued at most once, so the walk terminates even if the
      # snapshot contains a pid/ppid cycle (reused pids can produce one).
      case "$seen" in *"|$p|"*) continue ;; esac
      for pid in ${frontier[@]+"${frontier[@]}"}; do
        if [ "$pp" = "$pid" ]; then
          seen="$seen$p|"; next+=("$p"); all+=("$p"); break
        fi
      done
    done <<EOF
$snapshot
EOF
    frontier=(${next[@]+"${next[@]}"})
  done
  # Parents first: one that is already dying cannot fork a replacement child.
  for pid in ${all[@]+"${all[@]}"}; do kill "-$sig" "$pid" 2>/dev/null || true; done
  return 0
}

# ai_run_timeout <seconds> <command...> — run a command on a clock. <seconds> of
# 0 disables the clock. Returns the command's exit status, or 124 if the watchdog
# had to kill it. stdout and stderr are INHERITED (direnv_run hides them), which
# is what lets a mutating upgrade stream brew's and npm's own output; stdin is
# inherited too, so callers choose it with a plain `</dev/null` redirection.
#
# Job control is enabled only when stdin is NOT a terminal, and that is the whole
# subtlety. `set -m` puts the child in its own process group, which is what makes
# the kill reach a build's grandchildren — but a process group that is not the
# terminal's foreground group is STOPPED by SIGTTIN the instant it reads the tty,
# and the run then hangs until the watchdog fires (measured on bash 3.2). With a
# terminal present the child therefore stays in our group, where it can prompt and
# where the user's own Ctrl-C already reaches the whole tree. Without one nothing
# can prompt, so containment wins.
#
# Deliberately a copy of direnv_run's idiom rather than a refactor of it:
# direnv_run is load-bearing on every agent launch and the blast radius of
# touching it dwarfs twenty duplicated lines.
#
# Split in two, and the split is load-bearing. The marker file that records
# whether the watchdog fired is created, read and removed HERE, in the calling
# shell, and never inside the subshell below — because that subshell turns job
# control on, and with job control on, forking ANY external command (an `rm`,
# say) once a background job has ended makes bash announce the job: "Killed: 9
# ( waited=0; while ... )" or "[2]+ Done ( ... )", seventy lines of it per run,
# on stderr, quoting the watchdog's own source back at the user. Measured. From
# the moment it forks anything, the subshell therefore runs builtins only.
ai_run_timeout() {
  local secs="$1" fired="" rc=0
  shift
  case "$secs" in
    ''|*[!0-9]*) secs=0 ;;
    ??????????*) secs=0 ;;
  esac
  if [ "$secs" -gt 0 ]; then
    # mktemp rather than a name built from pids: a predictable path in a shared
    # /tmp could be pre-created as a symlink, and the watchdog would then
    # truncate whatever it pointed at. Where mktemp is missing we fall back to
    # the elapsed-time heuristic below, which is weaker but no worse than what
    # this function did before it recorded anything at all.
    fired="$(mktemp "${TMPDIR:-/tmp}/ai-kit-timeout.XXXXXX" 2>/dev/null || true)"
  fi
  _ai_run_timeout "$secs" "$fired" "$@" || rc=$?
  if [ -n "$fired" ]; then
    # A watchdog kill arrives as a plain signal death. Telling it apart from the
    # command's own crash is what turns "killed" into a message that names
    # AGENT_UPDATE_TIMEOUT, which is the one thing a source-building user needs
    # — and the marker says which happened, where the old test ("died of a
    # signal, and the clock had run out") also described a command that crashed
    # late of its own accord.
    if [ -s "$fired" ] && [ "$rc" -gt 128 ]; then rc=124; fi
    rm -f "$fired" 2>/dev/null || true
  fi
  return "$rc"
}

_ai_run_timeout() (
  secs="$1"; fired_file="$2"; shift 2
  jobctl=1
  if [ -t 0 ]; then jobctl=0; else set -m; fi

  command_pid="" watchdog_pid=""
  trap '
    if [ -n "$command_pid" ]; then
      if [ "$jobctl" -eq 1 ]; then kill -KILL -- "-$command_pid" 2>/dev/null || true
      else                         kill -KILL -- "$command_pid"  2>/dev/null || true; fi
    fi
    if [ -n "$watchdog_pid" ]; then
      if [ "$jobctl" -eq 1 ]; then kill -KILL -- "-$watchdog_pid" 2>/dev/null || true
      else                         kill -KILL -- "$watchdog_pid"  2>/dev/null || true; fi
    fi
    wait 2>/dev/null || true
  ' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  SECONDS=0
  # 0<&0 is required, not decorative: bash redirects an asynchronous command's
  # stdin from /dev/null "in the absence of any explicit redirections", and does
  # so on 3.2 even with job control on. Without it a command that prompts sees
  # EOF instead of the terminal the caller deliberately left attached.
  "$@" 0<&0 &
  command_pid=$!

  if [ "$secs" -gt 0 ]; then
    # The watchdog RECORDS that it fired rather than leaving anyone to infer it
    # from the clock: "died of a signal at or after the deadline" also describes
    # a command that crashed late of its own accord, and that was reported as
    # TIMED OUT with advice about AGENT_UPDATE_TIMEOUT. Harmless at the 900 s
    # default, actively misleading at the 1-2 s a test suite runs with.
    #
    # A file rather than the watchdog's own exit status, because reading that
    # status means `wait`ing for the watchdog, and it only notices a finished
    # command on its next one-second tick — a second added to every clocked call
    # in the run.
    #
    # Polls rather than sleeping once for the whole duration, so the watchdog
    # retires by itself the moment the command finishes. That matters in the
    # no-job-control mode, where the watchdog can only be killed by pid and a
    # `sleep 900` child of it would otherwise be orphaned for a quarter of an hour.
    (
      waited=0
      while [ "$waited" -lt "$secs" ]; do
        kill -0 "$command_pid" 2>/dev/null || exit 0
        sleep 1
        waited=$((waited + 1))
      done
      # Written BEFORE the kill, so the parent's `wait` — which returns only once
      # the command is dead — cannot observe the death without the marker.
      [ -z "$fired_file" ] || printf 'fired' >"$fired_file" 2>/dev/null || true
      if [ "$jobctl" -eq 1 ]; then
        kill -TERM -- "-$command_pid" 2>/dev/null || exit 0
        sleep 1
        kill -KILL -- "-$command_pid" 2>/dev/null || true
      else
        # Our own process group, so the whole tree has to be walked by hand.
        ai_update_kill_tree TERM "$command_pid"
        sleep 1
        ai_update_kill_tree KILL "$command_pid"
      fi
    ) >/dev/null 2>&1 &
    watchdog_pid=$!
  fi

  status=0
  wait "$command_pid" 2>/dev/null || status=$?
  # Only when there is no marker to speak for the watchdog: the caller applies
  # the real test, and must not have this weaker one applied underneath it.
  if [ -z "$fired_file" ] && [ "$secs" -gt 0 ] && [ "$status" -gt 128 ] \
     && [ "$SECONDS" -ge "$secs" ]; then
    status=124
  fi
  exit "$status"
)

# ---- The network seam (the only one in the package) ------------------------

# ai_update_fetch <url> — body on stdout, non-zero on any failure. Every byte
# this feature pulls over the network goes through here; bin/ai itself still
# contains no curl, no wget and no URL. Fails closed: with neither client
# installed every lookup degrades to "unknown", which the report states plainly
# rather than guessing.
ai_update_fetch() {
  local rc=0 noglob=0
  if [ "${AI_UPDATE_OFFLINE:-0}" = 1 ]; then return 1; fi
  # `head -c` is the cap that holds for all three clients: curl's own
  # --max-filesize is the better signal (it fails the transfer rather than
  # truncating it), wget has no per-file equivalent at all, and AI_UPDATE_FETCH_CMD
  # is whatever the test suite points it at.
  if [ -n "${AI_UPDATE_FETCH_CMD:-}" ]; then
    # Unquoted on purpose: this is configured as a command LINE ("python3
    # /tmp/stub.py"), and the test suite relies on it word-splitting. Globbing is
    # off across that split — word-splitting is wanted, pathname expansion is not,
    # and without this AI_UPDATE_FETCH_CMD='echo *' expands against the CWD.
    case "$-" in *f*) noglob=1 ;; esac
    set -f
    ai_run_timeout 15 $AI_UPDATE_FETCH_CMD "$1" </dev/null |
      head -c "$_AI_UPDATE_MAX_BODY" || rc=$?
    [ "$noglob" -eq 1 ] || set +f
    return "$rc"
  elif command -v curl >/dev/null 2>&1; then
    ai_run_timeout 15 curl -fsSL --max-time 10 --max-filesize "$_AI_UPDATE_MAX_BODY" \
      --retry 0 -- "$1" </dev/null | head -c "$_AI_UPDATE_MAX_BODY"
  elif command -v wget >/dev/null 2>&1; then
    ai_run_timeout 15 wget -q -O - --timeout=10 --tries=1 -- "$1" </dev/null |
      head -c "$_AI_UPDATE_MAX_BODY"
  else
    return 1
  fi
}

# ---- Homebrew discovery (update.sh-local; never alters PATH) ---------------

# ai_update_brew_candidates — every plausible brew binary, best guess first, one
# per line.
#
# platform.sh:5 returns early on anything but Darwin, so AI_HOMEBREW is ALWAYS
# empty on Linux and cannot be the source of truth here: a per-user Linuxbrew puts
# its binaries under ~/.linuxbrew, i.e. inside $HOME, and misclassifying that as a
# native install makes us run `claude update`, which a Homebrew-managed Claude
# answers with "up to date" while changing nothing. See INVARIANT H1 below.
#
# HOMEBREW_PREFIX (exported by `brew shellenv`) and `command -v` lead because they
# are the only two entries that cope with an arbitrary no-root prefix. The rest
# are blind guesses used only to find the BINARY, never to locate brew's trees,
# and among blind guesses the invoking user's own home outranks a system-wide
# default. Nothing here touches PATH — the question is "which brew owns this
# binary", not platform.sh's "which brew should supply tools to the installer".
ai_update_brew_candidates() {
  printf '%s\n' \
    "${HOMEBREW_PREFIX:+$HOMEBREW_PREFIX/bin/brew}" \
    "${AI_HOMEBREW:-}" \
    "$(command -v brew 2>/dev/null || true)" \
    "${HOME:+$HOME/.linuxbrew/bin/brew}" \
    /home/linuxbrew/.linuxbrew/bin/brew \
    /opt/homebrew/bin/brew \
    /usr/local/bin/brew
}

# ai_update_brew_scan — build _ai_brew_bins / _ai_brew_prefixes: every DISTINCT
# usable brew and the prefix each one reports. Once per run.
#
# Scanning them all, rather than keeping the first, is a deliberate departure from
# a single-brew model: a machine can genuinely host more than one Homebrew — an
# Intel /usr/local beside an arm64 /opt/homebrew, or a per-user Linuxbrew beside a
# system one — and keeping the first would classify a binary the OTHER one owns as
# a native install, which is exactly the H1 misclassification. The de-duplication
# is what keeps the usual case at a single probe: on a normal machine the first
# three candidates are the same binary.
#
# The prefix always comes from asking brew. ~23 ms per distinct candidate (these
# are pure-shell shortcuts in brew.sh, no Ruby) and correct by construction for a
# no-root install at an arbitrary prefix.
ai_update_brew_scan() {
  [ -z "${_ai_brew_scanned:-}" ] || return 0
  _ai_brew_scanned=1
  _ai_brew_bins=(); _ai_brew_prefixes=()
  _ai_brew_cellars=(); _ai_brew_caskrooms=(); _ai_brew_roots_done=()
  local c seen=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    [ -x "$c" ] || continue
    case "$seen" in *"|$c|"*) continue ;; esac
    seen="$seen|$c|"
    _ai_brew_bins+=("$c")
    _ai_brew_prefixes+=("$(ai_update_trim "$(ai_run_timeout 20 "$c" --prefix </dev/null 2>/dev/null || true)")")
  done < <(ai_update_brew_candidates)
  return 0
}

# There is deliberately no "the first usable brew" helper. Nothing here may ask
# that question: every caller needs the brew that owns a particular binary or
# package, and answering with _ai_brew_bins[0] is how '--via brew' came to report
# "Homebrew has none of these installed" on a machine where the second Homebrew
# had it. Ask ai_update_brew_owner, or loop the scan.

# ai_update_brew_roots <index> — set _ai_brew_cellar / _ai_brew_caskroom for that
# brew. Memoized PER INDEX, so each brew answers each question at most once per
# run however many tools and however many brews are in play.
#
# --caskroom is always <prefix>/Caskroom but only exists from brew 2.5.0, hence
# the one fallback. --cellar is genuinely NOT always <prefix>/Cellar — brew
# prefers $HOMEBREW_REPOSITORY/Cellar when that directory exists, and de-symlinks
# the result (Fedora Silverblue's /home -> /var/home) — so it is never computed.
ai_update_brew_roots() {
  local i="$1" b
  if [ "${_ai_brew_roots_done[i]:-}" = 1 ]; then
    _ai_brew_cellar="${_ai_brew_cellars[i]}"
    _ai_brew_caskroom="${_ai_brew_caskrooms[i]}"
    return 0
  fi
  b="${_ai_brew_bins[i]}"
  _ai_brew_cellar="$(ai_update_trim "$(ai_run_timeout 20 "$b" --cellar </dev/null 2>/dev/null || true)")"
  _ai_brew_caskroom="$(ai_update_trim "$(ai_run_timeout 20 "$b" --caskroom </dev/null 2>/dev/null || true)")"
  [ -n "$_ai_brew_caskroom" ] || _ai_brew_caskroom="${_ai_brew_prefixes[i]:+${_ai_brew_prefixes[i]}/Caskroom}"
  _ai_brew_cellars[i]="$_ai_brew_cellar"
  _ai_brew_caskrooms[i]="$_ai_brew_caskroom"
  _ai_brew_roots_done[i]=1
  return 0
}

# ai_update_brew_owner <path> — set _ai_brew_owner to the index of the brew that
# owns <path>, and return 0; return 1 if none does. Never a hardcoded or inferred
# root: that is the half of INVARIANT H1 that makes an arbitrary no-root prefix
# work for free.
#
# The containment set is every tree brew REPORTS — prefix, Cellar, Caskroom — and
# not the prefix alone, because `brew --cellar` is NOT a subdirectory of
# `brew --prefix` in general: brew.sh:41-54 prefers $HOMEBREW_REPOSITORY/Cellar
# whenever that directory exists, then de-symlinks the result. A prefix-only gate
# therefore misses a formula-installed CLI on any machine where the repository and
# the prefix are split — and since both brew branches hang off this gate, the miss
# does not degrade to "unknown", it degrades to STANDALONE: we would run
# `claude update`, Homebrew's Claude would answer "Claude is up to date!", and we
# would print "already current" and exit 0. That silent no-op is the precise
# failure H1 exists to prevent, so the gate has to span the same ground.
#
# Two passes rather than one so the ordinary machine pays nothing: the prefix is
# already in hand from the scan, and it answers for every normal install without
# a single extra process. Only a path no prefix claims reaches the roots, and
# that costs two memoized `brew` calls per brew for the whole run.
#
# It sets a variable rather than printing one because the caller would otherwise
# have to run it inside $( ), and the per-run scan it primes would then be built
# in a subshell and thrown away — re-probing every brew for every tool.
ai_update_brew_owner() {
  ai_update_brew_scan
  local i p
  _ai_brew_owner=""
  for (( i=0; i<${#_ai_brew_bins[@]}; i++ )); do
    p="${_ai_brew_prefixes[i]}"
    [ -n "$p" ] || continue
    # ${path#"$prefix"/} != $path rather than a case glob, so a prefix containing
    # glob metacharacters cannot match something it does not actually contain.
    if [ "${1#"$p"/}" != "$1" ]; then _ai_brew_owner="$i"; return 0; fi
  done
  for (( i=0; i<${#_ai_brew_bins[@]}; i++ )); do
    ai_update_brew_roots "$i"
    p="${_ai_brew_cellar:-}"
    if [ -n "$p" ] && [ "${1#"$p"/}" != "$1" ]; then _ai_brew_owner="$i"; return 0; fi
    # Unconditionally <prefix>/Caskroom today, so pass 1 has already answered for
    # it; tested here anyway, because that is brew's promise and not ours.
    p="${_ai_brew_caskroom:-}"
    if [ -n "$p" ] && [ "${1#"$p"/}" != "$1" ]; then _ai_brew_owner="$i"; return 0; fi
  done
  return 1
}

# ai_update_override <tool> — the AI_KIT_*_BINARY override for <tool>, or empty.
# AI_KIT_ rather than this package's usual AGENT_ prefix because the user named
# these two variables explicitly; do not rename them.
ai_update_override() {
  case "$1" in
    claude) printf '%s' "${AI_KIT_CLAUDE_BINARY:-}" ;;
    codex)  printf '%s' "${AI_KIT_CODEX_BINARY:-}" ;;
  esac
}

# ---- Version algebra (pure; no subprocesses) -------------------------------

# ai_update_semver <string> — the first version-looking substring, normalized.
# Requiring the dot is what turns "codex-cli 0.154.0" into 0.154.0 and
# "2.1.296 (Claude Code)" into 2.1.296, and drops a leading v / rust-v tag prefix
# for free. No match => rc 1 => the caller reports "unknown", never a guess.
ai_update_semver() {
  local s
  s="$(ai_update_trim "$1")"
  if [[ "$s" =~ [0-9]+\.[0-9]+(\.[0-9]+)*([-+][0-9A-Za-z.-]+)? ]]; then
    printf '%s' "${BASH_REMATCH[0]}"
    return 0
  fi
  return 1
}

# ai_update_vercmp <a> <b> — PRINTS same | newer | older | unknown, describing <a>
# relative to <b>. A word, not an exit status, and that is the point: under
# `set -euo pipefail` a comparator returning 2 for "greater" would kill the script
# at any call site not already wrapped in a condition. A word cannot.
#
# `sort -V` is banned outright: it misorders 2.1.089 / 2.1.89 / 2.1.9, and both
# Apple and GNU sort place 1.0.0-rc.1 AFTER 1.0.0.
ai_update_vercmp() {
  local a b arel brel asuf bsuf ra rb pa pb na nb
  a="$(ai_update_trim "$1")"
  b="$(ai_update_trim "$2")"
  if [ -z "$a" ] || [ -z "$b" ]; then printf 'unknown'; return 0; fi

  arel="${a%%[-+]*}"; asuf="${a#"$arel"}"
  brel="${b%%[-+]*}"; bsuf="${b#"$brel"}"

  ra="$arel"; rb="$brel"
  while [ -n "$ra" ] || [ -n "$rb" ]; do
    pa="${ra%%.*}"; if [ "$ra" = "$pa" ]; then ra=""; else ra="${ra#*.}"; fi
    pb="${rb%%.*}"; if [ "$rb" = "$pb" ]; then rb=""; else rb="${rb#*.}"; fi
    # A missing component is zero, so 1.2 and 1.2.0 compare equal.
    [ -n "$pa" ] || pa=0
    [ -n "$pb" ] || pb=0
    case "$pa" in *[!0-9]*) printf 'unknown'; return 0 ;; esac
    case "$pb" in *[!0-9]*) printf 'unknown'; return 0 ;; esac
    # 10# is mandatory: a bare $((08)) is an octal syntax error, and an aborted
    # arithmetic expansion under `set -e` takes the whole launcher down with it.
    na=$((10#$pa)); nb=$((10#$pb))
    if [ "$na" -gt "$nb" ]; then printf 'newer'; return 0; fi
    if [ "$na" -lt "$nb" ]; then printf 'older'; return 0; fi
  done

  # Only now, with the release parts equal, can a suffix decide anything. That
  # ordering is what guarantees we never tell a user to update backwards:
  # 0.163.0-alpha.5 against a latest of 0.162.1 is settled above, as 'newer'.
  case "$asuf" in +*) asuf="" ;; esac    # build metadata carries no precedence
  case "$bsuf" in +*) bsuf="" ;; esac
  if [ "$asuf" = "$bsuf" ]; then printf 'same'; return 0; fi
  if [ -z "$asuf" ]; then printf 'newer'; return 0; fi   # 1.0.0 outranks 1.0.0-rc.1
  if [ -z "$bsuf" ]; then printf 'older'; return 0; fi
  # Two different pre-releases. A labelled ASCII heuristic, not a semver
  # implementation — neither CLI ships pre-releases on the channels we track.
  if [[ "$asuf" < "$bsuf" ]]; then printf 'older'; else printf 'newer'; fi
}

# ---- Install-method detection ----------------------------------------------

# ai_update_origin <tool> — sets _o_method _o_pkg _o_path _o_note _o_brew _o_bin
#                            _o_label
# _o_method is one of:
#   brew-cask brew-formula standalone unsupported unknown broken missing
# _o_bin   is the binary we inspect and upgrade (an AI_KIT_*_BINARY override, or
#          whatever `command -v` found).
# _o_brew  is the brew that owns it, so the upgrade later runs the RIGHT brew on a
#          machine that has more than one.
# _o_label names what an `unsupported` install actually is, for the report.
#
# INVARIANT H1: the Homebrew step runs BEFORE the "under $HOME means standalone"
# step, on every platform, and its containment test compares against the trees
# brew itself reports — never a hardcoded or inferred root. A per-user Linuxbrew
# lives inside $HOME, so a $HOME-first ladder classifies it as standalone and then
# runs a self-updater that a package-managed install ignores while reporting
# success.
#
# Nothing here is gated on Darwin, and that is not future-proofing: casks have had
# real Linux artifacts since brew 4.5.0, and both claude-code and codex ship
# arm64_linux/x86_64_linux builds with no macOS dependency.
ai_update_origin() {
  local tool="$1" bin pkg scope rest owner override ovname
  _o_method=unknown; _o_pkg=""; _o_path=""; _o_note=""; _o_brew=""; _o_bin=""; _o_label=""

  override="$(ai_update_override "$tool")"
  case "$tool" in
    claude) ovname=AI_KIT_CLAUDE_BINARY ;;
    *)      ovname=AI_KIT_CODEX_BINARY ;;
  esac
  if [ -n "$override" ]; then
    # A bare name is refused outright, because the two halves of this function
    # would then disagree about what it means: `[ -x ]` and ai_realpath resolve a
    # name with no slash against the CWD, while actually RUNNING it goes through
    # PATH. With ./claude present and AI_KIT_CLAUDE_BINARY=claude, we classified
    # $PWD/claude and then reported the version of a different binary entirely —
    # the exact substitution this variable exists to rule out.
    case "$override" in
      */*) ;;
      *)
        _o_method=broken; _o_path="$override"; _o_bin="$override"
        _o_note="$ovname is '$(ai_update_fit 24 "$(ai_update_clean "$override")")', a bare name — give it a path"
        return 0
        ;;
    esac
    # A set-but-unusable override is a hard error, never a fall back to PATH: a
    # user who points this at one binary must not get a different one upgraded.
    if [ ! -x "$override" ]; then
      _o_method=broken; _o_path="$override"; _o_bin="$override"
      _o_note="$ovname names $(ai_update_clean "$override"), which is not an executable file"
      return 0
    fi
    bin="$override"
  else
    bin="$(command -v "$tool" 2>/dev/null || true)"
    if [ -z "$bin" ]; then _o_method=missing; return 0; fi
  fi
  _o_bin="$bin"

  _o_path="$(ai_realpath "$bin" 2>/dev/null || true)"
  if [ -z "$_o_path" ] || [ ! -e "$_o_path" ]; then
    _o_method=broken
    _o_note="$(ai_update_fit 48 "$(ai_update_clean "$bin")") does not resolve to an existing file"
    _o_path="${_o_path:-$bin}"
    return 0
  fi

  # Homebrew first, and against every tree brew reports — see ai_update_brew_owner
  # for why the prefix alone is not the containment set (INVARIANT H1).
  if ai_update_brew_owner "$_o_path"; then
    owner="$_ai_brew_owner"
    ai_update_brew_roots "$owner"
    if [ -n "${_ai_brew_caskroom:-}" ] && [ "${_o_path#"$_ai_brew_caskroom"/}" != "$_o_path" ]; then
      pkg="${_o_path#"$_ai_brew_caskroom"/}"
      _o_method=brew-cask; _o_pkg="${pkg%%/*}"; _o_brew="${_ai_brew_bins[owner]}"
      return 0
    fi
    if [ -n "${_ai_brew_cellar:-}" ] && [ "${_o_path#"$_ai_brew_cellar"/}" != "$_o_path" ]; then
      pkg="${_o_path#"$_ai_brew_cellar"/}"
      _o_method=brew-formula; _o_pkg="${pkg%%/*}"; _o_brew="${_ai_brew_bins[owner]}"
      return 0
    fi
  fi

  case "$_o_path" in
    */node_modules/*)
      # Detected and named, never upgraded. We deliberately do NOT run `npm root
      # -g` to tell npm apart from pnpm, yarn and bun: the answer would change
      # nothing, since none of the four is a method we drive, and asking would
      # require node to be installed just to produce a message. The LAST
      # node_modules wins — a dependency of a dependency still lives under the
      # global package's own tree.
      pkg="${_o_path##*/node_modules/}"
      case "$pkg" in
        @*) scope="${pkg%%/*}"; rest="${pkg#*/}"; _o_pkg="$scope/${rest%%/*}" ;;
        *)  _o_pkg="${pkg%%/*}" ;;
      esac
      _o_method=unsupported
      _o_label=npm-global
      _o_note="a global Node package install (npm, pnpm, yarn or bun)"
      return 0
      ;;
  esac

  if [ -n "${HOME:-}" ] && [ "${_o_path#"$HOME"/}" != "$_o_path" ]; then
    _o_method=standalone
    return 0
  fi

  # Outside $HOME and claimed by neither of the two methods we drive. Both native
  # installers are per-user, so this is either a system package (upgrading which
  # would need root — banned) or a layout we do not know. Report, never touch.
  _o_method=unknown
  _o_note="outside \$HOME, and owned by neither Homebrew nor a native installer"
  return 0
}

# ai_update_force <tool> — apply --via, overriding the classification ONLY.
# Only the two methods we actually drive are accepted. Every safety rule survives
# it except one: --via standalone overrides the "outside $HOME means unknown"
# refusal, because that is precisely the assertion the user is making. It does not
# relax no-sudo and it does not permit `claude install`.
ai_update_force() {
  local tool="$1" b bi name names tried=""
  case "${update_via:-}" in "") return 0 ;; esac

  # --via re-classifies an EXISTING binary; it cannot conjure one. A missing or
  # broken install therefore stays exactly as the ladder found it, and is
  # reported rather than repaired.
  case "$_o_method" in missing|broken) return 0 ;; esac

  case "$update_via" in
    standalone)
      _o_method=standalone; _o_pkg=""; _o_brew=""; _o_label=""
      _o_note="classified by --via standalone"
      ;;
    brew)
      ai_update_brew_scan
      if [ "${#_ai_brew_bins[@]}" -eq 0 ]; then
        echo "--via brew: no Homebrew installation was found." >&2
        echo "ai-kit never installs Homebrew for you — install it from https://brew.sh," >&2
        echo "or use --via standalone if this came from the CLI's own installer." >&2
        exit 2
      fi
      # Probe the known names rather than assuming one. Both Claude casks can be
      # installed at once (only claude-code@latest declares conflicts_with), so
      # which token answers here is also what decides the channel.
      case "$tool" in
        claude) names="claude-code@latest claude-code" ;;
        codex)  names="codex" ;;
      esac
      for name in $names; do tried="${tried:+$tried, }$name"; done
      # EVERY brew, not just _ai_brew_bins[0]. The scan exists because a machine
      # can host more than one Homebrew (an Intel /usr/local beside an arm64
      # /opt/homebrew, a per-user Linuxbrew beside a system one); asking only the
      # first would answer "Homebrew has none of these installed" with the cask
      # sitting in the second, and send the user to --via standalone, which for a
      # brew-managed CLI is the silent no-op H1 exists to prevent.
      _o_pkg=""; b=""
      for (( bi=0; bi<${#_ai_brew_bins[@]}; bi++ )); do
        for name in $names; do
          if ai_run_timeout 20 env HOMEBREW_NO_ENV_HINTS=1 "${_ai_brew_bins[bi]}" \
               list --versions -- "$name" </dev/null >/dev/null 2>&1; then
            b="${_ai_brew_bins[bi]}"; _o_pkg="$name"
            break
          fi
        done
        [ -z "$_o_pkg" ] || break
      done
      if [ -z "$_o_pkg" ]; then
        echo "--via brew: Homebrew has none of these installed: $tried" >&2
        echo "Install one first, or use --via standalone instead." >&2
        exit 2
      fi
      if ai_run_timeout 20 env HOMEBREW_NO_ENV_HINTS=1 "$b" list --cask -- "$_o_pkg" \
           </dev/null >/dev/null 2>&1; then
        _o_method=brew-cask
      elif ai_run_timeout 20 env HOMEBREW_NO_ENV_HINTS=1 "$b" list --formula -- "$_o_pkg" \
             </dev/null >/dev/null 2>&1; then
        _o_method=brew-formula
      else
        echo "--via brew: '$_o_pkg' is installed but is neither a cask nor a formula." >&2
        exit 2
      fi
      _o_brew="$b"; _o_label=""
      _o_note="classified by --via brew"
      ;;
  esac
  return 0
}

# ---- Per-tool queries ------------------------------------------------------

# ai_update_installed <binary> — the version THAT binary reports, or rc 1. The
# binary, not the tool name, so an AI_KIT_*_BINARY override is the thing measured.
ai_update_installed() {
  local out
  out="$(ai_run_timeout 20 env DISABLE_AUTOUPDATER=1 \
           CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE=0 \
           "$1" --version </dev/null 2>/dev/null || true)"
  out="${out%%$'\n'*}"
  ai_update_semver "$out"
}

# ai_update_channel <tool> <binary> — stable | latest. Must be called while _o_*
# still describes <tool>, because the Homebrew answer is read off the cask token.
#
# Channel is method-dependent, and getting it wrong is the silent failure mode of
# this whole feature: comparing a stable-channel user against 'latest' nags them
# forever. Homebrew answers it implicitly (the cask token IS the channel), which
# is why `claude doctor` — 1.3 s and a network call — is only ever reached when
# the cask token cannot answer. Codex has one channel, so `codex doctor` (7 s) is
# never called at all.
ai_update_channel() {
  local tool="$1" bin="${2:-claude}" out
  case "${AGENT_UPDATE_CHANNEL:-}" in
    stable|latest) printf '%s' "$AGENT_UPDATE_CHANNEL"; return 0 ;;
  esac
  if [ "$tool" != claude ]; then printf 'latest'; return 0; fi
  case "$_o_method" in
    brew-cask|brew-formula)
      # Generic so it survives a rename: a token ending in @latest tracks latest,
      # anything else tracks stable.
      case "$_o_pkg" in
        *@latest) printf 'latest' ;;
        *)        printf 'stable' ;;
      esac
      return 0
      ;;
  esac
  if [ -z "${_ai_claude_channel_probed:-}" ]; then
    _ai_claude_channel_probed=1
    # Default to latest, and never crash when the line moves or disappears: an
    # unrecognised doctor must degrade to the installer's own default, not to an
    # aborted run.
    _ai_claude_channel=latest
    # DISABLE_AUTOUPDATER on every probe: asking a question about the installation
    # must not be what CHANGES it. Claude mounts its background updater as part of
    # starting up, so an unguarded `doctor` here could kick off the very upgrade
    # this run is still deciding whether to perform — and on a Homebrew install
    # that is a `brew upgrade --cask` racing the one we may be about to run
    # ourselves. It suppresses only the background path; the explicit upgrade in
    # ai_update_cmd is unaffected.
    out="$(ai_run_timeout 20 env DISABLE_AUTOUPDATER=1 \
             CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE=0 \
             "$bin" doctor </dev/null 2>/dev/null || true)"
    case "$(printf '%s\n' "$out" |
            LC_ALL=C sed -n 's/^[[:space:]]*Auto-update channel:[[:space:]]*//p' |
            head -1 || true)" in
      stable*) _ai_claude_channel=stable ;;
      latest*) _ai_claude_channel=latest ;;
    esac
  fi
  printf '%s' "$_ai_claude_channel"
}

# ai_update_latest <tool> <installed> — a validated latest version, or rc 1.
# Never prints a guess; "unknown" is a legitimate, reportable answer.
#
# <installed> exists for one case only: brew's --json=v2 answers "this package is
# not outdated" with an EMPTY casks/formulae list, which is a positive statement
# that the installed version IS the latest. Without the second argument that
# tri-state would collapse into the same rc 1 as "brew could not be asked".
ai_update_latest() {
  local tool="$1" installed="${2:-}" kind b out v channel
  case "$_o_method" in
    brew-cask|brew-formula)
      if [ "$_o_method" = brew-cask ]; then kind=cask; else kind=formula; fi
      # AI_UPDATE_OFFLINE is a promise about the WHOLE subcommand, not just the
      # HTTP we issue ourselves. `brew outdated` is a separate program that
      # refreshes its tap over the network on its own schedule, so gating only
      # ai_update_fetch would leave the flag telling a comfortable lie: the
      # native path would go quiet while a brew-managed one still reached out.
      # Degrades exactly like every other failed lookup — "unknown", never a
      # guess — which is what makes the stronger claim safe to state.
      if [ "${AI_UPDATE_OFFLINE:-0}" = 1 ]; then return 1; fi
      # The brew that OWNS this binary, not merely the first one found.
      b="${_o_brew:-}"
      [ -n "$b" ] || return 1
      # --json=v2 is mandatory: the plain form prints nothing machine-readable.
      # The watchdog is 60 s rather than 20 because auto-update is left at the
      # user's own setting — the same freshness policy as every other brew command
      # they run — and a cold tap fetch is legitimately slow.
      # `--` before the package: $_o_pkg is a directory name lifted out of the
      # Caskroom, so a cask directory called '--debug' or '--greedy' would
      # otherwise be read by brew as an OPTION, leaving the command with no
      # package argument at all — i.e. acting on every cask installed.
      out="$(ai_run_timeout 60 env HOMEBREW_NO_ENV_HINTS=1 \
               "$b" outdated "--$kind" --json=v2 -- "$_o_pkg" </dev/null 2>/dev/null || true)"
      # Measured on Homebrew 7.0.9, and the reason the status is discarded rather
      # than tested: `outdated --json=v2 <pkg>` exits 1 BOTH when the package is
      # outdated (printing a perfectly good document) and when the name is unknown
      # (printing nothing at all), and 0 when it is current. The exit code carries
      # no usable signal, so the CONTENT decides — which also means the `|| true`
      # above is what keeps a brew that exits 1 from killing the run under `set -e`.
      out="$(ai_update_trim "$out")"
      # Not a brew document at all: an unknown cask/formula, or a killed brew.
      case "$out" in *'"formulae"'*) ;; *) return 1 ;; esac
      # ... and not a document the watchdog truncated half way through. The
      # trailing brace is only the cheap pre-filter; ai_update_json_complete is
      # the actual proof, and the distinction is load-bearing — see its comment.
      case "$out" in *'}') ;; *) return 1 ;; esac
      ai_update_json_complete "$out" || return 1
      v="$(ai_update_trim "$(ai_update_json_field "$out" current_version)")"
      if [ -n "$v" ]; then
        ai_update_valid "$v" || return 1
        printf '%s' "$v"
        return 0
      fi
      # A complete document with no current_version is brew stating positively
      # that this package is NOT outdated, so the installed version is the latest.
      if ai_update_valid "$installed"; then printf '%s' "$installed"; return 0; fi
      return 1
      ;;
    *)
      # standalone, and also unsupported/unknown: the public release pointer is
      # the only source left, and a binary we refuse to touch still deserves an
      # honest verdict.
      #
      # VERSION ORACLE ONLY. registry.npmjs.org/-/package/<pkg>/dist-tags is a
      # public JSON endpoint read over plain HTTPS through the fetch seam; the
      # `npm` binary is never invoked and node is not required. Do not read this
      # as npm support — npm installs are classified `unsupported` and reported.
      if [ "$tool" = claude ]; then
        channel="$(ai_update_channel claude "$_o_bin")"
        # The body is the bare version — 7 bytes, no trailing newline. Only the
        # FIRST line is considered, the way ai_update_installed treats --version
        # output: everything here is attacker-chosen text once the far end is not
        # the server we expect, and a body of "2.1.296\n<anything>" used to be
        # accepted whole and printed into the LATEST column.
        out="$(ai_update_fetch \
                 "https://downloads.claude.ai/claude-code-releases/$channel" || true)"
        v="$(ai_update_trim "${out%%$'\n'*}")"
        if ai_update_valid "$v"; then ai_update_semver "$v" || printf '%s' "$v"; return 0; fi
        out="$(ai_update_fetch \
                 "https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags" || true)"
        v="$(ai_update_trim "$(ai_update_json_field "$out" "$channel")")"
        if ai_update_valid "$v"; then ai_update_semver "$v" || printf '%s' "$v"; return 0; fi
        return 1
      fi
      # ~3 KB. Never the unabbreviated package document — that one is 5 MB.
      out="$(ai_update_fetch "https://registry.npmjs.org/-/package/@openai/codex/dist-tags" || true)"
      v="$(ai_update_trim "$(ai_update_json_field "$out" latest)")"
      if ai_update_valid "$v"; then ai_update_semver "$v" || printf '%s' "$v"; return 0; fi
      return 1
      ;;
  esac
}

# ai_update_hint <tool> — the command that installs or repairs <tool> by hand.
# Kept in step with install.sh's preflight hints (install.sh:185-190) by hand, on
# purpose: sharing them would couple an offline, three-line installer check to a
# lib that makes network calls — exactly the coupling the lazy source buys away.
ai_update_hint() {
  case "$1" in
    claude) printf 'curl -fsSL https://claude.ai/install.sh | bash' ;;
    codex)  printf 'npm i -g @openai/codex   (or: brew install --cask codex)' ;;
  esac
}

# ai_update_cmd <tool> <method> <pkg> <brew> <binary> — fill _u_cmd (argv) and _u_cmd_display
# (what we tell the user we are running). Two forms because they answer different
# questions: the argv carries HOMEBREW_NO_ENV_HINTS and brew's absolute path,
# neither of which a user would ever type, while the display line is the command
# they can paste. Method, package and brew are passed in rather than read from
# _o_*, because the act phase runs after every tool has been classified and those
# globals then describe the LAST tool, not this one.
#
# Package names come from a filesystem path component, so they are passed as argv
# and never eval'd, and %q-quoted only on the way to the screen.
ai_update_cmd() {
  local tool="$1" method="$2" pkg="$3" b="${4:-}" bin="${5:-$1}"
  _u_cmd=(); _u_cmd_display=""
  case "$method" in
    brew-cask|brew-formula)
      [ -n "$b" ] || return 1
      # The `--` is load-bearing, not punctuation: $pkg is a Caskroom/Cellar
      # directory name, and brew reads a leading-dash one as an option. Without
      # it, a cask directory named '--greedy' turns this into a bare
      # `brew upgrade --cask --greedy`, which upgrades EVERY cask on the machine.
      if [ "$method" = brew-cask ]; then
        _u_cmd=(env HOMEBREW_NO_ENV_HINTS=1 "$b" upgrade --cask -- "$pkg")
        _u_cmd_display="brew upgrade --cask -- $(printf '%q' "$pkg")"
      else
        _u_cmd=(env HOMEBREW_NO_ENV_HINTS=1 "$b" upgrade --formula -- "$pkg")
        _u_cmd_display="brew upgrade --formula -- $(printf '%q' "$pkg")"
      fi
      ;;
    standalone)
      # The resolved binary, not the bare name: with AI_KIT_*_BINARY set, the
      # copy on PATH may not be the one the user asked us to update.
      _u_cmd=("$bin" update)
      _u_cmd_display="$(printf '%q' "$bin") update"
      ;;
    *) return 1 ;;
  esac
  return 0
}

# ai_update_run — execute _u_cmd, streaming. Stdin is inherited when a human is
# at the terminal (so anything that asks can ask) and /dev/null otherwise (so an
# unattended run fails fast instead of blocking on a prompt nobody will see).
ai_update_run() {
  local secs
  secs="$(ai_update_timeout_secs)"
  if [ -t 0 ]; then
    ai_run_timeout "$secs" "${_u_cmd[@]}"
  else
    ai_run_timeout "$secs" "${_u_cmd[@]}" </dev/null
  fi
}

# ai_update_path_copies <tool> — every DISTINCT path <tool> resolves to on PATH.
# `type -aP`, a bash builtin, not `which -a`. De-duplicated because a PATH that
# simply lists one directory twice is not two installations, and reporting it as
# one would send the user hunting for a stale copy that does not exist.
ai_update_path_copies() {
  local p seen=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$seen" in *"|$p|"*) continue ;; esac
    seen="$seen|$p|"
    printf '%s\n' "$p"
  done < <(type -aP "$1" 2>/dev/null || true)
}

# ---- Report ----------------------------------------------------------------

ai_update_via_text() {   # <method> <pkg> <tool> <channel> <label>
  case "$1" in
    brew-cask)    printf 'brew-cask:%s' "$2" ;;
    brew-formula) printf 'brew-formula:%s' "$2" ;;
    standalone)   if [ "$3" = claude ]; then printf 'native:%s' "$4"; else printf 'native'; fi ;;
    unsupported)  if [ -n "$2" ]; then printf '%s:%s' "${5:-unsupported}" "$2"
                  else printf '%s' "${5:-unsupported}"; fi ;;
    missing)      printf '-' ;;
    broken)       printf 'broken' ;;
    *)            printf 'unknown' ;;
  esac
}

ai_update_status_text() {  # <verdict> <method>
  case "$1" in
    current)  printf 'current' ;;
    ahead)    printf 'ahead' ;;
    unknown)  printf 'unknown' ;;
    missing)  printf 'NOT INSTALLED' ;;
    broken)   printf 'BROKEN' ;;
    outdated) case "$2" in
                unknown|unsupported) printf 'OUT OF DATE (not touched)' ;;
                *)                   printf 'OUTDATED' ;;
              esac ;;
  esac
}

# ai_update_act <index> — upgrade one tool, then verify. Split out of run_update
# only because the alternative is four levels of nesting; it reads and writes
# run_update's locals through bash's dynamic scoping, which is also why it is a
# private helper rather than anything reusable. It rewrites verdicts[i] to the
# OUTCOME (upgraded / failed / current), so the summary counts what happened
# rather than what was predicted.
ai_update_act() {
  local i="$1" t="${tools[i]}" rc=0 newv="" secs line ov ovname
  local -a copies=()
  secs="$(ai_update_timeout_secs)"
  ov="$(ai_update_override "$t")"
  case "$t" in claude) ovname=AI_KIT_CLAUDE_BINARY ;; *) ovname=AI_KIT_CODEX_BINARY ;; esac

  if ! ai_update_cmd "$t" "${methods[i]}" "${pkgs[i]}" "${brews[i]}" "${bins[i]}"; then
    verdicts[i]=failed
    ai_update_label "$t" "no upgrade command is known for this installation."
    return 0
  fi

  ai_update_label "$t" "$_u_cmd_display"
  ai_update_run || rc=$?

  # The binary may have been replaced underneath this shell's command hash.
  hash -r 2>/dev/null || true
  newv="$(ai_update_installed "${bins[i]}" || true)"

  if [ "$rc" -eq 124 ]; then
    verdicts[i]=failed
    ai_update_label "$t" "TIMED OUT after ${secs}s — it may or may not have finished."
    ai_update_cont  "A Homebrew prefix that is not the default cannot use bottles and builds"
    ai_update_cont  "from source, which legitimately takes longer. Remove the clock with:"
    ai_update_cont  "  AGENT_UPDATE_TIMEOUT=0 ${invoked_as:-ai} update $t"
    return 0
  fi
  if [ "$rc" -ne 0 ]; then
    verdicts[i]=failed
    ai_update_label "$t" "FAILED ($_u_cmd_display exited $rc) — nothing was changed."
    return 0
  fi
  # Every verdict below is a statement about a version we read. If we could not
  # read one AFTER the upgrade, we know nothing, and the one thing we must not do
  # is say "already current" — which is what happened when both reads failed: the
  # before-read left inst="?", the after-read came back empty, and a standalone
  # tool whose own updater had exited 0 without doing anything (prompting on a
  # stdin that was /dev/null, say) was reported as current, exit 0.
  if [ -z "$newv" ]; then
    verdicts[i]=failed
    ai_update_label "$t" "could not read '$t --version' after the upgrade."
    ai_update_cont  "The command above reported success, so it may well have worked, but"
    ai_update_cont  "nothing here confirms it. Check it yourself:"
    ai_update_cont  "  $(printf '%q' "${bins[i]}") --version"
    return 0
  fi
  if [ "$newv" != "${insts[i]}" ]; then
    verdicts[i]=upgraded
    ai_update_label "$t" "${insts[i]} -> $newv  OK"
    return 0
  fi
  if [ "${verdicts[i]}" = unknown ]; then
    # We never knew what "latest" was here. The CLI's own updater did, it ran, and
    # it found nothing newer — which is an answer, so this stops counting as
    # undetermined. That asymmetry is exactly why the mutating path still acts on
    # an unknown standalone tool while --check only reports it.
    verdicts[i]=current
    ai_update_label "$t" "already current ($newv; its own updater found nothing newer)."
    return 0
  fi

  # Reported success, same version: almost always a second copy earlier on PATH.
  verdicts[i]=failed
  ai_update_label "$t" "upgrade reported success, but '$t --version' still says ${insts[i]}."
  # With AI_KIT_*_BINARY set we measured exactly the binary the user named, so a
  # PATH shadow cannot be the explanation and listing copies would misdirect.
  # It also means PATH was never searched — so this branch says what it knows
  # rather than borrowing the other branch's "nothing shadows it", which would be
  # asserting the result of a check that did not happen.
  if [ -n "$ov" ]; then
    ai_update_cont "$ovname names the binary we read, so no PATH shadow can"
    ai_update_cont "explain it — your PATH was not consulted. Check the output above."
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    copies+=("$(ai_update_clean "$line")")
  done < <(ai_update_path_copies "$t")
  if [ "${#copies[@]}" -gt 1 ]; then
    ai_update_cont "Another copy resolves earlier on your PATH:"
    for line in ${copies[@]+"${copies[@]}"}; do ai_update_cont "  $line"; done
    ai_update_cont "Fix your PATH or remove the stale copy."
  else
    ai_update_cont "Nothing else on your PATH shadows it, so the upgrade reported success"
    ai_update_cont "without replacing the binary. Check the command's output above."
  fi
  return 0
}

# run_update — classify everything, print the table, then act. That order is the
# feature's one real affordance: the user sees the whole plan, including what we
# refuse to touch, before the first byte is downloaded.
#
# Exit codes, precedence 2 > 1 > 3 > 0:
#   0  nothing left to do          2  usage error (raised at the point of error)
#   1  actionable and unresolved   3  could not determine, nothing else actionable
# 3 exists so that '<cmd> update --check && deploy' does not go green on a plane.
run_update() {
  local check="${update_check:-0}" via="${update_via:-}"
  local -a tools=() methods=() pkgs=() opaths=() notes=() brews=() bins=() labels=()
  local -a insts=() lats=() verdicts=() chans=() parts=() hints=()
  local t i n inst lat verdict chan summary unknown_list
  local n_out=0 n_untouched=0 n_unknown=0 n_missing=0 n_broken=0
  local n_current=0 n_ahead=0 n_upgraded=0 n_failed=0
  local actionable=0 undetermined=0 self_unknown=0 blocks=0

  if ! command -v ai_realpath >/dev/null 2>&1; then
    echo "'${invoked_as:-ai} update' needs agent.d/lib/paths.sh, which is missing from" >&2
    echo "this installation. Re-run install.sh to restore the payload." >&2
    return 2
  fi
  case "${AGENT_UPDATE_CHANNEL:-}" in
    ""|stable|latest) ;;
    *) echo "AGENT_UPDATE_CHANNEL must be 'stable' or 'latest'; ignoring '$AGENT_UPDATE_CHANNEL'." >&2
       AGENT_UPDATE_CHANNEL="" ;;
  esac

  if [ -n "${update_tool:-}" ]; then tools=("$update_tool"); else tools=(claude codex); fi
  n="${#tools[@]}"

  if [ "$n" -eq 2 ]; then echo "checking:  ${tools[0]}, ${tools[1]}"
  else                    echo "checking:  ${tools[0]}"; fi
  if [ "$check" -eq 1 ]; then echo "mode:      check only (nothing will be changed)"
  else                        echo "mode:      upgrade"; fi
  [ -z "$via" ] || echo "method:    forced to $via (--via $via)"
  echo

  # ---- classify; nothing in this loop mutates the machine ----
  for t in "${tools[@]}"; do
    ai_update_origin "$t"
    ai_update_force "$t"
    inst="-"; lat="-"; chan=""
    case "$_o_method" in
      missing) verdict=missing ;;
      broken)  verdict=broken ;;
      *)
        [ "$t" != claude ] || chan="$(ai_update_channel "$t" "$_o_bin")"
        inst="$(ai_update_installed "$_o_bin" || true)"
        [ -n "$inst" ] || inst="?"
        lat="$(ai_update_latest "$t" "$inst" || true)"
        if [ -z "$lat" ] || [ "$inst" = "?" ]; then
          [ -n "$lat" ] || lat="?"
          verdict=unknown
        else
          case "$(ai_update_vercmp "$inst" "$lat")" in
            same)  verdict=current ;;
            older) verdict=outdated ;;
            newer) verdict=ahead ;;
            *)     verdict=unknown ;;
          esac
        fi
        ;;
    esac
    methods+=("$_o_method"); pkgs+=("$_o_pkg"); opaths+=("$_o_path"); notes+=("$_o_note")
    brews+=("$_o_brew"); bins+=("$_o_bin"); labels+=("$_o_label")
    insts+=("$inst"); lats+=("$lat"); verdicts+=("$verdict"); chans+=("$chan")
  done

  # ---- the table, printed before anything is touched ----
  # Sized to the rows it actually has, because the two widest fields pull against
  # each other: STATUS is a phrase ('OUT OF DATE (not touched)', 25 columns) and
  # VIA carries arbitrary text — a Caskroom directory, a scoped npm package.
  # Columns fixed wide enough for both ran to 95 on the npm row, and the overflow
  # then shoved STATUS out of alignment, so the one row a user most needs to read
  # — an install we refuse to touch, which they have to act on themselves — was
  # also the one that came apart. VIA is the field that yields: it takes whatever
  # is left of 80 and is middle-ellipsised into it, and nothing is lost, because
  # the full text is repeated in the explanation below the table. INSTALLED and
  # LATEST are capped too, so a binary that answers --version with a paragraph
  # cannot push the row over on its own. (Design section 7.)
  local w_tool=4 w_inst=9 w_lat=6 w_via=3 w_stat=6 room
  local -a vias=() stats=() sinsts=() slats=()
  for (( i=0; i<n; i++ )); do
    # Only VIA is cleaned: INSTALLED and LATEST are ai_update_semver output, whose
    # character set is fixed, while VIA is built from path components.
    vias+=("$(ai_update_clean "$(ai_update_via_text "${methods[i]}" "${pkgs[i]}" \
                                 "${tools[i]}" "${chans[i]}" "${labels[i]}")")")
    stats+=("$(ai_update_status_text "${verdicts[i]}" "${methods[i]}")")
    sinsts+=("$(ai_update_fit 18 "${insts[i]}")")
    slats+=("$(ai_update_fit 18 "${lats[i]}")")
    [ "${#tools[i]}"   -le "$w_tool" ] || w_tool="${#tools[i]}"
    [ "${#sinsts[i]}"  -le "$w_inst" ] || w_inst="${#sinsts[i]}"
    [ "${#slats[i]}"   -le "$w_lat"  ] || w_lat="${#slats[i]}"
    [ "${#vias[i]}"    -le "$w_via"  ] || w_via="${#vias[i]}"
    [ "${#stats[i]}"   -le "$w_stat" ] || w_stat="${#stats[i]}"
  done
  # Two leading spaces plus four single-space separators: six columns of furniture.
  room=$(( 80 - 6 - w_tool - w_inst - w_lat - w_stat ))
  [ "$room" -ge 3 ] || room=3
  [ "$w_via" -le "$room" ] || w_via="$room"
  printf "  %-${w_tool}s %-${w_inst}s %-${w_lat}s %-${w_via}s %s\n" \
    TOOL INSTALLED LATEST VIA STATUS
  for (( i=0; i<n; i++ )); do
    printf "  %-${w_tool}s %-${w_inst}s %-${w_lat}s %-${w_via}s %s\n" \
      "${tools[i]}" "${sinsts[i]}" "${slats[i]}" \
      "$(ai_update_fit "$w_via" "${vias[i]}")" "${stats[i]}"
  done
  echo

  # ---- act, or explain why we will not ----
  for (( i=0; i<n; i++ )); do
    t="${tools[i]}"
    case "${verdicts[i]}" in
      missing)
        blocks=1
        ai_update_label "$t" "not installed. ai-kit never installs an agent CLI for you."
        ai_update_cont  "To install it:"
        ai_update_cont  "  $(ai_update_hint "$t")"
        # Point at the OTHER tool by name, but only when it is actually usable —
        # "check only the one you use" is useless advice if neither is installed.
        if [ "$n" -eq 2 ] && [ "${verdicts[$((1 - i))]}" != missing ]; then
          ai_update_cont "Or check only the tool you use:  ${invoked_as:-ai} update ${tools[$((1 - i))]}"
        fi
        ;;
      broken)
        blocks=1
        ai_update_label "$t" "${notes[i]}."
        # An override that names the wrong thing is a settings mistake, not a
        # damaged install, and telling the user to reinstall the CLI would send
        # them to repair something that is not broken.
        if [ -n "$(ai_update_override "$t")" ]; then
          ai_update_cont "Point that variable at the binary, or unset it to use PATH."
        else
          ai_update_cont "Repair the installation before updating it:"
          ai_update_cont "  $(ai_update_hint "$t")"
        fi
        ;;
      ahead)
        [ "$check" -eq 1 ] || { blocks=1
          ai_update_label "$t" "${insts[i]} is newer than ${lats[i]}; leaving it alone."; }
        ;;
      current)
        [ "$check" -eq 1 ] || { blocks=1; ai_update_label "$t" "already current, nothing to do."; }
        ;;
      unknown)
        # The mutating path degrades differently from --check, and that asymmetry
        # is the point: for a native install, deciding what is latest is exactly
        # the job of the command we are about to run.
        if [ "$check" -eq 0 ] && [ "${methods[i]}" = standalone ]; then
          blocks=1
          ai_update_act "$i"
        fi
        ;;
      outdated)
        case "${methods[i]}" in
          unknown|unsupported)
            # The one verdict that is the same in both modes: we refuse to touch
            # it, so --check and the upgrade run print the same refusal.
            verdicts[i]=untouched
            blocks=1
            ai_update_label "$t" "$(ai_update_clean "${opaths[i]}")"
            ai_update_cont  "is ${notes[i]},"
            ai_update_cont  "so '${invoked_as:-ai} update' will not touch it. Upgrade it the way you"
            ai_update_cont  "installed it:"
            if [ "${methods[i]}" = unsupported ] && [ -n "${pkgs[i]}" ]; then
              ai_update_cont "  npm install -g $(printf '%q' "${pkgs[i]}@latest")"
              ai_update_cont "  (or the pnpm / yarn / bun equivalent, if that is what you used)"
            else
              ai_update_cont "  $(ai_update_hint "$t")"
              if [ "$t" = claude ] && [ "$(uname -s)" != Darwin ]; then
                ai_update_cont "If it came from Anthropic's apt/dnf/apk repo, use your package manager."
              fi
            fi
            ai_update_cont  "Or, if you know how it was installed:"
            ai_update_cont  "  ${invoked_as:-ai} update $t --via brew|standalone"
            ;;
          *)
            if [ "$check" -eq 1 ]; then
              if ai_update_cmd "$t" "${methods[i]}" "${pkgs[i]}" "${brews[i]}" "${bins[i]}"; then
                hints+=("$(printf '  %-26s # runs: %s' \
                           "${invoked_as:-ai} update $t" "$_u_cmd_display")")
              fi
            else
              blocks=1
              ai_update_act "$i"
            fi
            ;;
        esac
        ;;
    esac
  done
  [ "$blocks" -eq 0 ] || echo

  # ---- count the OUTCOMES, not the predictions ----
  for (( i=0; i<n; i++ )); do
    case "${verdicts[i]}" in
      outdated)  n_out=$((n_out + 1)) ;;
      untouched) n_out=$((n_out + 1)); n_untouched=$((n_untouched + 1)) ;;
      upgraded)  n_upgraded=$((n_upgraded + 1)) ;;
      failed)    n_failed=$((n_failed + 1)) ;;
      current)   n_current=$((n_current + 1)) ;;
      ahead)     n_ahead=$((n_ahead + 1)) ;;
      missing)   n_missing=$((n_missing + 1)) ;;
      broken)    n_broken=$((n_broken + 1)) ;;
      unknown)
        n_unknown=$((n_unknown + 1))
        case "${methods[i]}" in standalone) self_unknown=1 ;; esac
        ;;
    esac
  done
  [ "$((n_out + n_failed + n_missing + n_broken))" -eq 0 ] || actionable=1
  [ "$n_unknown" -eq 0 ] || undetermined=1

  # ---- summary ----
  if [ "$undetermined" -eq 1 ]; then
    unknown_list=""
    for (( i=0; i<n; i++ )); do
      [ "${verdicts[i]}" = unknown ] || continue
      unknown_list="${unknown_list:+$unknown_list, }${tools[i]}"
    done
    echo "Could not determine the latest version for $unknown_list — no network, or the"
    echo "release endpoint did not answer. Nothing was changed."
    if [ "$check" -eq 1 ] && [ "$self_unknown" -eq 1 ]; then
      echo "'${invoked_as:-ai} update <tool>' would still run the CLI's own updater, which"
      echo "does its own check."
    fi
    echo
  fi

  if [ "$check" -eq 1 ]; then
    if [ "$n_out" -gt 0 ]; then
      # 'hints' holds one line per tool we can actually drive, so it is NOT the
      # same set as n_out, which counts the untouched ones too. Printing the
      # header unconditionally left "1 of 1 out of date. To upgrade it:" with
      # nothing beneath it for a lone npm global — a header promising a command
      # that, by design, does not exist. The instructions for those rows are the
      # per-tool ones already printed above the summary.
      if [ "${#hints[@]}" -eq 0 ]; then
        echo "$n_out of $n out of date; see above for how to upgrade."
      elif [ "$n_untouched" -gt 0 ]; then
        echo "$n_out of $n out of date. To upgrade what '${invoked_as:-ai} update' drives:"
        printf '%s\n' "${hints[@]}"
      elif [ "$n_out" -eq 1 ]; then
        echo "$n_out of $n out of date. To upgrade it:"
        printf '%s\n' "${hints[@]}"
      else
        echo "$n_out of $n out of date. To upgrade them:"
        printf '%s\n' "${hints[@]}"
      fi
    elif [ "$actionable" -eq 0 ] && [ "$undetermined" -eq 0 ]; then
      echo "Everything is up to date."
    fi
  else
    [ "$n_upgraded"  -eq 0 ] || parts+=("$n_upgraded upgraded")
    [ "$n_failed"    -eq 0 ] || parts+=("$n_failed failed")
    [ "$n_current"   -eq 0 ] || parts+=("$n_current already current")
    [ "$n_ahead"     -eq 0 ] || parts+=("$n_ahead ahead")
    [ "$n_untouched" -eq 0 ] || parts+=("$n_untouched not touched")
    [ "$n_missing"   -eq 0 ] || parts+=("$n_missing not installed")
    [ "$n_broken"    -eq 0 ] || parts+=("$n_broken broken")
    if [ "${#parts[@]}" -gt 0 ]; then
      summary="${parts[0]}"
      for (( i=1; i<${#parts[@]}; i++ )); do summary="$summary, ${parts[i]}"; done
      echo "$summary."
    fi
  fi

  if [ "$actionable" -eq 1 ]; then return 1; fi
  if [ "$undetermined" -eq 1 ]; then return 3; fi
  return 0
}
