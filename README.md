# ai-kit

`ai` runs your `claude` (Claude Code) or `codex` (OpenAI Codex) CLI in full-auto
mode with a team of seven specialist subagents, either in place on your current
branch or on a new branch in its own git worktree. You install, update and log
in to the CLI yourself; ai-kit never does.

> **No sandbox, no approval prompts.** In place, the agent edits your working
> tree and can commit to your branch. Use `wt` for anything risky, and run `ai`
> only on repositories you trust.

## Install

```bash
git clone https://github.com/Nicholas-Autio-Mitchell/ai-kit.git && cd ai-kit && ./install.sh
```

The installer asks for the payload directory (default
`${XDG_DATA_HOME:-~/.local/share}/ai-kit`), a directory on your `PATH`
(`~/.local/bin`) and the command name (`ai`). `-y` accepts the defaults;
`--prefix DIR`, `--bin-dir DIR` and `--name NAME` set them. Re-run it to upgrade
in place; `./install.sh --uninstall` (or `<prefix>/uninstall.sh`) removes it.

Requires Linux or macOS, bash (macOS `/bin/bash` 3.2 works), git 2.31+, and
`claude` and/or `codex` on your `PATH`. Optional: direnv 2.33+, and python3
(lets Codex pick the model's highest effort from its model catalogue).

## Usage

```
ai [wt] [claude|codex] [-b REF] [-n NAME] [--] [prompt...]
ai worktrees [--fix]
```

```bash
ai "Add a rate limiter to the API"         # Claude, in place
ai codex "Fix the failing auth test"       # Codex, in place
ai                                         # interactive session, same setup
ai wt -n auth "Refactor the login flow"    # new branch + worktree, named auth
ai wt codex -b main "Start the v2 API"     # Codex, in a worktree cut from main
ai worktrees --fix                         # audit and repair this repo's worktrees
AGENT_CLAUDE_MODEL=sonnet ai "Fix a typo"  # override a default for one run
```

- **In place** (default) runs at the repository root, on your current branch.
- **`wt`** cuts a new branch from `-b REF` (default: your current branch) into a
  worktree under `<repo-parent>/<repo>.worktrees/`, and prints the commands to
  merge it back when the session ends.
- **`-n NAME`** names the Claude session, and with `wt` also the branch and
  worktree.
- **`ai worktrees`** audits this repo's worktrees and their direnv state;
  `--fix` applies the safe repairs.
- `claude` is the default agent. Put `--` before a prompt that starts with `-`.

## What a run does

- **Claude:** `--model opus` (the latest Opus), `--effort max`, no permission
  prompts (`--dangerously-skip-permissions`, falling back to
  `--permission-mode dontAsk`), and `--setting-sources user,project,local`.
- **Codex:** `gpt-6-astra` at its highest supported reasoning effort, the fast
  service tier, live web search, and
  `--dangerously-bypass-approvals-and-sandbox`.
- **Team:** architect, researcher, precision-coder, test-engineer, critic,
  security-auditor and chronicler, installed as `.claude/agents/*.md` or
  `.codex/agents/*.toml`, hidden from `git status`, and removed when the session
  ends. Edit them in `agent.d/`, then re-run `./install.sh`.
- **Workflow:** the agent loops research → design → implement → test → review;
  the chronicler keeps `DEVLOG.md` and commits each milestone, unsigned unless
  `AGENT_NO_GPG_SIGN=0`.
- **direnv:** if direnv is installed and the repository's `.envrc` is allowed,
  each worktree gets it linked and allowed, and the agent runs under
  `direnv exec`. ai-kit never installs direnv.

Every default can be overridden for a run with an `AGENT_*` environment
variable; `ai --help` lists them.

Tests: `agent.d/tests/*.sh`.
