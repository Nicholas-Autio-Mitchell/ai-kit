#!/usr/bin/env python3
"""Exercise real launcher processes against fake Codex and temporary Git repos.

Run codex-launch.sh, optionally with unittest arguments such as -v or -k cache.
AI=/path/to/ai selects another launcher. All caches, repositories, worktrees,
and Git configuration writes are confined to temporary directories. No agent,
network request, user configuration write, or package installation is involved.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SUPPORT = Path(__file__).resolve().parents[1]
PACKAGE = SUPPORT.parent
LAUNCHER = Path(os.environ.get("AI", PACKAGE / "bin/ai"))
if "AI" not in os.environ and not LAUNCHER.is_file():
    LAUNCHER = PACKAGE / "ai"
LAUNCHER = LAUNCHER.resolve()

FAKE_CODEX = r'''
import json
import os
from pathlib import Path
import subprocess
import sys

args = sys.argv[1:]
configs, options, prompts = {}, {}, []
index = 0
while index < len(args):
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
team = {p.name: p.read_text() for p in (root / ".codex/agents").glob("*.toml")}
instructions = "\n".join(str(v) for k, v in configs.items() if "instructions" in k)
for key, value in configs.items():
    if "instructions" in key and "file" in key and isinstance(value, str):
        path = Path(value)
        if path.is_file():
            instructions += "\n" + path.read_text()
instructions += "\n" + "\n".join(v for k, v in files.items() if k != "DEVLOG.md")
result = {
    "cwd": str(root), "argv": args, "configs": configs, "options": options,
    "prompts": prompts, "files": files, "team": team,
    "instructions": instructions,
    "head": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "branch": subprocess.check_output(["git", "branch", "--show-current"], text=True).strip(),
    "status": subprocess.check_output(["git", "status", "--porcelain"], text=True),
}
Path(os.environ["AI_TEST_RECORD"]).write_text(json.dumps(result))
sys.exit(int(os.environ.get("AI_TEST_EXIT", "0")))
'''


def model(slug, efforts, priority=1):
    return {
        "slug": slug,
        "visibility": "list",
        "priority": priority,
        "supported_reasoning_levels": [{"effort": effort} for effort in efforts],
    }


class CodexLaunchTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-codex-tests-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.repo = self.root / "project with spaces"
        self.repo.mkdir()
        self.cache_home = self.root / "codex-config"
        self.cache_home.mkdir()
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        fake = self.fakebin / "codex"
        fake.write_text("#!" + sys.executable + "\n" + FAKE_CODEX)
        fake.chmod(0o755)
        # These are child-process configuration overrides; the running test's
        # own HOME and CODEX_HOME, and the user's files, are never changed.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("AGENT_", "CODEX_", "GIT_", "AI_TEST_", "DIRENV_"))
        }
        self.env.update({
            "PATH": str(self.fakebin) + os.pathsep + os.environ["PATH"],
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

    def launch(self, *args, launcher=None, cwd=None, env=None):
        self.runs += 1
        record = self.root / ("record-%d.json" % self.runs)
        process_env = dict(self.env, AI_TEST_RECORD=str(record))
        process_env.update(env or {})
        process = subprocess.run(
            [str(launcher or LAUNCHER), *args], cwd=str(cwd or self.repo),
            env=process_env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, timeout=20,
        )
        captured = json.loads(record.read_text()) if record.exists() else None
        return process, captured

    def successful(self, *args, **kwargs):
        process, record = self.launch(*args, **kwargs)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIsNotNone(record, process.stderr)
        return record

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
                record = self.successful("codex", "--here", env={"AGENT_NO_AGENTS": "1"})
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
                self.assert_settings(self.successful("codex", "--here"), effort=expected)

    def test_known_model_overrides_have_model_specific_fallbacks(self):
        for slug, effort in [
            ("gpt-5.6-sol", "ultra"), ("gpt-5.6-terra", "ultra"),
            ("gpt-5.6-luna", "max"), ("gpt-5.5", "xhigh"),
        ]:
            with self.subTest(model=slug):
                record = self.successful("codex", "--here", env={"AGENT_CODEX_MODEL": slug})
                self.assert_settings(record, slug, effort)

    def test_override_model_uses_its_own_cache_entry(self):
        self.cache({"models": [model("gpt-6-astra", ["ultra"]),
                               model("custom-model", ["low", "high"], 90)]})
        record = self.successful("codex", "--here", env={"AGENT_CODEX_MODEL": "custom-model"})
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
        record = self.successful("codex", "--here", env={"AGENT_CODEX_EFFORT": "high"})
        self.assert_settings(record, effort="high")
        record = self.successful("codex", "--here", env={
            "AGENT_CODEX_MODEL": "custom-model", "AGENT_CODEX_EFFORT": "medium",
        })
        self.assert_settings(record, "custom-model", "medium")

    def test_launch_flags_and_project_trust(self):
        record = self.successful("codex", "--here")
        self.assertEqual(record["configs"].get("service_tier"), "fast")
        self.assertIn("--dangerously-bypass-approvals-and-sandbox", record["argv"])
        self.assertIn("--search", record["argv"])
        self.assertEqual(record["options"].get("--enable"), "multi_agent")
        self.assertEqual(record["configs"].get('projects."%s".trust_level' % self.repo), "trusted")
        record = self.successful("codex", "--here", env={"AGENT_CODEX_SEARCH": "0"})
        self.assertNotIn("--search", record["argv"])

    def test_explicit_empty_tier_preserves_codex_account_default(self):
        record = self.successful("codex", "--here", env={"AGENT_CODEX_TIER": ""})
        self.assertNotIn("service_tier", record["configs"])

    def test_legacy_overrides_work_and_current_names_take_precedence(self):
        legacy = {"AGENT_WT_CODEX_MODEL": "gpt-5.5", "AGENT_WT_CODEX_EFFORT": "high",
                  "AGENT_WT_CODEX_TIER": "flex", "AGENT_WT_CODEX_SEARCH": "0"}
        record = self.successful("codex", "--here", env=legacy)
        self.assert_settings(record, "gpt-5.5", "high")
        self.assertEqual(record["configs"].get("service_tier"), "flex")
        self.assertNotIn("--search", record["argv"])
        current = dict(legacy, AGENT_CODEX_MODEL="gpt-6-astra", AGENT_CODEX_EFFORT="ultra",
                       AGENT_CODEX_TIER="fast", AGENT_CODEX_SEARCH="1")
        record = self.successful("codex", "--here", env=current)
        self.assert_settings(record)
        self.assertEqual(record["configs"].get("service_tier"), "fast")
        self.assertIn("--search", record["argv"])

    def test_prompt_and_interactive_launch_preload_root_instructions(self):
        task = "Preserve this task verbatim.\nSecond line with $shell and `text`."
        for prompt in ([], [task]):
            with self.subTest(prompt=bool(prompt)):
                record = self.successful("codex", "--here", *prompt)
                self.assert_root_instructions(record)
                if prompt:
                    self.assertTrue("\n".join(record["prompts"]).endswith(task))
                else:
                    self.assertEqual(record["prompts"], [])

    def test_leading_dash_prompt_is_not_reinterpreted_as_codex_options(self):
        task = "--model another-model\n- fix the bug; preserve $shell and `text`"
        record = self.successful("codex", "--here", "--", task)
        self.assertEqual(record["prompts"], [task])
        self.assert_settings(record)
        self.assert_root_instructions(record)

    def test_source_layout_installs_team_and_cleans_up_in_place(self):
        exclude = self.repo / ".git/info/exclude"
        before = exclude.read_bytes()
        record = self.successful("codex", "--here")
        expected = {path.name for path in (SUPPORT / "codex-agents").glob("*.toml")}
        self.assertGreater(len(expected), 0)
        self.assertEqual(set(record["team"]), expected)
        # The logbook is intentionally committable; temporary agent definitions
        # must stay hidden from broad staging commands.
        self.assertEqual(record["status"].replace("?? DEVLOG.md\n", ""), "")
        self.assertFalse((self.repo / ".codex").exists())
        self.assertFalse((self.repo / "DEVLOG.md").exists())
        self.assertEqual(exclude.read_bytes(), before)
        self.assertEqual(self.git("status", "--porcelain"), "")

    def test_installed_flat_layout_through_symlink_finds_team(self):
        prefix = self.root / "installed payload"
        prefix.mkdir()
        shutil.copy2(LAUNCHER, prefix / "ai")
        shutil.copytree(SUPPORT, prefix / "agent.d")
        command = self.fakebin / "custom-ai-name"
        command.symlink_to(prefix / "ai")
        record = self.successful("codex", "--here", launcher=command)
        self.assertIn("architect.toml", record["team"])
        self.assert_root_instructions(record)

    def test_no_agents_does_not_install_team_or_claim_one_is_available(self):
        record = self.successful("codex", "--here", env={"AGENT_NO_AGENTS": "1"})
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
        record = self.successful("codex", "--here")
        self.assertEqual(record["team"]["architect.toml"], custom)
        self.assertEqual(record["files"]["AGENTS.md"], project_instructions)
        self.assert_root_instructions(record)
        self.assertEqual((agents / "architect.toml").read_text(), custom)
        self.assertEqual((self.repo / "AGENTS.md").read_text(), project_instructions)
        self.assertEqual(list(agents.iterdir()), [agents / "architect.toml"])
        self.assertEqual(self.git("status", "--porcelain"), status)

    def test_worktree_commands_use_committed_base_and_leave_dirty_source_untouched(self):
        (self.repo / "seed.txt").write_text("pre-existing dirty user work\n")
        (self.repo / "untracked.txt").write_text("also user-owned\n")
        source_status = self.git("status", "--porcelain")
        wrapper = LAUNCHER.parent / "codex-wt"
        cases = [(LAUNCHER, ["wt", "codex"]), (wrapper, [])]
        for index, (launcher, args) in enumerate(cases):
            with self.subTest(command=launcher.name):
                record = self.successful(*args, "-n", "isolated-%d" % index,
                                         "Worktree task", launcher=launcher)
                worktree = Path(record["cwd"])
                self.assertEqual(worktree.parent, Path(str(self.repo) + ".worktrees"))
                self.assertEqual(record["options"].get("-C"), str(worktree))
                self.assertEqual(record["head"], self.initial_head)
                self.assertTrue(record["branch"].startswith("codex/isolated-%d-" % index))
                self.assertEqual((worktree / "seed.txt").read_text(), "committed seed\n")
                self.assertFalse((worktree / "untracked.txt").exists())
                self.assertIn("architect.toml", record["team"])
                self.assert_root_instructions(record)
        self.assertEqual(self.git("branch", "--show-current").strip(), self.initial_branch)
        self.assertEqual(self.git("status", "--porcelain"), source_status)
        self.assertEqual((self.repo / "seed.txt").read_text(), "pre-existing dirty user work\n")

    def test_codex_stays_in_place_by_default_and_explicit_here_overrides_wt(self):
        for args in (["codex"], ["here", "codex"], ["codex", "--here"],
                     ["wt", "codex", "--here"]):
            with self.subTest(args=args):
                record = self.successful(*args)
                self.assertEqual(record["cwd"], str(self.repo))
                self.assertEqual(record["options"].get("-C"), str(self.repo))

    def test_dotted_names_and_prompts_produce_valid_direct_child_worktrees(self):
        for args in (["-n", "audit..dots", "task"], ["Review v1..v2"]):
            with self.subTest(args=args):
                record = self.successful("wt", "codex", *args)
                self.assertEqual(Path(record["cwd"]).parent, Path(str(self.repo) + ".worktrees"))
                self.git("check-ref-format", "--branch", record["branch"])

    def test_explicit_base_and_nested_launch_stay_anchored_to_main_repo(self):
        self.git("branch", "release-fixture")
        (self.repo / "seed.txt").write_text("new current-branch commit\n")
        self.git("commit", "-qam", "Advance current branch")
        first = self.successful("wt", "codex", "--base", "release-fixture", "-n", "release")
        self.assertEqual(first["head"], self.initial_head)
        second = self.successful("wt", "codex", "-n", "nested", cwd=first["cwd"])
        self.assertEqual(Path(second["cwd"]).parent, Path(str(self.repo) + ".worktrees"))
        self.assertEqual(second["head"], self.initial_head)

    def test_agent_exit_status_propagates_and_here_scaffold_is_cleaned(self):
        process, record = self.launch("wt", "codex", "--here", env={"AI_TEST_EXIT": "37"})
        self.assertEqual(process.returncode, 37, process.stderr)
        self.assertEqual(record["cwd"], str(self.repo))
        self.assertIn("architect.toml", record["team"])
        self.assertFalse((self.repo / ".codex").exists())
        self.assertFalse((self.repo / "DEVLOG.md").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")
        process, record = self.launch("wt", "codex", "-n", "failed-session",
                                      env={"AI_TEST_EXIT": "37"})
        self.assertEqual(process.returncode, 37, process.stderr)
        self.assertTrue(Path(record["cwd"]).is_dir())


if __name__ == "__main__":
    if not LAUNCHER.is_file():
        raise SystemExit("Cannot find ai launcher; set AI=/path/to/ai")
    unittest.main(verbosity=2)
