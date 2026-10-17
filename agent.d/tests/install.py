#!/usr/bin/env python3
"""Test installation and removal with native Bash and portable utilities.

Run install.sh: the tests run in parallel worker processes (parallel_runner.py,
AI_TEST_JOBS=1 for one), or in-process given unittest arguments such as -k upgrade.
INSTALL_TEST_BASH selects a Bash executable (e.g. /bin/bash on macOS).
Every install, home directory, command link and Git setting is a temporary
fixture. Fake agent CLIs avoid network access. direnv and every package manager
are hidden from PATH, and logging fakes stand in for the package managers, so a
regression can never install anything on the host. A readlink shim deliberately
rejects GNU options even on Linux.

The fake commands are written once per run and shared by every test: on hosts
whose endpoint security scans each new executable on its first exec, a fresh
copy per test cost about half a second per command.
"""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


PACKAGE = Path(__file__).resolve().parents[2]
BASH = Path(os.environ.get("INSTALL_TEST_BASH") or shutil.which("bash")).resolve()
REAL_GIT = shutil.which("git")
REAL_READLINK = shutil.which("readlink")
# Anything that could fetch or install software. install.sh must call none of
# them: users bring their own claude/codex, and direnv is optional.
INSTALLERS = ("brew", "port", "apt-get", "apt", "dnf", "yum", "pacman", "zypper",
              "apk", "sudo", "curl", "wget")
PAYLOAD = {"ai", "agent.d", "uninstall.sh", "VERSION", "manifest"}
# Every command name a test installs or a re-run probes for. They are hidden
# from PATH: a re-run finds the install behind the command PATH resolves, and a
# test must never find (and upgrade) the user's real one.
COMMAND_NAMES = ("ai", "ai-kit", "kit", "renamed", "third")


def command(path, body):
    """Write a /bin/sh command: it starts about ten times faster than Python."""
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return path


def path_without(names, shadow_root):
    """The caller's PATH with every command in `names` hidden.

    A directory that holds one of them is replaced by a shadow directory of
    symlinks to its other entries, so ordinary tools stay reachable wherever
    direnv or a package manager happens to be installed (e.g. /usr/bin).
    """
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


class InstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shared = tempfile.TemporaryDirectory(prefix="ai-kit install fixtures ")
        cls.addClassCleanup(shared.cleanup)
        shared_root = Path(shared.name).resolve()
        cls.tools = shared_root / "tools"
        cls.tools.mkdir()
        # A symlink, not a wrapper: `#!/usr/bin/env bash` scripts (the installed
        # launcher) must run under the Bash being tested.
        (cls.tools / "bash").symlink_to(BASH)
        command(cls.tools / "uname", 'if [ "$1" = -s ]; then echo "${INSTALL_TEST_OS:-Darwin}"; else echo arm64; fi\n')
        command(cls.tools / "readlink", """\
case "$#:$1" in
  1:-*) ;;
  1:*) exec %s "$1" ;;
esac
echo "readlink: GNU options are not available in this fixture" >&2
exit 64
""" % shlex.quote(REAL_READLINK))
        command(cls.tools / "git", """\
if [ "$#" -eq 1 ] && [ "$1" = --version ] && [ -n "${INSTALL_TEST_GIT_VERSION+set}" ]; then
  echo "git version $INSTALL_TEST_GIT_VERSION"
else
  exec %s "$@"
fi
""" % shlex.quote(REAL_GIT))
        command(cls.tools / "codex", 'echo "codex-cli 0.154.0"\n')
        command(cls.tools / "claude", 'echo "2.1.0 (Claude Code)"\n')
        for name in INSTALLERS:
            command(cls.tools / name, 'echo "${0##*/} $*" >>"$INSTALL_TEST_INSTALLER_LOG"; exit 1\n')
        cls.path = str(cls.tools) + os.pathsep + path_without(
            INSTALLERS + ("direnv",) + COMMAND_NAMES, shared_root / "shadow")

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-kit install tests ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.prefix = self.root / "payload with spaces"
        self.bindir = self.root / "commands with spaces"
        self.installer_log = self.root / "installers.log"
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
            "PATH": self.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "INSTALL_TEST_OS": "Darwin",
            "INSTALL_TEST_INSTALLER_LOG": str(self.installer_log),
        })

    def tearDown(self):
        # Every test, not only the dedicated one: nothing may ever be installed.
        self.assertFalse(self.installer_log.exists(),
                         "a package manager or downloader ran:\n" +
                         (self.installer_log.read_text() if self.installer_log.exists() else ""))

    def run_script(self, script, *args, env=None, cwd=None):
        return subprocess.run(
            [str(BASH), str(script), *map(str, args)], cwd=cwd or self.root,
            env=dict(self.env, **(env or {})), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60,
        )

    def install(self, *args, script=None, env=None):
        return self.run_script(
            script or PACKAGE / "install.sh", "-y", "--prefix", self.prefix,
            "--bin-dir", self.bindir, "--name", "kit", *args, env=env,
        )

    def successful(self, process):
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        return process

    def manifest_links(self):
        return [line[len("link="):] for line in (self.prefix / "manifest").read_text().splitlines()
                if line.startswith("link=")]

    def test_install_creates_one_link_to_the_payload_and_it_launches(self):
        self.successful(self.install())
        self.assertEqual(os.listdir(self.bindir), ["kit"])
        link = self.bindir / "kit"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.resolve(), self.prefix / "ai")
        self.assertTrue(os.access(link, os.X_OK))
        self.assertEqual(self.manifest_links(), [str(link)])
        self.assertIn("command=kit\n", (self.prefix / "manifest").read_text())
        self.assertEqual(set(os.listdir(self.prefix)), PAYLOAD)
        support = self.prefix / "agent.d"
        self.assertEqual(len(list((support / "agents").glob("*.md"))), 7)
        self.assertEqual(len(list((support / "codex-agents").glob("*.toml"))), 7)
        self.assertTrue((support / "DEVLOG.template.md").is_file())
        # README.md at the repository root is the only manual; nothing ships one.
        self.assertEqual(list(self.prefix.rglob("README*")), [])
        process = self.successful(self.run_script(link, "--help"))
        self.assertIn("usage: kit ", process.stdout)

    def test_linux_install_and_uninstall(self):
        self.successful(self.install(env={"INSTALL_TEST_OS": "Linux"}))
        self.successful(self.run_script(self.prefix / "uninstall.sh", "-y"))
        self.assertFalse(self.prefix.exists())
        self.assertEqual(os.listdir(self.bindir), [])

    def test_shortcut_options_were_removed(self):
        for option in ("--shortcuts", "--no-shortcuts"):
            with self.subTest(option=option):
                process = self.install(option)
                self.assertEqual(process.returncode, 1, process.stderr)
                self.assertIn("unknown option: " + option, process.stderr)
                self.assertFalse(self.prefix.exists())
                self.assertFalse(self.bindir.exists())

    def test_upgrade_removes_links_an_older_install_recorded_but_not_foreign_ones(self):
        self.successful(self.install())
        # What an older ai-kit left behind: wrapper scripts in the payload, an
        # owned link to each, all recorded in the manifest...
        shortcuts = {"kit-wt": "agent-wt", "claude-wt": "claude-wt", "codex-wt": "codex-wt"}
        with open(self.prefix / "manifest", "a") as manifest:
            for name, wrapper in shortcuts.items():
                (self.prefix / wrapper).write_text("#!/bin/sh\n")
                (self.bindir / name).symlink_to(self.prefix / wrapper)
                manifest.write("link=%s\n" % (self.bindir / name))
        # ...except that the user has since put their own tool at one of the names.
        foreign = self.root / "users own codex-wt"
        foreign.write_text("user-owned\n")
        (self.bindir / "codex-wt").unlink()
        (self.bindir / "codex-wt").symlink_to(foreign)
        (self.prefix / "user-note").write_text("keep me\n")
        (self.prefix / "user-note").chmod(0o600)
        (self.prefix / "user-dir").mkdir(mode=0o700)

        self.successful(self.install("--name", "renamed"))
        self.assertEqual(sorted(os.listdir(self.bindir)), ["codex-wt", "renamed"])
        self.assertEqual((self.bindir / "renamed").resolve(), self.prefix / "ai")
        self.assertEqual((self.bindir / "codex-wt").resolve(), foreign)
        self.assertEqual(foreign.read_text(), "user-owned\n")
        self.assertEqual((self.prefix / "user-note").read_text(), "keep me\n")
        # Modes are set on the payload only, never on what the user put there.
        self.assertEqual((self.prefix / "user-note").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.prefix / "user-dir").stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.manifest_links(), [str(self.bindir / "renamed")])
        # The older launchers' wrapper scripts go too; the user's files stay.
        self.assertEqual(set(os.listdir(self.prefix)), PAYLOAD | {"user-note", "user-dir"})

    def reinstall(self, *args, env=None):
        """Re-run install.sh -y with only `args`: the upgrade a `git pull` user runs."""
        return self.successful(self.run_script(PACKAGE / "install.sh", "-y", *args, env=env))

    def assert_unchanged_install(self, process):
        self.assertIn("upgrading ai-kit", process.stderr)
        self.assertEqual(os.listdir(self.bindir), ["kit"])
        self.assertEqual((self.bindir / "kit").resolve(), self.prefix / "ai")
        self.assertEqual(self.manifest_links(), [str(self.bindir / "kit")])
        manifest = (self.prefix / "manifest").read_text()
        self.assertIn("bin_dir=%s\n" % self.bindir, manifest)
        self.assertIn("command=kit\n", manifest)
        # Nothing laid down at the built-in defaults beside it.
        self.assertFalse((self.home / ".local").exists())

    def test_rerun_with_only_the_prefix_keeps_the_recorded_settings(self):
        self.successful(self.install())
        self.assert_unchanged_install(self.reinstall("--prefix", self.prefix))

    def test_rerun_with_no_options_finds_the_install_through_its_command(self):
        self.successful(self.install())
        # Through the link where the command would go...
        self.assert_unchanged_install(self.reinstall("--bin-dir", self.bindir, "--name", "kit"))
        # ...and through the command PATH finds, with nothing given at all but its name.
        self.assert_unchanged_install(self.reinstall(
            "--name", "kit", env={"PATH": str(self.bindir) + os.pathsep + self.path}))

    def test_rerun_with_no_options_finds_the_install_at_the_default_prefix(self):
        self.prefix = self.home / ".local/share/ai-kit"
        self.successful(self.install())
        self.assertEqual(os.listdir(self.home / ".local"), ["share"])
        process = self.reinstall()
        self.assertIn("upgrading ai-kit", process.stderr)
        self.assertEqual(os.listdir(self.bindir), ["kit"])
        self.assertEqual((self.bindir / "kit").resolve(), self.prefix / "ai")
        self.assertEqual(self.manifest_links(), [str(self.bindir / "kit")])
        self.assertFalse((self.home / ".local/bin").exists())

    def test_rerun_finds_the_install_through_any_link_in_the_command_directory(self):
        # A custom prefix and name: neither the default prefix nor `ai` leads to it.
        self.bindir = self.home / ".local/bin"
        self.successful(self.install())
        process = self.reinstall()
        self.assertIn("upgrading ai-kit", process.stderr)
        self.assertEqual(os.listdir(self.bindir), ["kit"])
        self.assertEqual((self.bindir / "kit").resolve(), self.prefix / "ai")
        self.assertFalse((self.home / ".local/share").exists())
        # Renaming finds it the same way, and moves the one command.
        self.reinstall("--name", "renamed")
        self.assertEqual(os.listdir(self.bindir), ["renamed"])
        self.assertEqual(self.manifest_links(), [str(self.bindir / "renamed")])
        self.assertFalse((self.home / ".local/share").exists())

    def test_rerun_does_not_guess_between_two_installs_in_the_command_directory(self):
        self.bindir = self.home / ".local/bin"
        self.successful(self.install())
        second = self.root / "second payload"
        self.successful(self.run_script(PACKAGE / "install.sh", "-y", "--prefix", second,
                                        "--bin-dir", self.bindir, "--name", "renamed"))
        before = (self.prefix / "manifest").read_text(), (second / "manifest").read_text()
        process = self.run_script(PACKAGE / "install.sh", "-y")
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn("several ai-kit installs", process.stderr)
        self.assertIn(str(self.prefix), process.stderr)
        self.assertIn(str(second), process.stderr)
        self.assertEqual(((self.prefix / "manifest").read_text(), (second / "manifest").read_text()), before)
        # The default prefix is preferred to the scan: it is no guess.
        self.prefix = self.home / ".local/share/ai-kit"
        self.successful(self.install("--name", "third"))
        process = self.reinstall()
        self.assertIn("upgrading ai-kit", process.stderr)
        self.assertIn("at %s\n" % self.prefix, process.stderr)

    def test_fresh_install_says_it_found_no_install_to_upgrade(self):
        process = self.reinstall()
        self.assertIn("No existing install found", process.stderr)
        self.assertNotIn("upgrading ai-kit", process.stderr)
        self.assertTrue((self.home / ".local/bin/ai").is_symlink())

    def test_moving_the_prefix_names_the_install_that_owns_the_command(self):
        self.successful(self.install())
        elsewhere = self.root / "elsewhere"
        process = self.run_script(PACKAGE / "install.sh", "-y", "--prefix", elsewhere,
                                  "--bin-dir", self.bindir, "--name", "kit")
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn("is the command of the ai-kit install at %s" % self.prefix, process.stderr)
        self.assertIn("uninstall.sh", process.stderr)
        self.assertNotIn("not created by ai-kit", process.stderr)
        self.assertFalse(elsewhere.exists())
        self.assertEqual((self.bindir / "kit").resolve(), self.prefix / "ai")

    def test_rerun_keeps_the_recorded_name_when_another_command_shadows_it(self):
        self.successful(self.install())
        other = self.root / "other tools"
        other.mkdir()
        command(other / "kit", "exit 0\n")
        process = self.reinstall("--prefix", self.prefix, env={
            "PATH": os.pathsep.join([str(other), str(self.bindir), self.path])})
        self.assertIn("'kit' is already a command on your PATH", process.stderr)
        self.assertNotIn("Suggesting", process.stderr)
        self.assertEqual(os.listdir(self.bindir), ["kit"])

    def test_rerun_option_still_overrides_a_recorded_setting(self):
        self.successful(self.install())
        self.reinstall("--prefix", self.prefix, "--name", "renamed")
        self.assertEqual(os.listdir(self.bindir), ["renamed"])
        self.assertEqual(self.manifest_links(), [str(self.bindir / "renamed")])

    def test_rerun_does_not_trust_a_manifest_recording_another_prefix(self):
        self.successful(self.install())
        manifest = self.prefix / "manifest"
        manifest.write_text(manifest.read_text().replace(
            "prefix=%s\n" % self.prefix, "prefix=%s\n" % (self.root / "elsewhere")))
        process = self.reinstall("--prefix", self.prefix)
        self.assertIn("records the prefix '%s'" % (self.root / "elsewhere"), process.stderr)
        self.assertNotIn("upgrading ai-kit", process.stderr)
        self.assertIn("command=ai\n", manifest.read_text())
        self.assertTrue((self.home / ".local/bin/ai").is_symlink())

    def test_upgrade_keeps_the_link_a_manifest_recorded_through_a_symlink(self):
        self.successful(self.install())
        # An older manifest that named the command directory through a symlink
        # still describes the very link this run recreates.
        alias = self.root / "commands alias"
        alias.symlink_to(self.bindir, target_is_directory=True)
        manifest = self.prefix / "manifest"
        manifest.write_text(manifest.read_text().replace(
            "link=%s\n" % (self.bindir / "kit"), "link=%s\n" % (alias / "kit")))
        self.successful(self.install())
        self.assertEqual((self.bindir / "kit").resolve(), self.prefix / "ai")
        self.assertEqual(self.manifest_links(), [str(self.bindir / "kit")])

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
        self.assertEqual(set(os.listdir(self.prefix)), PAYLOAD)
        self.assertEqual((self.prefix / "ai").read_bytes(), (PACKAGE / "bin/ai").read_bytes())

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
        self.successful(self.install())
        foreign = self.root / "other tool"
        foreign.write_text("owned by somebody else\n")
        link = self.bindir / "kit"
        link.unlink()
        link.symlink_to(foreign)
        settings = self.home / ".codex/config.toml"
        settings.parent.mkdir()
        settings.write_text('model = "personal"\n')
        process = self.successful(self.run_script(self.prefix / "uninstall.sh", "-y"))
        self.assertIn("left alone", process.stderr)
        self.assertEqual(link.resolve(), foreign)
        self.assertEqual(foreign.read_text(), "owned by somebody else\n")
        self.assertEqual(settings.read_text(), 'model = "personal"\n')
        self.assertFalse(self.prefix.exists())

    def test_prefix_must_hold_nothing_but_ai_kit(self):
        # uninstall.sh removes the prefix whole, so nothing else may live there.
        for label, entries in (("user files", ["notes.txt"]),
                               ("a payload beside a user file", ["ai", "agent.d/", "notes.txt"])):
            with self.subTest(prefix=label):
                for entry in entries:
                    path = self.prefix / entry
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.mkdir() if entry.endswith("/") else path.write_text("mine\n")
                process = self.install()
                self.assertEqual(process.returncode, 1, process.stderr)
                self.assertIn("is not an ai-kit install", process.stderr)
                self.assertEqual(sorted(os.listdir(self.prefix)), sorted(e.rstrip("/") for e in entries))
                self.assertEqual((self.prefix / "notes.txt").read_text(), "mine\n")
                self.assertFalse(self.bindir.exists())
                shutil.rmtree(self.prefix)
        for label, entries in (("empty", []), ("an interrupted install", ["ai", "agent.d/"])):
            with self.subTest(prefix=label):
                self.prefix.mkdir()
                for entry in entries:
                    path = self.prefix / entry
                    path.mkdir() if entry.endswith("/") else path.write_text("partial\n")
                self.successful(self.install())
                self.assertEqual(set(os.listdir(self.prefix)), PAYLOAD)
                self.assertEqual((self.prefix / "ai").read_bytes(), (PACKAGE / "bin/ai").read_bytes())
                shutil.rmtree(self.prefix)
                shutil.rmtree(self.bindir)

    @unittest.skipIf(os.geteuid() == 0, "root can write to any directory")
    def test_unwritable_command_directory_fails_before_the_payload(self):
        self.bindir.mkdir(mode=0o555)
        self.addCleanup(self.bindir.chmod, 0o755)
        process = self.install()
        self.assertEqual(process.returncode, 1, process.stderr)
        self.assertIn("cannot write to", process.stderr)
        self.assertFalse(self.prefix.exists())
        self.assertEqual(os.listdir(self.bindir), [])

    def test_colon_in_name_or_command_directory_is_rejected(self):
        for args, message in ((["--name", "ai:kit"], "invalid command name"),
                              (["--bin-dir", self.root / "odd:dir"], "cannot contain ':'")):
            with self.subTest(args=args):
                process = self.install(*args)
                self.assertEqual(process.returncode, 1, process.stderr)
                self.assertIn(message, process.stderr)
                self.assertFalse(self.prefix.exists())
                self.assertFalse(self.bindir.exists())
                self.assertFalse((self.root / "odd:dir").exists())

    def test_installer_never_installs_direnv_or_calls_a_package_manager(self):
        old_direnv = self.root / "direnv 2.32"
        old_direnv.mkdir()
        command(old_direnv / "direnv", 'case "$#:$1" in 1:version) echo 2.32.0 ;; *) exit 1 ;; esac\n')
        for platform, direnv, note in (
            ("Darwin", None, "direnv not found"),
            ("Linux", None, "direnv not found"),
            ("Darwin", old_direnv, "older than 2.33"),
        ):
            with self.subTest(platform=platform, direnv=direnv and "2.32"):
                env = {"INSTALL_TEST_OS": platform}
                if direnv:
                    env["PATH"] = str(direnv) + os.pathsep + self.path
                process = self.successful(self.install(env=env))
                self.assertIn(note, process.stderr)
                # tearDown proves no package manager or downloader ran at all.
                self.assertFalse(self.installer_log.exists(), self.installer_log)
                self.assertEqual([p for p in self.root.rglob("direnv") if p.parent != old_direnv], [])
                shutil.rmtree(self.prefix)
                shutil.rmtree(self.bindir)

    def test_installed_launcher_runs_the_callers_agents_and_keeps_their_path(self):
        self.successful(self.install())
        # The caller's claude/codex come first on PATH. A Homebrew prefix that
        # holds other copies must not win, and nothing may be put on the
        # agent's PATH ahead of the caller's.
        record = ('[ "$1" = --version ] && { echo fake; exit 0; }\n'
                  'printf "%%s\\t%%s\\t%%s\\n" %s "${0##*/}" "$PATH" >>"$AI_TEST_RECORD"\n')
        caller, brew_prefix = self.root / "caller bin", self.root / "brew prefix"
        (brew_prefix / "bin").mkdir(parents=True)
        caller.mkdir()
        for agent in ("claude", "codex"):
            command(caller / agent, record % "caller")
            command(brew_prefix / "bin" / agent, record % "brew-prefix")
        command(caller / "brew", 'if [ "$1" = --prefix ]; then echo %s; else exit 1; fi\n'
                % shlex.quote(str(brew_prefix)))
        workdir = self.root / "not a repository"
        workdir.mkdir()
        recorded = self.root / "agents.tsv"
        path = str(caller) + os.pathsep + self.path
        for agent in ("claude", "codex"):
            with self.subTest(agent=agent):
                self.successful(self.run_script(
                    self.bindir / "kit", agent, "task", cwd=workdir,
                    env={"PATH": path, "AI_TEST_RECORD": str(recorded),
                         "AGENT_DIRENV": "0", "AGENT_NO_AGENTS": "1"}))
        self.assertEqual(recorded.read_text().splitlines(),
                         ["caller\tclaude\t" + path, "caller\tcodex\t" + path])

    def test_git_preflight_rejects_version_without_required_worktree_features(self):
        process = self.install(env={"INSTALL_TEST_GIT_VERSION": "2.30.9"})
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("2.31", process.stderr)
        self.assertFalse(self.prefix.exists())

    def test_git_preflight_accepts_apple_version_suffix(self):
        process = self.successful(self.install(env={"INSTALL_TEST_GIT_VERSION": "2.39.5 (Apple Git-154)"}))
        self.assertIn("git 2.39.5", process.stderr)

    def test_missing_git_provides_platform_install_guidance(self):
        no_git = self.root / "no git"
        no_git.mkdir()
        for tool in self.tools.iterdir():
            if tool.name != "git":
                (no_git / tool.name).symlink_to(tool)
        for command in ("dirname", "cat"):
            (no_git / command).symlink_to(shutil.which(command))
        for platform, remedy in (("Darwin", "xcode-select --install"), ("Linux", "package manager")):
            with self.subTest(platform=platform):
                process = self.install(env={"PATH": str(no_git), "INSTALL_TEST_OS": platform})
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
    sys.dont_write_bytecode = True  # keep __pycache__ out of the package
    import parallel_runner
    parallel_runner.main(InstallTests)
