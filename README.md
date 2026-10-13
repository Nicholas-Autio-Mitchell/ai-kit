# ai-kit

Run **Claude Code** or **OpenAI Codex** in full-auto mode with a bundled team of
seven specialist subagents — either **in place** on your current branch, or
inside a throwaway **git worktree**.

**Codex defaults to `gpt-6-astra` at `ultra` effort.** Use `codex-wt` or
`ai wt codex` to launch it in a fresh worktree; `ai codex` runs on your current
branch. Claude remains the default agent.

Launch command:
```bash
usage:
  ai [wt|here] [claude|codex] [options] [--] [prompt...]
  ai worktrees [--fix]
```

Examples:
```bash
ai                                                    # in place, into session waiting for prompt
ai wt                                                 # new git worktree
ai          "Add a rate limiter to the API gateway"   # in place, current branch
ai wt       "Refactor the scheduler to use asyncio"   # isolated worktree + branch
ai    codex "Fix the failing auth test"               # in place, GPT-6 Astra, ultra
ai wt codex "Refactor the auth flow"                  # Codex in a new worktree
ai worktrees                                          # audit this repo's worktrees
```

These launch with maximum configured reasoning effort, no approval prompts, and
a logbook/commit discipline. Codex's model is explicitly `gpt-6-astra`; future
model releases do not silently change that choice. The Codex launch contract
was checked against CLI **0.154.0**, the September 9, 2026 release listed in
the [official changelog](https://learn.chatgpt.com/docs/changelog).

Use `ai --help` for full list of options.

---

## Install

```bash
git clone <this-repo> ai-kit
cd ai-kit
./install.sh
```

The installer runs a preflight, asks **four** questions, and prints exactly what
it did. Nothing is written outside the two directories you pick.

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
| `python3` | *optional for launching* — reads the selected Codex model's supported effort; required by the Codex regression suite |
| `direnv` | *optional* — lets worktree sessions inherit your project environment |
| git `user.name` / `user.email` | set globally; the chronicler agent commits |

On macOS, install Git with `xcode-select --install`, or use `brew install git`.
The installer prints PATH setup instructions for your shell (including zsh).

Ubuntu, if git is older than 2.31:

```bash
sudo add-apt-repository ppa:git-core/ppa && sudo apt update && sudo apt install git
```

## The install pattern

A versioned **payload** directory plus **owned symlinks**. Only symlinks ever
land in a directory on your `PATH`:

```
~/.local/share/ai-kit/          # the payload — self-contained, not on PATH
├── ai  agent-wt  claude-wt  codex-wt
├── agent.d/                    # subagent definitions, manual, logbook template
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

Re-running `install.sh` upgrades in place and drops links from the previous
install that the new one does not recreate (renamed the command, turned
shortcuts off).

**Worktree shortcuts** (opt-in, off by default to keep your `PATH` clean):

| shortcut | equivalent |
|---|---|
| `<cmd>-wt "…"` | `<cmd> wt "…"` |
| `claude-wt "…"` | `<cmd> wt claude "…"` |
| `codex-wt "…"` | `<cmd> wt codex "…"` |

## After installing

Credentials are per-machine and **none ship with this package**. Sign in once:

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

## Usage

```
ai [wt|here] [claude|codex] [options] [--] [prompt...]
ai worktrees [--fix]

modes:
  (default)          work in place, on the current branch
  wt                 work in a fresh worktree + branch, then print the merge-back recipe
  here               work in place, on the current branch
  worktrees          audit this repo's worktrees + direnv (runs no agent)

options:
  -a, --agent NAME   codex or claude (usually given as a bare word instead)
      --wt/--here    force worktree / in-place mode
  -b, --base REF     worktree only: base ref to branch from (default: current branch)
  -n, --name NAME    session label; under 'wt' it also names the branch/worktree
      --fix          'worktrees' only: apply the repairs instead of listing them
  -h, --help         full manual: modes, examples, environment overrides
```

Run with no prompt (`ai`, `ai codex`) to drop into an interactive session with
everything already configured.

**Full manual:** `agent.d/README.md`, also installed at
`<prefix>/agent.d/README.md` and linked from `ai --help`.

## The team

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

```bash
AGENT_CLAUDE_MODEL=sonnet ai "Rename these variables"
AGENT_DIRENV=0 ai wt --base origin/pr-1234 "Review this PR"
```

The full table, with the reasoning behind each default, is in
`agent.d/README.md`.

## Tests

```bash
agent.d/tests/install.sh            # offline install/upgrade/uninstall coverage
agent.d/tests/codex-launch.sh       # offline; requires python3, bash and git
agent.d/tests/direnv-worktree.sh    # also requires direnv
```

Fake `claude`/`codex` binaries record launch arguments and environment in temporary
git repositories. The Codex suite checks launch modes, model and effort
selection, preloaded instructions, team discovery, and cleanup without making
model requests. The direnv suite also redirects its trust store via
`XDG_DATA_HOME`. Both find the launcher relative to themselves and accept
`AI=/path/to/ai` to test another copy.

## Updating

```bash
git pull && ./install.sh -y
```

## Uninstall

```bash
~/.local/share/ai-kit/uninstall.sh          # or: ./uninstall.sh from the clone
```

Removes the payload and the symlinks it recorded. Your `~/.claude/` and
`~/.codex/` settings and credentials are never touched.

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

## Layout of this repo

```
├── install.sh            # preflight, four questions, payload + symlinks, manifest
├── uninstall.sh          # manifest-driven, refuses to remove anything else
├── VERSION
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
    └── tests/
```
