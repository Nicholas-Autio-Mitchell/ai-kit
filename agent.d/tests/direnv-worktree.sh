#!/usr/bin/env bash
# Test harness for the `ai` launcher: worktrees, direnv, the session scaffold,
# the merge-back recipe, and the `ai worktrees` audit.
#
#   agent.d/tests/direnv-worktree.sh          # run everything
#   AI_TEST_ROOT=/some/dir  ...               # keep the fixtures for inspection
#                                             # (otherwise kept only on failure)
#   AI=/path/to/ai          ...               # test a launcher somewhere else
#
# The launcher runs under the `bash` first on PATH (its shebang is
# `#!/usr/bin/env bash`) except where a section names /bin/bash, so a directory
# holding a `bash` link, first on PATH, selects the Bash under test. The suite
# itself is Bash 3.2 compatible.
#
# The launcher under test is found relative to THIS file, so the suite works from
# a git clone, from an installed prefix, and from a copy in any other location.
#
# Nothing outside $ROOT is touched: direnv's trust store is redirected via
# XDG_DATA_HOME (essential — allow tokens are keyed on path+contents, so tokens
# from a previous run would silently pre-authorise the fixtures and produce a
# false pass), and fake claude/codex binaries on PATH record their argv and
# inherited environment instead of launching a real agent.
#
# Most launches use codex: everything before the agent starts is shared by both
# agents, and a codex launch is cheaper. claude is used where the behaviour is
# Claude's own (its flags, --name, its team directory). The one slow section, a
# hanging .envrc that has to wait out the launcher's 20 s probe timeout, runs in
# the background while the others run.
set -uo pipefail

# Locate the launcher relative to this harness rather than hard-coding a path, so
# the suite is as relocatable as the tool it tests. Two candidates cover both
# layouts: <root>/bin/ai (the packaged/installed one) and <root>/ai (a launcher
# sitting directly beside its agent.d/). An explicit AI= overrides both.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -P "$here/../.." && pwd)"
command -v direnv >/dev/null 2>&1 || {
  echo "direnv 2.33+ is required for this suite; ai-kit never installs it." >&2
  exit 2
}
direnv_version="$(direnv version)"
if ! [[ "$direnv_version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || \
   [ "${BASH_REMATCH[1]:-0}" -lt 2 ] || \
   { [ "${BASH_REMATCH[1]:-0}" -eq 2 ] && [ "${BASH_REMATCH[2]:-0}" -lt 33 ]; }; then
  echo "direnv 2.33.0+ is required for these JSON status tests (found $direnv_version)." >&2
  exit 2
fi
if [ -z "${AI:-}" ]; then
  for _c in "$root/bin/ai" "$root/ai"; do
    [ -x "$_c" ] && { AI="$_c"; break; }
  done
fi
if [ -z "${AI:-}" ] || [ ! -x "$AI" ]; then
  echo "Cannot find the 'ai' launcher (looked in $root/bin and $root)." >&2
  echo "Run the suite from its package, or set AI=/path/to/ai." >&2
  exit 2
fi

# Scratch area: everything this suite creates lives here and nowhere else.
ROOT="${AI_TEST_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/ai-tests-XXXXXX")}"
mkdir -p "$ROOT"
ROOT="$(cd -P "$ROOT" && pwd -P)"
WORK="$ROOT/work"
FAKEBIN="$ROOT/fakebin"
OUT="$ROOT/out"

# direnv's allow store is global and keyed on (path + contents), so tokens from a
# previous run of this very suite would still be valid and silently pre-authorise
# the fixtures. Point direnv at a per-run store: full isolation, and the user's
# real ~/.local/share/direnv is never touched. CODEX_HOME keeps the launcher away
# from the user's real Codex model catalogue.
export XDG_DATA_HOME="$ROOT/xdg"
export XDG_CONFIG_HOME="$ROOT/config"
export XDG_CACHE_HOME="$ROOT/cache"
export CODEX_HOME="$ROOT/codex-home"
for _gv in ${!GIT_@}; do unset "$_gv"; done
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
for _dv in ${!DIRENV_@}; do unset "$_dv"; done
for _av in ${!AGENT_@}; do unset "$_av"; done
unset _dv _av _gv
rm -rf "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$CODEX_HOME"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$CODEX_HOME"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  {
  fail=$((fail+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"
  if [ -n "${2:-}" ]; then printf '       %s\n' "$2"; fi
  return 0   # must be 0: callers use `cond && bad ... || ok ...`
}
have() { grep -qF -- "$2" "$1" 2>/dev/null; }

setup_fakes() {
  rm -rf "$FAKEBIN"; mkdir -p "$FAKEBIN"
  # AI_TEST_OLD_CLAUDE=1 is a CLI without --name; AI_TEST_OBSERVE=1 also records
  # what the session sees of its scaffold; AI_TEST_COMMIT=1 commits some work.
  # Both are inert on --version, which an installer preflight may ask for.
  cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "0.0.0 (fake claude)"; exit 0; }
if [ "${1:-}" = "--help" ]; then
  [ -n "${AI_TEST_OLD_CLAUDE:-}" ] || echo "  -n, --name <name>   Set a display name for this session"
  echo "  --model <model>  Model for the session"
  exit 0
fi
{
  echo "ARGV_BEGIN"
  for a in "$@"; do echo "ARG:$a"; done
  echo "ARGV_END"
  echo "CWD:$PWD"
  echo "VIRTUAL_ENV:${VIRTUAL_ENV:-<unset>}"
  echo "MARKER:${AI_TEST_MARKER:-<unset>}"
  echo "DIRENV_FILE:${DIRENV_FILE:-<unset>}"
  if [ -n "${AI_TEST_OBSERVE:-}" ]; then
    echo "TEAM:$(ls .claude/agents 2>/dev/null | grep -c '\.md$')"
    git status --porcelain | sed 's/^/STATUS:/'
    echo "EXCLUDE:$(cksum <"$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude")"
  fi
} > "$AI_TEST_OUT"
if [ -n "${AI_TEST_COMMIT:-}" ]; then
  echo "the agent's work" > work.txt
  { git add work.txt && git commit -qm "Agent work"; } || echo "COMMIT_FAILED" >> "$AI_TEST_OUT"
fi
exit 0
EOF
  cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--version" ] && { echo "0.0.0 (fake codex)"; exit 0; }
{
  echo "ARGV_BEGIN"
  for a in "$@"; do echo "ARG:$a"; done
  echo "ARGV_END"
  echo "MARKER:${AI_TEST_MARKER:-<unset>}"
  echo "CWD:$PWD"
  echo "CONFIG:${AI_TEST_CONFIG_MARKER:-<unset>}"
  echo "DIRENV_CONFIG:${DIRENV_CONFIG:-<unset>}"
  echo "DIRENV_BASH:${DIRENV_BASH:-<unset>}"
} > "$AI_TEST_OUT"
exit 0
EOF
  chmod +x "$FAKEBIN"/*
}

# make_repo <name> [--envrc] [--allow] [--allow-marker] [--hook]
make_repo() {
  local name="$1"; shift
  local dir="$WORK/$name"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
  echo seed > "$dir/seed.txt"
  git -C "$dir" add seed.txt
  git -C "$dir" commit -qm init
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --envrc)
        cat > "$dir/.envrc" <<EOF
export AI_TEST_MARKER="from-$name"
export VIRTUAL_ENV="\$PWD/.venv"
EOF
        ;;
      --allow) direnv allow "$dir" ;;
      # An allowed .envrc with an observable side effect, to prove which
      # operations do and do not evaluate it.
      --allow-marker)
        printf 'touch "%s-SIDE-EFFECT"\nexport AI_TEST_MARKER=side\n' "$dir" > "$dir/.envrc"
        direnv allow "$dir"
        ;;
      --hook)
        mkdir -p "$dir/.git/hooks"
        cat > "$dir/.git/hooks/post-checkout" <<'HOOK'
#!/bin/bash
MAIN=$(git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##')
SRC="$MAIN/.envrc"
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
   && [ "$PWD" != "$MAIN" ] && [ -f "$SRC" ] && [ ! -e ".envrc" ]; then
  ln -s "$SRC" .envrc
  echo "HOOK-LINKED"
fi
HOOK
        chmod +x "$dir/.git/hooks/post-checkout"
        ;;
    esac
    shift
  done
  printf '%s\n' "$dir"
}

# run_ai <cwd> <outfile> <args...> — the team is skipped unless the caller sets
# AGENT_NO_AGENTS=0. Captures <outfile> (the fake agent's record) and
# <outfile>.stdout / .stderr / .rc (the launcher's own).
run_ai() {
  local cwd="$1" out="$2"; shift 2
  ( cd "$cwd" \
    && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$out" AGENT_NO_AGENTS="${AGENT_NO_AGENTS:-1}" \
       "$AI" "$@" ) >"$out.stdout" 2>"$out.stderr"
  echo $? > "$out.rc"
}

# recipe_of <stderr-file> — the merge-back recipe the launcher printed last.
recipe_of() {
  sed -n '/^Bring the committed work back to the regular branch:$/,$p' "$1" | sed 1d
}

# Bound whole launcher processes, including any descendants, on macOS and Linux.
# A timed-out process gets a nonzero status; callers must require success too.
# Its own job-control chatter goes wherever the caller sends ITS stderr, so the
# launcher's stderr is always captured separately (see the last section).
bounded() (
  set -m
  task_pid="" guard_pid=""
  trap '
    [ -z "$task_pid" ] || kill -KILL -- "-$task_pid" 2>/dev/null || true
    [ -z "$guard_pid" ] || kill -KILL -- "-$guard_pid" 2>/dev/null || true
    wait 2>/dev/null || true
  ' EXIT
  "$@" &
  task_pid=$!
  (sleep 60; kill -KILL -- "-$task_pid" 2>/dev/null || true) >/dev/null 2>&1 &
  guard_pid=$!
  rc=0
  wait "$task_pid" 2>/dev/null || rc=$?
  exit "$rc"
)

rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
setup_fakes

# ---- Background: a hanging .envrc is bounded without GNU timeout ----------
# Started first and reported last: the launcher's probe gives up after 20 s.
hang_section() {
  local R26 rc26
  R26="$(make_repo repo26)"
  cat > "$R26/.envrc" <<'EOF'
echo "$$" > "$AI_TEST_HUNG_PID"
trap '' TERM
while :; do sleep 30; done
EOF
  direnv allow "$R26"
  bounded env PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t26" AI_TEST_HUNG_PID="$OUT/hung.pid" \
    AGENT_NO_AGENTS=1 bash -c 'cd "$1" && exec "$2" codex "task" 2>"$3"' _ "$R26" "$AI" "$OUT/t26.stderr" \
    >"$OUT/t26.stdout" 2>"$OUT/t26.bounded"
  rc26=$?
  [ "$rc26" -eq 0 ] && have "$OUT/t26" "MARKER:<unset>" \
    && have "$OUT/t26.stderr" "failed to evaluate" \
    && ok "a hanging probe times out and the agent still launches" \
    || bad "hanging probe failed to recover" "rc=$rc26 $(tail -3 "$OUT/t26.stderr" 2>&1)"
  if [ -f "$OUT/hung.pid" ] && ! kill -0 "$(cat "$OUT/hung.pid")" 2>/dev/null; then
    ok "the timed-out .envrc leaves no running shell"
  else
    bad "the timed-out .envrc process survived, or the timeout control never ran"
  fi
}
hang_section </dev/null >"$OUT/hang.results" 2>&1 &
hang_pid=$!

echo
echo "=== 1. --help / usage ==="
if ( cd "$ROOT" && "$AI" --help ) >"$OUT/help" 2>&1; then
  have "$OUT/help" "worktrees [--fix]" && ok "help documents 'worktrees'" || bad "help lacks worktrees"
  have "$OUT/help" "AGENT_DIRENV" && ok "help documents AGENT_DIRENV" || bad "help lacks AGENT_DIRENV"
  have "$OUT/help" "--name" && ok "help documents --name" || bad "help lacks --name"
else
  bad "ai --help exited non-zero"
fi
( cd "$ROOT" && "$AI" --badflag ) >"$OUT/bad" 2>&1; [ $? -eq 2 ] && ok "unknown flag exits 2" || bad "unknown flag exit code"

echo
echo "=== 2. claude in a worktree: placement, flags, environment, scaffold ==="
R1="$(make_repo repo1 --envrc --allow)"
exclude1="$R1/.git/info/exclude"
exclude_sum="$(cksum <"$exclude1")"
AI_TEST_OBSERVE=1 AI_TEST_COMMIT=1 AGENT_NO_AGENTS=0 run_ai "$R1" "$OUT/t2" wt -n alpha "task"
wt2="$(sed -n 's/^worktree: *//p' "$OUT/t2.stderr")"
case "$wt2" in
  "$WORK/repo1.worktrees/alpha-"*) ok "worktree created in <repo>.worktrees/ ($(basename "$wt2"))" ;;
  *) bad "worktree in unexpected place" "$wt2" ;;
esac
[ "$(cat "$OUT/t2.rc")" = 0 ] && ok "the launcher exits with claude's status (0)" \
  || bad "launch failed" "rc=$(cat "$OUT/t2.rc"): $(tail -3 "$OUT/t2.stderr")"
claude_flags='ARG:--model
ARG:opus
ARG:--allow-dangerously-skip-permissions
ARG:--dangerously-skip-permissions
ARG:--permission-mode
ARG:dontAsk
ARG:--effort
ARG:max
ARG:--setting-sources
ARG:user,project,local
ARG:--name
ARG:alpha'
[ "$(sed -n '2,13p' "$OUT/t2")" = "$claude_flags" ] \
  && ok "claude gets the whole autorun flag set by default, then --name" \
  || bad "claude's flags differ" "$(sed -n '2,13p' "$OUT/t2" | tr '\n' ' ')"
[ "$(grep -B1 '^ARGV_END$' "$OUT/t2" | head -1)" = "task" ] && have "$OUT/t2" "Task:" \
  && ok "the guarded prompt is the last argument and ends with the task" \
  || bad "prompt argument malformed" "$(grep -B2 '^ARGV_END$' "$OUT/t2")"
have "$OUT/t2" "MARKER:from-repo1" && ok "claude inherited \$AI_TEST_MARKER from the .envrc" \
  || bad "claude did not get the direnv environment" "$(grep MARKER "$OUT/t2" 2>&1)"
have "$OUT/t2" "TEAM:7" && ok "during the run, .claude/agents holds the seven-agent team" \
  || bad "team not installed" "$(grep '^TEAM:' "$OUT/t2")"
if ! grep -q '^STATUS:?? DEVLOG.md$' "$OUT/t2"; then
  bad "git status was not captured during the run" "$(grep '^STATUS:' "$OUT/t2" | tr '\n' ' ')"
elif grep -q '^STATUS:.*\.claude' "$OUT/t2"; then
  bad "git status shows the scaffold during the run" "$(grep '^STATUS:' "$OUT/t2" | tr '\n' ' ')"
else
  ok "git status does not list .claude/ during the run"
fi
have "$OUT/t2" "EXCLUDE:$exclude_sum" && ok "the shared .git/info/exclude is untouched during the run" \
  || bad ".git/info/exclude changed during the run"
[ "$(git -C "$wt2" log -1 --format=%s 2>/dev/null)" = "Agent work" ] \
  && ok "the agent committed its work on the worktree branch" \
  || bad "the agent could not commit in its worktree" "$(grep COMMIT_FAILED "$OUT/t2")"
[ ! -e "$wt2/.claude" ] && ok "after the session the worktree has no .claude/ scaffold" \
  || bad "scaffold left in the worktree" "$(ls -A "$wt2/.claude" 2>&1)"
[ ! -e "$wt2/DEVLOG.md" ] && ok "after the session the untouched DEVLOG.md is gone" \
  || bad "unchanged DEVLOG.md left in the worktree"
[ "$(cksum <"$exclude1")" = "$exclude_sum" ] && ! grep -q 'agent scaffold' "$exclude1" \
  && ok ".git/info/exclude is byte-identical afterwards (no scaffold block)" \
  || bad ".git/info/exclude was changed" "$(cat "$exclude1")"

echo
echo "=== 3. ANCHOR FIX: creating a worktree FROM INSIDE a worktree ==="
run_ai "$wt2" "$OUT/t3" codex wt -n beta "task"
wt3="$(sed -n 's/^worktree: *//p' "$OUT/t3.stderr")"
case "$wt3" in
  "$WORK/repo1.worktrees/beta-"*) ok "nested launch still lands in the canonical root" ;;
  *) bad "nested launch scattered the worktree" "$wt3" ;;
esac

echo
echo "=== 4. direnv: the worktree gets an allowed link to the main .envrc ==="
[ -L "$wt2/.envrc" ] && ok ".envrc symlink created in the worktree" || bad ".envrc not symlinked"
[ "$(readlink "$wt2/.envrc")" = "$R1/.envrc" ] && ok "symlink target is absolute, to the main repo" \
  || bad "symlink target wrong" "$(readlink "$wt2/.envrc" 2>&1)"
( cd "$wt2" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ) \
  && ok "worktree .envrc is allowed" || bad "worktree .envrc NOT allowed"
have "$OUT/t2.stderr" "direnv:" && ok "launch banner reports direnv" || bad "no direnv line in banner"

echo
echo "=== 5. the printed merge-back recipe brings the committed work home ==="
recipe_of "$OUT/t2.stderr" > "$OUT/t2.recipe"
rm_at="$(grep -n '^rm ' "$OUT/t2.recipe" | cut -d: -f1)"
remove_at="$(grep -n '^git worktree remove ' "$OUT/t2.recipe" | cut -d: -f1)"
[ -n "$rm_at" ] && [ -n "$remove_at" ] && [ "$rm_at" -lt "$remove_at" ] \
  && ok "the recipe removes the .envrc link ai made before 'git worktree remove'" \
  || bad "no .envrc removal before git worktree remove" "$(cat "$OUT/t2.recipe")"
( cd "$ROOT" && bash -e "$OUT/t2.recipe" ) >"$OUT/t2.merge" 2>&1 \
  && ok "the recipe runs cleanly (switch, merge, rm, worktree remove, branch -d)" \
  || bad "the printed recipe failed" "$(tail -3 "$OUT/t2.merge")"
[ "$(cat "$R1/work.txt" 2>/dev/null)" = "the agent's work" ] \
  && ok "the agent's commit landed on the target branch" || bad "work not merged"
[ ! -e "$wt2" ] && ! git -C "$R1" worktree list | grep -qF "$wt2" \
  && ok "the worktree is gone, directory and registration" || bad "worktree still present"

echo
echo "=== 6. idempotent with a repo post-checkout hook ==="
R5="$(make_repo repo5 --envrc --allow --hook)"
run_ai "$R5" "$OUT/t5" codex wt -n hooked "task"
wt5="$(sed -n 's/^worktree: *//p' "$OUT/t5.stderr")"
have "$OUT/t5.stderr" "HOOK-LINKED" && ok "repo hook ran and linked first" || bad "hook did not run"
[ -L "$wt5/.envrc" ] && [ "$(readlink "$wt5/.envrc")" = "$R5/.envrc" ] \
  && ok "hook's symlink left intact (not clobbered)" || bad "hook symlink was replaced"
have "$OUT/t5" "MARKER:from-repo5" && ok "hook-linked worktree still gets blessed + loaded" \
  || bad "hook-linked worktree not blessed"
recipe_of "$OUT/t5.stderr" > "$OUT/t5.recipe"
grep -q '^git worktree remove ' "$OUT/t5.recipe" && ! grep -q '^rm ' "$OUT/t5.recipe" \
  && ok "recipe leaves the hook's link to the hook" \
  || bad "recipe removes a link the hook made, not ai (or is missing)" "$(cat "$OUT/t5.recipe")"

echo
echo "=== 7. trust is propagated, never created ==="
R6="$(make_repo repo6 --envrc)"          # .envrc present but NEVER allowed
run_ai "$R6" "$OUT/t6" codex wt -n untrusted "task"
wt6="$(sed -n 's/^worktree: *//p' "$OUT/t6.stderr")"
[ -d "$wt6" ] && [ ! -e "$wt6/.envrc" ] && [ ! -L "$wt6/.envrc" ] \
  && ok "an unallowed main .envrc is not even linked into the worktree" \
  || bad "worktree got an .envrc from an unallowed source" "$(ls -la "$wt6/.envrc" 2>&1)"
if ( cd "$wt6" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: blessed a worktree whose source .envrc was never allowed"
else
  ok "unallowed source .envrc is NOT auto-blessed in the worktree"
fi
have "$OUT/t6" "MARKER:<unset>" && ok "agent ran WITHOUT the unallowed env" || bad "env leaked from unallowed .envrc"
[ "$(cat "$OUT/t6.rc")" = "0" ] && ok "blocked .envrc still launches the agent (no hard failure)" \
  || bad "blocked .envrc aborted the launch" "rc=$(cat "$OUT/t6.rc")"
grep -qxF "        direnv allow $R6" "$OUT/t6.stderr" && ok "prints the remedy: direnv allow <the directory>" \
  || bad "no 'direnv allow <directory>' remedy" "$(grep 'direnv allow' "$OUT/t6.stderr")"
recipe_of "$OUT/t6.stderr" > "$OUT/t6.recipe"
grep -q '^git worktree remove ' "$OUT/t6.recipe" && ! grep -q '^rm ' "$OUT/t6.recipe" \
  && ok "recipe has no .envrc step when nothing was linked" \
  || bad "recipe removes an .envrc that was never linked (or is missing)" "$(cat "$OUT/t6.recipe")"

echo
echo "=== 8. a branch's own, different .envrc is not auto-blessed ==="
R7="$(make_repo repo7 --envrc --allow)"
# Commit the branch's .envrc with plumbing: a checkout would disturb the main
# worktree's own (allowed, untracked) .envrc.
evil_blob="$(printf 'export AI_TEST_MARKER="EVIL"\n' | git -C "$R7" hash-object -w --stdin)"
evil_tree="$( { git -C "$R7" ls-tree HEAD; printf '100644 blob %s\t.envrc\n' "$evil_blob"; } | git -C "$R7" mktree)"
git -C "$R7" branch evil "$(git -C "$R7" commit-tree "$evil_tree" -p HEAD -m "branch carries its own .envrc")"
run_ai "$R7" "$OUT/t7" codex wt -b evil -n evilwt "task"
wt7="$(sed -n 's/^worktree: *//p' "$OUT/t7.stderr")"
if [ "$(cat "$wt7/.envrc" 2>/dev/null)" = 'export AI_TEST_MARKER="EVIL"' ] && ! [ -L "$wt7/.envrc" ] \
   && [ "$(cat "$R7/.envrc")" = 'export AI_TEST_MARKER="from-repo7"
export VIRTUAL_ENV="$PWD/.venv"' ]; then
  if ( cd "$wt7" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
    bad "SECURITY: auto-blessed a committed .envrc that differs from the main repo's"
  else
    ok "committed, differing .envrc left blocked"
  fi
  have "$OUT/t7" "MARKER:<unset>" && ok "evil .envrc never executed" \
    || bad "SECURITY: evil .envrc was executed (or codex never ran)" "$(grep MARKER "$OUT/t7")"
else
  bad "fixture: the evil branch's committed .envrc is missing from the worktree" "$wt7"
fi

echo
echo "=== 9. in place: never calls direnv allow ==="
R8="$(make_repo repo8 --envrc)"           # unallowed
run_ai "$R8" "$OUT/t8" codex "task"
if ( cd "$R8" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: in-place mode allowed the user's unreviewed .envrc"
else
  ok "in-place mode did not allow an unreviewed .envrc"
fi
direnv allow "$R8/.envrc"
run_ai "$R8" "$OUT/t8b" codex "task"
have "$OUT/t8b" "MARKER:from-repo8" && ok "in-place mode loads an ALREADY-allowed .envrc" \
  || bad "in-place mode did not load the allowed env"

echo
echo "=== 10. --name: forwarded only where it can be ==="
run_ai "$R1" "$OUT/t9c" codex -n cx "task"
have "$OUT/t9c.stderr" "no launch-time session name" && ok "codex prints the /name hint" || bad "no codex hint"
have "$OUT/t9c" "ARGV_END" && ! have "$OUT/t9c" "ARG:--name" && ok "--name not passed to codex" \
  || bad "--name wrongly passed to codex (or codex never ran)"
# direnv plays no part in --name; AGENT_DIRENV=0 keeps the claude launch short.
AI_TEST_OLD_CLAUDE=1 AGENT_DIRENV=0 run_ai "$R1" "$OUT/t9d" -n legacy "task"
have "$OUT/t9d.stderr" "no --name flag" && ok "an older claude degrades to a note" || bad "no degradation note"
have "$OUT/t9d" "ARGV_END" && ! have "$OUT/t9d" "ARG:--name" && ok "--name withheld from old CLI" \
  || bad "--name passed to a CLI that lacks it (or claude never ran)"

echo
echo "=== 11. --base is worktree-only; --fix is worktrees-only ==="
run_ai "$R1" "$OUT/t10" -b main "task"
[ "$(cat "$OUT/t10.rc")" = "2" ] && ok "--base in place exits 2" || bad "--base restriction lost"
run_ai "$R1" "$OUT/t10b" --fix "task"
[ "$(cat "$OUT/t10b.rc")" = "2" ] && ok "--fix outside 'worktrees' exits 2" || bad "--fix restriction missing"

echo
echo "=== 12. AGENT_DIRENV=0 disables everything ==="
AGENT_DIRENV=0 run_ai "$R1" "$OUT/t11" codex wt -n nodirenv "task"
wt11="$(sed -n 's/^worktree: *//p' "$OUT/t11.stderr")"
[ -d "$wt11" ] && [ ! -e "$wt11/.envrc" ] && ok "AGENT_DIRENV=0 skips the symlink" \
  || bad "AGENT_DIRENV=0 still linked .envrc (or no worktree)" "$wt11"
have "$OUT/t11" "MARKER:<unset>" && ok "AGENT_DIRENV=0 skips the env" || bad "env loaded despite AGENT_DIRENV=0"
have "$OUT/t11.stderr" "AGENT_DIRENV=0" && ok "banner says why direnv is off" || bad "banner silent"

echo
echo "=== 13. non-repo directory still works ==="
mkdir -p "$WORK/plain"
run_ai "$WORK/plain" "$OUT/t12" codex "task"
[ "$(cat "$OUT/t12.rc")" = "0" ] && ok "runs in a non-git directory" || bad "non-repo run failed"
run_ai "$WORK/plain" "$OUT/t12b" worktrees
[ "$(cat "$OUT/t12b.rc")" = "1" ] && ok "'worktrees' outside a repo exits 1 with a message" \
  || bad "worktrees outside a repo" "rc=$(cat "$OUT/t12b.rc")"

echo
echo "=== 14. 'ai worktrees' audit ==="
run_ai "$R1" "$OUT/t13" worktrees
have "$OUT/t13.stdout" "worktree root:" && ok "audit prints the canonical root" || bad "no root line"
have "$OUT/t13.stdout" "main" && ok "audit lists the main worktree" || bad "main missing"
grep -qE '^  ok +ok ' "$OUT/t13.stdout" && ok "healthy worktrees show ok/ok" \
  || bad "no ok/ok rows" "$(sed -n '5,12p' "$OUT/t13.stdout")"

echo
echo "=== 15. 'ai worktrees --fix' repairs a NESTED tree ==="
R14="$(make_repo repo14 --envrc --allow)"
run_ai "$R14" "$OUT/t14a" codex wt -n one "task"
# Recreate the old bug's shape by hand: a worktree nested under another.
git -C "$R14" worktree add -q "$WORK/repo14.worktrees/one.worktrees/deep" -b deep
rm -f "$WORK/repo14.worktrees/one.worktrees/deep/.envrc"
run_ai "$R14" "$OUT/t14b" worktrees
have "$OUT/t14b.stdout" "NESTED" && ok "audit flags the nested tree" || bad "nested not flagged"
have "$OUT/t14b.stdout" "missing" && ok "audit flags the missing .envrc" || bad "missing .envrc not flagged"
[ "$(cat "$OUT/t14b.rc")" = "1" ] && ok "audit exits 1 when issues exist" || bad "audit exit code"
run_ai "$R14" "$OUT/t14c" worktrees --fix
[ -d "$WORK/repo14.worktrees/deep" ] && ok "--fix moved the nested tree to the root" \
  || bad "--fix did not move it" "$(cat "$OUT/t14c.stdout")"
[ -L "$WORK/repo14.worktrees/deep/.envrc" ] && ok "--fix linked .envrc in the moved tree" || bad "no .envrc after move"
( cd "$WORK/repo14.worktrees/deep" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ) \
  && ok "--fix re-blessed at the NEW path" || bad "moved tree not re-blessed"
[ -d "$WORK/repo14.worktrees/one.worktrees" ] && bad "empty container left behind" || ok "empty container removed"
run_ai "$R14" "$OUT/t14d" worktrees
[ "$(cat "$OUT/t14d.rc")" = "0" ] && ok "audit is clean after --fix" || bad "still dirty" "$(cat "$OUT/t14d.stdout")"

echo
echo "=== 16. --fix prunes a dead registration ==="
R15="$(make_repo repo15 --envrc --allow)"
run_ai "$R15" "$OUT/t15a" codex wt -n doomed "task"
wt15="$(sed -n 's/^worktree: *//p' "$OUT/t15a.stderr")"
rm -rf "$wt15"
run_ai "$R15" "$OUT/t15b" worktrees
have "$OUT/t15b.stdout" "GONE" && ok "audit flags the dead registration" || bad "GONE not flagged"
run_ai "$R15" "$OUT/t15c" worktrees --fix
run_ai "$R15" "$OUT/t15d" worktrees
have "$OUT/t15d.stdout" "GONE" && bad "--fix did not prune" || ok "--fix pruned the dead registration"

echo
echo "=== 17. STRAY trees are reported but never moved ==="
R16="$(make_repo repo16 --envrc --allow)"
git -C "$R16" worktree add -q "$WORK/elsewhere-16" -b stray
run_ai "$R16" "$OUT/t16" worktrees
have "$OUT/t16.stdout" "STRAY" && ok "audit flags the stray tree" || bad "STRAY not flagged"
have "$OUT/t16.stdout" "worktree move" && ok "prints an opt-in move command" || bad "no move suggestion"
run_ai "$R16" "$OUT/t16b" worktrees --fix
[ -d "$WORK/elsewhere-16" ] && ok "--fix did NOT move the stray tree" || bad "--fix moved a stray tree"
[ -L "$WORK/elsewhere-16/.envrc" ] && ok "--fix still repaired the stray tree's direnv" || bad "stray direnv unrepaired"

echo
echo "=== 18. an explicitly DENIED .envrc is not reported as loaded ==="
# direnv exec RUNS the command on a denied rc — silently, with no environment,
# exit 0. So the exec probe alone would claim success; only `status --json`
# distinguishes allowed(0) from blocked(1) from denied(2).
R17="$(make_repo repo17 --envrc --allow)"
direnv deny "$R17/.envrc"
den="$( cd "$R17" && direnv status --json 2>/dev/null | grep -oE '"allowed": [0-9]' )"
[ "$den" = '"allowed": 2' ] && ok "fixture is in the denied state" || bad "could not deny" "$den"
run_ai "$R17" "$OUT/t17" codex "task"
[ "$(cat "$OUT/t17.rc")" = "0" ] && ok "denied .envrc still launches the agent" || bad "denied .envrc aborted launch"
have "$OUT/t17" "MARKER:<unset>" && ok "denied .envrc contributes no environment" || bad "denied env leaked"
have "$OUT/t17.stderr" "NOT loaded" && ok "banner reports NOT loaded (does not claim success)" \
  || bad "banner wrongly claimed the env was loaded" "$(grep -i direnv "$OUT/t17.stderr")"

echo
echo "=== 19. worktree/branch names from hostile prompts ==="
R18="$(make_repo repo18 --envrc --allow)"
run_ai "$R18" "$OUT/t18" codex wt -- '$(touch $ROOT/pwned-marker); `id`; rm -rf ~ --'
[ -e $ROOT/pwned-marker ] && bad "SECURITY: command substitution in the prompt executed" \
  || ok "prompt-derived name cannot inject commands"
wt18="$(sed -n 's/^worktree: *//p' "$OUT/t18.stderr")"
case "$wt18" in
  "$WORK/repo18.worktrees/"*) ok "hostile prompt still yields a path under the root" ;;
  *) bad "hostile prompt escaped the worktree root" "$wt18" ;;
esac
[ -d "$wt18" ] && ok "hostile-named worktree was actually created" || bad "worktree missing" "$wt18"

echo
echo "=== 20. REGRESSION: inherited DIRENV_* must not forge an allow (loadedRC) ==="
# `direnv status --json` reports the CALLER's loadedRC next to the directory's
# foundRC, each with its own "allowed". An unanchored read of that blob treats
# someone else's allowed .envrc as this one's — and `ai` launches agents under
# `direnv exec`, so it poisons its own children.
R19="$(make_repo repo19 --envrc)"            # .envrc present, NEVER allowed
mkdir -p "$WORK/trusted19"
printf 'export TRUSTED19=1\n' > "$WORK/trusted19/.envrc"
direnv allow "$WORK/trusted19"
( cd "$R19" && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t19" AGENT_NO_AGENTS=1 \
    direnv exec "$WORK/trusted19" "$AI" codex wt -n forged "task" ) >"$OUT/t19.stdout" 2>"$OUT/t19.stderr"
wt19="$(sed -n 's/^worktree: *//p' "$OUT/t19.stderr")"
if [ ! -d "$wt19" ]; then
  bad "fixture: no worktree was created under the inherited direnv state" "$(tail -3 "$OUT/t19.stderr")"
elif ( cd "$wt19" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: inherited DIRENV_* forged a blessing for an unallowed .envrc"
else
  ok "inherited DIRENV_* cannot forge a blessing"
fi
have "$OUT/t19" "MARKER:<unset>" && ok "unallowed .envrc was not executed" \
  || bad "SECURITY: unallowed .envrc executed" "$(grep MARKER "$OUT/t19")"
have "$OUT/t19" "MARKER:from-repo19" && bad "SECURITY: hostile env reached the agent" || ok "no hostile env reached the agent"

echo
echo "=== 21. non-regular .envrc is refused (FIFO / directory) ==="
R20="$(make_repo repo20 --envrc --allow)"
run_ai "$R20" "$OUT/t20a" codex wt -n fifo "task"
wt20="$(sed -n 's/^worktree: *//p' "$OUT/t20a.stderr")"
rm -f "$wt20/.envrc"; mkfifo "$wt20/.envrc"                  # symlink-to-FIFO stand-in
bounded env PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t20" AGENT_NO_AGENTS=1 \
  bash -c 'cd "$1" && exec "$2" worktrees 2>"$3"' _ "$wt20" "$AI" "$OUT/t20.stderr" \
  >"$OUT/t20.stdout" 2>"$OUT/t20.bounded"
rc20=$?
[ "$rc20" -eq 1 ] && have "$OUT/t20.stdout" "worktree root:" && have "$OUT/t20.stdout" "blocked" \
  && ok "a FIFO .envrc does not hang the audit" || bad "audit failed or hung on a FIFO .envrc"
bounded env PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t20launch" AGENT_NO_AGENTS=1 \
  bash -c 'cd "$1" && exec "$2" codex "task" 2>"$3"' _ "$wt20" "$AI" "$OUT/t20launch.stderr" \
  >"$OUT/t20launch.stdout" 2>"$OUT/t20launch.bounded"
[ "$?" -eq 0 ] && have "$OUT/t20launch" "MARKER:<unset>" \
  && ok "a FIFO .envrc still launches Codex without an environment" || bad "FIFO launch failed or hung"
rm -f "$wt20/.envrc"; mkdir "$wt20/.envrc"                   # directory named .envrc
bounded env PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t20b" AGENT_NO_AGENTS=1 \
  bash -c 'cd "$1" && exec "$2" worktrees --fix 2>"$3"' _ "$R20" "$AI" "$OUT/t20b.stderr" \
  >"$OUT/t20b.stdout" 2>"$OUT/t20b.bounded"
rc20=$?
[ "$rc20" -eq 0 ] && have "$OUT/t20b.stdout" "worktree root:" \
  && ok "a directory named .envrc does not hang --fix" || bad "--fix failed or hung"
if ( cd "$wt20" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: blessed an ancestor via a directory named .envrc"
else
  ok "directory named .envrc is refused, no ancestor blessed"
fi
rmdir "$wt20/.envrc" 2>/dev/null || true

echo
echo "=== 22. 'ai worktrees' is genuinely read-only (executes no .envrc) ==="
R21="$(make_repo repo21 --allow-marker)"
run_ai "$R21" "$OUT/t21a" codex wt -n sidefx "task"
# The launch above legitimately evaluates the .envrc (that is the whole point),
# so clear the evidence first; only what the AUDIT does should be measured.
[ -e "$R21-SIDE-EFFECT" ] && ok "launch does evaluate the .envrc (control)" \
  || bad "control failed: launch did not evaluate the .envrc"
find "$WORK" -maxdepth 2 -name '*-SIDE-EFFECT' -delete
run_ai "$R21" "$OUT/t21" worktrees
if find "$WORK" -maxdepth 2 -name '*-SIDE-EFFECT' | grep -q .; then
  bad "audit executed an .envrc (side effect fired)"
else
  ok "audit executed no .envrc"
fi

echo
echo "=== 23. DEEP layouts are reported, never auto-moved ==="
R22="$(make_repo repo22 --envrc --allow)"
git -C "$R22" worktree add -q "$WORK/repo22.worktrees/team/api" -b teamapi
run_ai "$R22" "$OUT/t22" worktrees
have "$OUT/t22.stdout" "DEEP" && ok "a nested layout of your own is labelled DEEP" || bad "DEEP not reported"
run_ai "$R22" "$OUT/t22b" worktrees --fix
[ -d "$WORK/repo22.worktrees/team/api" ] && ok "--fix did NOT move a DEEP tree" || bad "--fix moved a DEEP tree"

echo
echo "=== 24. -n is sanitized for paths/refs but kept as the session label ==="
R23="$(make_repo repo23 --envrc --allow)"
AGENT_DIRENV=0 run_ai "$R23" "$OUT/t23" wt -n 'Team/API $(touch '"$ROOT"'/pwned-name)`id`' "task"
[ -e "$ROOT/pwned-name" ] && bad "SECURITY: --name injected via the printed recipe" \
  || ok "--name cannot inject into printed commands"
wt23="$(sed -n 's/^worktree: *//p' "$OUT/t23.stderr")"
case "$wt23" in
  "$WORK/repo23.worktrees/"*/*) bad "--name with '/' nested the worktree" "$wt23" ;;
  "$WORK/repo23.worktrees/"*)   ok "--name with '/' stays directly under the root" ;;
  *) bad "unexpected worktree path" "$wt23" ;;
esac
have "$OUT/t23.stderr" "sanitised" && ok "reports the sanitised branch name" || bad "no sanitisation note"
grep -q 'ARG:Team/API' "$OUT/t23" && ok "session label keeps the original text" \
  || bad "session label was mangled" "$(grep -A1 'ARG:--name' "$OUT/t23")"
run_ai "$R23" "$OUT/t23b" codex wt -n '../../escape' "task"
wt23b="$(sed -n 's/^worktree: *//p' "$OUT/t23b.stderr")"
case "$wt23b" in
  "$WORK/repo23.worktrees/"*) ok "--name '../..' cannot escape the root" ;;
  *) bad "--name escaped the worktree root" "$wt23b" ;;
esac

echo
echo "=== 25. Codex worktree commands: physical paths and system Bash ==="
R24="$(make_repo 'project with spaces' --envrc --allow)"
ln -s "$WORK" "$ROOT/linked projects"
( cd "$ROOT/linked projects/project with spaces" \
  && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t24" AGENT_NO_AGENTS=1 \
     /bin/bash "$AI" wt codex -n portable "task" ) >"$OUT/t24.stdout" 2>"$OUT/t24.stderr"
rc24=$?
wt24="$(sed -n 's/^worktree: *//p' "$OUT/t24.stderr")"
[ "$rc24" -eq 0 ] && have "$OUT/t24" "MARKER:from-project with spaces" \
  && ok "system Bash launches ai wt codex with direnv through a symlinked path" \
  || bad "system Bash/symlinked path lost the Codex environment"
have "$OUT/t24" "CWD:$wt24" && ok "Codex runs in the physical worktree" || bad "Codex cwd mismatch"

echo
echo "=== 26. custom direnv configuration and Bash survive state scrubbing ==="
R25="$(make_repo repo25 --envrc)"
custom_config="$ROOT/custom direnv config"
custom_bash="$ROOT/custom-bash"
mkdir -p "$custom_config"
printf '%s\n' 'export AI_TEST_CONFIG_MARKER=custom-config' > "$custom_config/direnvrc"
cat > "$custom_bash" <<'EOF'
#!/bin/sh
exec /bin/bash "$@"
EOF
chmod +x "$custom_bash"
DIRENV_CONFIG="$custom_config" DIRENV_BASH="$custom_bash" direnv allow "$R25"
DIRENV_CONFIG="$custom_config" DIRENV_BASH="$custom_bash" \
  run_ai "$R25" "$OUT/t25" wt codex -n configured "task"
[ "$(cat "$OUT/t25.rc")" -eq 0 ] && have "$OUT/t25" "CONFIG:custom-config" \
  && ok "the configured direnvrc reaches the agent" || bad "custom direnvrc was ignored"
have "$OUT/t25" "DIRENV_CONFIG:$custom_config" && have "$OUT/t25" "DIRENV_BASH:$custom_bash" \
  && ok "DIRENV_CONFIG and DIRENV_BASH are preserved" || bad "direnv configuration variables were scrubbed"

echo
echo "=== 27. REGRESSION: direnv probes leak no job notices under /bin/bash ==="
# direnv_allowed runs direnv_run inside $( ... 2>/dev/null ). While direnv_run
# ended in `exit`, Bash 3.2 restored the caller's stderr before the watchdog
# cleanup ran, and "Killed: 9 ( sleep 20; ... )" / "[N]+ Done" notices reached
# the terminal (measured here: about one probe in seven). Ten launches that load
# an allowed .envrc, then a --fix and five audits over twelve worktrees, make
# about 120 probes under the system Bash, so the old code cannot slip through;
# the last section checks every launcher stderr this suite captured.
R27="$(make_repo repo27 --envrc --allow)"
loaded=0
for i in 1 2 3 4 5 6 7 8 9 10; do
  ( cd "$R27" && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t27-$i" AGENT_NO_AGENTS=1 \
      /bin/bash "$AI" codex "task $i" ) >"$OUT/t27-$i.stdout" 2>"$OUT/t27-$i.stderr"
  have "$OUT/t27-$i" "MARKER:from-repo27" && loaded=$((loaded + 1))
done
[ "$loaded" -eq 10 ] && ok "/bin/bash ($(/bin/bash -c 'echo $BASH_VERSION')) loaded the allowed .envrc 10 times" \
  || bad "only $loaded of 10 /bin/bash launches loaded the allowed .envrc"
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  git -C "$R27" worktree add -q "$WORK/repo27.worktrees/w$i" -b "w$i"
done
( cd "$R27" && /bin/bash "$AI" worktrees --fix ) >"$OUT/t27-fix.stdout" 2>"$OUT/t27-fix.stderr"
audited=0
for i in 1 2 3 4 5; do
  ( cd "$R27" && /bin/bash "$AI" worktrees ) >"$OUT/t27-audit-$i.stdout" 2>"$OUT/t27-audit-$i.stderr" \
    && [ "$(grep -cE '^  ok +ok ' "$OUT/t27-audit-$i.stdout")" -eq 12 ] && audited=$((audited + 1))
done
[ "$audited" -eq 5 ] && ok "after --fix, five /bin/bash audits each probed twelve allowed worktrees" \
  || bad "the audits did not see twelve allowed worktrees" "$(sed -n '1,14p' "$OUT/t27-audit-1.stdout")"

echo
echo "=== 28. a hanging .envrc is bounded without GNU timeout (ran in the background) ==="
wait "$hang_pid"
cat "$OUT/hang.results"
pass=$((pass + $(grep -c 'PASS' "$OUT/hang.results")))
fail=$((fail + $(grep -c 'FAIL' "$OUT/hang.results")))
[ "$(grep -cE 'PASS|FAIL' "$OUT/hang.results")" -eq 2 ] || bad "the background section did not report both results"

echo
echo "=== 29. no job-control notice reached any launcher's stderr ==="
notice='Killed|\]\+ +Done|sleep 20|waited=0'
captures=0
for f in "$OUT"/*.stderr; do captures=$((captures + 1)); done
if grep -qE "$notice" "$OUT"/*.stderr; then
  bad "job-control notices leaked into launcher stderr" \
    "$(grep -HE "$notice" "$OUT"/*.stderr | head -3 | sed "s#$OUT/##")"
else
  ok "none in $captures launcher stderr captures"
fi

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  echo "fixtures kept for inspection: $ROOT"
  exit 1
fi
[ -n "${AI_TEST_ROOT:-}" ] || rm -rf "$ROOT"
