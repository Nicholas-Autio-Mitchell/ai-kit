# ai

Launch an AI coding agent (**Codex** or **Claude**) in **full-auto mode** with a
bundled **team of specialist subagents** — either **in place** on your current
branch, or inside a throwaway **git worktree**.

```
ai [wt|here] [claude|codex] [options] [--] [prompt...]
ai worktrees [--fix]
ai update [--check] [--via brew|standalone] [claude|codex]
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

**Update (`update`)** — `ai update` upgrades the **agent CLIs** (`claude`,
`codex`). It runs no agent and needs no repository, and it is the only part of
this package that makes a network call. Full detail in *Updating the agent CLIs*
below. It is not how you upgrade **ai-kit**: for that, `git pull &&
./install.sh -y` in your clone. The two share no command and no machinery.

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

The launch contract was first checked against **Codex CLI 0.154.0**, listed in
the [official September 9, 2026 changelog](https://learn.chatgpt.com/docs/changelog),
and **re-verified against 0.162.1 on October 12, 2026**: every flag the launcher
passes — `--dangerously-bypass-approvals-and-sandbox`, `--search`, `--enable`,
`-c`, `-m`, `-C` — still exists on that release. The bundled catalogue and the
local cache inspected on September 12, 2026 advertise Astra `ultra` as maximum
reasoning and delegation effort. The checks cover CLI argument parsing and
assembled instructions, without sending an inference request.

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
ai update [--check] [--via brew|standalone] [claude|codex]

modes:
  (default)          work in place, on the current branch
  wt                 work in a fresh worktree + branch
  here               work in place, on the current branch
  worktrees          audit this repo's worktrees + direnv (no agent)
  update             upgrade the agent CLIs (no agent, no repository needed)

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
      --check        'update' only: report what is behind and change nothing
      --via METHOD   'update' only, and one named tool only: assert how that CLI
                     was installed (brew | standalone) instead of detecting it
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
  ai update --check             # are claude and codex current? changes nothing
  ai update codex               # upgrade just codex, if it is behind
```

`-h`/`--help` prints the full manual on stdout (pipe it to `less`); a mistyped
flag prints only a short usage hint on stderr.

The bare words `wt`, `here`, `worktrees`, `update`, `claude` and `codex` are only
recognized while they *lead* the argument list — everything from the first other
word on is the prompt.
So `ai claude wt ...` keeps `wt` in the prompt, and a task that genuinely
starts with one of those words just needs quoting:
`ai 'codex is failing to build'` runs Claude on that prompt.

`update` gets a sharper rule than the rest, because it is also ordinary English:
see *When `update` is a subcommand and when it is a prompt* below.

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

## Updating the agent CLIs (`ai update`)

```
ai update [--check] [--via brew|standalone] [claude|codex]
```

This upgrades the **agent CLIs** — the `claude` and `codex` binaries. It is not
how you upgrade **ai-kit**; that is `git pull && ./install.sh -y` in your clone,
and the two share no command and no code path.

With no argument it looks at both CLIs and upgrades whichever is behind. Name
one to narrow it. `--check` makes the whole run read-only. It runs no agent, and
it is dispatched before the launcher's repository lookup, so it works from any
directory — no repository required.

```bash
ai update --check              # report only; changes nothing
ai update                      # upgrade whichever CLI is behind
ai update codex                # just that one
ai update claude --via brew    # assert the method when detection cannot tell
```

Three things it never does, in any path: **use sudo** (not even offered),
**install a CLI you do not already have**, and **run `claude install`** — which
would lay a second, native installation down beside a package-managed one.

### What it drives, and what it only reports

Exactly two methods are upgraded — Homebrew, in either of its package flavours,
and the CLI's own installer:

| Installed via | Reported as | `ai update` runs |
|---|---|---|
| Homebrew cask | `brew-cask:<token>` | `brew upgrade --cask -- <token>` |
| Homebrew formula | `brew-formula:<name>` | `brew upgrade --formula -- <name>` |
| The CLI's own install script | `native`, or `native:<channel>` for Claude | `claude update` / `codex update` |

Everything else is detected, named in the report, and left alone, with the
command you can run yourself:

| Installed via | Reported as | Why not |
|---|---|---|
| npm, pnpm, yarn or bun global | `npm-global:<pkg>` | four managers with four global roots, four upgrade verbs and four failure modes; getting any of it wrong installs a *second* copy beside the one you have |
| apt / dnf / apk | `unknown` | needs root, and there is no sudo here |
| Outside `$HOME`, claimed by no Homebrew | `unknown` | neither drivable method owns it |

**Why only two.** They are the two that can be driven correctly *and verified*.
Reporting is cheap and cannot install a duplicate CLI; a half-right upgrade
driver can.

**Why Homebrew is driven directly** rather than delegated to the CLI's own
updater: a Homebrew-managed Claude answers `claude update` with "Claude is up to
date!" and changes nothing, and Codex's own updater recognises Homebrew only by
testing whether the executable path starts with `/opt/homebrew` or `/usr/local`
on macOS — so a Linuxbrew or non-default-prefix install falls through to "could
not detect the installation method" and bails.

### How an installation is classified

Per tool, in this order:

1. **The binary.** `AI_KIT_CLAUDE_BINARY` / `AI_KIT_CODEX_BINARY` if set,
   otherwise `command -v`. An override must be a *path*, not a bare name, and
   must be executable; set-but-unusable is a hard error for that tool and
   **never** a fall back to `PATH`. Someone who names one binary must not get a
   different one upgraded.
2. **Resolve symlinks** to the real file.
3. **Homebrew — first, on every platform.** The containment test is every tree
   brew itself reports: `brew --prefix`, `brew --cellar`, `brew --caskroom`.
   Never a hardcoded or inferred root, which is why Homebrew at *any* prefix
   works for free: `/opt/homebrew`, `/usr/local`, Linuxbrew at
   `/home/linuxbrew/.linuxbrew`, a per-user `~/.linuxbrew`, or an arbitrary
   prefix with spaces in it. On a machine with more than one brew, the one that
   *owns* the binary is the one that upgrades it.
4. Under a `node_modules/` → `npm-global`. Reported, never touched. The four
   Node package managers are deliberately not told apart: the answer would
   change nothing, and asking would require node to be installed just to produce
   a message.
5. Under `$HOME` → `standalone`.
6. Otherwise → `unknown`. Reported, never touched.

Step 3 must precede step 5, and that ordering is the whole reason this works on
Linux: a per-user Linuxbrew lives *inside* `$HOME`, so a `$HOME`-first ladder
classifies it as a native install and then runs `claude update` — which a
Homebrew-managed Claude ignores while reporting success.

For Claude the release **channel** matters, because comparing a stable-channel
user against `latest` nags them forever. Under Homebrew the cask token is the
channel (a token ending in `@latest` tracks latest, anything else stable);
otherwise it is read from `claude doctor`. `AGENT_UPDATE_CHANNEL=stable|latest`
forces it. Codex has one channel, so its doctor is never called.

### Reading the report

The whole plan is printed — including the rows it refuses to act on — before the
first byte is downloaded:

```
checking:  claude, codex
mode:      check only (nothing will be changed)

  TOOL   INSTALLED LATEST  VIA             STATUS
  claude 2.1.296   2.1.296 native:latest   current
  codex  0.162.1   0.162.1 brew-cask:codex current

Everything is up to date.
```

| STATUS | Means |
|---|---|
| `current` | installed matches the latest version found |
| `ahead` | installed is newer than anything found; left alone |
| `OUTDATED` | behind, and `ai update` can drive the upgrade |
| `OUT OF DATE (not touched)` | behind, but installed by a method that is only reported |
| `unknown` | the latest version could not be determined |
| `NOT INSTALLED` | no such binary — and ai-kit will not install one |
| `BROKEN` | the binary, or an `AI_KIT_*_BINARY` override, does not resolve to an executable file |

`VIA` is the only column allowed to overflow, so it is middle-ellipsised into
whatever is left of 80 columns (`npm-global:@.../claude-code`). Nothing is lost:
every row that is cut is repeated in full in the explanation printed beneath the
table, which is also where the pasteable command lives.

After a real upgrade the tool **re-reads `--version` and reports the outcome**,
not the prediction. A command that exits 0 without changing the version is a
failure, not a win — almost always a second copy earlier on your `PATH`, which
it then lists for you. If the version cannot be read at all afterwards, it says
so rather than claiming success.

### Exit codes

| Exit | Meaning |
|---|---|
| `0` | nothing left to do: everything current, ahead, or successfully upgraded |
| `1` | something actionable and unresolved — out of date (including the rows it refuses to touch), an upgrade that failed, a CLI not installed, or a broken binary |
| `2` | usage error |
| `3` | the latest version could not be determined for at least one tool, and nothing else was actionable |

Precedence is `2 > 1 > 3 > 0`. `3` exists so that `ai update --check && deploy`
cannot go green on a plane: "I could not find out" is reported as its own
answer, never as "up to date".

### When `update` is a subcommand, and when it is a prompt

`update` is the one bare word that also reads as ordinary English, so it does
not use the plain "a leading bare word wins" rule. The split is structural: bare
words are prompt material — that is this CLI's entire premise — whereas flags
never are, since the parser already rejects any unknown `-*`. So **one
recognised update flag commits the whole line to the subcommand**, and from
there strictness is free:

```
ai update                          -> the subcommand
ai update --check codex            -> the subcommand
ai update the README to mention X  -> a prompt; the agent runs
ai update codex extra              -> a prompt (words only)
ai update --check extra            -> error: 'extra' after a flag
```

A `--` after `update` is literal prompt text, exactly as it is in
`ai fix -- the bug`: by then the line has already been classified as a prompt,
and `--` only ends option parsing in leading option position. So
`ai update -- the README` is the prompt `update -- the README`. To force a
prompt either way, quote it or put `--` first:

```bash
ai -- update anything
ai 'update anything'
```

After an agent word it is always prompt text, like every other bare word:
`ai codex update` runs Codex on the prompt "update".

**The `*-wt` wrappers do not reach the subcommand**, and nothing tries to rescue
them — they pass `wt` themselves, so their argument order decides what `update`
means first:

| You type | It becomes | What happens |
|---|---|---|
| `codex-wt update` | `ai wt --agent codex update` | the agent is already set, so `update` is **prompt** text: an ordinary worktree launch on the prompt "update" (outside a repository, the worktree check rejects it first) |
| `agent-wt update` | `ai wt update` | no agent yet, so `update` **is** the subcommand — and the bare `wt` then fails the guard: *"'update' runs no agent and cuts no worktree; drop 'wt'/'here'."* |

Updating the CLIs from a worktree wrapper is not a thing. Run `ai update`.

### Forcing the method, pinning the binary

`--via brew|standalone` overrides the classification **and nothing else**. It
applies to one named tool (`ai update claude --via brew`), because asserting a
method for "whatever you find" is not an assertion. `--via brew` with no usable
Homebrew is an error rather than a guess. `--via standalone` relaxes exactly one
refusal — "outside `$HOME` means unknown", which is precisely the claim you are
making — and relaxes neither the no-sudo rule nor the ban on `claude install`.
Neither form can conjure a binary: a missing or broken install stays as the
ladder found it and is reported, not repaired.

`AI_KIT_CLAUDE_BINARY` / `AI_KIT_CODEX_BINARY` point the whole run — detection,
version read, upgrade and post-upgrade verification — at one specific binary:

```bash
AI_KIT_CODEX_BINARY=/opt/x/bin/codex ai update codex
```

### Network, offline, and timeouts

**`ai update` is the only part of this package that makes a network call.** One
release lookup per CLI, plus whatever Homebrew does on its own:

- Claude: `downloads.claude.ai/claude-code-releases/<channel>`, falling back to
  the npm registry's `dist-tags` document.
- Codex: the npm registry's `dist-tags` document.
- Either, under Homebrew: `brew outdated --json=v2` instead.

The registry is read **only as a version oracle**, over plain HTTPS. The `npm`
binary is never invoked and node is never required — do not read those URLs as
npm support. Every response body is capped (64 KB) and every version string is
validated before it can reach the report, so an error page, a captive-portal
redirect or a region block degrades to `unknown` rather than being mined for
digits.

| Variable | Default | Effect |
|---|---|---|
| `AI_UPDATE_OFFLINE` | `0` | `1` suppresses every version lookup — ai-kit's HTTP and the `brew outdated` call alike; each then reports `unknown` |
| `AGENT_UPDATE_TIMEOUT` | `900` | seconds a mutating upgrade may run before it is killed; `0` removes the clock |
| `AGENT_UPDATE_CHANNEL` | *(empty)* | force Claude's channel: `stable` or `latest` |
| `AI_UPDATE_FETCH_CMD` | *(empty)* | **test seam.** A command line handed the URL as its last argument, which must print the body. It replaces the HTTP client entirely. `AI_UPDATE_OFFLINE=1` is how you say "no network" |

A Homebrew prefix that is not the default **cannot use bottles and builds from
source**, which legitimately runs past fifteen minutes. That is what
`AGENT_UPDATE_TIMEOUT=0` is for, and the timeout message says so. When a timeout
does fire, the run reports that the upgrade may or may not have finished — it
does not guess.

Without `curl` or `wget` (and without `AI_UPDATE_FETCH_CMD`), every lookup
degrades to `unknown`, which the report states plainly.

> **`AI_UPDATE_OFFLINE=1` covers the whole subcommand, not just our own HTTP.**
> It gates ai-kit's fetch seam *and* the `brew outdated --json=v2` lookup, because
> brew is a separate program that refreshes its tap on its own schedule — gating
> only the former would have let the flag go quiet on a native install while a
> brew-managed one still reached out. Every suppressed lookup degrades to
> `unknown`, never to a guess, which is what makes the stronger claim safe.
>
> It stops *lookups*, not upgrades: `ai update` offline reports `unknown` and
> changes nothing, but an explicit `--via` upgrade still runs its package
> manager, which will of course use the network.

### Where the code lives

`agent.d/lib/update.sh`, sourced **lazily** — only once `bin/ai`'s argument
grammar has already decided this run is an `update` subcommand. That is
load-bearing rather than tidy: `bin/ai` runs under `set -euo pipefail`, so a
truncated or syntactically broken lib sourced eagerly would abort *every* agent
launch. Sourced there, the worst it can do is degrade `ai update` to a clean
exit 2. The grammar itself therefore stays in `bin/ai` and never moves into the
lib.

### `ai update` regression tests

```bash
agent.d/tests/update.sh
UPDATE_TEST_BASH=/bin/bash agent.d/tests/update.sh      # pick a Bash
agent.d/tests/update.sh -v -k linuxbrew                 # unittest arguments
```

Offline: the agent CLIs, Homebrew, `sudo` and the network seam are all fakes,
and neither `curl` nor `wget` is ever placed on the fixture `PATH`. Containment
is the point of the file — an early manual test upgraded the developer's real
Codex CLI — so four independent guards each suffice on their own: `uname`
answers `Linux` so the Homebrew PATH preference never engages, `platform.sh` is
replaced with a neutered fixture, the fixture `PATH` is built only from
explicitly symlinked utilities with the host `PATH` never appended, and every
fake logs its argv so the suite can fail any run that names a real prefix. The
fake `sudo` log must be empty in every single test, and the module fingerprints
the host's real `claude`/`codex`/`brew` before the first test and fails the run
if any of them moved.

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

`ai update` only — see *Updating the agent CLIs* above for the detail:

| Variable                        | Default                                                                 |
|---------------------------------|-------------------------------------------------------------------------|
| `AGENT_UPDATE_TIMEOUT`          | `900` seconds per mutating upgrade; `0` removes the clock (source builds) |
| `AGENT_UPDATE_CHANNEL`          | empty — force Claude's release channel: `stable` or `latest`             |
| `AI_UPDATE_OFFLINE`             | `0` — `1` makes `update` touch no network at all                         |
| `AI_UPDATE_FETCH_CMD`           | empty — **test seam**: replaces the HTTP client entirely                  |
| `AI_KIT_CLAUDE_BINARY`          | empty — inspect and upgrade *this* binary; set-but-unusable is an error, never a `PATH` fallback |
| `AI_KIT_CODEX_BINARY`           | empty — as above, for `codex` (`AI_KIT_`, not `AGENT_`, by request)       |

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
    ├── lib/                 # sourced by the launcher
    │   ├── platform.sh      # macOS Homebrew tool preference
    │   ├── paths.sh         # ai_realpath — the only symlink resolver allowed
    │   ├── dependencies.sh  # installer-side package-manager handling
    │   └── update.sh        # 'ai update'; sourced lazily, only for that run
    └── tests/               # install, dependencies, Codex launch, direnv, update
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
- `curl` or `wget` (optional): used by `ai update` alone, and by nothing else in
  the package. Without either, every version lookup degrades to `unknown` and
  the report says so.
- git `user.name` / `user.email` set globally — the chronicler commits.
- **Credentials are per-machine and ship with nothing here.** Run `claude` then
  `/login`, and `codex login`, on each new machine.
- These agents run with **no approval prompts and no sandbox**. That's the point
  — but only run them on tasks/repos you trust. In-place mode has **no isolation
  at all**: the agent edits your real working tree and can commit to your current
  branch. Prefer `wt` when the task is risky, exploratory, or long-running.
- `ai update` is the **only** part of this package that makes a network call,
  and `AI_UPDATE_OFFLINE=1` removes even that. It never uses sudo, never
  installs a CLI you do not already have, and never runs `claude install`.
- **Python is required for the install, dependency, Codex-launch and update test
  suites** (the direnv suite is pure Bash, and also needs `direnv`). None of
  them is needed to use the tool.
