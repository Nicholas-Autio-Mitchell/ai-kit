# ai-kit

Run **Claude Code** or **OpenAI Codex** in full-auto mode with a bundled team of
seven specialist subagents — either **in place** on your current branch, or
inside a throwaway **git worktree**.

**Codex defaults to `gpt-6-astra` at `ultra` effort.** Use `codex-wt` or
`ai wt codex` to launch it in a fresh worktree; `ai codex` runs on your current
branch. Claude remains the default agent.

```bash
usage:
  ai [wt|here] [claude|codex] [options] [--] [prompt...]
  ai worktrees [--fix]
  ai update [--check] [--via brew|standalone] [claude|codex]
```

`ai --help` prints the full option list. **Full manual:** `agent.d/README.md`,
also installed at `<prefix>/agent.d/README.md`.

---

## Install

```bash
git clone <this-repo> ai-kit
cd ai-kit
./install.sh
```

The installer runs a preflight, asks **four** questions, and prints exactly what
it did. ai-kit files stay in the two directories you pick. If direnv is missing,
the installer installs it through your package manager; uninstalling ai-kit
leaves that shared dependency installed.

```
Install directory for the tool itself?   [~/.local/share/ai-kit]
Directory on your PATH for the command?  [~/.local/bin]
Command name?                            [ai]
Also install worktree shortcuts?         [y/N]
```

Non-interactive (CI, dotfile bootstraps, or piping into a shell):

```bash
./install.sh -y                                  # all defaults
./install.sh --name aid --shortcuts -y           # pick a name, add shortcuts
./install.sh --prefix /opt/ai-kit --bin-dir ~/bin -y
```

Then sign in once per machine — **no credentials ship with this package**:

```bash
claude          # then: /login
codex login
```

Claude's full-auto disclaimer is also accepted once per machine. Until it is,
`--dangerously-skip-permissions` is vetoed and the session falls back to
`--permission-mode dontAsk` — still unattended, but anything that *would* have
prompted is denied rather than asked. To accept it up front, add to
`~/.claude/settings.json`:

```json
{ "skipDangerousModePermissionPrompt": true }
```

The installer reports this; it never edits your Claude or Codex config.

## Upgrade

**Two unrelated things can be upgraded.** They have separate sections below
because they share no machinery and no command:

| You want to upgrade | Command |
|---|---|
| **ai-kit** — this launcher, the subagent team, the manual | `git pull && ./install.sh -y` |
| **the agent CLIs** — the `claude` and `codex` binaries | `ai update` |

### Upgrading ai-kit itself

From your clone:

```bash
git pull && ./install.sh -y
```

Re-running `install.sh` upgrades in place and drops links from the previous
install that the new one does not recreate (you renamed the command, or turned
shortcuts off). It never touches the agent CLIs.

### Upgrading the agent CLIs — `ai update`

```bash
ai update --check              # read-only: report what is behind, change nothing
ai update                      # upgrade whichever of claude/codex is behind
ai update codex                # just that one
ai update claude --via brew    # assert the method when detection cannot tell
```

`ai update` works out how each CLI was installed and upgrades the two methods it
can drive safely — **Homebrew** and **each CLI's own installer**. Every other
install method is detected, named, and reported with the command to run
yourself; nothing is touched. It needs no repository, runs no agent, never uses
sudo, and **never installs a CLI you do not already have**.

```
checking:  claude, codex
mode:      check only (nothing will be changed)

  TOOL   INSTALLED LATEST  VIA             STATUS
  claude 2.1.296   2.1.296 native:latest   current
  codex  0.162.1   0.162.1 brew-cask:codex current

Everything is up to date.
```

**This is the only part of ai-kit that makes a network call** — one release
lookup per CLI, plus whatever Homebrew does on its own. `AI_UPDATE_OFFLINE=1`
suppresses every version lookup, ai-kit's own HTTP and the `brew outdated` call
alike, so nothing reaches out; each version then reports `unknown`.

`--check` exits 0 when everything is current, 1 when something is out of date,
missing or broken, and 3 when the latest version could not be determined — so
`ai update --check && deploy` cannot go green on a plane. The full exit-code
table is in the manual.

> `update` is also an ordinary English word, so the launcher splits it by shape:
> `ai update --check codex` is the subcommand, while `ai update the README to
> mention X` runs the **agent** on that prompt. The rule, and its corner cases,
> are in the manual.

## Running it

```bash
ai                                                    # interactive, in place
ai          "Add a rate limiter to the API gateway"   # in place, current branch
ai wt       "Refactor the scheduler to use asyncio"   # isolated worktree + branch
ai    codex "Fix the failing auth test"               # in place, GPT-6 Astra, ultra
ai wt codex "Refactor the auth flow"                  # Codex in a new worktree
ai worktrees                                          # audit this repo's worktrees
```

Run with no prompt (`ai`, `ai codex`) to drop into an interactive session with
everything already configured. The options you actually reach for:

| | |
|---|---|
| `-n, --name NAME` | session label; under `wt` it also names the branch and directory |
| `-b, --base REF` | `wt` only: branch from this ref instead of your current branch |
| `--wt` / `--here` | force the mode when the bare word is inconvenient |
| `--` | end option parsing; everything after it is prompt text |

`ai --help` prints the rest, with the environment overrides.

**A first session, in order of increasing commitment.** Start in a repository
you trust — in-place mode edits your real working tree:

```bash
cd ~/src/some-repo

ai worktrees                   # read-only. What does ai-kit make of this repo?
ai update --check              # read-only. Are the CLIs current?

ai "Summarise what this repo does and write it to NOTES.md"
                               # in place: real branch, real files, real commit

ai wt "Add a --version flag"   # isolated: branches off your current branch into
                               # <repo>.worktrees/, prints the merge-back recipe
```

Worktree mode is the one to reach for when the task is risky, exploratory,
long-running, or run in parallel: it cannot touch your branch, and the session
ends by printing the exact `git merge --ff-only` / `git worktree remove`
commands.

**Worktree shortcuts** (opt-in at install time, off by default to keep your
`PATH` clean):

| shortcut | equivalent |
|---|---|
| `<cmd>-wt "…"` | `<cmd> wt "…"` |
| `claude-wt "…"` | `<cmd> wt claude "…"` |
| `codex-wt "…"` | `<cmd> wt codex "…"` |

---

## How it works

Both agents launch with maximum configured reasoning effort, no approval
prompts, and a logbook/commit discipline. Codex's model is explicitly
`gpt-6-astra`; future model releases do not silently change that choice. The
Codex launch contract was first checked against CLI 0.154.0 and **re-verified
against 0.162.1 on 2026-10-12** — every flag the launcher passes
(`--dangerously-bypass-approvals-and-sandbox`, `--search`, `--enable`, `-c`,
`-m`, `-C`) still exists. See the
[official changelog](https://learn.chatgpt.com/docs/changelog).

### The team

Installed into each session as real subagents — `.claude/agents/*.md` for
Claude, `.codex/agents/*.toml` for Codex. Codex receives the workflow through
`developer_instructions` and enables `multi_agent`, including when launched
without an initial prompt.

| Agent | Role |
|---|---|
| `researcher` | Grounds the work in the codebase + external docs before design. |
| `architect` | Big-picture, elegant, minimal system design (before code). |
| `precision-coder` | Detail-oriented implementation: types, correctness, performance. |
| `test-engineer` | Tests, reproduction, coverage, honest verification. |
| `critic` | Skeptical second review loop over every plan and diff. |
| `security-auditor` | Vulnerabilities, unsafe patterns, error handling, edge cases. |
| `chronicler` | `DEVLOG.md` + docs + milestone git commits. The only committer. |

Default loop per chunk of work: `researcher → architect → precision-coder +
test-engineer → critic + security-auditor → revise → chronicler`.

**In-place mode leaves no trace:** the team and a `DEVLOG.md` scaffold are
installed temporarily, hidden from `git status` via `.git/info/exclude`, and
removed when the session ends — including on Ctrl-C.

To change the team, edit `agent.d/agents/*.md` and `agent.d/codex-agents/*.toml`
and re-run `./install.sh`.

### The install pattern

A versioned **payload** directory plus **owned symlinks**. Only symlinks ever
land in a directory on your `PATH`:

```
~/.local/share/ai-kit/          # the payload — self-contained, not on PATH
├── ai  agent-wt  claude-wt  codex-wt
├── agent.d/                    # subagent definitions, libs, manual, tests
├── manifest                    # exactly what was created, for uninstall
├── uninstall.sh
└── VERSION

~/.local/bin/ai  ->  ~/.local/share/ai-kit/ai
```

Three properties fall out of it, and they are the reason for the layout:

- **It cannot clobber another tool.** Before writing anything, the installer
  checks every name it is about to create. A name that exists and is *not*
  already a symlink into the payload is a hard conflict: it reports it, changes
  nothing, and exits non-zero. It also notices when `ai` is already a command on
  your `PATH` and suggests a different name instead of shadowing it.
- **The command name is yours to choose.** The launcher resolves its own
  location through symlinks and looks for `agent.d/` beside itself, so a symlink
  named anything at all works. `--name` is a real knob, not a cosmetic one.
- **Uninstall is surgical.** `uninstall.sh` removes only what `manifest`
  records, and only while each entry is still a symlink into the payload. A name
  you have since taken over with your own tool is reported and left alone.

### direnv

The installer reuses an existing direnv, and installs one through your package
manager if it is missing (Homebrew on macOS; `apt-get`, `dnf`, `yum`, `pacman`,
`zypper` or `apk` on Linux, with sudo only where the package manager needs it).
It never bootstraps Homebrew itself.

Both platforms then use the same workflow: review the project's `.envrc`, run
`direnv allow .` once, then launch. Existing trust propagates into the worktree
and `direnv exec` supplies the agent's environment. Blocked or broken
environments are reported, never silently allowed. `AGENT_DIRENV=0` disables
the integration for a run. Shell hooks are not needed by ai-kit; the installer
leaves your shell files alone. The manual has the trust model, the symlink
trap, and the whitelist alternative.

### What `ai update` does

1. **Classify, touching nothing.** For each CLI it resolves the binary
   (`AI_KIT_CLAUDE_BINARY` / `AI_KIT_CODEX_BINARY` if set, else `command -v`),
   then asks, in this order: does a Homebrew installation own this path? is it
   under a `node_modules/`? is it under `$HOME`? Homebrew is asked **first**,
   and by querying `brew --prefix`, `brew --cellar` and `brew --caskroom`
   rather than by matching hardcoded paths — so Homebrew at any prefix works,
   including Linuxbrew at `/home/linuxbrew/.linuxbrew`, a per-user
   `~/.linuxbrew`, and an arbitrary prefix with spaces in it. On a machine with
   several brews, the one that owns the binary is the one that upgrades it.
2. **Print the whole plan**, including the rows it refuses to touch, before the
   first byte is downloaded.
3. **Act**, then **verify** by re-reading `--version`. A command that reports
   success without changing the version is reported as a failure, not a win —
   usually a second copy earlier on your `PATH`, which it then lists for you.

Latest versions come from the vendors' public release endpoints over HTTPS. The
`npm` binary is never invoked and node is never required; `registry.npmjs.org`
is read only as a version oracle. For a Homebrew install the oracle is
`brew outdated --json=v2` instead.

## Requirements

Linux and macOS, including Apple Silicon and Intel Macs. The installer checks
the prerequisites and tells you what is missing. On macOS it searches existing
Homebrew tools first, then tools on your system PATH. Both Homebrew Bash and
Apple's bundled Bash work; GNU coreutils are not required. If neither source
provides a required tool, installation stops with setup instructions.

| | |
|---|---|
| **bash** | 3.2 or newer (included with macOS) |
| **git** | **2.31 or newer** — the launcher uses `git rev-parse --path-format=absolute` |
| **claude** and/or **codex** | at least one CLI on your `PATH` |
| `python3` | *optional for launching* — reads the selected Codex model's supported effort; required by the Python test suites |
| `direnv` | **2.33+** — installed automatically if missing; loads project environments |
| `curl` or `wget` | *optional* — only `ai update` uses them; without either, every version lookup reports `unknown` |
| git `user.name` / `user.email` | set globally; the chronicler agent commits |

On macOS, install Git with `xcode-select --install`, or use `brew install git`.
The installer prints PATH setup instructions for your shell (including zsh).

Ubuntu, if git is older than 2.31:

```bash
sudo add-apt-repository ppa:git-core/ppa && sudo apt update && sudo apt install git
```

If your distribution only packages direnv older than 2.33 (Ubuntu 24.04, for
example), install a current one using
[direnv's instructions](https://direnv.net/docs/installation.html) before
running the ai-kit installer — 2.33 is the floor for its
[JSON status API](https://direnv.net/CHANGELOG.html).

## What is supported

- **Platforms:** Linux and macOS (Apple Silicon and Intel), Bash 3.2 and newer.
- **Agents:** `claude` and `codex`, in place or in a worktree, with or without
  an initial prompt.
- **Command name:** anything you choose at install time.
- **Homebrew at any prefix**, for both tool discovery and `ai update`.

`ai update` upgrades **exactly two** methods — Homebrew, in either of its
package flavours, and the CLI's own installer:

| Installed via | Reported as | `ai update` runs |
|---|---|---|
| Homebrew cask | `brew-cask:<token>` | `brew upgrade --cask -- <token>` |
| Homebrew formula | `brew-formula:<name>` | `brew upgrade --formula -- <name>` |
| The CLI's own install script | `native` / `native:<channel>` | `claude update` / `codex update` |

Homebrew is driven directly rather than delegated to the CLI, because the CLIs
get it wrong: a Homebrew-managed Claude answers `claude update` with "Claude is
up to date!" and does nothing, and Codex's own updater only recognises Homebrew
at the two default macOS prefixes.

## What is not supported

Everything below is **detected, named in the report, and left alone**, with the
command you can run yourself:

| Installed via | Reported as | Why not |
|---|---|---|
| npm, pnpm, yarn or bun global | `npm-global:<pkg>` | four managers, four global roots and four failure modes; getting one wrong installs a *second* copy beside yours |
| apt / dnf / apk (distro package) | `unknown` | needs root, and ai-kit never uses sudo — not even offered |
| Anywhere outside `$HOME` that no Homebrew claims | `unknown` | neither of the two drivable methods owns it |

Also not supported, by design:

- **ai-kit never installs a missing CLI.** A missing `claude`/`codex` is
  reported with the vendor's install command, and `ai update` exits 1.
- **`claude install` is never run**, anywhere: it lays a second, native
  installation down beside a package-managed one.
- **No sudo**, in any path.
- **`AI_KIT_*_BINARY` never falls back.** Set but not executable is a hard error
  for that tool — a user who names one binary must not get a different one
  upgraded.
- **`codex-wt update` and `agent-wt update` do not reach the subcommand.** The
  wrappers pass `wt` first, so `codex-wt update` is a worktree launch on the
  prompt "update", and `agent-wt update` stops with "`update` runs no agent and
  cuts no worktree". Run `ai update`.
- **Windows outside a Linux environment.** The launcher is Bash.

## Safety

These agents run with **no approval prompts and no sandbox**. That is the point,
but it means you should only point them at tasks and repositories you trust.

- **In-place mode has no isolation.** The agent edits your real working tree and
  may commit to your current branch. It is told to leave pre-existing
  uncommitted changes alone and to stage explicit paths, never `git add -A` —
  but it is still your real branch. Use `wt` for anything risky, exploratory,
  long-running, or run in parallel.
- **Push, force-push, rebase, `reset --hard`, branch switching and remote/config
  changes are forbidden** in the guardrails. Commits stay local.
- **Commit signing is off by default**, scoped to the run via `GIT_CONFIG_*` so
  your repo's git config is never modified. Set `AGENT_NO_GPG_SIGN=0` to keep
  signing (you may then be prompted for a passphrase mid-run).
- **direnv trust is propagated, never created.** A worktree's `.envrc` is
  blessed only when it is a symlink to, or byte-identical with, one you have
  already allowed. In place, `direnv allow` is never called at all. See the
  manual for the full threat model — including what the claim does *not* cover.

## Configuration

All run-time tuning is environment variables — nothing to configure at install
time beyond the four questions.

| Variable | Default |
|---|---|
| `AGENT_CLAUDE_MODEL` | `opus` (alias → latest Opus; `claude-opus-5[1m]` for 1M context) |
| `AGENT_CLAUDE_EFFORT` | `max` (empty inherits `effortLevel` from your settings) |
| `AGENT_CLAUDE_PERMISSION_MODE` | `dontAsk` |
| `AGENT_CODEX_MODEL` | `gpt-6-astra`, independent of cache ranking |
| `AGENT_CODEX_EFFORT` | selected model's highest advertised effort; Astra fallback is `ultra` |
| `AGENT_CODEX_TIER` | `fast` (empty omits the override and inherits Codex config) |
| `AGENT_WORKTREE_DIR` | `<main-repo-parent>/<main-repo>.worktrees` |
| `AGENT_DIRENV` | `1` (`0` disables direnv integration entirely) |
| `AGENT_NO_AGENTS` | `0` (`1` skips the bundled team, its directive, and Codex feature enabling) |
| `AGENT_NO_GPG_SIGN` | `1` — commits unsigned, scoped to the run, so auto-commits never block on a passphrase |
| `AGENT_CLAUDE_AUTOUPDATE` | `0` — Claude's *background* auto-updater is off for the session, so it cannot replace its own binary mid-run or race `ai update`; `1` keeps your own behaviour |

`ai update` only:

| Variable | Default |
|---|---|
| `AGENT_UPDATE_TIMEOUT` | `900` seconds per upgrade; `0` removes the clock — needed when a non-default Homebrew prefix cannot use bottles and builds from source |
| `AGENT_UPDATE_CHANNEL` | *(empty)* — force Claude's release channel: `stable` or `latest` |
| `AI_UPDATE_OFFLINE` | `0` (`1` makes `ai update` touch no network at all) |
| `AI_KIT_CLAUDE_BINARY` | *(empty)* — inspect and upgrade **this** binary instead of the one on `PATH`. Set but unusable is an error, never a fallback |
| `AI_KIT_CODEX_BINARY` | *(empty)* — as above, for `codex` |

```bash
AGENT_CLAUDE_MODEL=sonnet ai "Rename these variables"
AGENT_DIRENV=0 ai wt --base origin/pr-1234 "Review this PR"
AGENT_UPDATE_TIMEOUT=0 ai update codex       # source build, no clock
```

The full table, with the reasoning behind each default, is in
`agent.d/README.md`.

## Tests

```bash
agent.d/tests/install.sh            # offline install/upgrade/uninstall coverage
agent.d/tests/dependencies.sh       # offline package-manager and failure tests
agent.d/tests/codex-launch.sh       # offline; requires python3, bash and git
agent.d/tests/direnv-worktree.sh    # also requires direnv
agent.d/tests/update.sh             # offline 'ai update'; CLIs, brew and the
                                    # network are all fakes
```

Fake `claude`/`codex` binaries record launch arguments and environment in
temporary git repositories. The Codex suite checks launch modes, model and
effort selection, preloaded instructions, team discovery, and cleanup without
making model requests. The direnv suite also redirects its trust store via
`XDG_DATA_HOME`. The update suite fakes Homebrew, the agent CLIs and the network
seam, and asserts that no real prefix is ever named and that `sudo` is never
invoked. All of them find the launcher relative to themselves and accept
`AI=/path/to/ai` to test another copy. CI runs these suites on Linux and macOS,
including the system and Homebrew Bash on macOS.

## Uninstall

```bash
~/.local/share/ai-kit/uninstall.sh          # or: ./uninstall.sh from the clone
```

Removes the payload and the symlinks it recorded. Your `~/.claude/` and
`~/.codex/` settings and credentials are never touched, and neither are the
agent CLIs themselves.

## Layout of this repo

```
├── install.sh            # preflight, four questions, payload + symlinks, manifest
├── uninstall.sh          # manifest-driven, refuses to remove anything else
├── VERSION
├── DEVLOG.md             # the project logbook (what/why/how verified)
├── bin/                  # the launcher and its wrappers (installed to <prefix>/)
│   ├── ai
│   ├── agent-wt          # -> ai wt
│   ├── claude-wt         # -> ai wt --agent claude
│   └── codex-wt          # -> ai wt --agent codex
└── agent.d/              # installed to <prefix>/agent.d/
    ├── README.md         # the full manual
    ├── AGENTS.codex.md   # human-readable team charter
    ├── DEVLOG.template.md
    ├── agents/           # 7 Claude subagents  -> .claude/agents/*.md
    ├── codex-agents/     # 7 Codex subagents   -> .codex/agents/*.toml
    ├── lib/              # platform, paths, dependencies, and 'ai update'
    └── tests/
```
