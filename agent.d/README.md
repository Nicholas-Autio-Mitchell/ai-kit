# ai

Launch an AI coding agent (**Codex** or **Claude**) in **full-auto mode** with a
bundled **team of specialist subagents** — either **in place** on your current
branch, or inside a throwaway **git worktree**.

```
ai [wt|here] [claude|codex] [options] [--] [prompt...]
```

Both the mode and the agent are optional, so the shortest useful form is just:

```
ai          "Do the task"     # in place, current branch, Claude
ai wt       "Do the task"     # isolated worktree + branch, Claude
ai    codex "Do the task"     # in place, current branch, Codex
ai wt codex "Do the task"     # isolated worktree + branch, with Codex
ai here codex "Do the task"   # in place, current branch, Codex
```

Both agents default to in-place mode. Explicit `wt` / `--wt` and `here` / `--here`
select the mode for either agent. Model, effort, auto-run, subagent team, and
logbook discipline are identical across modes.

> **The command name is not fixed.** `install.sh` symlinks your chosen name at
> the launcher, and the launcher resolves its own location through symlinks to
> find `agent.d/` beside itself — so `ai`, `aid`, `ai-kit` or anything else all
> work identically. This document says `ai` throughout; substitute your own.
>
> Two names deserve care. `agent` is owned by the cursor-agent installer, which
> recreates `~/.local/bin/agent` on every self-update and would silently
> overwrite anything parked there — so it is left to Cursor. And `ai` itself is
> short and popular; the installer checks whether it is already taken on your
> `PATH` and suggests an alternative rather than shadowing it.

Optional worktree-mode shortcuts (`install.sh --shortcuts`):

```
<cmd>-wt  [claude|codex] "..."   ==  ai wt [claude|codex] "..."
codex-wt  "..."                  ==  ai wt codex  "..."
claude-wt "..."                  ==  ai wt claude "..."
```

They are separate scripts rather than bare symlinks because a `*-wt` name only
selects worktree mode; picking the *agent* takes an argument.

---

## What it does

**In place (`here`, default)** — work on the current branch:

1. Resolves the **repository root** and stays on your **current branch**.
2. Installs the **subagent team** and a `DEVLOG.md` scaffold **temporarily**,
   git-ignores them for the session, and **removes them on exit** — the
   repository is left exactly as it was found.
3. Launches the agent in full-auto mode with guardrails: commit your own work in
   milestones, never push/rebase/reset/switch branches, never touch the user's
   pre-existing uncommitted changes, stage explicit paths (never `git add -A`).

**Worktree (`wt`)** — work in a separate directory and branch:

1. Creates a fresh worktree + branch off `<base>` (default: your current branch,
   so the work fast-forwards straight back) under
   `<main-repo-parent>/<main-repo>.worktrees/`.
2. Installs the team + `DEVLOG.md` into the worktree (permanently — it's
   throwaway anyway).
3. Wires up **direnv** so the worktree resolves to the same project environment
   as the repository it was cut from (see below).
4. Launches the agent inside the worktree.
5. Prints the exact commands to **merge the work back**.

**Audit (`worktrees`)** — `ai worktrees` lists every worktree of the current
repository, where it sits relative to the canonical root, and what direnv makes
of it. Read-only, and that is enforced rather than assumed: it reports from
`direnv status` and never uses `direnv exec` as a probe, because `exec` evaluates
the `.envrc` before running anything — an "audit" that fires `use flake` across a
dozen worktrees is not read-only.

`--fix` applies the repairs: prune dead registrations, consolidate `NESTED`
trees, and re-link / re-allow `.envrc` everywhere. `STRAY` and `DEEP` trees are
never moved automatically.

## Worktrees all land in one place

Worktrees are grouped next to the **main** worktree — the one `git worktree list`
reports first — never next to whichever worktree you happen to be standing in.

That distinction is the whole point. `git rev-parse --show-toplevel` returns the
*current* worktree, so launching `ai wt` from inside a worktree used to create
`<that-worktree>.worktrees/<new>` nested underneath it, and a repository's trees
would end up scattered across several roots. Anchoring on the main worktree means
one repository has exactly one worktree root, which is also what makes the direnv
blessing and `ai worktrees` tractable.

`AGENT_WORKTREE_DIR` overrides the root. Pointing every repository at a single
shared root is a reasonable variant — see the direnv whitelist note below.

## direnv

`install.sh` ensures **direnv 2.33+** is available. It reuses existing Homebrew
or system tools on macOS; if missing, it uses existing Homebrew to install
`direnv`. Without Homebrew, install direnv manually and re-run the installer.
On Linux it uses the first available system package manager: `apt-get`, `dnf`,
`yum`, `pacman`, `zypper`, or `apk`. Installation failure or an unsupported/old
version stops before replacing the ai-kit payload. Noninteractive sudo uses
`-n`; authenticate with `sudo -v` first or install the dependency yourself.
Homebrew itself and shell hooks are never installed automatically. Uninstalling
ai-kit leaves direnv and its configuration intact.

The launcher uses identical trust and execution rules on Linux and macOS.
`direnv exec` works without a shell hook. Optional interactive-shell setup is
[documented by direnv](https://direnv.net/docs/hook.html): add
`eval "$(direnv hook zsh)"` to `~/.zshrc` or
`eval "$(direnv hook bash)"` to `~/.bashrc`; for macOS Bash login shells, source
`.bashrc` from `.bash_profile` too.

A worktree is only useful if it resolves to the **same project environment** as
the repository it was cut from. When the main worktree has an `.envrc`, every
launch:

1. **symlinks** that `.envrc` into the worktree (absolute target, so it survives
   `git worktree move`),
2. runs **`direnv allow`** on it, and
3. launches the agent through **`direnv exec`**, so the *agent process* inherits
   the project's `PATH` / `VIRTUAL_ENV` — not just your interactive shells.

Step 3 is the part a shell hook alone cannot do: `direnv`'s hook only fires for
interactive shells, so without it the agent would run with the wrong `python`.

### Why the allow has to be re-run

direnv keys trust on `sha256(path + "\n" + contents)`. Two consequences:

- every worktree **path** needs its own blessing, and
- editing the shared `.envrc` invalidates **all** of them at once.

So the link+bless runs on *every* launch, not just at creation — it self-heals
after you edit the `.envrc`. `ai worktrees --fix` does the same in bulk for trees
that already exist.

### The symlink trap

`direnv allow` is given the **directory**, never the `.envrc` path. This is not
cosmetic:

| invocation | what direnv records |
|---|---|
| `direnv allow <dir>/.envrc` | resolves symlinks over the **whole** path → blesses the shared **target**; the worktree stays blocked, and it exits **0** |
| `direnv allow <dir>` | resolves only the directory, then joins `.envrc` plainly → blesses the **worktree's own** path ✅ |

`direnv exec` only cleans the path (no symlink resolution), so the directory form
is the one whose token `exec` actually looks up. Both are given the physical path
with `cd -P` and `pwd -P`, supported by both platforms, so they cannot disagree.

(Allowing a worktree by hand works fine — `cd <worktree> && direnv allow` with no
argument uses the current directory and hits the good case.)

### Trust is propagated, never created

`ai` will not make an unreviewed `.envrc` executable:

- A worktree's `.envrc` is blessed **only** when it is a symlink to, or
  byte-identical with, an `.envrc` the main worktree has **already** allowed. A
  branch that carries its own, different `.envrc` is left blocked.
- **In place, `direnv allow` is never called at all.** An unallowed `.envrc` in
  your real repository is reported with the remedy, not executed.
- If direnv cannot load the directory cleanly, the run **downgrades to a plain
  launch** with a warning — a broken `.envrc` never stops the agent starting.

Supporting details, each of which was a real bug caught in review:

- Every direnv call clears inherited **state** (`DIRENV_DIFF`, `DIRENV_DIR`,
  `DIRENV_FILE`, `DIRENV_WATCHES`, `DIRENV_IN_ENVRC`) while preserving
  `DIRENV_CONFIG`, `DIRENV_BASH`, and other configuration. `direnv status
  --json` reports the *caller's* `loadedRC` beside the directory's `foundRC`,
  each with its own `allowed` field — and since `ai` launches agents under
  `direnv exec`, it would otherwise poison its own children into treating any
  `.envrc` as allowed.
- The allowed-check parses **`foundRC` only**, pinned to the exact path being
  blessed, and **fails closed**: blocked, denied, missing, or unparseable all
  read as "not allowed". An unrecognised direnv disables the feature rather than
  waving it through.
- The `.envrc` must be a **regular file** (`-f`, which follows symlinks). That
  rules out a directory named `.envrc` — direnv skips those and keeps walking up,
  so `allow` would bless an *ancestor* — and a symlink to a FIFO, which can serve
  different bytes to the comparison and to `direnv allow`, and hangs both.
- Probes use a portable Bash watchdog with a 20-second limit and closed stdin.
  It cleans up subprocesses on exit, so a hanging `.envrc` cannot wedge launch.
  GNU `timeout` is not required on either platform.

**What the claim does *not* cover.** It is about the `.envrc`'s *bytes*. Those
bytes then run in a directory whose contents come from `<base>`, and `.envrc`
idioms are directory-relative: `dotenv` reads the branch's `.env`, `PATH_add bin`
puts the branch's `bin/` ahead of yours, `use flake` / `layout poetry` execute
branch content directly. A worktree cut from a ref you do not trust can therefore
still influence the environment through a perfectly trusted `.envrc`. That is
inherent to direnv plus worktrees rather than anything `ai` introduces — but when
you are reviewing someone else's code, `AGENT_DIRENV=0 ai wt --base origin/pr-1234
…` is the right call.

`AGENT_DIRENV=0` turns all of it off.

### If you would rather not re-allow at all

direnv's `[whitelist] prefix` in `~/.config/direnv/direnv.toml` bypasses the allow
check for everything under a path, which removes the per-worktree blessing
entirely and survives `.envrc` edits. It also means **any** `.envrc` under that
prefix auto-executes, so it is a real trust decision rather than a mechanical one.
If you take it, point `AGENT_WORKTREE_DIR` at one shared root for all repositories
and whitelist that — and write the prefix **with a trailing slash**, because
direnv matches it as a raw string prefix, so `/x/wt` would also match `/x/wt-evil`.

### Tests

```
agent.d/tests/direnv-worktree.sh        # requires direnv
AI_TEST_ROOT=/tmp/keep agent.d/tests/direnv-worktree.sh   # keep fixtures to inspect
AI=/path/to/ai         agent.d/tests/direnv-worktree.sh   # test a launcher elsewhere
```

The harness locates the launcher relative to itself, so it runs unchanged from a
git clone (`<repo>/bin/ai`) or from an installed prefix (`<prefix>/ai`).

Fake `claude`/`codex` on `PATH` record their argv and the environment they
inherited, so the suite asserts on *behaviour* — "did the `.envrc`'s variable
actually reach the agent process" — rather than on structure. That distinction
caught the symlink trap above, which passed every structural check (symlink
present, `direnv allow` exited 0) while being completely non-functional.

It isolates Git configuration (including commit signing), direnv configuration
with `XDG_CONFIG_HOME`, and the trust store with `XDG_DATA_HOME`:
allow tokens are keyed on path **and** contents, so tokens left by a previous run
silently pre-authorise the fixtures and the suite passes for the wrong reason.

The security regressions it pins: inherited direnv state cannot forge a blessing; a
FIFO or a directory named `.envrc` is refused without hanging; `-n` cannot inject
into printed commands or escape the worktree root; `DEEP`/`STRAY` trees survive
`--fix`; and `ai worktrees` executes no `.envrc` — that last one with a control
proving the *launch* does, so the test cannot pass vacuously.

### Repo hooks still work

A `post-checkout` hook that symlinks `.envrc` into new worktrees composes fine:
`ai` only creates the link when one is absent and never replaces an existing one.
The hook alone is not sufficient, though — it cannot put the environment into the
agent's process, which is what step 3 is for.

If you also want a **plain `git worktree add`** to come out fully wired, the hook
can do the blessing itself. Note the directory form of `direnv allow`, for the
reason in "The symlink trap" above — the obvious `direnv allow .envrc` silently
blesses the wrong path:

```bash
#!/bin/bash
# .git/hooks/post-checkout — link + bless .envrc in a new worktree
main=$(git rev-parse --path-format=absolute --git-common-dir)
main=${main%/.git}                      # ${..%..} strips only a TRAILING /.git,
                                        # unlike sed 's|/.git||' which strips the
                                        # first match anywhere in the path
src="$main/.envrc"
[ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] || exit 0
[ "$PWD" != "$main" ] && [ -f "$src" ] || exit 0
[ -e .envrc ] || ln -s "$src" .envrc
command -v direnv >/dev/null && direnv allow "$PWD"   # directory, NOT "$PWD/.envrc"
```

Blessing from a hook is a slightly stronger claim than what `ai` makes: it allows
whatever the main repo's `.envrc` currently contains, without checking that you
had already allowed it. That is usually what you want in your own repository —
just be aware it is the weaker of the two trust models.

## The two agents

| Agent  | Model                       | Effort / mode              | Auto-run flag                                |
|--------|-----------------------------|----------------------------|----------------------------------------------|
| codex  | `gpt-6-astra` | highest supported effort (`ultra`), `fast` tier | `--dangerously-bypass-approvals-and-sandbox` |
| claude *(default)* | `opus` alias → latest Opus (now `claude-opus-5`) | `--effort max` (ultracode) | `--allow-dangerously-skip-permissions` + `--dangerously-skip-permissions` + `--permission-mode dontAsk` |

**Claude** is launched with the `opus` alias, which the CLI resolves to the
current model in that family.

**Codex** always defaults to `gpt-6-astra`, even if its model cache is absent,
stale, or ranks another model first. Set `AGENT_CODEX_MODEL` to choose a different
model explicitly. A model identifier still needs to be available to your account.

When `AGENT_CODEX_EFFORT` is unset or empty, `ai` reads the selected model's
supported efforts from `$CODEX_HOME/models_cache.json`
(`~/.codex/models_cache.json` by default). It chooses the highest advertised level in this order:
`ultra > max > xhigh > high > medium > low > minimal > none`. The cache is a
local snapshot, so the launcher cannot guarantee compatibility with every future
model or CLI release.

If that model has no usable cache entry, or `python3` is unavailable, known
defaults are `ultra` for `gpt-6-astra`, `gpt-5.6-sol` (also `gpt-5.6`), and
`gpt-5.6-terra`, `max` for `gpt-5.6-luna`, and `xhigh` for `gpt-5.5`.
For an unknown model without a
usable catalogue entry, set `AGENT_CODEX_EFFORT` explicitly; the launcher stops
with guidance instead of guessing. An explicit effort override takes precedence.

The launch contract was checked against **Codex CLI 0.154.0**, listed in the
[official September 9, 2026 changelog](https://learn.chatgpt.com/docs/changelog).
That CLI's bundled catalogue and the local cache inspected on September 12,
2026 advertise Astra `ultra` as maximum reasoning and delegation effort. The
checks cover CLI argument parsing and assembled instructions, without sending
an inference request.

`AGENT_CODEX_TIER=fast` is the default. Set `AGENT_CODEX_TIER=` to omit the tier
override and inherit your Codex configuration. This is useful when your account
or deployment does not support fast mode; for example, the
[Astra API EU data residency configuration](https://developers.openai.com/api/docs/guides/latest-model?model=gpt-6-astra)
does not support fast mode.

Codex web search: Codex enables web search by default (cached mode) and defaults
to **live** results under a full-access sandbox (which `ai` uses). `ai`
still passes **`--search`** to force live results explicitly. `AGENT_CODEX_SEARCH=0`
just omits `--search` (Codex falls back to its default mode, *not* off — to truly
disable, set `web_search="disabled"` in Codex config). Claude reaches the web via
its built-in WebSearch/WebFetch tools, so it needs no equivalent flag.

> **"UltraCode"** is the multi-agent orchestration *mode*, not an `--effort`
> value (the CLI only accepts `low|medium|high|xhigh|max`). So Claude is
> launched at `--effort max` **and** with an in-prompt directive to drive the
> bundled team and adversarially verify — which is the "ultracode" behavior.

## Your Claude settings (`~/.claude/settings.json`)

User-level settings are global to your account and load in **every** Claude
session regardless of working directory — so the session **and its subagents**
honor `~/.claude/settings.json` automatically. To make this explicit and robust
against any mode/version default, the Claude launch passes
`--setting-sources user,project,local` (override via
`AGENT_CLAUDE_SETTING_SOURCES`; empty = Claude's own default).

**Precedence** (high → low): managed/enterprise → command-line flags → local →
project → user. So two of `ai`'s flags intentionally override the matching
user settings:

- **`--effort max`** overrides your user `effortLevel`. To inherit your setting
  instead (e.g. `xhigh`), run with `AGENT_CLAUDE_EFFORT=` (empty), which drops
  the flag.
- **`--dangerously-skip-permissions`** supersedes the `permissions` block. If your
  user settings already set `defaultMode: bypassPermissions`, the effect is the
  same (full auto).

### Why `--permission-mode dontAsk` is passed too

`--dangerously-skip-permissions` asks for the `bypassPermissions` mode, and that
*one* mode can be vetoed independently of everything else — by an org feature
gate, by `permissions.disableBypassPermissionsMode` in settings, or by the
bypass disclaimer never having been accepted interactively on this machine. When
it is vetoed, Claude quietly falls through to the `default` mode, which the UI
labels **"manual"** — so you get a session that prompts for everything despite
having asked for full auto.

Claude resolves the request in order: `bypassPermissions` first, then
`--permission-mode`, then `permissions.defaultMode` from settings. Crucially,
`--permission-mode` is **not** subject to the bypass veto, so it is what actually
keeps the session unattended when bypass is blocked. Hence all three flags:

```
--allow-dangerously-skip-permissions   # make the bypass mode available
--dangerously-skip-permissions         # ask for it (best case)
--permission-mode dontAsk              # what you get if bypass is vetoed
```

**Caveat on `dontAsk`:** it never prompts, but anything that *would* have
prompted is **denied** rather than asked. So `ask` rules in your org settings
become hard denials under this mode. Override with
`AGENT_CLAUDE_PERMISSION_MODE=acceptEdits` (or `auto`) if that bites, or set it
empty to drop the flag entirely.

Everything else — `env`, `hooks`, `statusLine`, `outputStyle`, `allowedCommands`,
model aliases, etc. — applies normally. Avoid `--bare`, `--safe-mode`, or a
`--setting-sources` value that omits `user`, all of which would skip your user
settings.

## Usage

```
ai [wt|here] [claude|codex] [options] [--] [prompt...]
ai worktrees [--fix]

modes:
  (default)          work in place, on the current branch
  wt                 work in a fresh worktree + branch
  here               work in place, on the current branch
  worktrees          audit this repo's worktrees + direnv (no agent)

agents:
  claude (default)   latest Opus, --effort max, ultracode
  codex              GPT-6 Astra at its highest supported reasoning effort

options:
  -a, --agent NAME   codex or claude (usually given as a bare word instead)
      --wt           force worktree mode (same as the bare 'wt' word)
      --here         force in-place mode (useful for the *-wt wrappers)
  -b, --base REF     worktree only: base ref to branch from (default: current branch)
  -n, --name NAME    session label (both modes); under 'wt' it also names the
                     branch/worktree, defaulting to a slug of the prompt
      --fix          'worktrees' only: apply the repairs instead of listing them
  -h, --help         full help: modes, examples, environment overrides

examples:
  ai "Add a rate limiter to the API gateway"
  ai codex "Fix the failing auth test"
  ai codex --here "Explain the current auth flow"   # Codex on the current branch
  ai                            # no prompt: interactive session, best config
  ai -n auth-review "Why does login 500 on retry?"   # named, in place
  ai wt "Risky refactor of the scheduler"
  ai wt codex --base release/1.2 "Backport the auth fix"
  claude-wt --name rate-limiter "Add a rate limiter"
  ai codex -- "- refactor the failing test"   # -- ends option parsing
  ai worktrees                  # audit; --fix to consolidate and re-bless
```

`-h`/`--help` prints the full manual on stdout (pipe it to `less`); a mistyped
flag prints only a short usage hint on stderr.

The bare words `wt`, `here`, `worktrees`, `claude` and `codex` are only recognized
while they *lead* the argument list — everything from the first other word on is
the prompt.
So `ai claude wt ...` keeps `wt` in the prompt, and a task that genuinely
starts with one of those words just needs quoting:
`ai 'codex is failing to build'` runs Claude on that prompt.

### No-prompt (interactive) mode

Omit the prompt (`ai`, `ai codex`, `claude-wt`, …) and you are dropped into
an **interactive session** with everything already configured. Claude preloads
guardrails via `--append-system-prompt`; Codex preloads them through the
invocation's `-c developer_instructions=...` override. Codex receives the same
workflow with or without an initial task. `codex-wt` or `ai wt codex` creates a
worktree in both cases. The worktree is named `session-<timestamp>` when no
prompt or `--name` is given.

The Codex override replaces an existing `developer_instructions` config value
for that invocation; project `AGENTS.md` files are still read normally. The
launcher does not write this override to your Codex config.

### Naming a session

`-n/--name` is a **session label in both modes**. Claude receives it as `--name`,
which shows up in the prompt box, the `/resume` picker and the terminal title, so
a run is identifiable later without cutting a worktree for it. Under `wt` it
additionally names the branch and directory, as it always did.

The flag is probed for before it is passed, so a Claude CLI too old to have it
degrades to a note rather than refusing to start. Codex has no launch-time
equivalent — it names sessions from inside the TUI — so `ai` says so and suggests
its `/name` command.

## In-place mode leaves no trace

The subagent team has to live on disk (`.claude/agents/*.md` for Claude,
`.codex/agents/*.toml` for Codex) because that's how both CLIs discover
subagents. In a worktree that's free; in your real repository it would be litter.
So in-place mode:

- **never clobbers** a file you already have (existing definitions win),
- records exactly which files/directories it created,
- appends a marked block to `.git/info/exclude` so the scaffold stays out of
  `git status` and can't be swept into a `git add -A`,
- removes those files, the marked exclude block, and an untouched scaffolded
  `DEVLOG.md` when the session ends (also on Ctrl-C / `SIGTERM`).

The agent is also told in its guardrails that the scaffold is temporary and must
never be committed.

> Cleanup runs after the agent process exits, so interrupting a live session
> doesn't pull the team out from under it. One caveat: two concurrent in-place
> runs in the *same* repository share one scaffold, and whichever finishes first
> removes it. Use `wt` (or separate repos) for parallel sessions.

## The bundled team

A varied, deliberately non-overlapping team ships with the tool:

| Agent             | Role                                                              |
|-------------------|-------------------------------------------------------------------|
| `architect`       | Big-picture, elegant, simple system design (before code).         |
| `precision-coder` | Detail-oriented implementation: types, correctness, performance.  |
| `critic`          | Skeptical **second review loop** over every plan and diff.        |
| `chronicler`      | Logbook + decision log + docs + **milestone git commits**.        |
| `test-engineer`   | Tests, reproduction, coverage, honest verification.               |
| `researcher`      | Grounds work in the codebase + external docs before design.       |
| `security-auditor`| Vulnerabilities, unsafe patterns, error handling, edge cases.     |

Default loop per chunk of work:
`researcher → architect → precision-coder + test-engineer → critic +
security-auditor → revise → chronicler (document + commit)`.

**How the team is delivered — real subagents for both:**
- **Claude:** `.claude/agents/*.md` so it can delegate to them.
- **Codex:** `.codex/agents/*.toml` (Codex's `multi_agent` feature). The launch
  marks the working root trusted (`-c projects."<dir>".trust_level="trusted"`) so
  Codex loads its project `.codex/` layers. It also passes `--enable multi_agent`
  and preloads a directive to spawn the specialists through
  `developer_instructions`. Spawned subagents inherit the parent's model,
  effort, and full-auto sandbox override.

`AGENT_NO_AGENTS=1` skips installing the bundled team and omits its directive
and the Codex feature-enabling flag. Existing Codex settings still apply.

## The logbook & git history

The **chronicler** maintains `DEVLOG.md` — one entry per feature/change with
**what**, **why** (the key decision + alternatives), and **how it was verified**
— and **commits at each meaningful milestone** so the history reads as a clean
series of reviewable chunks. Commits stay local; push/rebase/reset are forbidden.

## Merging worktree work back

When a worktree session finishes it prints these (using real paths):

```
cd <repo>
git switch <your-branch>
git merge --ff-only <agent-branch>   # if rejected, use: git merge --no-ff <agent-branch>
git worktree remove <worktree>
git branch -d <agent-branch>
```

The fast-forward succeeds in the common case because the worktree branches from
your current branch. If you used `--base` to branch from elsewhere, or the
target advanced meanwhile, the `--ff-only` step is rejected — use the `--no-ff`
fallback shown above.

> **GPG signing is OFF by default** so the chronicler's auto-commits never block
> on a passphrase prompt. It is scoped to the run via `GIT_CONFIG_*` env vars
> that the agent's `git` calls inherit — your repo's git config is never
> modified. Set `AGENT_NO_GPG_SIGN=0` to keep your normal signing behavior (you
> may then be prompted for your passphrase mid-run). **Note this applies to
> in-place mode too:** commits the agent makes on your real branch are unsigned.
> If your team requires signed history, re-sign before pushing (e.g.
> `git rebase --exec 'git commit --amend -S --no-edit' <base>`).

## Environment overrides

Defaults favor maximum effort and unattended work. The legacy `AGENT_WT_*`
names are still honored as fallbacks.

| Variable                        | Default                                                                 |
|---------------------------------|-------------------------------------------------------------------------|
| `AGENT_CLAUDE_MODEL`            | `opus` (alias → latest Opus; use `claude-opus-5[1m]` for 1M context)     |
| `AGENT_CLAUDE_EFFORT`           | `max` (set to `xhigh` if `max` overthinks; empty = inherit `effortLevel`)|
| `AGENT_CLAUDE_PERMISSION_MODE`  | `dontAsk` — fallback autorun mode if bypass is vetoed (`acceptEdits`, `auto`, `bypassPermissions`, `dontAsk`, `plan`, `manual`; empty omits the flag) |
| `AGENT_CLAUDE_SETTING_SOURCES`  | `user,project,local` (empty = Claude's default)                         |
| `AGENT_CODEX_MODEL`             | `gpt-6-astra`, independent of cache ranking                            |
| `AGENT_CODEX_EFFORT`            | highest advertised effort for the selected model; known fallback defaults above |
| `AGENT_CODEX_TIER`              | `fast` (empty omits the override and inherits Codex config)            |
| `AGENT_CODEX_SEARCH`            | `1`: force Codex live web search (`--search`); `0` omits the flag        |
| `AGENT_WORKTREE_DIR`            | `<main-repo-parent>/<main-repo>.worktrees` (legacy `CODEX_WORKTREE_DIR` honored) |
| `AGENT_DIRENV`                  | `1` — link + allow `.envrc` per worktree and launch under `direnv exec` (`0` disables) |
| `AGENT_SUPPORT_DIR`             | `<dir-of-ai>/agent.d`, or `../agent.d` in the source clone              |
| `AGENT_NO_AGENTS=1`             | skip the bundled team, its directive, and Codex feature enabling       |
| `AGENT_NO_GPG_SIGN`             | `1` (default): commits unsigned, scoped to the run; `0` keeps signing    |

## Customizing the team

The canonical agent definitions live in `agent.d/agents/*.md` (standard Claude
Code subagent format: YAML frontmatter + system-prompt body) and
`agent.d/codex-agents/*.toml`. To change the team: edit, add, or delete files
there — the change applies to every future run. Mirror any role changes in
`agent.d/AGENTS.codex.md` so the human-readable charter stays in sync.

Edits go in the **source clone**, then `./install.sh -y` to push them to the
installed payload. Editing `<prefix>/agent.d/` directly works too, but the next
install overwrites it.

## File layout

Installed payload — self-contained, versioned, and never on your `PATH`:

```
<prefix>/                    # default: ${XDG_DATA_HOME:-~/.local/share}/ai-kit
├── ai                       # in place by default; `wt` creates a worktree
├── agent-wt                 # wrapper -> ai wt
├── codex-wt                 # wrapper -> ai wt --agent codex
├── claude-wt                # wrapper -> ai wt --agent claude
├── manifest                 # what install.sh created, for a surgical uninstall
├── uninstall.sh
├── VERSION
└── agent.d/
    ├── README.md            # this file
    ├── AGENTS.codex.md      # human-readable team charter (reference)
    ├── DEVLOG.template.md   # logbook scaffold
    ├── agents/              # 7 Claude subagents (.md)  -> .claude/agents/
    │   ├── architect.md   precision-coder.md   critic.md   chronicler.md
    │   └── test-engineer.md   researcher.md   security-auditor.md
    ├── codex-agents/        # 7 Codex subagents (.toml) -> .codex/agents/
    │   ├── architect.toml   precision-coder.toml   critic.toml   chronicler.toml
    │   └── test-engineer.toml   researcher.toml   security-auditor.toml
    └── tests/               # Codex launch and direnv regression suites
```

Only symlinks land in a directory on your `PATH`:

```
<bin-dir>/<cmd>       -> <prefix>/ai            # default: ~/.local/bin/ai
<bin-dir>/<cmd>-wt    -> <prefix>/agent-wt      # --shortcuts only
<bin-dir>/claude-wt   -> <prefix>/claude-wt     # --shortcuts only
<bin-dir>/codex-wt    -> <prefix>/codex-wt      # --shortcuts only
```

In the git repo the four scripts live under `bin/` instead of at the top level;
the launcher finds the adjacent `../agent.d/`. `install.sh` flattens the scripts
into `<prefix>/`, where `ai` finds `agent.d/` beside itself. Both layouts work
without an `AGENT_SUPPORT_DIR` override.

### Codex launch regression tests

```bash
agent.d/tests/codex-launch.sh
AI=/path/to/ai agent.d/tests/codex-launch.sh
```

The suite uses Python's standard library, fake CLIs, and temporary git
repositories. It checks default and explicit launch modes, model and effort
selection with missing or stale caches, workflow instructions with and without
a task, team discovery, and cleanup. It runs offline and makes no model requests.
The separate direnv suite is described above.

## Requirements & safety

Linux and macOS (Apple Silicon and Intel). `install.sh` accepts the system
Bash and BSD utilities on macOS. Existing Homebrew tools take precedence over
system PATH tools; either Homebrew Bash or Apple's Bash works. Missing required
tools produce installation guidance. GNU coreutils are not required.

- **bash 3.2+** and **git 2.31+**. The 2.31 floor is not cosmetic: the launcher
  uses `git rev-parse --path-format=absolute --git-common-dir` to find the
  repository that owns a worktree. (`git worktree move` needs 2.17 and
  `git branch --show-current` needs 2.22, so 2.31 covers everything.)
- The `codex` and/or `claude` CLIs on your `PATH`, recent enough to accept
  `--effort` / `--setting-sources` (Claude) and
  `--dangerously-bypass-approvals-and-sandbox` (Codex). Only `--name` is probed
  before use; the rest are passed unconditionally.
- `python3` (optional for launching): reads supported effort from Codex's model
  catalogue. Without it, or before the first cache exists, Astra still runs at
  `ultra`; other models use the known defaults above or require an explicit
  effort override. Python is required for the Codex regression suite.
- **direnv 2.33+**: the installer ensures this dependency is available. A direct
  source-checkout launch without direnv reports that no environment was loaded.
  `AGENT_DIRENV=0` remains an explicit per-run opt-out.
- git `user.name` / `user.email` set globally — the chronicler commits.
- **Credentials are per-machine and ship with nothing here.** Run `claude` then
  `/login`, and `codex login`, on each new machine.
- These agents run with **no approval prompts and no sandbox**. That's the point
  — but only run them on tasks/repos you trust. In-place mode has **no isolation
  at all**: the agent edits your real working tree and can commit to your current
  branch. Prefer `wt` when the task is risky, exploratory, or long-running.
