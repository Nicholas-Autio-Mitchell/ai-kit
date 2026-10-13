#!/usr/bin/env bash
# Test harness for the `ai` launcher — direnv integration, worktree anchoring, --name.
#
#   agent.d/tests/direnv-worktree.sh          # run everything
#   AI_TEST_ROOT=/some/dir  ...               # keep the fixtures for inspection
#   AI=/path/to/ai          ...               # test a launcher somewhere else
#
# The launcher under test is found relative to THIS file, so the suite works from
# a git clone, from an installed prefix, and from a copy in any other location.
#
# Nothing outside $ROOT is touched: direnv's trust store is redirected via
# XDG_DATA_HOME (essential — allow tokens are keyed on path+contents, so tokens
# from a previous run would silently pre-authorise the fixtures and produce a
# false pass), and fake claude/codex binaries on PATH record their argv and
# inherited environment instead of launching a real agent.
# Fake `claude`/`codex` on PATH record their argv + the environment they inherited,
# so we can assert without launching a real agent.
set -uo pipefail

# Locate the launcher relative to this harness rather than hard-coding a path, so
# the suite is as relocatable as the tool it tests. Two candidates cover both
# layouts: <root>/bin/ai (the packaged/installed one) and <root>/ai (a launcher
# sitting directly beside its agent.d/). An explicit AI= overrides both.
here="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd -P "$here/../.." && pwd)"
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
WORK="$ROOT/work"
FAKEBIN="$ROOT/fakebin"
OUT="$ROOT/out"

# direnv's allow store is global and keyed on (path + contents), so tokens from a
# previous run of this very suite would still be valid and silently pre-authorise
# the fixtures. Point direnv at a per-run store: full isolation, and the user's
# real ~/.local/share/direnv is never touched.
export XDG_DATA_HOME="$ROOT/xdg"
rm -rf "$XDG_DATA_HOME"; mkdir -p "$XDG_DATA_HOME"

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
  cat > "$FAKEBIN/claude" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "--help" ]; then
  echo "  -n, --name <name>   Set a display name for this session"
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
} > "$AI_TEST_OUT"
exit 0
EOF
  # An older CLI with no --name flag, for the graceful-degradation path.
  cat > "$FAKEBIN/claude-old" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "--help" ] && { echo "  --model <model>  Model for the session"; exit 0; }
{ echo "ARGV_BEGIN"; for a in "$@"; do echo "ARG:$a"; done; echo "ARGV_END"; } > "$AI_TEST_OUT"
exit 0
EOF
  sed 's/claude/codex/' /dev/null >/dev/null
  cat > "$FAKEBIN/codex" <<'EOF'
#!/usr/bin/env bash
{
  echo "ARGV_BEGIN"
  for a in "$@"; do echo "ARG:$a"; done
  echo "ARGV_END"
  echo "MARKER:${AI_TEST_MARKER:-<unset>}"
} > "$AI_TEST_OUT"
exit 0
EOF
  chmod +x "$FAKEBIN"/*
}

# make_repo <name> [--envrc] [--allow] [--hook]
make_repo() {
  local name="$1"; shift
  local dir="$WORK/$name"
  mkdir -p "$dir"
  git init -q "$dir"
  git -C "$dir" config user.email t@t
  git -C "$dir" config user.name t
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

# run_ai <cwd> <outfile> <args...>
run_ai() {
  local cwd="$1" out="$2"; shift 2
  ( cd "$cwd" \
    && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$out" AGENT_NO_AGENTS=1 \
       "$AI" "$@" ) >"$out.stdout" 2>"$out.stderr"
  echo $? > "$out.rc"
}

rm -rf "$WORK" "$OUT"; mkdir -p "$WORK" "$OUT"
setup_fakes

echo
echo "=== 1. --help / usage still work ==="
if "$AI" --help >"$OUT/help" 2>&1; then
  have "$OUT/help" "worktrees [--fix]" && ok "help documents 'worktrees'" || bad "help lacks worktrees"
  have "$OUT/help" "AGENT_DIRENV" && ok "help documents AGENT_DIRENV" || bad "help lacks AGENT_DIRENV"
  have "$OUT/help" "Session label, in BOTH modes" && ok "help documents --name in both modes" || bad "help --name stale"
else
  bad "ai --help exited non-zero"
fi
"$AI" --badflag >"$OUT/bad" 2>&1; [ $? -eq 2 ] && ok "unknown flag exits 2" || bad "unknown flag exit code"

echo
echo "=== 2. worktree lands beside the MAIN worktree ==="
R1="$(make_repo repo1 --envrc --allow)"
run_ai "$R1" "$OUT/t2" wt -n alpha "task"
wt2="$(sed -n 's/^worktree: *//p' "$OUT/t2.stderr")"
case "$wt2" in
  "$WORK/repo1.worktrees/alpha-"*) ok "worktree created in <repo>.worktrees/ ($(basename "$wt2"))" ;;
  *) bad "worktree in unexpected place" "$wt2" ;;
esac

echo
echo "=== 3. ANCHOR FIX: creating a worktree FROM INSIDE a worktree ==="
run_ai "$wt2" "$OUT/t3" wt -n beta "task"
wt3="$(sed -n 's/^worktree: *//p' "$OUT/t3.stderr")"
case "$wt3" in
  "$WORK/repo1.worktrees/beta-"*) ok "nested launch still lands in the canonical root" ;;
  *) bad "nested launch scattered the worktree" "$wt3" ;;
esac

echo
echo "=== 4. direnv: symlink + allow + env reaches the agent ==="
[ -L "$wt2/.envrc" ] && ok ".envrc symlink created in the worktree" || bad ".envrc not symlinked"
[ "$(readlink "$wt2/.envrc")" = "$R1/.envrc" ] && ok "symlink target is absolute, to the main repo" \
  || bad "symlink target wrong" "$(readlink "$wt2/.envrc" 2>&1)"
( cd "$wt2" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ) \
  && ok "worktree .envrc is allowed" || bad "worktree .envrc NOT allowed"
have "$OUT/t2" "MARKER:from-repo1" && ok "agent process inherited \$AI_TEST_MARKER from .envrc" \
  || bad "agent did not get the direnv environment" "$(grep MARKER "$OUT/t2" 2>&1)"
have "$OUT/t2.stderr" "direnv:" && ok "launch banner reports direnv" || bad "no direnv line in banner"

echo
echo "=== 5. idempotent with a repo post-checkout hook ==="
R5="$(make_repo repo5 --envrc --allow --hook)"
run_ai "$R5" "$OUT/t5" wt -n hooked "task"
wt5="$(sed -n 's/^worktree: *//p' "$OUT/t5.stderr")"
have "$OUT/t5.stderr" "HOOK-LINKED" && ok "repo hook ran and linked first" || bad "hook did not run"
[ -L "$wt5/.envrc" ] && [ "$(readlink "$wt5/.envrc")" = "$R5/.envrc" ] \
  && ok "hook's symlink left intact (not clobbered)" || bad "hook symlink was replaced"
have "$OUT/t5" "MARKER:from-repo5" && ok "hook-linked worktree still gets blessed + loaded" \
  || bad "hook-linked worktree not blessed"

echo
echo "=== 6. trust is propagated, never created ==="
R6="$(make_repo repo6 --envrc)"          # .envrc present but NEVER allowed
run_ai "$R6" "$OUT/t6" wt -n untrusted "task"
wt6="$(sed -n 's/^worktree: *//p' "$OUT/t6.stderr")"
if ( cd "$wt6" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: blessed a worktree whose source .envrc was never allowed"
else
  ok "unallowed source .envrc is NOT auto-blessed in the worktree"
fi
have "$OUT/t6" "MARKER:<unset>" && ok "agent ran WITHOUT the unallowed env" || bad "env leaked from unallowed .envrc"
[ "$(cat "$OUT/t6.rc")" = "0" ] && ok "blocked .envrc still launches the agent (no hard failure)" \
  || bad "blocked .envrc aborted the launch" "rc=$(cat "$OUT/t6.rc")"
have "$OUT/t6.stderr" "direnv allow" && ok "prints the direnv allow remedy" || bad "no remedy printed"

echo
echo "=== 7. a branch's own, different .envrc is not auto-blessed ==="
R7="$(make_repo repo7 --envrc --allow)"
git -C "$R7" checkout -q -b evil
printf 'export AI_TEST_MARKER="EVIL"\n' > "$R7/committed.envrc"
git -C "$R7" add -f committed.envrc && git -C "$R7" mv committed.envrc .envrc 2>/dev/null \
  || { cp "$R7/committed.envrc" "$R7/.envrc.tracked"; }
git -C "$R7" add -f .envrc 2>/dev/null
git -C "$R7" commit -qm "branch carries its own .envrc" 2>/dev/null
git -C "$R7" checkout -q master 2>/dev/null || git -C "$R7" checkout -q main
run_ai "$R7" "$OUT/t7" wt -b evil -n evilwt "task"
wt7="$(sed -n 's/^worktree: *//p' "$OUT/t7.stderr")"
if [ -f "$wt7/.envrc" ] && ! [ -L "$wt7/.envrc" ]; then
  if ( cd "$wt7" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
    bad "SECURITY: auto-blessed a committed .envrc that differs from the main repo's"
  else
    ok "committed, differing .envrc left blocked"
  fi
  have "$OUT/t7" "MARKER:EVIL" && bad "SECURITY: evil .envrc was executed" || ok "evil .envrc never executed"
else
  ok "branch .envrc setup not applicable here (skipped)"
fi

echo
echo "=== 8. in place: never calls direnv allow ==="
R8="$(make_repo repo8 --envrc)"           # unallowed
run_ai "$R8" "$OUT/t8" "task"
if ( cd "$R8" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: in-place mode allowed the user's unreviewed .envrc"
else
  ok "in-place mode did not allow an unreviewed .envrc"
fi
direnv allow "$R8/.envrc"
run_ai "$R8" "$OUT/t8b" "task"
have "$OUT/t8b" "MARKER:from-repo8" && ok "in-place mode loads an ALREADY-allowed .envrc" \
  || bad "in-place mode did not load the allowed env"

echo
echo "=== 9. --name works without a worktree ==="
run_ai "$R1" "$OUT/t9" -n my-session "task"
have "$OUT/t9" "ARG:--name" && have "$OUT/t9" "ARG:my-session" \
  && ok "in-place --name forwarded to claude" || bad "--name not forwarded in place"
run_ai "$R1" "$OUT/t9b" wt -n wt-session "task"
have "$OUT/t9b" "ARG:wt-session" && ok "worktree mode also labels the session" || bad "wt --name not forwarded"
# codex has no launch-time name
run_ai "$R1" "$OUT/t9c" codex -n cx "task"
have "$OUT/t9c.stderr" "no launch-time session name" && ok "codex prints the /name hint" || bad "no codex hint"
have "$OUT/t9c" "ARG:--name" && bad "--name wrongly passed to codex" || ok "--name not passed to codex"
# older claude without --name
cp "$FAKEBIN/claude" "$FAKEBIN/claude.bak"; cp "$FAKEBIN/claude-old" "$FAKEBIN/claude"
run_ai "$R1" "$OUT/t9d" -n legacy "task"
have "$OUT/t9d.stderr" "no --name flag" && ok "older claude degrades to a note" || bad "no degradation note"
have "$OUT/t9d" "ARG:--name" && bad "--name passed to a CLI that lacks it" || ok "--name withheld from old CLI"
mv "$FAKEBIN/claude.bak" "$FAKEBIN/claude"

echo
echo "=== 10. --base is still worktree-only; --fix is worktrees-only ==="
run_ai "$R1" "$OUT/t10" -b main "task"
[ "$(cat "$OUT/t10.rc")" = "2" ] && ok "--base in place exits 2" || bad "--base restriction lost"
run_ai "$R1" "$OUT/t10b" --fix "task"
[ "$(cat "$OUT/t10b.rc")" = "2" ] && ok "--fix outside 'worktrees' exits 2" || bad "--fix restriction missing"

echo
echo "=== 11. AGENT_DIRENV=0 disables everything ==="
( cd "$R1" && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t11" AGENT_NO_AGENTS=1 AGENT_DIRENV=0 \
    "$AI" wt -n nodirenv "task" ) >"$OUT/t11.stdout" 2>"$OUT/t11.stderr"
wt11="$(sed -n 's/^worktree: *//p' "$OUT/t11.stderr")"
[ -e "$wt11/.envrc" ] && bad "AGENT_DIRENV=0 still linked .envrc" || ok "AGENT_DIRENV=0 skips the symlink"
have "$OUT/t11" "MARKER:<unset>" && ok "AGENT_DIRENV=0 skips the env" || bad "env loaded despite AGENT_DIRENV=0"
have "$OUT/t11.stderr" "AGENT_DIRENV=0" && ok "banner says why direnv is off" || bad "banner silent"

echo
echo "=== 12. non-repo directory still works ==="
mkdir -p "$WORK/plain"
run_ai "$WORK/plain" "$OUT/t12" "task"
[ "$(cat "$OUT/t12.rc")" = "0" ] && ok "runs in a non-git directory" || bad "non-repo run failed"
run_ai "$WORK/plain" "$OUT/t12b" worktrees
[ "$(cat "$OUT/t12b.rc")" = "1" ] && ok "'worktrees' outside a repo exits 1 with a message" \
  || bad "worktrees outside a repo" "rc=$(cat "$OUT/t12b.rc")"

echo
echo "=== 13. 'ai worktrees' audit ==="
run_ai "$R1" "$OUT/t13" worktrees
have "$OUT/t13.stdout" "worktree root:" && ok "audit prints the canonical root" || bad "no root line"
have "$OUT/t13.stdout" "main" && ok "audit lists the main worktree" || bad "main missing"
grep -qE '^  ok +ok ' "$OUT/t13.stdout" && ok "healthy worktrees show ok/ok" \
  || bad "no ok/ok rows" "$(sed -n '5,12p' "$OUT/t13.stdout")"

echo
echo "=== 14. 'ai worktrees --fix' repairs a NESTED tree ==="
R14="$(make_repo repo14 --envrc --allow)"
run_ai "$R14" "$OUT/t14a" wt -n one "task"
wt14="$(sed -n 's/^worktree: *//p' "$OUT/t14a.stderr")"
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
echo "=== 15. --fix prunes a dead registration ==="
R15="$(make_repo repo15 --envrc --allow)"
run_ai "$R15" "$OUT/t15a" wt -n doomed "task"
wt15="$(sed -n 's/^worktree: *//p' "$OUT/t15a.stderr")"
rm -rf "$wt15"
run_ai "$R15" "$OUT/t15b" worktrees
have "$OUT/t15b.stdout" "GONE" && ok "audit flags the dead registration" || bad "GONE not flagged"
run_ai "$R15" "$OUT/t15c" worktrees --fix
run_ai "$R15" "$OUT/t15d" worktrees
have "$OUT/t15d.stdout" "GONE" && bad "--fix did not prune" || ok "--fix pruned the dead registration"

echo
echo "=== 16. STRAY trees are reported but never moved ==="
R16="$(make_repo repo16 --envrc --allow)"
git -C "$R16" worktree add -q "$WORK/elsewhere-16" -b stray
run_ai "$R16" "$OUT/t16" worktrees
have "$OUT/t16.stdout" "STRAY" && ok "audit flags the stray tree" || bad "STRAY not flagged"
have "$OUT/t16.stdout" "worktree move" && ok "prints an opt-in move command" || bad "no move suggestion"
run_ai "$R16" "$OUT/t16b" worktrees --fix
[ -d "$WORK/elsewhere-16" ] && ok "--fix did NOT move the stray tree" || bad "--fix moved a stray tree"
[ -L "$WORK/elsewhere-16/.envrc" ] && ok "--fix still repaired the stray tree's direnv" || bad "stray direnv unrepaired"

echo
echo "=== 17. an explicitly DENIED .envrc is not reported as loaded ==="
# direnv exec RUNS the command on a denied rc — silently, with no environment,
# exit 0. So the exec probe alone would claim success; only `status --json`
# distinguishes allowed(0) from blocked(1) from denied(2).
R17="$(make_repo repo17 --envrc --allow)"
direnv deny "$R17/.envrc"
den="$( cd "$R17" && direnv status --json 2>/dev/null | grep -oE '"allowed": [0-9]' )"
[ "$den" = '"allowed": 2' ] && ok "fixture is in the denied state" || bad "could not deny" "$den"
run_ai "$R17" "$OUT/t17" "task"
[ "$(cat "$OUT/t17.rc")" = "0" ] && ok "denied .envrc still launches the agent" || bad "denied .envrc aborted launch"
have "$OUT/t17" "MARKER:<unset>" && ok "denied .envrc contributes no environment" || bad "denied env leaked"
have "$OUT/t17.stderr" "NOT loaded" && ok "banner reports NOT loaded (does not claim success)" \
  || bad "banner wrongly claimed the env was loaded" "$(grep -i direnv "$OUT/t17.stderr")"

echo
echo "=== 18. worktree/branch names from hostile prompts ==="
R18="$(make_repo repo18 --envrc --allow)"
run_ai "$R18" "$OUT/t18" wt -- '$(touch $ROOT/pwned-marker); `id`; rm -rf ~ --'
[ -e $ROOT/pwned-marker ] && bad "SECURITY: command substitution in the prompt executed" \
  || ok "prompt-derived name cannot inject commands"
wt18="$(sed -n 's/^worktree: *//p' "$OUT/t18.stderr")"
case "$wt18" in
  "$WORK/repo18.worktrees/"*) ok "hostile prompt still yields a path under the root" ;;
  *) bad "hostile prompt escaped the worktree root" "$wt18" ;;
esac
[ -d "$wt18" ] && ok "hostile-named worktree was actually created" || bad "worktree missing" "$wt18"

echo
echo "=== 19. REGRESSION: inherited DIRENV_* must not forge an allow (loadedRC) ==="
# `direnv status --json` reports the CALLER's loadedRC next to the directory's
# foundRC, each with its own "allowed". An unanchored read of that blob treats
# someone else's allowed .envrc as this one's — and `ai` launches agents under
# `direnv exec`, so it poisons its own children.
R19="$(make_repo repo19 --envrc)"            # .envrc present, NEVER allowed
mkdir -p "$WORK/trusted19"
printf 'export TRUSTED19=1\n' > "$WORK/trusted19/.envrc"
direnv allow "$WORK/trusted19"
( cd "$R19" && PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t19" AGENT_NO_AGENTS=1 \
    direnv exec "$WORK/trusted19" "$AI" wt -n forged "task" ) >"$OUT/t19.stdout" 2>"$OUT/t19.stderr"
wt19="$(sed -n 's/^worktree: *//p' "$OUT/t19.stderr")"
if ( cd "$wt19" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: inherited DIRENV_* forged a blessing for an unallowed .envrc"
else
  ok "inherited DIRENV_* cannot forge a blessing"
fi
have "$OUT/t19" "MARKER:<unset>" && ok "unallowed .envrc was not executed" \
  || bad "SECURITY: unallowed .envrc executed" "$(grep MARKER "$OUT/t19")"
have "$OUT/t19" "MARKER:from-repo19" && bad "SECURITY: hostile env reached the agent" || ok "no hostile env reached the agent"

echo
echo "=== 20. non-regular .envrc is refused (FIFO / directory) ==="
R20="$(make_repo repo20 --envrc --allow)"
run_ai "$R20" "$OUT/t20a" wt -n fifo "task"
wt20="$(sed -n 's/^worktree: *//p' "$OUT/t20a.stderr")"
rm -f "$wt20/.envrc"; mkfifo "$wt20/.envrc"                  # symlink-to-FIFO stand-in
timeout 60 env PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t20" AGENT_NO_AGENTS=1 \
  bash -c "cd '$wt20' && '$AI' worktrees" >"$OUT/t20.stdout" 2>&1
[ $? -ne 124 ] && ok "a FIFO .envrc does not hang the audit" || bad "audit hung on a FIFO .envrc"
rm -f "$wt20/.envrc"; mkdir "$wt20/.envrc"                   # directory named .envrc
timeout 60 env PATH="$FAKEBIN:$PATH" AI_TEST_OUT="$OUT/t20b" AGENT_NO_AGENTS=1 \
  bash -c "cd '$R20' && '$AI' worktrees --fix" >"$OUT/t20b.stdout" 2>&1
rc20=$?
[ "$rc20" -ne 124 ] && ok "a directory named .envrc does not hang --fix" || bad "--fix hung"
if ( cd "$wt20" && direnv status --json 2>/dev/null | grep -q '"allowed": 0' ); then
  bad "SECURITY: blessed an ancestor via a directory named .envrc"
else
  ok "directory named .envrc is refused, no ancestor blessed"
fi
rmdir "$wt20/.envrc" 2>/dev/null || true

echo
echo "=== 21. 'ai worktrees' is genuinely read-only (executes no .envrc) ==="
R21="$(make_repo repo21 --allow-marker)"
run_ai "$R21" "$OUT/t21a" wt -n sidefx "task"
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
echo "=== 22. DEEP layouts are reported, never auto-moved ==="
R22="$(make_repo repo22 --envrc --allow)"
git -C "$R22" worktree add -q "$WORK/repo22.worktrees/team/api" -b teamapi
run_ai "$R22" "$OUT/t22" worktrees
have "$OUT/t22.stdout" "DEEP" && ok "a nested layout of your own is labelled DEEP" || bad "DEEP not reported"
run_ai "$R22" "$OUT/t22b" worktrees --fix
[ -d "$WORK/repo22.worktrees/team/api" ] && ok "--fix did NOT move a DEEP tree" || bad "--fix moved a DEEP tree"

echo
echo "=== 23. -n is sanitized for paths/refs but kept as the session label ==="
R23="$(make_repo repo23 --envrc --allow)"
run_ai "$R23" "$OUT/t23" wt -n 'Team/API $(touch '"$ROOT"'/pwned-name)`id`' "task"
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
run_ai "$R23" "$OUT/t23b" wt -n '../../escape' "task"
wt23b="$(sed -n 's/^worktree: *//p' "$OUT/t23b.stderr")"
case "$wt23b" in
  "$WORK/repo23.worktrees/"*) ok "--name '../..' cannot escape the root" ;;
  *) bad "--name escaped the worktree root" "$wt23b" ;;
esac

echo
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
