#!/usr/bin/env python3
"""Exercise real launcher processes against fake agents and temporary Git repos.

Run codex-launch.sh: the tests run in parallel worker processes
(parallel_runner.py, AI_TEST_JOBS=1 for one), or in-process given unittest
arguments such as -k cache. AI=/path/to/ai selects another launcher; the `bash`
first on PATH runs it. All caches, repositories, worktrees, and Git
configuration writes are confined to temporary directories. No agent, network
request, user configuration write, or package installation is involved. direnv
is off (AGENT_DIRENV=0) except where a test is about direnv being absent or too
old; direnv-worktree.sh covers the real thing.

The fake agent records its argv, working tree and Git state as JSON. One file
serves as both `codex` and `claude` and is written once per run: on hosts whose
endpoint security scans each new executable on its first exec, a fresh copy per
test costs about half a second.
"""

import json
import os
from pathlib import Path
import shlex
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


SUPPORT = Path(__file__).resolve().parents[1]
PACKAGE = SUPPORT.parent
LAUNCHER = Path(os.environ.get("AI", PACKAGE / "bin/ai"))
if "AI" not in os.environ and not LAUNCHER.is_file():
    LAUNCHER = PACKAGE / "ai"
LAUNCHER = LAUNCHER.resolve()
CODEX_TEAM = sorted(path.name for path in (SUPPORT / "codex-agents").glob("*.toml"))
CLAUDE_TEAM = sorted(path.name for path in (SUPPORT / "agents").glob("*.md"))
RECIPE_HEADING = "Bring the committed work back to the regular branch:\n"
REMOVED_OPTIONS = (["--here"], ["--wt"], ["--worktree"], ["--in-place"], ["--no-wt"],
                   ["--agent", "codex"], ["-a", "codex"], ["codex", "--here"],
                   ["wt", "codex", "--here"])

FAKE_AGENT = r'''
import json
import os
from pathlib import Path
import signal
import subprocess
import sys

agent = os.path.basename(sys.argv[0])
args = sys.argv[1:]
signal.alarm(60)  # never outlive a broken test

if args == ["--version"]:  # inert: an installer preflight may ask
    print("0.0.0 (fake %s)" % agent)
    sys.exit(0)
if args == ["--help"]:  # the launcher's probe for claude --name
    hold = os.environ.get("AI_TEST_HOLD_PROBE")
    if hold:
        signal.signal(signal.SIGINT, signal.SIG_DFL)
        Path(hold).write_text("probing\n")
        signal.pause()
    print("  -n, --name <name>   Set a display name for this session")
    sys.exit(0)


def git(*command, check=False):
    return subprocess.run(["git", *command], stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, check=check).stdout


configs, options, prompts = {}, {}, []
index = 0
while agent == "codex" and index < len(args):
    arg = args[index]
    if arg == "--":
        prompts.extend(args[index + 1:])
        break
    elif arg in ("-c", "--config"):
        key, value = args[index + 1].split("=", 1)
        try:
            configs[key] = json.loads(value)
        except ValueError:
            configs[key] = value
        index += 2
    elif arg in ("-C", "--cd", "-m", "--model", "--enable", "--disable"):
        options[arg] = args[index + 1]
        index += 2
    elif arg.startswith("-"):
        options[arg] = True
        index += 1
    else:
        prompts.extend(args[index:])
        break

root = Path.cwd()
files = {}
for relative in ("AGENTS.md", "AGENTS.override.md", ".codex/config.toml", "DEVLOG.md"):
    path = root / relative
    if path.is_file():
        files[relative] = path.read_text()
team_dir = root / (".codex/agents" if agent == "codex" else ".claude/agents")
team = {p.name: p.read_text() for p in team_dir.glob("*.toml" if agent == "codex" else "*.md")}
instructions = "\n".join(str(v) for k, v in configs.items() if "instructions" in k)
instructions += "\n" + "\n".join(v for k, v in files.items() if k != "DEVLOG.md")
common = git("rev-parse", "--path-format=absolute", "--git-common-dir").strip()
exclude = Path(common, "info", "exclude") if common else None
Path(os.environ["AI_TEST_RECORD"]).write_text(json.dumps({
    "agent": agent, "cwd": str(root), "argv": args, "configs": configs,
    "options": options, "prompts": prompts, "files": files, "team": team,
    "team_entries": sorted(os.listdir(team_dir)) if team_dir.is_dir() else [],
    "instructions": instructions,
    "head": git("rev-parse", "HEAD").strip(),
    "branch": git("branch", "--show-current").strip(),
    "status": git("status", "--porcelain"),
    "exclude": exclude.read_text() if exclude and exclude.is_file() else None,
}))

team_change = os.environ.get("AI_TEST_TEAM")
if team_change == "edit":
    with open(team_dir / "architect.toml", "a") as member:
        member.write("# edited by the agent\n")
elif team_change == "delete":
    os.unlink(team_dir / "critic.toml")
elif team_change == "commit":
    git("add", "-f", str(team_dir / "critic.toml"), check=True)
    git("commit", "-qm", "Keep a team member", check=True)
devlog = os.environ.get("AI_TEST_DEVLOG")
if devlog == "edit":
    with open("DEVLOG.md", "a") as logbook:
        logbook.write("\n## An entry the agent wrote\n")
elif devlog == "commit":
    git("add", "DEVLOG.md", check=True)
    git("commit", "-qm", "Keep the logbook", check=True)
if os.environ.get("AI_TEST_COMMIT"):
    Path("work.txt").write_text("the agent's work\n")
    git("add", "work.txt", check=True)
    git("commit", "-qm", "Agent work", check=True)
hold = os.environ.get("AI_TEST_HOLD")
if hold:
    on_interrupt = os.environ.get("AI_TEST_ON_INT", "default")
    if on_interrupt == "default":
        signal.signal(signal.SIGINT, signal.SIG_DFL)
    else:
        signal.signal(signal.SIGINT, lambda *_: sys.exit(int(on_interrupt)))
    Path(hold).write_text("running\n")
    signal.pause()
sys.exit(int(os.environ.get("AI_TEST_EXIT", "0")))
'''

# direnv 2.32: answers `direnv version`, fails `direnv version 2.33.0` (as the
# real one does for an older binary), and logs anything else it is asked to do.
OLD_DIRENV = '''#!/bin/sh
echo "$*" >>"$AI_TEST_DIRENV_LOG"
case "$#:$1" in
  1:version) echo 2.32.0 ;;
  *) exit 1 ;;
esac
'''


def path_without(names, shadow_root):
    """The caller's PATH with every command in `names` hidden (see install.py)."""
    entries, seen = [], set()
    for directory in os.environ["PATH"].split(os.pathsep):
        if not os.path.isabs(directory) or directory in seen or not os.path.isdir(directory):
            continue
        seen.add(directory)
        if not any(os.path.lexists(os.path.join(directory, name)) for name in names):
            entries.append(directory)
            continue
        shadow = shadow_root / str(len(entries))
        shadow.mkdir(parents=True)
        for entry in os.listdir(directory):
            if entry not in names:
                (shadow / entry).symlink_to(os.path.join(directory, entry))
        entries.append(str(shadow))
    return os.pathsep.join(entries)


def model(slug, efforts, priority=1):
    return {
        "slug": slug,
        "visibility": "list",
        "priority": priority,
        "supported_reasoning_levels": [{"effort": effort} for effort in efforts],
    }


class LauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shared = tempfile.TemporaryDirectory(prefix="ai-launch fixtures ")
        cls.addClassCleanup(shared.cleanup)
        shared_root = Path(shared.name).resolve()
        cls.fakebin = shared_root / "fakebin"
        cls.fakebin.mkdir()
        fake = cls.fakebin / "codex"
        fake.write_text("#!" + sys.executable + "\n" + FAKE_AGENT)
        fake.chmod(0o755)
        (cls.fakebin / "claude").symlink_to("codex")
        cls.old_direnv = shared_root / "direnv 2.32"
        cls.old_direnv.mkdir()
        (cls.old_direnv / "direnv").write_text(OLD_DIRENV)
        (cls.old_direnv / "direnv").chmod(0o755)
        cls.path = str(cls.fakebin) + os.pathsep + os.environ["PATH"]
        cls.path_without_direnv = str(cls.fakebin) + os.pathsep + path_without(
            ("direnv",), shared_root / "shadow")

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-launch-tests-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.repo = self.root / "project with spaces"
        self.repo.mkdir()
        self.cache_home = self.root / "codex-config"
        self.cache_home.mkdir()
        # These are child-process configuration overrides; the running test's
        # own HOME and CODEX_HOME, and the user's files, are never changed.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("AGENT_", "CODEX_", "GIT_", "AI_TEST_", "DIRENV_"))
        }
        self.env.update({
            "PATH": self.path,
            "CODEX_HOME": str(self.cache_home),
            "AGENT_DIRENV": "0",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
        })
        self.git("init", "-q")
        self.git("config", "user.email", "launcher-test@example.invalid")
        self.git("config", "user.name", "Launcher tests")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "seed.txt").write_text("committed seed\n")
        self.git("add", "seed.txt")
        self.git("commit", "-qm", "Initial fixture")
        self.initial_head = self.git("rev-parse", "HEAD").strip()
        self.initial_branch = self.git("branch", "--show-current").strip()
        self.exclude = self.repo / ".git/info/exclude"
        self.runs = 0

    def git(self, *args, cwd=None):
        return subprocess.check_output(
            ["git", "-C", str(cwd or self.repo), *args], env=self.env,
            stderr=subprocess.PIPE, text=True,
        )

    def cache(self, contents):
        (self.cache_home / "models_cache.json").write_text(
            contents if isinstance(contents, str) else json.dumps(contents)
        )

    def next_record(self):
        self.runs += 1
        return self.root / ("record-%d.json" % self.runs)

    def launch(self, *args, launcher=None, cwd=None, env=None):
        record = self.next_record()
        process = subprocess.run(
            [str(launcher or LAUNCHER), *args], cwd=str(cwd or self.repo),
            env=dict(self.env, AI_TEST_RECORD=str(record), **(env or {})),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=30,
        )
        captured = json.loads(record.read_text()) if record.exists() else None
        return process, captured

    def successful(self, *args, **kwargs):
        process, record = self.launch(*args, **kwargs)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIsNotNone(record, process.stderr)
        return record

    def interrupted(self, *args, ready, env, sig=signal.SIGINT):
        """Launch in a session of its own and, once the fake says it is `ready`,
        signal the whole process group: SIGINT is what Ctrl-C at a terminal does.

        The launcher starts with SIGINT at its default disposition, as a
        terminal's foreground job does. A runner started in the background of a
        non-interactive shell would otherwise pass on an ignored SIGINT, which
        Bash cannot trap, and every interrupt test would be meaningless."""
        record = self.next_record()
        process = subprocess.Popen(
            [str(LAUNCHER), *args], cwd=str(self.repo),
            env=dict(self.env, AI_TEST_RECORD=str(record), **env),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
            preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL),
        )
        try:
            deadline = time.monotonic() + 20
            while not ready.exists():
                self.assertIsNone(process.poll(), "launcher exited before the interrupt")
                self.assertLess(time.monotonic(), deadline, "the fake never became ready")
                time.sleep(0.02)
            os.killpg(process.pid, sig)
            stdout, stderr = process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
        captured = json.loads(record.read_text()) if record.exists() else None
        return process.returncode, stderr, captured

    def recipe(self, stderr):
        """The printed merge-back recipe, and each of its lines as argv."""
        self.assertIn(RECIPE_HEADING, stderr)
        text = stderr.split(RECIPE_HEADING, 1)[1]
        return text, [shlex.split(line, comments=True) for line in text.splitlines() if line.strip()]

    def assert_settings(self, record, expected_model="gpt-6-astra", effort="ultra"):
        self.assertEqual(record["options"].get("-m"), expected_model)
        self.assertEqual(record["configs"].get("model_reasoning_effort"), effort)

    def assert_root_instructions(self, record, team=True):
        # Team files cannot substitute for instructions delivered to the root
        # agent. Positional task text is also excluded: interactive mode has none.
        instructions = record["instructions"]
        self.assertIn(record["cwd"], instructions)
        self.assertIn("DEVLOG.md", instructions)
        self.assertIn("push", instructions)
        if team:
            for role in ("architect", "precision-coder", "critic", "chronicler"):
                self.assertIn(role, instructions)

    def assert_no_scaffold(self, directory):
        self.assertFalse((directory / ".codex").exists())
        self.assertFalse((directory / ".claude").exists())
        self.assertFalse((directory / "DEVLOG.md").exists())

    # ---- Codex model and effort ------------------------------------------

    def test_default_astra_survives_missing_malformed_and_stale_cache(self):
        cases = [
            None, "not json", {"models": []}, {"models": None},
            {"models": [None, "bad row"]},
            {"models": [model("gpt-5.6-sol", ["high", "ultra"])]},
            {"models": [model("future-other-model", ["max"], 0),
                        model("gpt-6-astra", ["high", "ultra"], 10)]},
        ]
        for contents in cases:
            with self.subTest(cache=contents):
                if contents is not None:
                    self.cache(contents)
                record = self.successful("codex", env={"AGENT_NO_AGENTS": "1"})
                self.assert_settings(record)

    def test_effort_uses_selected_models_highest_advertised_level(self):
        for levels, expected in [
            (["high", "max", "ultra", "xhigh"], "ultra"),
            (["high", "xhigh", "max"], "max"),
            (["medium", "xhigh", "high"], "xhigh"),
            (["medium", "high"], "high"),
        ]:
            with self.subTest(levels=levels):
                self.cache({"models": [model("other", ["ultra"], 0),
                                       model("gpt-6-astra", levels, 50)]})
                record = self.successful("codex", env={"AGENT_NO_AGENTS": "1"})
                self.assert_settings(record, effort=expected)

    def test_known_model_overrides_have_model_specific_fallbacks(self):
        for slug, effort in [
            ("gpt-5.6-sol", "ultra"), ("gpt-5.6-terra", "ultra"),
            ("gpt-5.6-luna", "max"), ("gpt-5.5", "xhigh"),
        ]:
            with self.subTest(model=slug):
                record = self.successful("codex", env={"AGENT_CODEX_MODEL": slug,
                                                       "AGENT_NO_AGENTS": "1"})
                self.assert_settings(record, slug, effort)

    def test_override_model_uses_its_own_cache_entry(self):
        self.cache({"models": [model("gpt-6-astra", ["ultra"]),
                               model("custom-model", ["low", "high"], 90)]})
        record = self.successful("codex", env={"AGENT_CODEX_MODEL": "custom-model",
                                               "AGENT_NO_AGENTS": "1"})
        self.assert_settings(record, "custom-model", "high")

    def test_unknown_override_requires_effort_before_creating_worktree(self):
        before = self.git("worktree", "list", "--porcelain")
        process, record = self.launch("wt", "codex", env={"AGENT_CODEX_MODEL": "custom-model"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIsNone(record)
        self.assertIn("AGENT_CODEX_EFFORT", process.stderr)
        self.assertEqual(self.git("worktree", "list", "--porcelain"), before)
        self.assertFalse(Path(str(self.repo) + ".worktrees").exists())

    def test_explicit_effort_wins_with_or_without_model_cache(self):
        self.cache({"models": [model("gpt-6-astra", ["ultra"])]})
        record = self.successful("codex", env={"AGENT_CODEX_EFFORT": "high", "AGENT_NO_AGENTS": "1"})
        self.assert_settings(record, effort="high")
        record = self.successful("codex", env={
            "AGENT_CODEX_MODEL": "custom-model", "AGENT_CODEX_EFFORT": "medium",
            "AGENT_NO_AGENTS": "1",
        })
        self.assert_settings(record, "custom-model", "medium")

    # ---- Codex launch -----------------------------------------------------

    def test_launch_flags_and_project_trust(self):
        record = self.successful("codex")
        self.assertEqual(record["configs"].get("service_tier"), "fast")
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", record["argv"])
        self.assertIn("--search", record["argv"])
        self.assertEqual(record["options"].get("--enable"), "multi_agent")
        self.assertEqual(record["configs"].get('projects."%s".trust_level' % self.repo), "trusted")
        record = self.successful("codex", env={"AGENT_CODEX_SEARCH": "0", "AGENT_NO_AGENTS": "1"})
        self.assertNotIn("--search", record["argv"])

    def test_explicit_empty_tier_preserves_codex_account_default(self):
        record = self.successful("codex", env={"AGENT_CODEX_TIER": "", "AGENT_NO_AGENTS": "1"})
        self.assertNotIn("service_tier", record["configs"])

    def test_prompt_and_interactive_launch_preload_root_instructions(self):
        task = "Preserve this task verbatim.\nSecond line with $shell and `text`."
        for prompt in ([], [task]):
            with self.subTest(prompt=bool(prompt)):
                record = self.successful("codex", *prompt)
                self.assert_root_instructions(record)
                if prompt:
                    self.assertEqual(record["prompts"], [task])
                else:
                    self.assertEqual(record["prompts"], [])

    def test_leading_dash_prompt_is_not_reinterpreted_as_codex_options(self):
        task = "--model another-model\n- fix the bug; preserve $shell and `text`"
        record = self.successful("codex", "--", task, env={"AGENT_NO_AGENTS": "1"})
        self.assertEqual(record["prompts"], [task])
        self.assert_settings(record)
        self.assert_root_instructions(record, team=False)

    def test_agent_exit_status_propagates_in_both_modes(self):
        for args in (["codex"], ["wt", "codex", "-n", "failed-session"]):
            with self.subTest(args=args):
                process, record = self.launch(*args, env={"AI_TEST_EXIT": "37"})
                self.assertEqual(process.returncode, 37, process.stderr)
                self.assertIn("architect.toml", record["team"])
                self.assertTrue(Path(record["cwd"]).is_dir())
                self.assert_no_scaffold(Path(record["cwd"]))
        self.assertEqual(self.git("status", "--porcelain"), "")

    # ---- Arguments --------------------------------------------------------

    def test_removed_options_exit_2_and_launch_nothing(self):
        for args in REMOVED_OPTIONS:
            with self.subTest(args=args):
                process, record = self.launch(*args, "task")
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("Unknown option", process.stderr)
                self.assertIsNone(record)
        self.assertFalse(Path(str(self.repo) + ".worktrees").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_leading_keywords_work_in_any_order(self):
        quiet = {"AGENT_NO_AGENTS": "1"}
        record = self.successful("codex", "task", env=quiet)
        self.assertEqual(record["cwd"], str(self.repo))
        self.assertEqual(record["options"].get("-C"), str(self.repo))
        for args in (["wt", "codex", "task"], ["codex", "wt", "task"]):
            with self.subTest(args=args):
                record = self.successful(*args, env=quiet)
                self.assertEqual(Path(record["cwd"]).parent, Path(str(self.repo) + ".worktrees"))
                self.assertTrue(record["branch"].startswith("codex/task-"), record["branch"])
                self.assertEqual(record["prompts"], ["task"])

    def test_a_repeated_keyword_starts_the_prompt(self):
        quiet = {"AGENT_NO_AGENTS": "1"}
        record = self.successful("wt", "codex", "wt", "task", env=quiet)
        self.assertEqual(record["prompts"], ["wt task"])
        self.assertTrue(record["branch"].startswith("codex/wt-task-"), record["branch"])
        for args, prompt in ((["codex", "claude", "task"], "claude task"),
                             (["codex", "codex", "task"], "codex task")):
            with self.subTest(args=args):
                record = self.successful(*args, env=quiet)
                self.assertEqual(record["agent"], "codex")
                self.assertEqual(record["cwd"], str(self.repo))
                self.assertEqual(record["prompts"], [prompt])

    def test_worktrees_takes_only_fix(self):
        for args in (["worktrees", "junk"], ["worktrees", "--fix", "extra"],
                     ["worktrees", "-n", "name"]):
            with self.subTest(args=args):
                process, record = self.launch(*args)
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIsNone(record)
        process, _ = self.launch("worktrees")
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertIn("worktree root:", process.stdout)

    # ---- Scaffold: team, .gitignore, DEVLOG ------------------------------

    def test_source_layout_installs_team_and_cleans_up_in_place(self):
        before = self.exclude.read_bytes()
        record = self.successful("codex")
        self.assertGreater(len(CODEX_TEAM), 0)
        self.assertEqual(sorted(record["team"]), CODEX_TEAM)
        # Hidden by a .gitignore inside the team directory, not by editing the
        # exclude file that every worktree of the repository shares.
        self.assertEqual(record["team_entries"], sorted(CODEX_TEAM + [".gitignore"]))
        self.assertEqual(record["status"], "?? DEVLOG.md\n")
        self.assertEqual(record["exclude"], before.decode())
        self.assert_no_scaffold(self.repo)
        self.assertEqual(self.exclude.read_bytes(), before)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_installed_flat_layout_through_symlink_finds_team(self):
        prefix = self.root / "installed payload"
        prefix.mkdir()
        shutil.copy2(LAUNCHER, prefix / "ai")
        shutil.copytree(SUPPORT, prefix / "agent.d")
        command = self.root / "custom-ai-name"
        command.symlink_to(prefix / "ai")
        record = self.successful("codex", launcher=command)
        self.assertEqual(sorted(record["team"]), CODEX_TEAM)
        self.assert_root_instructions(record)

    def test_no_agents_does_not_install_team_or_claim_one_is_available(self):
        record = self.successful("codex", env={"AGENT_NO_AGENTS": "1"})
        self.assertEqual(record["team"], {})
        self.assertNotEqual(record["options"].get("--enable"), "multi_agent")
        self.assertNotIn("bundled team", record["instructions"].lower())
        self.assert_root_instructions(record, team=False)

    def test_existing_project_instructions_and_agent_are_preserved(self):
        agents = self.repo / ".codex/agents"
        agents.mkdir(parents=True)
        custom = 'name = "architect"\ndeveloper_instructions = "User-owned definition"\n'
        (agents / "architect.toml").write_text(custom)
        project_instructions = "User project rules: retain this exact text.\n"
        (self.repo / "AGENTS.md").write_text(project_instructions)
        status = self.git("status", "--porcelain")
        record = self.successful("codex")
        self.assertEqual(record["team"]["architect.toml"], custom)
        self.assertEqual(record["files"]["AGENTS.md"], project_instructions)
        self.assert_root_instructions(record)
        self.assertEqual((agents / "architect.toml").read_text(), custom)
        self.assertEqual((self.repo / "AGENTS.md").read_text(), project_instructions)
        self.assertEqual(list(agents.iterdir()), [agents / "architect.toml"])
        self.assertEqual(self.git("status", "--porcelain"), status)

    def test_tracked_team_file_stays_tracked_and_untouched(self):
        mine = self.repo / ".codex/agents/mine.toml"
        mine.parent.mkdir(parents=True)
        mine.write_text('name = "mine"\n')
        self.git("add", ".codex/agents/mine.toml")
        self.git("commit", "-qm", "Track my own agent")
        before = self.exclude.read_bytes()
        record = self.successful("codex")
        self.assertEqual(record["team_entries"], sorted(CODEX_TEAM + [".gitignore", "mine.toml"]))
        self.assertEqual(record["status"], "?? DEVLOG.md\n")
        self.assertEqual(os.listdir(mine.parent), ["mine.toml"])
        self.assertEqual(mine.read_text(), 'name = "mine"\n')
        self.assertEqual(self.git("ls-files", ".codex"), ".codex/agents/mine.toml\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.exclude.read_bytes(), before)

    def test_scaffolded_devlog_is_removed_only_when_untouched_and_untracked(self):
        template = (SUPPORT / "DEVLOG.template.md").read_text()
        self.successful("codex", env={"AI_TEST_DEVLOG": "edit"})
        devlog = self.repo / "DEVLOG.md"
        self.assertEqual(devlog.read_text(), template + "\n## An entry the agent wrote\n")
        devlog.unlink()
        # Committed unchanged: it is the agent's work now, and deleting it would
        # leave a tracked file missing.
        self.successful("codex", env={"AI_TEST_DEVLOG": "commit"})
        self.assertEqual(devlog.read_text(), template)
        self.assertEqual(self.git("ls-files", "DEVLOG.md"), "DEVLOG.md\n")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_scaffold_the_agent_changed_or_committed_is_kept(self):
        agents = self.repo / ".codex/agents"
        self.successful("codex", env={"AI_TEST_TEAM": "edit"})
        self.assertEqual(os.listdir(agents), ["architect.toml"])
        self.assertTrue((agents / "architect.toml").read_text().endswith("# edited by the agent\n"))
        shutil.rmtree(self.repo / ".codex")
        self.successful("codex", env={"AI_TEST_TEAM": "commit"})
        self.assertEqual(os.listdir(agents), ["critic.toml"])
        self.assertEqual(self.git("ls-files", ".codex"), ".codex/agents/critic.toml\n")
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_scaffold_the_agent_deleted_neither_breaks_cleanup_nor_the_exit_status(self):
        process, record = self.launch("codex", env={"AI_TEST_TEAM": "delete", "AI_TEST_EXIT": "37"})
        self.assertEqual(process.returncode, 37, process.stderr)
        self.assertEqual(sorted(record["team"]), CODEX_TEAM)
        self.assert_no_scaffold(self.repo)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_a_killed_sessions_leftovers_are_adopted_and_cleaned_by_the_next_run(self):
        ready = self.root / "running"
        status, _, _ = self.interrupted("codex", "task", ready=ready, sig=signal.SIGKILL,
                                        env={"AI_TEST_HOLD": str(ready)})
        self.assertEqual(status, -signal.SIGKILL)
        agents = self.repo / ".codex/agents"
        self.assertEqual(sorted(os.listdir(agents)), sorted(CODEX_TEAM + [".gitignore"]))
        self.assertTrue((self.repo / "DEVLOG.md").is_file())
        # A leftover the user has since changed is theirs, and stays.
        changed = agents / "architect.toml"
        changed.write_text(changed.read_text() + "# my change\n")
        record = self.successful("codex", "task")
        self.assertEqual(sorted(record["team"]), CODEX_TEAM)
        self.assertEqual(os.listdir(agents), ["architect.toml"])
        self.assertTrue(changed.read_text().endswith("# my change\n"))
        self.assertFalse((self.repo / "DEVLOG.md").exists())
        self.assertEqual(self.git("status", "--porcelain"), "?? .codex/\n")

    # ---- Worktrees --------------------------------------------------------

    def test_worktree_commands_use_committed_base_and_leave_dirty_source_untouched(self):
        (self.repo / "seed.txt").write_text("pre-existing dirty user work\n")
        (self.repo / "untracked.txt").write_text("also user-owned\n")
        source_status = self.git("status", "--porcelain")
        before = self.exclude.read_bytes()
        record = self.successful("wt", "codex", "-n", "isolated", "Worktree task")
        worktree = Path(record["cwd"])
        self.assertEqual(worktree.parent, Path(str(self.repo) + ".worktrees"))
        self.assertEqual(record["options"].get("-C"), str(worktree))
        self.assertEqual(record["head"], self.initial_head)
        self.assertTrue(record["branch"].startswith("codex/isolated-"))
        self.assertEqual((worktree / "seed.txt").read_text(), "committed seed\n")
        self.assertFalse((worktree / "untracked.txt").exists())
        self.assertEqual(sorted(record["team"]), CODEX_TEAM)
        self.assertEqual(record["status"], "?? DEVLOG.md\n")
        self.assert_root_instructions(record)
        # The worktree's scaffold goes too, so it is clean once the session ends.
        self.assert_no_scaffold(worktree)
        self.assertEqual(self.git("status", "--porcelain", cwd=worktree), "")
        self.assertEqual(self.exclude.read_bytes(), before)
        self.assertEqual(self.git("branch", "--show-current").strip(), self.initial_branch)
        self.assertEqual(self.git("status", "--porcelain"), source_status)
        self.assertEqual((self.repo / "seed.txt").read_text(), "pre-existing dirty user work\n")

    def test_printed_merge_back_recipe_runs_once_the_agent_has_committed(self):
        process, record = self.launch("wt", "codex", "-n", "feature", "task",
                                      env={"AI_TEST_COMMIT": "1"})
        self.assertEqual(process.returncode, 0, process.stderr)
        worktree, branch = Path(record["cwd"]), record["branch"]
        recipe, commands = self.recipe(process.stderr)
        self.assertIn(["git", "worktree", "remove", str(worktree)], commands)
        self.assertNotIn(".envrc", recipe)  # direnv is off: nothing was linked
        merged = subprocess.run(["bash", "-ec", recipe], env=self.env, cwd=str(self.root),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.assertEqual(merged.returncode, 0, recipe + merged.stdout)
        self.assertEqual((self.repo / "work.txt").read_text(), "the agent's work\n")
        self.assertFalse(worktree.exists())
        self.assertEqual(self.git("branch", "--list", branch), "")
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_dotted_names_and_prompts_produce_valid_direct_child_worktrees(self):
        for args in (["-n", "audit..dots", "task"], ["Review v1..v2"]):
            with self.subTest(args=args):
                record = self.successful("wt", "codex", *args, env={"AGENT_NO_AGENTS": "1"})
                self.assertEqual(Path(record["cwd"]).parent, Path(str(self.repo) + ".worktrees"))
                self.git("check-ref-format", "--branch", record["branch"])

    def test_explicit_base_and_nested_launch_stay_anchored_to_main_repo(self):
        self.git("branch", "release-fixture")
        (self.repo / "seed.txt").write_text("new current-branch commit\n")
        self.git("commit", "-qam", "Advance current branch")
        quiet = {"AGENT_NO_AGENTS": "1"}
        first = self.successful("wt", "codex", "--base", "release-fixture", "-n", "release", env=quiet)
        self.assertEqual(first["head"], self.initial_head)
        second = self.successful("wt", "codex", "-n", "nested", cwd=first["cwd"], env=quiet)
        self.assertEqual(Path(second["cwd"]).parent, Path(str(self.repo) + ".worktrees"))
        self.assertEqual(second["head"], self.initial_head)

    # ---- Ctrl-C -----------------------------------------------------------

    def test_interrupt_before_the_launch_exits_130_and_removes_the_scaffold(self):
        # Claude with a name probes `claude --help` after the scaffold exists and
        # before the real launch: the fake holds the probe until interrupted.
        ready = self.root / "probing"
        status, stderr, record = self.interrupted(
            "claude", "-n", "held", "task", ready=ready, env={"AI_TEST_HOLD_PROBE": str(ready)})
        self.assertEqual(status, 130, stderr)
        self.assertIsNone(record)  # the agent itself never started
        self.assert_no_scaffold(self.repo)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_interrupt_during_the_run_reaches_the_agent_not_the_launcher(self):
        for on_interrupt, expected in (("42", 42), ("default", 130)):
            with self.subTest(agent_on_interrupt=on_interrupt):
                ready = self.root / ("running-" + on_interrupt)
                status, stderr, record = self.interrupted(
                    "wt", "codex", "-n", "held-" + on_interrupt, "task", ready=ready,
                    env={"AI_TEST_HOLD": str(ready), "AI_TEST_ON_INT": on_interrupt})
                self.assertEqual(status, expected, stderr)
                worktree = Path(record["cwd"])
                self.assertIn(["git", "worktree", "remove", str(worktree)], self.recipe(stderr)[1])
                self.assertTrue(worktree.is_dir())
                self.assert_no_scaffold(worktree)
                self.assertEqual(self.git("status", "--porcelain", cwd=worktree), "")

    # ---- Claude -----------------------------------------------------------

    def test_claude_omits_emptied_flags_and_keeps_a_tracked_team_file(self):
        mine = self.repo / ".claude/agents/mine.md"
        mine.parent.mkdir(parents=True)
        mine.write_text("my own agent\n")
        self.git("add", ".claude/agents/mine.md")
        self.git("commit", "-qm", "Track my own agent")
        before = self.exclude.read_bytes()
        record = self.successful("claude", "-n", "my session", env={
            "AGENT_CLAUDE_EFFORT": "", "AGENT_CLAUDE_PERMISSION_MODE": "",
            "AGENT_CLAUDE_SETTING_SOURCES": "",
        })
        # No prompt: the workflow goes in as an appended system prompt.
        self.assertEqual(record["argv"][:-1], [
            "--model", "opus", "--allow-dangerously-skip-permissions",
            "--dangerously-skip-permissions", "--name", "my session",
            "--append-system-prompt",
        ])
        workflow = record["argv"][-1]
        for expected in (str(self.repo), ".claude/agents/", "DEVLOG.md", "chronicler"):
            self.assertIn(expected, workflow)
        self.assertEqual(record["team_entries"], sorted(CLAUDE_TEAM + [".gitignore", "mine.md"]))
        self.assertEqual(record["status"], "?? DEVLOG.md\n")
        self.assertEqual(record["exclude"], before.decode())
        self.assertEqual(os.listdir(mine.parent), ["mine.md"])
        self.assertEqual(mine.read_text(), "my own agent\n")
        self.assertEqual(self.git("ls-files", ".claude"), ".claude/agents/mine.md\n")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.exclude.read_bytes(), before)

    # ---- direnv -----------------------------------------------------------

    def test_direnv_is_off_when_absent_or_older_than_2_33(self):
        (self.repo / ".envrc").write_text("export AI_TEST_MARKER=loaded\n")
        calls = self.root / "direnv-calls"
        for label, path, note in (
            ("absent", self.path_without_direnv, "off (direnv not installed)"),
            ("2.32", str(self.old_direnv) + os.pathsep + self.path, "off (direnv older than 2.33)"),
        ):
            with self.subTest(direnv=label):
                env = {"AGENT_DIRENV": "1", "AGENT_NO_AGENTS": "1", "PATH": path,
                       "AI_TEST_DIRENV_LOG": str(calls)}
                process, record = self.launch("codex", "task", env=env)
                self.assertEqual(process.returncode, 0, process.stderr)
                self.assertIsNotNone(record, process.stderr)
                self.assertIn("direnv:        " + note + "\n", process.stderr)
                process, _ = self.launch("worktrees", env=env)
                self.assertIn("direnv source:  " + note + "\n", process.stdout)
        # The old binary was only ever asked its version, never to load anything.
        self.assertEqual(set(calls.read_text().splitlines()), {"version 2.33.0"})


if __name__ == "__main__":
    if not LAUNCHER.is_file():
        raise SystemExit("Cannot find ai launcher; set AI=/path/to/ai")
    sys.dont_write_bytecode = True  # keep __pycache__ out of the package
    import parallel_runner
    parallel_runner.main(LauncherTests)
