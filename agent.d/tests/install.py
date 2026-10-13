#!/usr/bin/env python3
"""Test installation and removal with native Bash and portable utilities.

Run install.sh, optionally with unittest arguments such as -v or -k upgrade.
INSTALL_TEST_BASH selects a Bash executable (e.g. /bin/bash on macOS).
Every install, home directory, command link and Git setting is a temporary
fixture. Fake agent/direnv CLIs avoid network access and package installation;
a readlink shim deliberately rejects GNU options even on Linux.
"""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parents[2]
BASH = Path(os.environ.get("INSTALL_TEST_BASH", shutil.which("bash"))).resolve()
REAL_GIT = shutil.which("git")


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-kit install tests ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.prefix = self.root / "payload with spaces"
        self.bindir = self.root / "commands with spaces"
        self.fakebin = self.root / "fakebin"
        self.fakebin.mkdir()
        self.brew_prefix = self.root / "homebrew prefix"
        (self.brew_prefix / "bin").mkdir(parents=True)
        self.write_command("bash", 'import os, sys\nos.execv(%r, [%r] + sys.argv[1:])\n' % (str(BASH), str(BASH)))
        self.write_command("uname", 'import os, sys\nprint(os.environ.get("INSTALL_TEST_OS", "Darwin") if sys.argv[1:] == ["-s"] else "arm64")\n')
        # Keep actual host Homebrew out of the fixture. Its real tools must not
        # shadow the fake Git/readlink binaries that exercise portability.
        self.write_command("brew", '''import os, sys
if sys.argv[1:] == ["--prefix"] and not os.environ.get("INSTALL_TEST_BREW_BROKEN"):
    print(os.environ["INSTALL_TEST_BREW_PREFIX"])
else:
    sys.exit(1)
''')
        self.write_command("readlink", '''import os, sys
if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
    print("readlink: GNU options are not available in this fixture", file=sys.stderr)
    sys.exit(64)
try:
    print(os.readlink(sys.argv[1]))
except OSError:
    sys.exit(1)
''')
        self.write_command("git", '''import os, sys
if sys.argv[1:] == ["--version"] and "INSTALL_TEST_GIT_VERSION" in os.environ:
    print("git version " + os.environ["INSTALL_TEST_GIT_VERSION"])
else:
    os.execv(%r, [%r] + sys.argv[1:])
''' % (REAL_GIT, REAL_GIT))
        self.write_command("codex", 'print("codex-cli 0.154.0")\n')
        self.write_command("claude", 'print("2.1.0 (Claude Code)")\n')
        self.write_command("direnv", 'import sys\nsys.exit(0) if sys.argv[1:] != ["version"] else print("2.37.1")\n')
        # Override configuration only in child processes, leaving the running
        # tests and the user's shell/environment untouched.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("AGENT_", "CODEX_", "GIT_", "DIRENV_", "INSTALL_TEST_"))
        }
        self.env.update({
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "PATH": str(self.fakebin) + os.pathsep + os.environ["PATH"],
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "INSTALL_TEST_OS": "Darwin",
            "INSTALL_TEST_BREW_PREFIX": str(self.brew_prefix),
        })

    def write_command(self, name, body, directory=None):
        path = (directory or self.fakebin) / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def run_script(self, script, *args, env=None):
        return subprocess.run(
            [str(BASH), str(script), *map(str, args)], cwd=self.root,
            env=dict(self.env, **(env or {})), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
        )

    def install(self, *args, script=None, env=None):
        return self.run_script(
            script or PACKAGE / "install.sh", "-y", "--prefix", self.prefix,
            "--bin-dir", self.bindir, "--name", "kit", *args, env=env,
        )

    def successful(self, process):
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_macos_install_shortcuts_and_launch_help(self):
        self.successful(self.install("--shortcuts"))
        for name, target in (
            ("kit", "ai"), ("kit-wt", "agent-wt"),
            ("claude-wt", "claude-wt"), ("codex-wt", "codex-wt"),
        ):
            with self.subTest(command=name):
                link = self.bindir / name
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.resolve(), self.prefix / target)
                self.assertTrue(os.access(link, os.X_OK))
                process = self.run_script(link, "--help")
                self.successful(process)
                self.assertIn("usage:", process.stdout.lower())
        self.assertTrue((self.prefix / "agent.d/README.md").is_file())
        self.assertIn("command=kit\n", (self.prefix / "manifest").read_text())

    def test_linux_install_and_uninstall(self):
        self.successful(self.install(env={"INSTALL_TEST_OS": "Linux"}))
        self.successful(self.run_script(self.prefix / "uninstall.sh", "-y"))
        self.assertFalse(self.prefix.exists())
        self.assertFalse((self.bindir / "kit").is_symlink())

    def test_upgrade_rename_removes_owned_shortcuts(self):
        self.successful(self.install("--shortcuts"))
        (self.prefix / "user-note").write_text("keep me\n")
        self.successful(self.install("--name", "renamed", "--no-shortcuts"))
        self.assertEqual((self.prefix / "user-note").read_text(), "keep me\n")
        self.assertEqual((self.bindir / "renamed").resolve(), self.prefix / "ai")
        for name in ("kit", "kit-wt", "claude-wt", "codex-wt"):
            self.assertFalse((self.bindir / name).is_symlink(), name)
        manifest = (self.prefix / "manifest").read_text()
        self.assertEqual(sum(line.startswith("link=") for line in manifest.splitlines()), 1)

    def test_upgrade_same_name_accepts_relative_symlink_chain(self):
        self.successful(self.install())
        link = self.bindir / "kit"
        link.unlink()
        bridge = self.root / "relative bridge"
        bridge.symlink_to(os.path.relpath(self.prefix / "ai", bridge.parent))
        link.symlink_to(os.path.relpath(bridge, self.bindir))
        self.successful(self.install())
        self.assertEqual(link.resolve(), self.prefix / "ai")

    def test_installer_source_resolves_relative_symlink(self):
        link = self.root / "installer link"
        link.symlink_to(os.path.relpath(PACKAGE / "install.sh", link.parent))
        self.successful(self.install(script=link))
        self.assertTrue((self.prefix / "agent.d/README.md").is_file())

    def test_prefix_through_symlink_uninstalls_from_installed_copy(self):
        actual = self.root / "real parent"
        actual.mkdir()
        alias = self.root / "parent alias"
        alias.symlink_to(actual, target_is_directory=True)
        self.prefix = alias / "payload"
        self.successful(self.install())
        self.successful(self.run_script(self.prefix / "uninstall.sh", "-y"))
        self.assertFalse((actual / "payload").exists())
        self.assertFalse((self.bindir / "kit").is_symlink())
        self.assertTrue(alias.is_symlink())

    def test_conflicting_foreign_link_preserves_existing_files(self):
        self.bindir.mkdir()
        foreign = self.root / "foreign tool"
        foreign.write_text("user-owned\n")
        link = self.bindir / "kit"
        link.symlink_to(foreign)
        process = self.install()
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Conflict", process.stderr)
        self.assertEqual(link.resolve(), foreign)
        self.assertEqual(foreign.read_text(), "user-owned\n")
        self.assertFalse(self.prefix.exists())

    def test_uninstall_leaves_replaced_foreign_link_and_user_config(self):
        self.successful(self.install("--shortcuts"))
        foreign = self.root / "other tool"
        foreign.write_text("owned by somebody else\n")
        link = self.bindir / "codex-wt"
        link.unlink()
        link.symlink_to(foreign)
        settings = self.home / ".codex/config.toml"
        settings.parent.mkdir()
        settings.write_text('model = "personal"\n')
        self.successful(self.run_script(self.prefix / "uninstall.sh", "-y"))
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), foreign)
        self.assertEqual(settings.read_text(), 'model = "personal"\n')
        for name in ("kit", "kit-wt", "claude-wt"):
            self.assertFalse((self.bindir / name).is_symlink(), name)
        self.assertFalse(self.prefix.exists())

    def test_git_preflight_rejects_version_without_required_worktree_features(self):
        process = self.install(env={"INSTALL_TEST_GIT_VERSION": "2.30.9"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("2.31", process.stderr)
        self.assertFalse(self.prefix.exists())

    def test_git_preflight_accepts_apple_version_suffix(self):
        self.successful(self.install(env={"INSTALL_TEST_GIT_VERSION": "2.39.5 (Apple Git-154)"}))

    def test_macos_prefers_existing_homebrew_git(self):
        self.write_command("git", '''import os, sys
if sys.argv[1:] == ["--version"]:
    print("git version 2.50.0")
else:
    os.execv(%r, [%r] + sys.argv[1:])
''' % (REAL_GIT, REAL_GIT), directory=self.brew_prefix / "bin")
        process = self.install(env={"INSTALL_TEST_GIT_VERSION": "2.30.9"})
        self.successful(process)
        self.assertIn("git 2.50.0", process.stderr)

    def test_macos_falls_back_to_path_when_homebrew_lacks_git(self):
        process = self.install(env={"INSTALL_TEST_GIT_VERSION": "2.39.5"})
        self.successful(process)
        self.assertIn("git 2.39.5", process.stderr)

    def test_macos_falls_back_to_path_when_homebrew_prefix_lookup_fails(self):
        process = self.install(env={
            "INSTALL_TEST_BREW_BROKEN": "1", "INSTALL_TEST_GIT_VERSION": "2.39.5",
        })
        self.successful(process)
        self.assertIn("git 2.39.5", process.stderr)

    def test_linux_keeps_callers_path_priority(self):
        self.write_command("git", 'print("git version 2.50.0")\n', directory=self.brew_prefix / "bin")
        process = self.install(env={
            "INSTALL_TEST_OS": "Linux", "INSTALL_TEST_GIT_VERSION": "2.30.9",
        })
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("2.30.9", process.stderr)
        self.assertFalse(self.prefix.exists())

    def test_missing_git_provides_platform_install_guidance(self):
        (self.fakebin / "git").unlink()
        for command in ("dirname", "cat"):
            (self.fakebin / command).symlink_to(shutil.which(command))
        for platform, remedy in (("Darwin", "xcode-select --install"), ("Linux", "package manager")):
            with self.subTest(platform=platform):
                process = self.install(env={"PATH": str(self.fakebin), "INSTALL_TEST_OS": platform})
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("git not found", process.stderr)
                self.assertIn(remedy, process.stderr)
                self.assertFalse(self.prefix.exists())

    def test_unsupported_platform_fails_before_writing_payload(self):
        process = self.install(env={"INSTALL_TEST_OS": "FreeBSD"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("FreeBSD", process.stderr)
        self.assertFalse(self.prefix.exists())


if __name__ == "__main__":
    unittest.main()
