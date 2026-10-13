#!/usr/bin/env python3
"""Offline installer dependency tests: every package manager is a local fake.

The fixture PATH contains only explicitly selected utilities. Its copied
platform helper limits Homebrew discovery to that PATH so an actual macOS
Homebrew installation can never receive a package-install request.
DEPENDENCY_TEST_BASH can select another Bash (including Apple's Bash 3.2).
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parents[2]
BASH = Path(os.environ.get("DEPENDENCY_TEST_BASH", shutil.which("bash"))).resolve()


PLATFORM_FIXTURE = '''# Limit discovery to fake commands; never use host Homebrew.
ai_prefer_homebrew() {
  AI_HOMEBREW=""
  [ "$(uname -s)" = Darwin ] || return 0
  AI_HOMEBREW="$(command -v brew 2>/dev/null || true)"
  if [ -n "$AI_HOMEBREW" ]; then
    local brew_prefix=""
    brew_prefix="$("$AI_HOMEBREW" --prefix)" || return 1
    export PATH="$brew_prefix/bin:$brew_prefix/sbin:$PATH"
  fi
}
'''


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-kit dependencies ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.fakebin = self.root / "fixture commands"
        self.fakebin.mkdir()
        self.brew_prefix = self.root / "homebrew"
        (self.brew_prefix / "bin").mkdir(parents=True)
        self.prefix = self.root / "installed payload"
        self.bindir = self.root / "installed commands"
        self.manager_log = self.root / "manager.jsonl"
        self.sudo_log = self.root / "sudo.jsonl"
        self.package = self.root / "package"
        self.package.mkdir()
        for name in ("install.sh", "uninstall.sh", "VERSION"):
            shutil.copy2(PACKAGE / name, self.package / name)
        for name in ("bin", "agent.d"):
            shutil.copytree(PACKAGE / name, self.package / name)
        (self.package / "agent.d/lib/platform.sh").write_text(PLATFORM_FIXTURE)

        # Do not append the host PATH: it may contain real package managers or
        # direnv, either of which would invalidate or endanger these tests.
        for name in (
            "awk", "cat", "chmod", "cp", "date", "dirname", "find", "grep",
            "head", "ln", "mkdir", "readlink", "rm", "sed",
        ):
            source = shutil.which(name)
            self.assertIsNotNone(source, "test prerequisite missing: " + name)
            (self.fakebin / name).symlink_to(source)
        (self.fakebin / "bash").symlink_to(BASH)
        (self.fakebin / "python3").symlink_to(sys.executable)
        self.write_command("uname", '''import os, sys
print(os.environ["DEPENDENCY_TEST_OS"] if sys.argv[1:] == ["-s"] else "arm64")
''')
        self.write_command("git", '''import sys
if sys.argv[1:] == ["--version"]:
    print("git version 2.39.5")
else:
    sys.exit(1)
''')
        self.write_command("codex", 'print("codex-cli 0.154.0")\n')
        self.write_command("claude", 'print("2.1.0 (Claude Code)")\n')
        self.write_command("sudo", '''import json, os, sys
with open(os.environ["DEPENDENCY_TEST_SUDO_LOG"], "a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
args = sys.argv[1:]
if args and args[0] == "-n":
    args = args[1:]
if os.environ.get("DEPENDENCY_TEST_SUDO_FAIL") == "1":
    print("sudo: a password is required", file=sys.stderr)
    sys.exit(1)
os.execvp(args[0], args)
''')
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("AGENT_", "CODEX_", "GIT_", "DIRENV_", "DEPENDENCY_TEST_"))
        }
        self.env.update({
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "PATH": str(self.fakebin),
            "SHELL": "/bin/bash",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "DEPENDENCY_TEST_OS": "Linux",
            "DEPENDENCY_TEST_MANAGER_LOG": str(self.manager_log),
            "DEPENDENCY_TEST_SUDO_LOG": str(self.sudo_log),
            "DEPENDENCY_TEST_BREW_PREFIX": str(self.brew_prefix),
            "DEPENDENCY_TEST_INSTALL_BIN": str(self.fakebin),
            "DEPENDENCY_TEST_PYTHON": sys.executable,
        })

    def write_command(self, name, body, directory=None):
        path = (directory or self.fakebin) / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def add_direnv(self, version="2.37.1", directory=None):
        return self.write_command(
            "direnv", "import sys\nprint(%r) if sys.argv[1:] == ['version'] else sys.exit(0)\n" % version,
            directory=directory,
        )

    def add_manager(self, name):
        return self.write_command(name, '''import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "brew" and args == ["--prefix"]:
    print(os.environ["DEPENDENCY_TEST_BREW_PREFIX"])
    sys.exit(0)
with open(os.environ["DEPENDENCY_TEST_MANAGER_LOG"], "a") as log:
    log.write(json.dumps([name] + args) + "\\n")
mode = os.environ.get("DEPENDENCY_TEST_INSTALL_MODE", "success")
if args == ["update"]:
    sys.exit(1 if mode == "update_failure" else 0)
if mode == "failure":
    print("fixture package installation failed", file=sys.stderr)
    sys.exit(1)
if mode != "missing":
    binary = pathlib.Path(os.environ["DEPENDENCY_TEST_INSTALL_BIN"]) / "direnv"
    body = "import sys\\nsys.exit(1)\\n" if mode == "broken" else "print('2.37.1')\\n"
    binary.write_text("#!" + os.environ["DEPENDENCY_TEST_PYTHON"] + "\\n" + body)
    binary.chmod(0o755)
''')

    def install(self, *args, env=None):
        return subprocess.run(
            [str(BASH), str(self.package / "install.sh"), "-y", "--prefix", str(self.prefix),
             "--bin-dir", str(self.bindir), "--name", "kit", *map(str, args)],
            cwd=self.root, env=dict(self.env, **(env or {})), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
        )

    def successful(self, process):
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertTrue((self.prefix / "ai").is_file())
        self.assertEqual((self.bindir / "kit").resolve(), self.prefix / "ai")

    def calls(self, path=None):
        path = path or self.manager_log
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def preserve_existing_payload(self):
        (self.prefix / "agent.d").mkdir(parents=True)
        (self.prefix / "agent.d/keep-me").write_text("old team\n")
        (self.prefix / "ai").write_text("old launcher\n")

    def assert_payload_preserved(self):
        self.assertEqual((self.prefix / "agent.d/keep-me").read_text(), "old team\n")
        self.assertEqual((self.prefix / "ai").read_text(), "old launcher\n")
        self.assertFalse(self.bindir.exists())

    def test_existing_linux_direnv_skips_package_installation(self):
        self.add_direnv()
        self.add_manager("apt-get")
        self.successful(self.install())
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.calls(self.sudo_log), [])

    def test_minimum_direnv_version_is_accepted(self):
        self.add_direnv("2.33.0")
        self.successful(self.install())
        self.assertEqual(self.calls(), [])

    def test_old_direnv_versions_preserve_payload_and_request_upgrade(self):
        self.preserve_existing_payload()
        self.add_manager("apt-get")
        for version in ("1.99.9", "2.32.3"):
            with self.subTest(version=version):
                self.add_direnv(version)
                process = self.install()
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("2.33.0", process.stderr)
                self.assertIn(version, process.stderr)
                self.assertRegex(process.stderr, r"(?i)upgrade")
                self.assertEqual(self.calls(), [])
                self.assert_payload_preserved()

    def test_unparseable_direnv_version_preserves_payload(self):
        self.preserve_existing_payload()
        self.add_direnv("unknown")
        process = self.install()
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("2.33.0", process.stderr)
        self.assertIn("unknown", process.stderr)
        self.assert_payload_preserved()

    def test_existing_macos_system_direnv_needs_no_homebrew(self):
        self.add_direnv()
        self.successful(self.install(env={"DEPENDENCY_TEST_OS": "Darwin"}))
        self.assertEqual(self.calls(), [])

    def test_macos_prefers_existing_homebrew_direnv(self):
        self.add_manager("brew")
        self.add_direnv("2.38.0", directory=self.brew_prefix / "bin")
        self.add_direnv("2.30.0")
        process = self.install(env={"DEPENDENCY_TEST_OS": "Darwin"})
        self.successful(process)
        self.assertIn("2.38.0", process.stderr)
        self.assertNotIn("2.30.0", process.stderr)
        self.assertEqual(self.calls(), [])

    def test_macos_reuses_system_direnv_when_homebrew_has_no_direnv(self):
        self.add_manager("brew")
        self.add_direnv()
        self.successful(self.install(env={"DEPENDENCY_TEST_OS": "Darwin"}))
        self.assertEqual(self.calls(), [])

    def test_macos_installs_missing_direnv_with_existing_homebrew(self):
        self.add_manager("brew")
        self.successful(self.install(env={
            "DEPENDENCY_TEST_OS": "Darwin",
            "DEPENDENCY_TEST_INSTALL_BIN": str(self.brew_prefix / "bin"),
        }))
        self.assertEqual(self.calls(), [["brew", "install", "direnv"]])
        self.assertEqual(self.calls(self.sudo_log), [])

    def test_macos_without_direnv_or_homebrew_has_actionable_error(self):
        self.preserve_existing_payload()
        process = self.install(env={"DEPENDENCY_TEST_OS": "Darwin"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("direnv", process.stderr)
        self.assertRegex(process.stderr, r"(?i)(homebrew|brew install)")
        self.assert_payload_preserved()
        self.assertEqual(self.calls(), [])

    def check_linux_manager(self, manager, expected):
        self.add_manager(manager)
        self.successful(self.install())
        self.assertEqual(self.calls(), expected)
        sudo_calls = self.calls(self.sudo_log)
        if os.geteuid() == 0:
            self.assertEqual(sudo_calls, [])
        else:
            self.assertEqual(len(sudo_calls), len(expected))
            for call, manager_call in zip(sudo_calls, expected):
                self.assertEqual(call[0], "-n", "non-interactive install must not wait for a password")
                self.assertEqual(Path(call[1]).name, manager_call[0])
                self.assertEqual(call[2:], manager_call[1:])

    def test_linux_apt_get(self):
        self.check_linux_manager("apt-get", [["apt-get", "update"], ["apt-get", "install", "-y", "direnv"]])

    def test_linux_dnf(self):
        self.check_linux_manager("dnf", [["dnf", "install", "-y", "direnv"]])

    def test_linux_yum(self):
        self.check_linux_manager("yum", [["yum", "install", "-y", "direnv"]])

    def test_linux_pacman(self):
        self.check_linux_manager("pacman", [["pacman", "-S", "--needed", "--noconfirm", "direnv"]])

    def test_linux_zypper(self):
        self.check_linux_manager("zypper", [["zypper", "--non-interactive", "install", "direnv"]])

    def test_linux_apk(self):
        self.check_linux_manager("apk", [["apk", "add", "direnv"]])

    def test_linux_prefers_native_package_manager_before_homebrew(self):
        self.add_manager("apt-get")
        self.add_manager("dnf")
        self.add_manager("brew")
        self.successful(self.install())
        self.assertEqual(self.calls(), [["apt-get", "update"], ["apt-get", "install", "-y", "direnv"]])

    def test_linux_without_package_manager_preserves_payload(self):
        self.preserve_existing_payload()
        process = self.install()
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("direnv", process.stderr)
        self.assertRegex(process.stderr, r"(?i)install")
        self.assert_payload_preserved()

    def test_failed_package_install_preserves_existing_payload(self):
        self.add_manager("apt-get")
        self.preserve_existing_payload()
        process = self.install(env={"DEPENDENCY_TEST_INSTALL_MODE": "failure"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("direnv", process.stderr)
        self.assert_payload_preserved()

    def test_failed_apt_update_stops_before_install_and_preserves_payload(self):
        self.add_manager("apt-get")
        self.preserve_existing_payload()
        process = self.install(env={"DEPENDENCY_TEST_INSTALL_MODE": "update_failure"})
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.calls(), [["apt-get", "update"]])
        self.assert_payload_preserved()

    def test_package_success_without_direnv_is_rejected(self):
        self.add_manager("apt-get")
        self.preserve_existing_payload()
        process = self.install(env={"DEPENDENCY_TEST_INSTALL_MODE": "missing"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("direnv", process.stderr)
        self.assert_payload_preserved()

    def test_installed_direnv_must_execute_successfully(self):
        self.add_manager("apt-get")
        self.preserve_existing_payload()
        process = self.install(env={"DEPENDENCY_TEST_INSTALL_MODE": "broken"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("direnv", process.stderr)
        self.assert_payload_preserved()

    def test_command_conflict_is_rejected_before_installing_dependencies(self):
        self.add_manager("apt-get")
        self.bindir.mkdir()
        foreign = self.bindir / "kit"
        foreign.write_text("user command\n")
        process = self.install()
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Conflict", process.stderr)
        self.assertEqual(foreign.read_text(), "user command\n")
        self.assertFalse(self.prefix.exists())
        self.assertEqual(self.calls(), [])

    def test_invalid_prefix_is_rejected_before_installing_dependencies(self):
        self.add_manager("apt-get")
        process = self.install("--prefix", self.home)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.calls(), [])

    @unittest.skipIf(os.geteuid() == 0, "root does not need sudo")
    def test_noninteractive_sudo_failure_preserves_payload(self):
        self.add_manager("apt-get")
        self.preserve_existing_payload()
        process = self.install(env={"DEPENDENCY_TEST_SUDO_FAIL": "1"})
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.calls(), [])
        self.assertEqual(self.calls(self.sudo_log)[0][0], "-n")
        self.assert_payload_preserved()

    @unittest.skipIf(os.geteuid() == 0, "root does not need sudo")
    def test_missing_sudo_preserves_payload_and_explains_install(self):
        (self.fakebin / "sudo").unlink()
        self.add_manager("apt-get")
        self.preserve_existing_payload()
        process = self.install()
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("sudo", process.stderr)
        self.assertIn("direnv", process.stderr)
        self.assertEqual(self.calls(), [])
        self.assert_payload_preserved()


if __name__ == "__main__":
    unittest.main()
