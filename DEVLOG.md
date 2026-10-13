# Development Logbook

This logbook is maintained by the **chronicler** agent. It is the project's
memory: every feature and notable change gets an entry, and key decisions are
recorded with their rationale, so future readers understand not just *what* was
built but *why*.

Conventions:
- Newest entries on top.
- One entry per feature / notable change.
- Each milestone commit should reference its entry.

---

## 2026-10-13 — `direnv_run` ends with `return`, so Bash 3.2 cannot leak job notices

**What:** `direnv_run()` in `bin/ai` ends with `return "$status"` instead of
`exit "$status"`. Nothing else changes.

**Why:** `direnv_allowed` calls `direnv_run` inside `$( ... 2>/dev/null )`.
Bash 3.2 implements `exit` in a `( )` subshell by unwinding through the
command substitution's cleanup, which restores the caller's saved stderr
before the EXIT trap runs (bash-3.2.57 `evalstring.c:194-197` ->
`subst.c:4713`). The trap then SIGKILLs the `sleep 20` watchdog, and bash
announces `line N: <pid> Killed: 9 ( sleep 20; ... )` on the terminal during
agent launches. `return` ends the subshell normally, so the caller's
redirection still holds when the trap runs. Same root cause as the `ai update`
notice in the entry below; this closes that entry's first follow-up.

**How verified:** the function extracted and called the way `direnv_allowed`
calls it, 20 calls per case. Bash 3.2: the notice appeared in 15/20 calls
without a tty and 19/20 with a pty before the change, 0/20 after. Bash 5.3:
0/20 in both cases. Exit statuses are unchanged: status 3 passes through, and
a failure inside `$( )` still propagates. A suite regression check (sections
27 and 29 of `direnv-worktree.sh`) lands with the `refactor(cli):` commit; its
result is under **Final verification** in the README entry above.

**Commits:** the `fix(direnv):` commit that carries this entry.

## 2026-10-13 — Remove `ai update` and the Claude auto-update override

**What:** Removed `ai update` (`agent.d/lib/update.sh`, its 90-test offline
suite `agent.d/tests/update.{py,sh}`, both CI steps) and the launcher's Claude
auto-update override: `AGENT_CLAUDE_AUTOUPDATE` is gone, and `bin/ai` no longer
sets `DISABLE_AUTOUPDATER` or `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE`. Done by
reverting 93647d3, 2ce6459 and ef4b778; their 2026-10-12 entries below are kept
as history.

**Why:** The owner re-scoped the project. Users bring their own `claude` /
`codex` CLI and own its install, version, updates and login; ai-kit only runs
the command on `PATH` and supplies the seven-agent team, the best-model /
max-effort / no-prompt defaults, and the git worktree features. A launcher that
upgrades a CLI it does not own, or suppresses that CLI's upgrades, contradicts
that.

The trigger: a user saw
`.../lib/update.sh: line 11: <pid> Killed: 9 ( waited=0; while ... )` during
`ai update --check`. Root cause (verified against the bash 3.2.57 and 5.3
sources, and reproduced): `_ai_run_timeout`'s EXIT trap SIGKILLs the
1-second-polling watchdog after every sub-second command and then runs a bare
`wait`, which by POSIX leaves the most recent background job's status
unreported; bash announces it when the parser reads the trap string's next
line, after `wait 2>/dev/null` has been undone. On bash 5.3 only the unsilenced
call sites (the HTTP fetch, the mutating upgrade) showed it, on 35-90% of
calls; on bash 3.2 inside `$( )` the EXIT trap even runs with the caller's
original stderr restored, so the "silenced" sites leaked too. Removing the
feature removes the bug.

**How verified:** `bin/ai`, `agent.d/lib`, `agent.d/tests` and the CI workflow
are now byte-identical to 354fb77, the commit before `ai update` landed. All
remaining suites pass under `/bin/bash` 3.2.57 and Homebrew bash 5.3.20, re-run
independently before this commit: install 16, dependencies 25, codex-launch 20,
direnv-worktree 82 passed / 0 failed. `grep` finds no `update.sh`,
`AGENT_UPDATE_*`, `AI_UPDATE_*`, `AI_KIT_*_BINARY` or `AUTOUPDATE` left in code,
tests or CI; only the two READMEs still mention them.

**Follow-ups:**
- `bin/ai`'s `direnv_run` uses the same watchdog + EXIT-trap idiom. On bash 3.2
  its call inside `$( ... 2>/dev/null )` in `direnv_allowed` can print the same
  kind of notice (reproduced 18/20 on 3.2, 0/20 on 5.3).
- `README.md` and `agent.d/README.md` still describe `ai update` and
  `AGENT_CLAUDE_AUTOUPDATE` until the README milestone rewrites them.

**Commits:** the `revert:` commit that carries this entry.

---

## 2026-10-12 — Stop Claude self-upgrading mid-session

**What:** `bin/ai` now sets `DISABLE_AUTOUPDATER=1` and
`CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE=0` in the environment of the Claude
session it starts, and `agent.d/lib/update.sh` sets the same two on its
`claude --version` and `claude doctor` probes. Scoped to the child process; no
settings file is touched. `AGENT_CLAUDE_AUTOUPDATE=1` restores the previous
behaviour. Codex is untouched — it has no equivalent background updater.

**Why:** `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE` was carried into this session
as an undocumented follow-up, and verifying it turned up a real hazard rather
than a documentation gap.

- It is **not** a `claude update` setting. With it set, Claude re-checks on a
  30-minute `setInterval` for the life of a session and runs
  `brew upgrade --cask claude-code` in the background. Nothing ties it to a user
  asking. This launcher exists to start long unattended runs, which is precisely
  the window such a check lands in.
- **Homebrew has no running-process protection.** The native installer keeps a
  per-version lock and leaves a running version on disk; Homebrew knows nothing
  about live Claude processes and replaces the payload. Anthropic's own docs note
  a session reads its executable from disk *as it works*, so the failure mode is
  a crashed session, not a deferred upgrade.
- **It can race `ai update`.** Homebrew does not lock cask upgrades: `CaskLock`
  exists in 7.0.9 but its only call site is `brew cleanup`. Formula operations
  lock; casks do not. Two upgrades of one cask serialise on the *download* lock
  (180 s) and then enter artifact replacement concurrently.

`DISABLE_AUTOUPDATER` is the right switch because it is evaluated *before* the
package-manager branch, so one variable covers the native and brew paths, and it
suppresses only the background check — the explicit upgrade this feature performs
still works. Anthropic's own remote runner sets it in child environments, which
is first-party precedent for a launcher doing so.

Default-off was chosen over opt-in because the cost is near zero and the failure
is silent: a native install's background update only applies on the *next* start,
so suppressing it within a session defers a download rather than losing an
upgrade. The one real cost — plugin auto-updates share the switch — is documented
rather than hidden.

The probes are guarded for a narrower reason worth stating on its own: asking a
question about an installation must not be what changes it. Claude mounts the
updater as part of starting up, so an unguarded `claude doctor` during
classification could trigger the very upgrade the run is still deciding whether
to perform.

**Also learned, and worth not re-deriving:** `"autoUpdates": false` in
`~/.claude.json` is dead config on a native install. The native installer writes
it together with `autoUpdatesProtectedForNative: true`, and the updater's own
guard ignores the former when the latter is set — which is why `claude doctor`
reports `Auto-updates: enabled` while the JSON says `false`. That contradiction
is intended behaviour; do not read that key as a preference.

**How verified:** `DISABLE_AUTOUPDATER=1 claude doctor` reports
`Auto-updates: disabled (set by env: DISABLE_AUTOUPDATER)` against a baseline of
`enabled`. A stub `claude` on `PATH` confirms the child receives
`DISABLE_AUTOUPDATER=1` / `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE=0` by default
and neither with `AGENT_CLAUDE_AUTOUPDATE=1`. Suites green after the change:
update 90, install 16, dependencies 25, codex-launch 20 (the last proving the
claude-only guard leaves Codex launches alone). The report line is behind an
explicit `if` rather than `[ ... ] && echo`, which under `set -e` would have
aborted every Codex run at that line.

**Follow-ups:** whether the background updater mounts in `-p` (print) mode is
unverified — static reading suggests the interactive REPL only, and the env var
is passed regardless. Whether
`CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE` is honoured from the `env` block of
`settings.json` as opposed to the process environment is also unverified, and
moot for suppression since `DISABLE_AUTOUPDATER` covers the path either way.

**Commits:** see below.

---

## 2026-10-12 — Documentation restructure; the logbook becomes real

**What:** `README.md` reorganised into an orientation page — install, upgrade,
run above the fold; how it works, requirements, supported, not supported below
it — and `agent.d/README.md` extended with the full `ai update` manual. The
`## Updating` section that meant "upgrade ai-kit" was split into two
unmistakably named ones. `agent.d/tests/update.sh` added to the Tests sections of
both READMEs and to both run blocks of `.github/workflows/test.yml`. The stale
"Compatibility verified with Codex CLI 0.154.0" updated to 0.162.1 in both
READMEs. `/DEVLOG.md` removed from `.gitignore`.

**Why:**

- **The naming collision was the point of the restructure.** `README.md:282`
  read `## Updating` and meant `git pull && ./install.sh -y` — upgrade *ai-kit*.
  The new `ai update` means upgrade the *agent CLIs*. Two upgrades, no shared
  machinery, one word. They are now *Upgrading ai-kit itself* and *Upgrading the
  agent CLIs — `ai update`*, under a parent `## Upgrade` whose first content is
  a two-row table disambiguating them. A reader never has to guess which one
  they are looking at.
- **Front page orients, manual details.** The split rule is no duplicated
  prose: the front page carries the common paths and one compact statement of
  each constraint, and defers the tables that only a developer mid-problem needs
  (exit codes, the full grammar corner cases, the classification ladder) to the
  manual. The direnv section on the front page shrank from 28 lines to 12 for
  the same reason — the manual already carries the trust model; the one fact it
  lost that was not already there (the Ubuntu 24.04 direnv-too-old caveat) moved
  up into Requirements rather than being dropped.
- **The sample `ai update --check` output appears in both READMEs on purpose.**
  Only `agent.d/` is installed into the payload, so the manual is the only one
  of the two a user has after `install.sh`, and it has to stand alone. Captured
  output is the one thing worth repeating; the explanations around it are not,
  and are not.
- **`.gitignore:9` listed `/DEVLOG.md`.** That existed because the only
  `DEVLOG.md` this repo had ever seen was a session scaffold that the launcher
  drops in and removes again, and an ignored path kept it out of `git status`
  as noise. The repo now keeps a real logbook, so the line had to go, and
  nothing needs to replace it: `bin/ai:1510` copies the scaffold only when no
  `DEVLOG.md` exists, and `bin/ai:1423` removes it only while it is still
  byte-identical to `agent.d/DEVLOG.template.md`. A tracked logbook is therefore
  invisible to both. The removal is one-time and safe — `.gitignore` never
  affected already-tracked files, and this file was untracked until now.
- **Codex 0.162.1 is a re-verification, not a version bump.** Every flag the
  launcher passes — `--dangerously-bypass-approvals-and-sandbox`, `--search`,
  `--enable`, `-c`, `-m`, `-C` — was confirmed present on 0.162.1. The manual
  keeps the 0.154.0 provenance alongside it rather than overwriting it, so the
  claim's history stays readable.

**How verified:** `bin/ai update --check` run against the real machine
(claude 2.1.296 `native:latest`, codex 0.162.1 `brew-cask:codex`) — the sample
report in both READMEs is that captured output, not a reconstruction. Every
documented flag, environment variable, exit code, status string and `VIA` label
was read back out of `agent.d/lib/update.sh` and `bin/ai` rather than taken from
the design. The `.gitignore` claim was checked against `bin/ai:1423` and
`bin/ai:1510`. **Not verified:** the CI workflow edit has not run in CI; it was
checked only by running both suites locally with the same `*_TEST_BASH`
variables it sets.

**Follow-ups:**

- ~~`AI_UPDATE_OFFLINE=1` is not the airgap three places claim it is.~~
  **RESOLVED in this pass, by fixing the code rather than weakening the claim.**
  Writing the manual exposed it: the only guard was in `ai_update_fetch`, so a
  **brew-managed** CLI was still looked up with `brew outdated --json=v2` — a
  separate program that refreshes its tap on its own schedule. The flag
  therefore went quiet on a native install while a brew-managed one still
  reached out, and `update.sh:52`, `bin/ai:327` and `bin/ai:382` all overclaimed.
  Nothing caught it because the test that pins the flag
  (`update.py:test_the_offline_switch_touches_nothing`) only covered the native
  case. `ai_update_latest`'s brew branch now returns early under the flag, so
  the lookup degrades to `unknown` exactly like a failed fetch and the original
  claim is true as written. Verified: `AI_UPDATE_OFFLINE=1 ai update --check`
  now reports `unknown` for **both** tools and exits 3; previously codex was
  resolved via brew. The documentation drafted against the broken behaviour was
  corrected in the same pass rather than shipped.
  *Worth keeping in mind:* the gap existed because the flag's name describes the
  subcommand while its implementation sat at the HTTP seam. A guarantee stated
  about a feature has to be enforced at the feature's boundary, not at the one
  layer that happens to be convenient.
- ~~`bin/ai:34` still reads 0.154.0.~~ **RESOLVED.** It now records 0.162.1 and
  names the flags re-verified against that release, so the claim says what was
  actually checked rather than only a number.
- The test fixtures still pin `codex-cli 0.154.0` and `2.1.0 (Claude Code)`
  (`agent.d/tests/install.py:63-64`, `dependencies.py:81-82`). Harmless — they
  are fake version strings, not assertions about the real CLI — but they are the
  last place the old number survives.
- `CLAUDE_CODE_PACKAGE_MANAGER_AUTO_UPDATE` was requested as a mention in the
  docs. It is referenced nowhere in this codebase and its behaviour was not
  verified here, so it is deliberately undocumented rather than half-asserted.
- **CI runtime to watch.** The update suite measured ~103 s per invocation
  locally. The workflow runs it once on Linux and twice on macOS (system Bash
  and Homebrew Bash), against a `timeout-minutes: 15` job cap. Comfortable now;
  worth re-checking if the suite keeps growing.

**Commits:** not yet committed — held for review.

---

## 2026-10-12 — `ai update`: upgrade the agent CLIs

**What:** A new subcommand, `ai update [--check] [--via brew|standalone]
[claude|codex]`. It works out how `claude` and `codex` were installed, upgrades
the two methods it can drive safely, and reports everything else with the
command to run by hand. `agent.d/lib/update.sh` (1440 lines) is new; `bin/ai`
gains 259 lines of grammar, guards and dispatch. `install.sh` gains a one-word
fix: `brew install codex` → `brew install --cask codex`.

Shape: `ai update` checks both CLIs and upgrades whatever is behind;
`ai update --check` is read-only; `ai update claude|codex` narrows to one;
`--via brew|standalone` forces the method for a single named tool. Supported for
upgrade, exactly two: **standalone/native** → `claude update` / `codex update`,
and **Homebrew** → `brew upgrade --cask|--formula <token>`. Detected but never
touched: npm/pnpm/yarn/bun globals, apt/dnf/apk packages, and anything outside
`$HOME` that no package manager claims. ai-kit never installs a missing CLI.

**Why:**

- **The hybrid upgrade rule — delegate to the CLI for native installs, drive the
  package manager ourselves for Homebrew — is the central decision.** The
  obvious design is "always delegate: run `claude update` / `codex update` and
  let the vendor sort it out". It is wrong in a way that fails *silently*: a
  Homebrew-managed Claude answers `claude update` with "Claude is up to date!"
  and changes nothing, and Codex's own updater detects Homebrew as
  `is_macos && exe_path.starts_with("/opt/homebrew" | "/usr/local")`, so a
  Linuxbrew or non-default-prefix install falls through to "could not detect the
  installation method" and bails. Both failure modes look like success from the
  outside. Driving `brew` ourselves is the only way to get a true answer for a
  brew install, and delegating is the only way to get a true answer for a native
  one — so the rule follows the detection, not a preference.
- **Two supported methods, and no more.** The alternative considered was
  breadth: add npm, then pnpm, then apt. Each manager needs its own global root,
  its own upgrade verb and its own failure modes, and getting any of that wrong
  does not fail safe — it installs a **second** copy of the CLI beside the one
  the user has, which is worse than doing nothing. Reporting is cheap, cannot
  duplicate an install, and still tells the user exactly what to run. Breadth
  was rejected on that asymmetry, not on effort.
- **One code path per manager we drive.** Having decided to drive Homebrew, we
  drive it completely: ownership, latest-version lookup and the upgrade all go
  through the same `brew` binary — the one that actually owns the resolved path,
  not merely the first one found — so a machine with several brews cannot have
  one of them answer a question another one acts on.
- **Homebrew at any prefix, by asking rather than assuming** (INVARIANT H1).
  Containment is tested against `brew --prefix`, `brew --cellar` and
  `brew --caskroom` — never a hardcoded path — so Linuxbrew at
  `/home/linuxbrew/.linuxbrew`, a per-user `~/.linuxbrew`, and an arbitrary
  prefix with spaces all work for free. The Homebrew step also has to run
  *before* the "under `$HOME` means native" step on every platform, because a
  per-user Linuxbrew lives inside `$HOME` and a `$HOME`-first ladder would
  classify it as native and then hit the silent no-op above.
- **Exit code 3 is deliberate.** `0` nothing to do, `1` actionable and
  unresolved, `2` usage error, `3` could not determine. Folding "I could not
  find out" into `0` would let `ai update --check && deploy` go green on a
  plane. Precedence is `2 > 1 > 3 > 0`.
- **The bare word `update` gets a sharper rule than `wt` or `worktrees`,**
  because it is also ordinary English and this CLI's premise is that bare words
  are prompt material. The split is structural rather than stylistic: flags are
  *never* prompt material — the parser already rejects any unknown `-*` — so one
  recognised update flag commits the whole line to the subcommand, and a
  words-only line stays a prompt. `ai update --check codex` is the subcommand;
  `ai update the README to mention X` runs the agent on that prompt.
- **`agent.d/lib/update.sh` is sourced lazily** (INVARIANT G1), only after the
  grammar in `bin/ai` has already decided this is an update run. `bin/ai` runs
  under `set -euo pipefail`, so a truncated or broken lib sourced eagerly would
  abort *every* agent launch; sourced at dispatch it can only ever degrade
  `ai update` to a clean exit 2. The grammar therefore stays in `bin/ai` and must
  never move into the lib.
- **`AI_KIT_CLAUDE_BINARY` / `AI_KIT_CODEX_BINARY` never fall back to `PATH`.**
  Set-but-unusable is a hard error for that tool. A user who names one binary
  must not silently get a different one upgraded — which is the exact
  substitution the variable exists to rule out.

**How verified:**

- `agent.d/tests/update.sh` — **90 tests, green**, run under both
  **bash 3.2.57** (`/bin/bash`, macOS system) and **bash 5.3.15**
  (Homebrew). Fully offline: the agent CLIs, Homebrew, `sudo` and the network
  seam are fakes, and neither `curl` nor `wget` is on the fixture `PATH`.
- The four existing suites re-run and **green**: `install.sh`,
  `dependencies.sh`, `codex-launch.sh`, `direnv-worktree.sh`.
- Containment is itself tested, after an early manual test upgraded the
  developer's real Codex CLI: four independent guards, each sufficient alone,
  plus a fingerprint of the host's real `claude`/`codex`/`brew` taken before the
  first test and re-checked after.
- Caught in review, both of them silent-success bugs rather than crashes:
  - **The brew-ownership check tested only `brew --prefix`.** `brew --cellar` is
    not a subdirectory of `brew --prefix` in general — brew prefers
    `$HOMEBREW_REPOSITORY/Cellar` whenever that directory exists — so on a
    machine where the repository and the prefix are split, a formula-installed
    CLI would have missed the Homebrew gate entirely. The miss did not degrade
    to `unknown`; it degraded to **standalone**, which runs `claude update`,
    which a Homebrew-managed Claude no-ops while reporting success, which we
    would have printed as "already current" and exited 0. The containment set
    now spans prefix, Cellar and Caskroom.
  - **A truncated `brew outdated --json=v2` document was read as "up to date".**
    An empty `casks`/`formulae` list is brew stating positively that the package
    is not outdated, so a document the watchdog cut off halfway looked identical
    to that answer. A completeness proof (balanced braces and brackets) now has
    to pass before the empty-list reading is allowed.
- **Not verified:** no end-to-end upgrade of a real CLI was performed as part of
  this verification — deliberately, since the suite exists precisely because
  doing that once upgraded a developer's real install. The mutating paths are
  covered against fakes only.

**Follow-ups:**

- `codex-wt update` and `agent-wt update` do not reach the subcommand, and this
  is documented as the real behaviour rather than papered over: the wrappers
  pass `wt` first, so `codex-wt update` is a worktree launch on the prompt
  "update", and `agent-wt update` stops with "'update' runs no agent and cuts no
  worktree". `ai update` is the way in. Revisit only if someone actually wants
  it.
- `AGENT_UPDATE_TIMEOUT` defaults to 900 s. A non-default Homebrew prefix cannot
  use bottles and builds from source, which legitimately exceeds that;
  `AGENT_UPDATE_TIMEOUT=0` is the documented answer, and the timeout message
  says so. Worth revisiting if source builds turn out to be common rather than
  exotic.

**Commits:** not yet committed — held for review.

---

## 2026-10-12 — Reversal: npm-global drops from supported to detect-and-report

**What:** The approved design specified npm-global as a **supported upgrade
method** — `npm install -g <pkg>@latest`, driven by ai-kit. The shipped
implementation does not do that. An npm/pnpm/yarn/bun global is classified
`unsupported`, named in the report as `npm-global:<pkg>`, and printed with the
command the user can run themselves. Nothing is executed.

**Why recorded:** so that a future reader comparing the code against the design
does not conclude that npm support was lost and "restore" it. The design carries
it in at least five distinct places, and all five are now dead letters:

| Design | Shipped |
|---|---|
| method table: `npm-global` → "**we do**" → `npm install -g <pkg>@latest` | classified `unsupported`; no upgrade command exists for it |
| `--via npm` as a third `--via` value, with its own "must never create an install that was not already there" rule | `--via` accepts `brew` and `standalone` only |
| latest version via `npm view <pkg> dist-tags.<channel>`, to honour a corporate registry mirror, with the public URL as fallback | the public `registry.npmjs.org` dist-tags URL only, through the fetch seam; `npm` is never executed |
| ladder step 4 confirms with `npm root -g`, and pnpm/yarn/bun fall through to `unknown` | the `node_modules/` shape alone decides; all four managers land on `npm-global`, and `npm root -g` is never run |
| tests assert `npm install -g @openai/codex@latest` is issued | tests assert the npm row is **reported** and nothing is issued |

(The design's `self` method was also renamed `standalone` on the way in; same
thing, clearer word.)

**Why reversed:** the user cut it after the design was approved. The reason is
the same asymmetry that limits the feature to two methods, but it bites hardest
here:

- `node_modules/` on a resolved path does not identify the *manager*. npm,
  pnpm, yarn and bun all produce one, with four different global roots and four
  different upgrade verbs. Telling them apart would mean running `npm root -g`,
  as the design did — which requires node to be installed purely to produce a
  message, and still leaves pnpm/yarn/bun unhandled. Once we are not driving
  any of them, the distinction buys nothing, so the probe went too.
- Getting it wrong does not fail safe. `npm install -g` against a CLI that pnpm
  actually owns installs a **second** copy beside the first, and the user is
  then shadowed by whichever lands earlier on `PATH` — a worse state than the
  out-of-date install they started with.
- Reporting costs one line and cannot do that. The report names the exact
  package it found and prints `npm install -g <pkg>@latest`, with a note that
  the pnpm/yarn/bun equivalent applies if that is what they used.

So the detection stayed and the driving went. The implementation comments carry
the same warning at the point where it would be tempting to grow it back:
`agent.d/lib/update.sh` notes that the one npm-shaped thing in the file is an
HTTPS read of `registry.npmjs.org`'s dist-tags document, used purely as a
**version oracle**, and that the `npm` binary is never invoked.

**How verified:** behaviour read out of `ai_update_origin` (sets
`_o_method=unsupported`, `_o_label=npm-global`, never an upgrade command) and
`ai_update_cmd` (returns non-zero for any method but `brew-*` and `standalone`),
and covered by the update suite's reporting tests. Documented as **not
supported** in both READMEs, with the reason.

**Follow-ups:** none. This is a closed decision; reopening it needs a new entry,
not a revert.

---

<!-- Add new entries ABOVE this line. Keep them concise but complete. -->
