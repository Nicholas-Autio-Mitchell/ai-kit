#!/usr/bin/env python3
"""Offline tests for '<cmd> update': every agent CLI, Homebrew and fetch is fake.

Run update.sh, optionally with unittest arguments such as -v or -k linuxbrew.
UPDATE_TEST_BASH selects a Bash executable (e.g. /bin/bash on macOS).

Containment, which is the whole point of this file. An earlier manual test
upgraded the developer's real Codex CLI, because platform.sh's
ai_prefer_homebrew prepends the REAL Homebrew bin to PATH on Darwin and
`command -v codex` then escaped the fixture. Four independent guards now make
that impossible, and each one alone would be sufficient:

  1. `uname -s` is a shim that answers Linux, so ai_prefer_homebrew returns
     before it can look at Homebrew at all;
  2. the copied agent.d/lib/platform.sh is replaced with a neutered fixture,
     exactly as dependencies.py does;
  3. the fixture PATH is built from explicitly symlinked utilities only and the
     host PATH is NEVER appended, so `command -v brew|claude|codex|npm|sudo`
     can only ever find a fake;
  4. every fake logs its argv, and assert_contained() fails any run in which a
     logged command, or any of its arguments, names a real prefix -- plus the
     fake sudo log must stay empty in every single test.

Residual, stated rather than hidden: ai_update_brew_candidates ends in the
hardcoded guesses /opt/homebrew/bin/brew and /usr/local/bin/brew, which no
fixture can hide from a child process. On a macOS developer machine the scan
therefore runs the real `brew --prefix` once per update run. That call is
read-only, and it cannot have consequences here: a real brew only becomes the
OWNER of a binary when its reported prefix contains that binary's resolved
path, and every path in this suite lives inside the temporary root. The module
fingerprints the host's real codex/claude/brew before the first test and fails
the run if any of them moved.

No network: AI_UPDATE_FETCH_CMD is pointed at a local stub for every run, and
neither curl nor wget is ever placed on the fixture PATH.
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
BASH = Path(os.environ.get("UPDATE_TEST_BASH", shutil.which("bash"))).resolve()

# Locations that belong to the real machine. Nothing a fixture runs may name one.
REAL_PREFIXES = ("/opt/homebrew", "/usr/local", "/home/linuxbrew",
                 "/Library/", os.path.expanduser("~") + "/")

CLAUDE_RELEASE = "https://downloads.claude.ai/claude-code-releases/"
CLAUDE_DIST = "https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags"
CODEX_DIST = "https://registry.npmjs.org/-/package/@openai/codex/dist-tags"

# dependencies.py's fixture, verbatim: discovery is limited to fake commands and
# the host Homebrew can never be reached through it.
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

# Logging preamble shared by every fake. Keyed on the full argv[0] so that a
# machine with two Homebrews can be asked which one actually ran the upgrade.
LOG = '''import json, os, pathlib, sys, time
def record(extra=None):
    entry = {"argv": [sys.argv[0]] + sys.argv[1:]}
    entry.update(extra or {})
    with open(os.environ["UPDATE_TEST_LOG"], "a") as handle:
        handle.write(json.dumps(entry) + "\\n")
cfg = json.loads(pathlib.Path(CONFIG).read_text()) if CONFIG else {}
args = sys.argv[1:]
'''

FAKE_TOOL = LOG + '''record()
version_file = pathlib.Path(cfg["version_file"])
tool = cfg["tool"]
if args == ["--version"]:
    version = version_file.read_text().strip()
    if cfg.get("banner") is not None:
        print(cfg["banner"])
    else:
        print(("codex-cli " + version) if tool == "codex" else (version + " (Claude Code)"))
    sys.exit(cfg.get("version_rc", 0))
if args == ["doctor"]:
    print(cfg.get("doctor", "Auto-update channel: latest"))
    sys.exit(0)
if args[:1] == ["update"]:
    time.sleep(cfg.get("update_sleep", 0))
    print("%s: checking for updates" % tool)
    if cfg.get("update_sets"):
        version_file.write_text(cfg["update_sets"])
    sys.exit(cfg.get("update_rc", 0))
if args[:1] == ["install"]:
    print("FORBIDDEN: a second installation was requested", file=sys.stderr)
    sys.exit(0)
# An agent launch: record it exactly as codex-launch.py does, so a prompt-form
# argument list can be proven to have reached the agent with its text intact.
launch = [a for a in args if a in ("--dangerously-skip-permissions",
                                   "--dangerously-bypass-approvals-and-sandbox")]
record_file = os.environ.get("UPDATE_TEST_RECORD")
if launch and record_file:
    text = args[-1] if args else ""
    task = text.split("Task:\\n", 1)[1] if "Task:\\n" in text else text
    pathlib.Path(record_file).write_text(json.dumps(
        {"tool": tool, "argv": args, "task": task, "cwd": os.getcwd()}))
sys.exit(0)
'''

FAKE_BREW = LOG + '''record({"env": {"HOMEBREW_NO_ENV_HINTS": os.environ.get("HOMEBREW_NO_ENV_HINTS")}})
def emit(text, rc=0):
    sys.stdout.write(text if text.endswith("\\n") else text + "\\n")
    sys.exit(rc)
if args == ["--prefix"]:
    emit(cfg["prefix"])
if args == ["--cellar"]:
    emit(cfg["cellar"])
if args == ["--caskroom"]:
    if not cfg.get("caskroom_supported", True):
        print("Error: Unknown command: --caskroom", file=sys.stderr)
        sys.exit(1)
    emit(cfg["caskroom"])
if args[:1] == ["outdated"]:
    spec = cfg.get("outdated", {}).get(args[-1], {"rc": 1, "stdout": ""})
    sys.stdout.write(spec.get("stdout", ""))
    sys.exit(spec.get("rc", 0))
if args[:1] == ["list"]:
    kind = cfg.get("installed", {}).get(args[-1])
    if kind is None:
        print("Error: No such keg: " + args[-1], file=sys.stderr)
        sys.exit(1)
    if args[1:2] == ["--cask"]:
        sys.exit(0 if kind == "cask" else 1)
    if args[1:2] == ["--formula"]:
        sys.exit(0 if kind == "formula" else 1)
    sys.exit(0)
if args[:1] == ["upgrade"]:
    if cfg.get("upgrade_signal"):
        os.kill(os.getpid(), cfg["upgrade_signal"])
    time.sleep(cfg.get("upgrade_sleep", 0))
    print("==> Upgrading " + args[-1])
    target = cfg.get("upgrade_sets", {}).get(args[-1])
    if target:
        pathlib.Path(target[0]).write_text(target[1])
    sys.exit(cfg.get("upgrade_rc", 0))
print("Error: Unknown command: " + " ".join(args), file=sys.stderr)
sys.exit(1)
'''

FAKE_PLAIN = LOG + '''with open(os.environ[cfg.get("log_env", "UPDATE_TEST_LOG")], "a") as handle:
    handle.write(json.dumps({"argv": [sys.argv[0]] + args}) + "\\n")
sys.stdout.write(cfg.get("stdout", ""))
sys.exit(cfg.get("rc", 0))
'''

# The network seam. AI_UPDATE_FETCH_CMD is deliberately word-split by the
# implementation, so the optional '--mode' argument is also a test of that.
FAKE_FETCH = LOG + '''mode = ""
if args[:1] == ["--mode"]:
    mode, args = args[1], args[2:]
url = args[-1] if args else ""
record({"url": url, "mode": mode})
spec = json.loads(pathlib.Path(os.environ["UPDATE_TEST_FETCH"]).read_text())
entry = spec.get(url)
if entry is None and mode:
    entry = spec.get(mode)
if entry is None:
    print("fixture fetch: nothing configured for " + url, file=sys.stderr)
    sys.exit(1)
sys.stdout.write(entry.get("body", ""))
sys.exit(entry.get("rc", 0))
'''

OUTDATED_CASK = ('{"formulae":[],"casks":[{"name":"codex","installed_versions":'
                 '["0.154.0"],"current_version":"0.162.1","pinned":false,'
                 '"pinned_version":null}]}')
CURRENT_JSON = '{"formulae":[],"casks":[]}'
HTML_ERROR = ('<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head>'
              '<body><h1>Error 1.2.3</h1><p>try again later</p></body></html>')


def fingerprint():
    """Identity of the host's real CLIs: path, target, mtime and size."""
    state = {}
    for tool in ("codex", "claude", "brew"):
        found = shutil.which(tool)
        if not found:
            continue
        target = os.path.realpath(found)
        try:
            info = os.stat(target)
        except OSError:
            continue
        state[tool] = (found, target, info.st_mtime_ns, info.st_size)
    return state


REAL_TOOLS = fingerprint()


def tearDownModule():
    after = fingerprint()
    if after != REAL_TOOLS:
        raise AssertionError(
            "CONTAINMENT FAILURE: the host's real CLIs changed during this suite.\n"
            "before: %r\nafter:  %r" % (REAL_TOOLS, after))


class UpdateFixture(unittest.TestCase):
    """A complete throwaway installation: package, HOME, PATH, CLIs and brews."""

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ai-kit update ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name).resolve()
        self.home = self.root / "home dir"
        self.work = self.root / "work dir"
        self.fakebin = self.root / "fixture commands"
        self.configs = self.root / "fixture config"
        self.versions = self.root / "fixture versions"
        for directory in (self.home, self.work, self.fakebin, self.configs, self.versions):
            directory.mkdir()
        self.log = self.root / "calls.jsonl"
        self.sudo_log = self.root / "sudo.jsonl"
        self.fetch_spec = self.configs / "fetch.json"
        self.fetch_spec.write_text("{}")
        self.record_file = self.root / "agent launch.json"
        self.fakes = 0
        self.mark = 0
        self.version_files = {}

        self.package = self.root / "package"
        self.package.mkdir()
        for name in ("bin", "agent.d"):
            shutil.copytree(PACKAGE / name, self.package / name)
        self.platform = self.package / "agent.d/lib/platform.sh"
        self.platform.write_text(PLATFORM_FIXTURE)
        self.ai = self.package / "bin/ai"
        self.lib = self.package / "agent.d/lib/update.sh"

        # Do not append the host PATH: it carries the real codex, claude, brew
        # and npm, any of which would make this suite dangerous rather than
        # merely wrong. Everything reachable from the fixture is listed here.
        for name in ("awk", "basename", "cat", "chmod", "cmp", "cp", "cut",
                     "date", "dirname", "env", "find", "git", "grep", "head",
                     "ln", "mkdir", "mktemp", "rm", "rmdir", "sed", "sleep",
                     "sort", "tr", "wc"):
            source = shutil.which(name)
            self.assertIsNotNone(source, "test prerequisite missing: " + name)
            (self.fakebin / name).symlink_to(source)
        (self.fakebin / "bash").symlink_to(BASH)
        # Linux, so platform.sh's ai_prefer_homebrew returns before it can look
        # at Homebrew at all. This is the guard that keeps a real `brew upgrade`
        # off the table; see the module docstring.
        self.write_command("uname", 'import os, sys\n'
                           'print(os.environ["UPDATE_TEST_OS"] if sys.argv[1:] == ["-s"] else "arm64")\n')
        # ai_realpath is the only resolver the package may use. Rejecting GNU
        # options keeps that honest, exactly as install.py does.
        self.write_command("readlink", '''import os, sys
if len(sys.argv) != 2 or sys.argv[1].startswith("-"):
    print("readlink: GNU options are not available in this fixture", file=sys.stderr)
    sys.exit(64)
try:
    print(os.readlink(sys.argv[1]))
except OSError:
    sys.exit(1)
''')
        self.write_fake("sudo", FAKE_PLAIN, {"log_env": "UPDATE_TEST_SUDO_LOG", "rc": 1})
        self.write_fake("ai-fetch-stub", FAKE_FETCH, None)
        # Present so that "the npm binary is never invoked" is a claim with
        # teeth: it would be logged, and assert_contained() fails the run.
        self.write_fake("npm", FAKE_PLAIN, {})
        # ai_update_brew_candidates ends in the hardcoded /opt/homebrew and
        # /usr/local guesses, which exist on a real macOS machine and which no
        # fixture can hide. HOMEBREW_PREFIX is the FIRST candidate, so pointing
        # it at this guard guarantees that `ai_update_brew` -- the answer
        # '--via brew' acts on -- is always a fake, whatever else is installed.
        # Its prefix contains no tool, so it can never own one either.
        self.guard_prefix = self.root / "guard homebrew"
        self.add_brew(self.guard_prefix, installed={
            "claude-code@latest": "cask", "claude-code": "cask", "codex": "cask"})

        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("AGENT_", "AI_", "CLAUDE_", "CODEX_", "DIRENV_",
                                   "GIT_", "HOMEBREW_", "NODE_", "NPM_",
                                   "DEPENDENCY_TEST_", "INSTALL_TEST_", "UPDATE_TEST_"))
        }
        self.env.update({
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.home / ".local/share"),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "PATH": str(self.fakebin),
            "SHELL": "/bin/bash",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "UPDATE_TEST_OS": "Linux",
            "UPDATE_TEST_LOG": str(self.log),
            "UPDATE_TEST_SUDO_LOG": str(self.sudo_log),
            "UPDATE_TEST_FETCH": str(self.fetch_spec),
            "UPDATE_TEST_RECORD": str(self.record_file),
            # The network seam is stubbed for every run, not only the runs that
            # care about it, so no test can reach the internet by omission.
            "AI_UPDATE_FETCH_CMD": "ai-fetch-stub",
            "HOMEBREW_PREFIX": str(self.guard_prefix),
            "AGENT_DIRENV": "0",
            "AGENT_NO_AGENTS": "1",
        })

    # ---- building the fixture ------------------------------------------

    def write_command(self, name, body, directory=None):
        path = (directory or self.fakebin) / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)
        return path

    def write_fake(self, name, template, config, directory=None):
        spec = ""
        if config is not None:
            self.fakes += 1
            spec = str(self.configs / ("%s-%d.json" % (name, self.fakes)))
            Path(spec).write_text(json.dumps(config))
        body = "CONFIG = %r\n" % spec + template
        return self.write_command(name, body, directory=directory)

    def add_tool(self, tool, path, version="0.154.0", link=True, **config):
        """Install a fake <tool> AT <path> (its location decides its method)."""
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        self.fakes += 1
        version_file = self.versions / ("%s-%d" % (tool, self.fakes))
        version_file.write_text(version)
        config.update({"tool": tool, "version_file": str(version_file)})
        self.write_fake(path.name, FAKE_TOOL, config, directory=path.parent)
        self.version_files[str(path)] = version_file
        if link:
            (self.fakebin / tool).symlink_to(path)
        return path

    def add_brew(self, prefix, directory=None, on_path=False, **config):
        """A fake Homebrew reporting <prefix> as its own, wherever it lives."""
        prefix = Path(prefix)
        config.setdefault("cellar", str(prefix / "Cellar"))
        config.setdefault("caskroom", str(prefix / "Caskroom"))
        config["prefix"] = str(prefix)
        directory = Path(directory) if directory else prefix / "bin"
        directory.mkdir(parents=True, exist_ok=True)
        brew = self.write_fake("brew", FAKE_BREW, config, directory=directory)
        if on_path:
            (self.fakebin / "brew").symlink_to(brew)
        return brew

    def cask_install(self, tool, prefix, package=None, version="0.154.0", **config):
        """The real Homebrew shape: <prefix>/Caskroom/<pkg>/<version>/bin/<tool>."""
        package = package or tool
        return self.add_tool(
            tool, Path(prefix) / "Caskroom" / package / version / "bin" / tool,
            version=version, **config)

    def fetch(self, mapping):
        spec = json.loads(self.fetch_spec.read_text())
        spec.update(mapping)
        self.fetch_spec.write_text(json.dumps(spec))

    # ---- running the launcher ------------------------------------------

    def first_brew_candidate(self, env=None):
        """The brew `ai_update_brew` would return, computed exactly as
        ai_update_brew_candidates orders them."""
        full = dict(self.env, **(env or {}))
        candidates = []
        if full.get("HOMEBREW_PREFIX"):
            candidates.append(full["HOMEBREW_PREFIX"] + "/bin/brew")
        if full.get("AI_HOMEBREW"):
            candidates.append(full["AI_HOMEBREW"])
        for directory in full.get("PATH", "").split(os.pathsep):
            found = os.path.join(directory, "brew")
            if os.access(found, os.X_OK):
                candidates.append(found)
                break
        if full.get("HOME"):
            candidates.append(full["HOME"] + "/.linuxbrew/bin/brew")
        candidates += ["/home/linuxbrew/.linuxbrew/bin/brew",
                       "/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        for candidate in candidates:
            if os.access(candidate, os.X_OK):
                return candidate
        return None

    def run_ai(self, *args, env=None, cwd=None, timeout=120, launcher=None):
        # Refuse to start a run in which the REAL Homebrew would be the first
        # usable candidate. '--via brew' acts on exactly that brew, so a
        # fixture that leaves it leading is one `ai update --via brew` away
        # from upgrading the developer's own CLI. This check is what makes
        # that state unwritable rather than merely unlikely.
        leader = self.first_brew_candidate(env)
        self.assertIsNotNone(leader, "UNSAFE FIXTURE: no brew at all is discoverable, so "
                                     "the hardcoded real-machine candidates would lead")
        self.assertTrue(leader.startswith(str(self.root)),
                        "UNSAFE FIXTURE: the first brew discovered is %r" % leader)
        if self.record_file.exists():
            self.record_file.unlink()
        self.mark = len(self.entries())
        process = subprocess.run(
            [str(BASH), str(launcher or self.ai), *map(str, args)],
            cwd=str(cwd or self.work), env=dict(self.env, **(env or {})),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, timeout=timeout,
        )
        self.assert_contained()
        return process

    def update(self, *args, **kwargs):
        return self.run_ai("update", *args, **kwargs)

    # ---- reading what happened -----------------------------------------

    def entries(self, path=None):
        path = path or self.log
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text().splitlines()]

    def commands(self):
        """Every logged call as [<command name>, *arguments]."""
        return [[Path(e["argv"][0]).name] + e["argv"][1:] for e in self.entries()]

    def calls_to(self, name):
        return [c for c in self.commands() if c[0] == name]

    def last_run(self):
        return self.entries()[self.mark:]

    def brew_subcommands(self):
        return [c[1] for c in self.calls_to("brew") if len(c) > 1]

    def fetched(self):
        return [e["url"] for e in self.entries() if "url" in e]

    def upgrades(self):
        """Every logged call that mutates something, with its full argv[0]."""
        return [e for e in self.entries()
                if e["argv"][1:2] in (["upgrade"], ["update"], ["install"])]

    def launch(self):
        if not self.record_file.exists():
            return None
        return json.loads(self.record_file.read_text())

    # ---- invariants asserted after every single run --------------------

    def assert_contained(self):
        self.assertEqual(self.entries(self.sudo_log), [],
                         "'update' must never invoke sudo, not even to offer it")
        self.assert_brew_probes_are_deduplicated()
        for entry in self.entries():
            argv = entry["argv"]
            name = Path(argv[0]).name
            self.assertNotEqual(name, "npm", "the npm binary must never be invoked")
            self.assertFalse(name == "claude" and argv[1:2] == ["install"],
                             "'claude install' lays down a second installation")
            if "/" in argv[0]:
                real = os.path.realpath(argv[0])
                self.assertTrue(real.startswith(str(self.root)),
                                "a command outside the fixture ran: " + real)
            for word in argv:
                for prefix in REAL_PREFIXES:
                    self.assertFalse(
                        word.startswith(prefix),
                        "a fake was pointed at the real machine: %r in %r" % (word, argv))

    def assert_brew_probes_are_deduplicated(self):
        """The scan keeps one entry per DISTINCT brew, so each binary answers
        each of --prefix/--cellar/--caskroom at most once per run."""
        counted = {}
        for entry in self.last_run():
            argv = entry["argv"]
            if Path(argv[0]).name != "brew" or argv[1:2] not in (
                    ["--prefix"], ["--cellar"], ["--caskroom"]):
                continue
            key = (os.path.realpath(argv[0]), argv[1])
            counted[key] = counted.get(key, 0) + 1
        for key, count in counted.items():
            self.assertEqual(count, 1, "%s was asked %d times in one run" % (key, count))

    def assert_table_fits_eighty_columns(self, process):
        for line in process.stdout.splitlines():
            if line.startswith("  ") and not line.startswith("        "):
                self.assertLessEqual(len(line), 80, "table line is %d columns: %r"
                                     % (len(line), line))

    def assert_upgrade_argv(self, entry, kind, package):
        """`brew upgrade --<kind> [--] <package>` and nothing else. The package
        is always its own argv element, never interpolated into a command."""
        argv = entry["argv"][1:]
        self.assertEqual(argv[:2], ["upgrade", "--" + kind], entry)
        self.assertEqual(argv[-1], package, entry)
        self.assertIn(argv[2:-1], ([], ["--"]),
                      "unexpected extra arguments: %r" % (argv,))

    def assert_display(self, text, kind, package, prefix=""):
        import re
        pattern = r"%s\s*brew upgrade --%s (-- )?%s" % (
            re.escape(prefix), kind, re.escape(package))
        self.assertRegex(text, pattern)

    def assert_no_upgrade_ran(self):
        for command in self.commands():
            self.assertNotIn(command[1:2], (["upgrade"], ["update"], ["install"]),
                             "nothing may be upgraded here, but ran: %r" % (command,))

    # ---- shared assertions ---------------------------------------------

    def table_row(self, process, tool):
        for line in process.stdout.splitlines():
            if line.startswith("  " + tool + " "):
                return line.split()
        self.fail("no table row for %r in:\n%s" % (tool, process.stdout))

    def assert_row(self, process, tool, installed=None, latest=None, via=None, status=None):
        row = self.table_row(process, tool)
        if installed is not None:
            self.assertEqual(row[1], installed, process.stdout)
        if latest is not None:
            self.assertEqual(row[2], latest, process.stdout)
        if via is not None:
            self.assertEqual(row[3], via, process.stdout)
        if status is not None:
            self.assertEqual(" ".join(row[4:]), status, process.stdout)


class GrammarTests(UpdateFixture):
    """Design section 2: every row of the behaviour table.

    'update' is the one subcommand word that also reads as ordinary English, so
    each row is proven by its CONSEQUENCE: a prompt row must reach the agent
    with its text intact (the record-file trick from codex-launch.py), and a
    subcommand row must produce the updater's report and launch nothing.
    """

    def setUp(self):
        super().setUp()
        # Outside $HOME and owned by no Homebrew: classified 'unknown', which is
        # report-only, so no grammar row can mutate anything even by accident.
        self.add_tool("claude", self.root / "system bin/claude", version="2.1.296")
        self.add_tool("codex", self.root / "system bin/codex", version="0.154.0")

    def assert_subcommand(self, process):
        self.assertIsNone(self.launch(), "an agent was launched:\n" + process.stdout)
        self.assertTrue(process.stdout.startswith("checking:"),
                        "the updater did not run:\n%s%s" % (process.stdout, process.stderr))
        return process

    def assert_prompt(self, process, task, tool="claude"):
        launched = self.launch()
        self.assertIsNotNone(
            launched, "the agent was not launched:\n%s%s" % (process.stdout, process.stderr))
        self.assertEqual(launched["task"], task)
        self.assertEqual(launched["tool"], tool)
        self.assertEqual(process.returncode, 0, process.stderr)

    def assert_usage_error(self, process, *fragments):
        self.assertEqual(process.returncode, 2,
                         "expected exit 2:\n%s%s" % (process.stdout, process.stderr))
        self.assertIsNone(self.launch(), "an agent was launched for a usage error")
        for fragment in fragments:
            self.assertIn(fragment, process.stderr)

    def test_command_forms_run_the_updater(self):
        for args, expect_tools in [
            ([], "checking:  claude, codex"),
            (["--check"], "checking:  claude, codex"),
            (["codex"], "checking:  codex"),
            (["--check", "codex"], "checking:  codex"),
            (["codex", "--check"], "checking:  codex"),
            (["claude", "--via", "brew"], "checking:  claude"),
            (["claude", "--via", "standalone", "--check"], "checking:  claude"),
            (["--via=standalone", "codex"], "checking:  codex"),
        ]:
            with self.subTest(args=args):
                process = self.update(*args)
                self.assert_subcommand(process)
                self.assertIn(expect_tools, process.stdout)

    def test_check_flag_announces_a_read_only_run(self):
        self.assertIn("mode:      check only (nothing will be changed)",
                      self.update("--check").stdout)
        self.assertIn("mode:      upgrade", self.update().stdout)
        self.assertIn("method:    forced to brew (--via brew)",
                      self.update("claude", "--via", "brew").stdout)

    def test_word_only_argument_lists_are_prompts_and_reach_the_agent(self):
        for args, task in [
            (["update", "the", "README", "to", "mention", "the", "new", "flag"],
             "update the README to mention the new flag"),
            (["update", "claude", "to", "use", "the", "new", "API"],
             "update claude to use the new API"),
            (["update", "the", "README", "--check", "for", "typos"],
             "update the README --check for typos"),
            (["update", "codex", "extra"], "update codex extra"),
            (["update", "--", "the", "README"], "update -- the README"),
            (["update", "--"], "update --"),
            (["update", "worktrees"], "update worktrees"),
            (["--", "update", "anything"], "update anything"),
        ]:
            with self.subTest(args=args):
                self.assert_prompt(self.run_ai(*args), task)

    def test_update_after_the_agent_name_is_prompt_text(self):
        self.assert_prompt(self.run_ai("codex", "update"), "update", tool="codex")
        self.assert_prompt(self.run_ai("claude", "update", "the", "README"),
                           "update the README")

    def test_a_flag_commits_the_line_and_junk_in_it_is_an_error(self):
        for args, fragments in [
            (["update", "--check", "--", "foo"], ("Unexpected argument '--'",)),
            (["update", "codex", "--check", "extra"],
             ("Unexpected argument 'extra'", "To run it as a prompt instead, quote it:")),
            (["update", "claude", "--via", "brew", "extra"], ("Unexpected argument 'extra'",)),
            (["update", "--via", "brew", "the", "README"], ("Unexpected argument 'the'",)),
            (["update", "--fix"], ("Unexpected argument '--fix'",)),
            (["update", "--name", "x"], ("Unexpected argument '--name'",)),
            (["update", "--base", "main"], ("Unexpected argument '--base'",)),
        ]:
            with self.subTest(args=args):
                self.assert_usage_error(self.run_ai(*args), *fragments)

    def test_option_and_subcommand_conflicts_are_usage_errors(self):
        for args, fragments in [
            (["update", "--via", "brew"], ("--via applies to one tool",)),
            (["update", "claude", "--via", "apt"], ("Unknown --via method 'apt'",)),
            (["update", "claude", "--via"], ("--via needs a value: brew or standalone.",)),
            (["update", "claude", "codex"], ("Name at most one of 'claude' or 'codex'",)),
            (["wt", "update"], ("runs no agent and cuts no worktree",)),
            (["here", "update"], ("runs no agent and cuts no worktree",)),
            (["update", "--wt"], ("Unexpected argument '--wt'",)),
            (["worktrees", "update"], ("different subcommands",)),
        ]:
            with self.subTest(args=args):
                self.assert_usage_error(self.run_ai(*args), *fragments)

    def test_via_npm_is_rejected_because_npm_is_not_a_driven_method(self):
        # The design table still lists '--via=npm'; the shipped implementation
        # drives exactly brew and standalone, and says so rather than guessing.
        self.assert_usage_error(self.update("--via=npm", "codex"),
                                "Unknown --via method 'npm'")

    def test_update_help_prints_the_manual_and_exits_0(self):
        process = self.update("--help")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIsNone(self.launch())
        self.assertIn("update [--check] [--via brew|standalone] [claude|codex]", process.stdout)
        self.assertIn("AI_UPDATE_OFFLINE", process.stdout)
        self.assertIn("AGENT_UPDATE_TIMEOUT", process.stdout)

    def test_worktree_wrapper_still_reaches_update(self):
        # A *-wt wrapper supplies an IMPLICIT mode, which 'update' ignores;
        # only an explicit 'wt'/'here'/--wt is rejected.
        wrapper = self.fakebin / "kit-wt"
        wrapper.symlink_to(self.ai)
        process = self.run_ai("update", "--check", "codex", launcher=wrapper)
        self.assert_subcommand(process)
        self.assertIn("checking:  codex", process.stdout)

    def test_no_grammar_row_ever_mutated_anything(self):
        for args in (["update"], ["update", "--check"], ["update", "codex"]):
            self.update(*args[1:])
        self.assert_no_upgrade_ran()


class InvariantG1Tests(UpdateFixture):
    """A missing, broken or incomplete update.sh degrades 'update' and NOTHING else.

    The grammar lives in bin/ai and the lib is sourced only after the grammar
    has already decided. These three tests are the regression guard: in each
    one 'ai update' must fail cleanly with exit 2, and 'ai "do the task"' must
    still launch the agent.
    """

    def setUp(self):
        super().setUp()
        self.add_tool("claude", self.root / "system bin/claude", version="2.1.296")
        self.add_tool("codex", self.root / "system bin/codex", version="0.154.0")

    def assert_degraded(self, *fragments):
        process = self.update()
        self.assertEqual(process.returncode, 2,
                         "expected a clean exit 2:\n%s%s" % (process.stdout, process.stderr))
        self.assertIsNone(self.launch(), "an agent was launched by 'update'")
        for fragment in fragments:
            self.assertIn(fragment, process.stderr)
        launched = self.run_ai("do the task")
        self.assertEqual(launched.returncode, 0, launched.stderr)
        self.assertIsNotNone(self.launch(), "the agent no longer launches:\n" + launched.stderr)
        self.assertEqual(self.launch()["task"], "do the task")

    def test_missing_update_lib(self):
        self.lib.unlink()
        self.assert_degraded("needs agent.d/lib/update.sh", "Re-run install.sh")

    def test_syntactically_broken_update_lib(self):
        self.lib.write_text('run_update() {\n  echo "never closed\n')
        self.assert_degraded("update.sh")

    def test_update_lib_without_run_update(self):
        self.lib.write_text("# a half-copied payload\nai_update_trim() { :; }\n")
        self.assert_degraded("defines no run_update", "incomplete")

    def test_missing_paths_lib(self):
        (self.package / "agent.d/lib/paths.sh").unlink()
        self.assert_degraded("needs agent.d/lib/paths.sh", "Re-run install.sh")


class LibraryTests(UpdateFixture):
    """The pure helpers, sourced straight out of the lib under set -euo pipefail.

    The shell options are part of the test: bin/ai runs under them, so a helper
    that aborts (a bare $((08)), a comparator returning non-zero) would take the
    whole launcher down rather than report 'unknown'.
    """

    def shell(self, script, *args):
        process = subprocess.run(
            [str(BASH), "-c", "set -euo pipefail\n" + script, "_", str(self.lib), *args],
            cwd=str(self.work), env=self.env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
        )
        self.assertEqual(process.returncode, 0,
                         "the helper aborted:\n%s%s" % (process.stdout, process.stderr))
        return process.stdout

    def vercmp(self, a, b):
        return self.shell('. "$1"\nprintf "%s" "$(ai_update_vercmp "$2" "$3")"\n', a, b)

    def test_vercmp_orders_releases_numerically(self):
        for a, b, expected in [
            ("0.154.0", "0.162.1", "older"),
            ("0.162.1", "0.154.0", "newer"),
            ("0.162.1", "0.162.1", "same"),
            ("2.1.89", "2.1.296", "older"),
            ("2.1.296", "2.1.89", "newer"),
            ("10.0.0", "9.9.9", "newer"),
            ("9.9.9", "10.0.0", "older"),
        ]:
            with self.subTest(a=a, b=b):
                self.assertEqual(self.vercmp(a, b), expected)

    def test_vercmp_survives_leading_zeros(self):
        # A bare $((08)) is an octal syntax error, which under set -e would kill
        # the launcher instead of reporting a version.
        for a, b, expected in [
            ("1.08.0", "1.8.0", "same"),
            ("1.08.0", "1.9.0", "older"),
            ("1.09.0", "1.8.0", "newer"),
            ("2.1.089", "2.1.89", "same"),
            ("0.09.0", "0.8.0", "newer"),
        ]:
            with self.subTest(a=a, b=b):
                self.assertEqual(self.vercmp(a, b), expected)

    def test_vercmp_treats_a_missing_component_as_zero(self):
        for a, b, expected in [("1.2", "1.2.0", "same"), ("1.2.0", "1.2", "same"),
                               ("1.2", "1.2.1", "older"), ("1.2.1", "1.2", "newer")]:
            with self.subTest(a=a, b=b):
                self.assertEqual(self.vercmp(a, b), expected)

    def test_vercmp_ranks_prereleases_below_their_release(self):
        for a, b, expected in [
            ("1.0.0-rc.1", "1.0.0", "older"),
            ("1.0.0", "1.0.0-rc.1", "newer"),
            ("1.0.0-rc.1", "1.0.0-rc.1", "same"),
            ("1.0.0-alpha", "1.0.0-beta", "older"),
            ("1.0.0-beta", "1.0.0-alpha", "newer"),
        ]:
            with self.subTest(a=a, b=b):
                self.assertEqual(self.vercmp(a, b), expected)

    def test_vercmp_ignores_build_metadata(self):
        for a, b in [("1.0.0+build", "1.0.0"), ("1.0.0", "1.0.0+build"),
                     ("1.0.0+build.2", "1.0.0+build.1")]:
            with self.subTest(a=a, b=b):
                self.assertEqual(self.vercmp(a, b), "same")

    def test_a_prerelease_of_a_higher_release_is_never_an_update_backwards(self):
        # The one row that must never regress: a nightly ahead of the published
        # release is 'ahead', not 'please downgrade'.
        self.assertEqual(self.vercmp("0.163.0-alpha.5", "0.162.1"), "newer")
        self.assertEqual(self.vercmp("0.162.1", "0.163.0-alpha.5"), "older")
        self.assertEqual(self.vercmp("2.2.0-rc.1", "2.1.296"), "newer")

    def test_vercmp_reports_unknown_rather_than_guessing(self):
        for a, b in [("", "1.0.0"), ("1.0.0", ""), ("", ""), ("abc", "1.0.0"),
                     ("1.0.0", "nightly"), ("1.x.0", "1.2.0"), ("1.2.0", "1.y.0"),
                     ("not a version at all", "1.0.0")]:
            with self.subTest(a=a, b=b):
                self.assertEqual(self.vercmp(a, b), "unknown")

    def test_semver_extracts_the_version_out_of_a_banner(self):
        script = ('. "$1"\nif v="$(ai_update_semver "$2")"; then printf "%s" "$v";'
                  ' else printf "UNKNOWN"; fi\n')
        for text, expected in [
            ("codex-cli 0.154.0", "0.154.0"),
            ("2.1.296 (Claude Code)", "2.1.296"),
            ("v1.2.3", "1.2.3"),
            ("rust-v0.162.1", "0.162.1"),
            ("  0.163.0-alpha.5  ", "0.163.0-alpha.5"),
            ("1.0.0+build.7", "1.0.0+build.7"),
            ("1.2", "1.2"),
            ("no version here", "UNKNOWN"),
            ("", "UNKNOWN"),
            ("build 12345", "UNKNOWN"),
        ]:
            with self.subTest(text=text):
                self.assertEqual(self.shell(script, text), expected)

    def test_the_latest_version_gate_rejects_anything_but_a_three_part_version(self):
        script = ('. "$1"\nif ai_update_valid "$2"; then printf "valid";'
                  ' else printf "invalid"; fi\n')
        for text, expected in [("1.2.3", "valid"), ("0.162.1", "valid"),
                               ("2.1.296", "valid"), ("1.2", "invalid"),
                               ("", "invalid"), ("v1.2.3", "invalid"),
                               (HTML_ERROR, "invalid"),
                               ("Error 1.2.3", "invalid")]:
            with self.subTest(text=text[:40]):
                self.assertEqual(self.shell(script, text), expected)

    def test_the_brew_candidate_ladder_keeps_the_shared_linuxbrew_path(self):
        # The /home/linuxbrew/.linuxbrew shape cannot be created on a developer
        # machine, so the ladder itself is asserted instead: the invoking user's
        # own home must outrank the system-wide service-user default, and
        # HOMEBREW_PREFIX and `command -v` must lead (they are the only two that
        # cope with an arbitrary prefix).
        self.add_brew(self.root / "on path brew", on_path=True)
        lines = [line for line in
                 self.shell('. "$1"\nai_update_brew_candidates\n').splitlines() if line]
        self.assertEqual(lines[0], str(self.guard_prefix / "bin/brew"))
        self.assertEqual(lines[1], str(self.fakebin / "brew"))
        self.assertIn(str(self.home / ".linuxbrew/bin/brew"), lines)
        self.assertIn("/home/linuxbrew/.linuxbrew/bin/brew", lines)
        self.assertLess(lines.index(str(self.home / ".linuxbrew/bin/brew")),
                        lines.index("/home/linuxbrew/.linuxbrew/bin/brew"))


OUTDATED_FORMULA = ('{"formulae":[{"name":"codex","installed_versions":["0.154.0"],'
                    '"current_version":"0.162.1","pinned":false,"pinned_version":null}],'
                    '"casks":[]}')


class DetectionTests(UpdateFixture):
    """Section 4's ladder, and INVARIANT H1 above all.

    H1: Homebrew is tested BEFORE 'under $HOME means standalone', on every
    platform, against the trees brew itself reports. A per-user Linuxbrew lives
    inside $HOME, so a $HOME-first ladder calls it a native install and then
    runs a self-updater that a Homebrew-managed CLI answers with 'up to date'
    while changing nothing. Every fixture here reports Linux from `uname`.
    """

    def outdated_brew(self, prefix, package, tool_path, latest="0.162.1",
                      document=OUTDATED_CASK, **config):
        """A brew that reports <package> outdated and really 'upgrades' it."""
        config.setdefault("outdated", {package: {"rc": 1, "stdout": document}})
        config.setdefault("upgrade_sets",
                          {package: [str(self.version_files[str(tool_path)]), latest]})
        return self.add_brew(prefix, **config)

    def assert_upgraded_by(self, brew, kind, package):
        """Exactly one upgrade ran, it was `brew upgrade --<kind> <package>`,
        and it was run by THIS brew."""
        upgrades = self.upgrades()
        self.assertEqual(len(upgrades), 1, "expected exactly one upgrade: %r" % (upgrades,))
        entry = upgrades[0]
        self.assert_upgrade_argv(entry, kind, package)
        self.assertEqual(os.path.realpath(entry["argv"][0]), str(brew),
                         "the wrong Homebrew ran the upgrade")
        self.assertEqual(entry.get("env", {}).get("HOMEBREW_NO_ENV_HINTS"), "1")

    def test_per_user_linuxbrew_cask_is_homebrew_not_standalone(self):
        # The exact misclassification H1 exists to prevent: ~/.linuxbrew is
        # inside $HOME, and brew is reachable neither on PATH nor through
        # HOMEBREW_PREFIX -- only through the $HOME/.linuxbrew candidate.
        prefix = self.home / ".linuxbrew"
        codex = self.cask_install("codex", prefix)
        brew = self.outdated_brew(prefix, "codex", codex)
        env = {"HOMEBREW_PREFIX": ""}

        check = self.update("--check", "codex", env=env)
        self.assert_row(check, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assertEqual(check.returncode, 1, check.stdout)
        self.assert_display(check.stdout, "cask", "codex", prefix="# runs:")
        self.assert_no_upgrade_ran()

        run = self.update("codex", env=env)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn("0.154.0 -> 0.162.1  OK", run.stdout)
        self.assertIn("1 upgraded.", run.stdout)
        self.assert_upgraded_by(brew, "cask", "codex")
        self.assertNotIn(["codex", "update"], self.commands())

    def test_service_user_linuxbrew_shape_is_homebrew(self):
        # Stands in for the shared /home/linuxbrew/.linuxbrew install, which
        # cannot be created on a developer machine: same shape -- a brew whose
        # prefix is some OTHER user's home, outside the invoking user's $HOME --
        # reached through `command -v`. The literal candidate's place in the
        # ladder is asserted separately, in LibraryTests.
        prefix = self.root / "home/linuxbrew/.linuxbrew"
        claude = self.cask_install("claude", prefix, package="claude-code", version="2.1.89")
        brew = self.outdated_brew(
            prefix, "claude-code", claude, latest="2.1.296", on_path=True,
            document='{"formulae":[],"casks":[{"name":"claude-code",'
                     '"installed_versions":["2.1.89"],"current_version":"2.1.296"}]}')
        run = self.update("claude", env={"HOMEBREW_PREFIX": ""})
        self.assert_row(run, "claude", "2.1.89", "2.1.296", "brew-cask:claude-code")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assert_upgraded_by(brew, "cask", "claude-code")
        self.assertNotIn(["claude", "update"], self.commands())
        self.assertNotIn(["claude", "install"], self.commands())

    def test_arbitrary_prefix_reached_only_through_homebrew_prefix(self):
        prefix = self.root / "opt/weird brew"
        claude = self.cask_install("claude", prefix, package="claude-code@latest",
                                   version="2.1.89")
        brew = self.outdated_brew(
            prefix, "claude-code@latest", claude, latest="2.1.296",
            document='{"formulae":[],"casks":[{"name":"claude-code@latest",'
                     '"installed_versions":["2.1.89"],"current_version":"2.1.296"}]}')
        run = self.update("claude", env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "claude", "2.1.89", "2.1.296",
                        "brew-cask:claude-code@latest", "OUTDATED")
        self.assert_upgraded_by(brew, "cask", "claude-code@latest")
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_prefix_comes_from_what_brew_reports_not_from_where_brew_lives(self):
        # A no-root install at an arbitrary prefix containing a space, with the
        # brew binary deliberately parked somewhere unrelated to it.
        prefix = self.root / "opt/a no root prefix with spaces"
        codex = self.cask_install("codex", prefix)
        brew = self.outdated_brew(prefix, "codex", codex, on_path=True,
                                  directory=self.root / "unrelated brew home")
        run = self.update("codex", env={"HOMEBREW_PREFIX": ""})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assert_upgraded_by(brew, "cask", "codex")

    def test_brew_without_a_caskroom_subcommand_falls_back_to_the_prefix(self):
        prefix = self.root / "opt/old brew"
        codex = self.cask_install("codex", prefix)
        brew = self.outdated_brew(prefix, "codex", codex, caskroom_supported=False)
        run = self.update("codex", env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assert_upgraded_by(brew, "cask", "codex")
        self.assertIn("--caskroom", self.brew_subcommands())

    def test_the_brew_that_owns_the_binary_is_the_one_that_upgrades_it(self):
        # Two Homebrews, as an Intel /usr/local beside an arm64 /opt/homebrew
        # would be. Only the second one's reported prefix contains the binary.
        first = self.root / "opt/first brew"
        second = self.root / "opt/second brew"
        codex = self.cask_install("codex", second)
        other = self.add_brew(first)
        owner = self.outdated_brew(second, "codex", codex, on_path=True)
        run = self.update("codex", env={"HOMEBREW_PREFIX": str(first)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assert_upgraded_by(owner, "cask", "codex")
        self.assertNotIn(str(other), [e["argv"][0] for e in self.upgrades()])
        # The non-owner answers read-only questions about its own trees and is
        # then left alone: never asked to list, and never asked to upgrade.
        probes = [c["argv"][1:] for c in self.entries()
                  if os.path.realpath(c["argv"][0]) == str(other)]
        self.assertIn(["--prefix"], probes)
        for probe in probes:
            self.assertIn(probe[0], ("--prefix", "--cellar", "--caskroom"),
                          "the non-owning brew was asked to do something: %r" % (probe,))

    def test_formula_install_is_upgraded_as_a_formula(self):
        prefix = self.root / "opt/formula brew"
        codex = self.add_tool("codex", prefix / "Cellar/codex/0.154.0/bin/codex")
        brew = self.outdated_brew(prefix, "codex", codex, document=OUTDATED_FORMULA)
        run = self.update("codex", env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-formula:codex", "OUTDATED")
        self.assert_upgraded_by(brew, "formula", "codex")

    def test_a_cellar_outside_the_prefix_is_still_homebrew(self):
        # brew prefers $HOMEBREW_REPOSITORY/Cellar when that directory exists,
        # and de-symlinks the result, so the Cellar genuinely is not always
        # under the prefix. Containment has to be tested against every tree
        # brew reports, not against the prefix alone.
        prefix = self.root / "opt/repo brew"
        cellar = self.root / "var/homebrew repository/Cellar"
        codex = self.add_tool("codex", cellar / "codex/0.154.0/bin/codex")
        brew = self.outdated_brew(prefix, "codex", codex, cellar=str(cellar),
                                  document=OUTDATED_FORMULA)
        run = self.update("codex", env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-formula:codex", "OUTDATED")
        self.assert_upgraded_by(brew, "formula", "codex")
        self.assertNotIn(["codex", "update"], self.commands())

    def test_a_caskroom_outside_the_prefix_is_still_homebrew(self):
        prefix = self.root / "opt/split brew"
        caskroom = self.root / "var/casks elsewhere/Caskroom"
        codex = self.add_tool("codex", caskroom / "codex/0.154.0/bin/codex")
        brew = self.outdated_brew(prefix, "codex", codex, caskroom=str(caskroom))
        run = self.update("codex", env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assert_upgraded_by(brew, "cask", "codex")

    def test_standalone_install_under_home_runs_the_cli_updater(self):
        claude = self.add_tool("claude", self.home / ".local/share/claude/versions/2.1.89/claude",
                               version="2.1.89", update_sets="2.1.296",
                               doctor="  Auto-update channel: stable")
        self.fetch({CLAUDE_RELEASE + "stable": {"body": "2.1.296"}})
        check = self.update("--check", "claude")
        self.assert_row(check, "claude", "2.1.89", "2.1.296", "native:stable", "OUTDATED")
        self.assertEqual(check.returncode, 1, check.stdout)
        self.assertEqual(self.fetched(), [CLAUDE_RELEASE + "stable"])
        self.assert_no_upgrade_ran()

        run = self.update("claude")
        self.assertIn(["claude", "update"], self.commands())
        self.assertIn("2.1.89 -> 2.1.296  OK", run.stdout)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertNotIn(["claude", "install"], self.commands())
        self.assertEqual([c for c in self.commands() if c[1:2] == ["upgrade"]], [])

    def test_npm_global_install_is_named_and_never_upgraded(self):
        codex = self.add_tool(
            "codex", self.home / ".npm-global/lib/node_modules/@openai/codex/bin/codex")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1","alpha":"0.163.0-alpha.5"}'}})
        run = self.update("codex")            # the MUTATING form must still refuse
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "npm-global:@openai/codex",
                        "OUT OF DATE (not touched)")
        self.assertIn("is a global Node package install (npm, pnpm, yarn or bun),", run.stdout)
        self.assertIn("npm install -g @openai/codex@latest", run.stdout)
        self.assertIn("ai update codex --via brew|standalone", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()

    def test_unscoped_node_package_is_named_too(self):
        self.add_tool("codex", self.home / ".nvm/lib/node_modules/codex-cli/bin/codex")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1"}'}})
        run = self.update("--check", "codex")
        self.assert_row(run, "codex", via="npm-global:codex-cli")
        self.assert_no_upgrade_ran()

    def test_system_install_outside_home_is_reported_never_touched(self):
        # Stands in for an apt/dnf package at /usr/bin/codex, which no test may
        # write to: outside $HOME and owned by no Homebrew is the same state.
        self.add_tool("codex", self.root / "usr/bin/codex")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1"}'}})
        run = self.update("codex")
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "unknown",
                        "OUT OF DATE (not touched)")
        self.assertIn(str(self.root / "usr/bin/codex"), run.stdout)
        self.assertIn("outside $HOME, and owned by neither Homebrew nor a native installer",
                      run.stdout)
        self.assertIn("npm i -g @openai/codex   (or: brew install --cask codex)", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()

    def test_system_claude_outside_home_names_the_distribution_repositories(self):
        self.add_tool("claude", self.root / "usr/bin/claude", version="2.1.89",
                      doctor="Auto-update channel: latest")
        self.fetch({CLAUDE_RELEASE + "latest": {"body": "2.1.296"}})
        run = self.update("claude")
        self.assert_row(run, "claude", "2.1.89", "2.1.296", "unknown",
                        "OUT OF DATE (not touched)")
        self.assertIn("curl -fsSL https://claude.ai/install.sh | bash", run.stdout)
        self.assertIn("If it came from Anthropic's apt/dnf/apk repo, use your package manager.",
                      run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()

    def test_a_missing_cli_is_reported_with_its_install_command(self):
        self.add_tool("codex", self.root / "usr/bin/codex")
        run = self.update()
        self.assert_row(run, "claude", "-", "-", "-", "NOT INSTALLED")
        self.assertIn("not installed. ai-kit never installs an agent CLI for you.", run.stdout)
        self.assertIn("curl -fsSL https://claude.ai/install.sh | bash", run.stdout)
        self.assertIn("Or check only the tool you use:  ai update codex", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()

    def test_the_platform_helper_is_never_rewritten(self):
        self.add_tool("codex", self.root / "usr/bin/codex")
        self.update("--check", "codex")
        self.assertEqual(self.platform.read_text(), PLATFORM_FIXTURE)


class BrewStatusTests(UpdateFixture):
    """`brew outdated --json=v2` carries no usable signal in its EXIT STATUS.

    Measured on Homebrew 7.0.9 and the reason the implementation reads the
    document instead: the command exits 1 both when the package is outdated
    (printing a perfectly good document) and when the name is unknown (printing
    nothing at all), and 0 when the package is current.
    """

    def brewed(self, rc, stdout, **config):
        prefix = self.root / "opt/brew"
        codex = self.cask_install("codex", prefix)
        self.add_brew(prefix, outdated={"codex": {"rc": rc, "stdout": stdout}},
                      upgrade_sets={"codex": [str(self.version_files[str(codex)]), "0.162.1"]},
                      **config)
        return {"HOMEBREW_PREFIX": str(prefix)}

    def test_exit_1_with_a_document_means_outdated(self):
        env = self.brewed(1, OUTDATED_CASK)
        run = self.update("--check", "codex", env=env)
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assertIn("1 of 1 out of date. To upgrade it:", run.stdout)

    def test_exit_0_with_empty_lists_means_current(self):
        env = self.brewed(0, CURRENT_JSON)
        run = self.update("--check", "codex", env=env)
        self.assert_row(run, "codex", "0.154.0", "0.154.0", "brew-cask:codex", "current")
        self.assertIn("Everything is up to date.", run.stdout)
        self.assertEqual(run.returncode, 0, run.stdout)

    def test_exit_1_with_no_output_means_unknown(self):
        env = self.brewed(1, "")
        run = self.update("--check", "codex", env=env)
        self.assert_row(run, "codex", "0.154.0", "?", "brew-cask:codex", "unknown")
        self.assertIn("Could not determine the latest version for codex", run.stdout)
        self.assertEqual(run.returncode, 3, run.stdout)

    def test_an_incomplete_document_is_never_read_as_current(self):
        # A document the watchdog cut short, or something that is not a brew
        # document at all, must degrade to 'unknown'. Reading it as 'current'
        # would tell the user they are up to date when nobody knows.
        documents = {
            "cut mid-token": '{"formulae":[],"casks":[{"name":"codex","current_version":"0.1',
            "cut after a brace": '{"formulae":[],"casks":[{"name":"codex"}',
            "cut before the casks": '{"formulae":[]',
            "not a brew document": "<html><body>502 Bad Gateway</body></html>",
            "empty on success": "",
        }
        for label, document in documents.items():
            with self.subTest(document=label):
                self.setUp()
                rc = 0 if label == "empty on success" else 1
                env = self.brewed(rc, document)
                run = self.update("--check", "codex", env=env)
                self.assert_row(run, "codex", "0.154.0", "?", "brew-cask:codex", "unknown")
                self.assertEqual(run.returncode, 3, run.stdout)

    def test_a_version_brew_reports_still_has_to_look_like_a_version(self):
        env = self.brewed(1, '{"formulae":[],"casks":[{"name":"codex",'
                             '"current_version":"HEAD-abcdef"}]}')
        run = self.update("--check", "codex", env=env)
        self.assert_row(run, "codex", "0.154.0", "?", "brew-cask:codex", "unknown")
        self.assertEqual(run.returncode, 3, run.stdout)


class LatestLookupTests(UpdateFixture):
    """Section 5: print a validated version, or report 'unknown'. Never a guess."""

    def setUp(self):
        super().setUp()
        self.claude = self.add_tool(
            "claude", self.home / ".local/share/claude/versions/2.1.89/claude",
            version="2.1.89", doctor="Auto-update channel: latest")

    def test_an_html_error_page_containing_a_version_is_not_a_version(self):
        self.fetch({CLAUDE_RELEASE + "latest": {"body": HTML_ERROR},
                    CLAUDE_DIST: {"body": HTML_ERROR}})
        run = self.update("--check", "claude")
        self.assert_row(run, "claude", "2.1.89", "?", "native:latest", "unknown")
        self.assertNotIn("1.2.3", run.stdout)
        self.assertEqual(run.returncode, 3, run.stdout)
        self.assertEqual(self.fetched(), [CLAUDE_RELEASE + "latest", CLAUDE_DIST])

    def test_a_failing_endpoint_falls_back_to_the_dist_tags_document(self):
        self.fetch({CLAUDE_RELEASE + "latest": {"rc": 1, "body": ""},
                    CLAUDE_DIST: {"body": '{"stable":"2.1.296","latest":"2.1.300"}'}})
        run = self.update("--check", "claude")
        self.assert_row(run, "claude", "2.1.89", "2.1.300", "native:latest", "OUTDATED")
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_the_channel_decides_which_key_is_read(self):
        self.fetch({CLAUDE_RELEASE + "stable": {"rc": 1, "body": ""},
                    CLAUDE_DIST: {"body": '{"stable":"2.1.296","latest":"2.1.300"}'}})
        run = self.update("--check", "claude", env={"AGENT_UPDATE_CHANNEL": "stable"})
        self.assert_row(run, "claude", "2.1.89", "2.1.296", "native:stable", "OUTDATED")
        self.assertEqual(self.calls_to("claude"), [["claude", "--version"]],
                         "a forced channel must not pay for 'claude doctor'")

    def test_an_invalid_channel_is_reported_and_ignored(self):
        self.fetch({CLAUDE_RELEASE + "latest": {"body": "2.1.296"}})
        run = self.update("--check", "claude", env={"AGENT_UPDATE_CHANNEL": "nightly"})
        self.assertIn("AGENT_UPDATE_CHANNEL must be 'stable' or 'latest'", run.stderr)
        self.assert_row(run, "claude", "2.1.89", "2.1.296", "native:latest", "OUTDATED")

    def test_an_unrecognised_doctor_degrades_to_the_installers_default(self):
        self.add_tool("claude", self.home / ".local/share/claude/versions/2.1.89/claude",
                      version="2.1.89", doctor="Auto-update channel: on alternate Tuesdays",
                      link=False)
        self.fetch({CLAUDE_RELEASE + "latest": {"body": "2.1.296"}})
        self.assert_row(self.update("--check", "claude"), "claude", via="native:latest")

    def test_the_offline_switch_touches_nothing(self):
        self.fetch({CLAUDE_RELEASE + "latest": {"body": "2.1.296"}})
        run = self.update("--check", "claude", env={"AI_UPDATE_OFFLINE": "1"})
        self.assert_row(run, "claude", "2.1.89", "?", "native:latest", "unknown")
        self.assertEqual(self.fetched(), [], "offline must reach the seam, not the network")
        self.assertEqual(run.returncode, 3, run.stdout)
        self.assertIn("no network, or the", run.stdout)
        self.assertIn("'ai update <tool>' would still run the CLI's own updater", run.stdout)

    def test_without_curl_or_wget_the_lookup_is_unknown(self):
        # Neither client is on the fixture PATH and no fetch command is set, so
        # ai_update_fetch fails closed without starting a single process.
        run = self.update("--check", "claude", env={"AI_UPDATE_FETCH_CMD": ""})
        self.assert_row(run, "claude", "2.1.89", "?", "native:latest", "unknown")
        self.assertEqual(self.fetched(), [])
        self.assertEqual(run.returncode, 3, run.stdout)

    def test_curl_is_driven_with_its_own_timeout_and_no_retries(self):
        self.write_fake("curl", FAKE_PLAIN, {"stdout": "2.1.296"})
        run = self.update("--check", "claude", env={"AI_UPDATE_FETCH_CMD": ""})
        self.assertEqual(len(self.calls_to("curl")), 1)
        call = self.calls_to("curl")[0]
        self.assertIn("-fsSL", call)                       # quiet, and fail on 4xx/5xx
        self.assertEqual(call[call.index("--max-time") + 1], "10")
        self.assertEqual(call[call.index("--retry") + 1], "0")
        self.assertEqual(call[-2:], ["--", CLAUDE_RELEASE + "latest"])
        self.assert_row(run, "claude", "2.1.89", "2.1.296", "native:latest", "OUTDATED")

    def test_wget_is_used_when_curl_is_absent(self):
        self.write_fake("wget", FAKE_PLAIN, {"stdout": "2.1.296\n"})
        run = self.update("--check", "claude", env={"AI_UPDATE_FETCH_CMD": ""})
        self.assertEqual(len(self.calls_to("wget")), 1)
        call = self.calls_to("wget")[0]
        self.assertIn("-q", call)
        self.assertEqual(call[call.index("-O") + 1], "-")   # body on stdout, no file
        self.assertIn("--timeout=10", call)
        self.assertIn("--tries=1", call)
        self.assertEqual(call[-2:], ["--", CLAUDE_RELEASE + "latest"])
        self.assert_row(run, "claude", "2.1.89", "2.1.296", "native:latest", "OUTDATED")

    def test_the_fetch_command_wins_over_curl_and_is_word_split(self):
        self.write_fake("curl", FAKE_PLAIN, {"stdout": "9.9.9"})
        self.fetch({"html": {"body": HTML_ERROR}})
        run = self.update("--check", "claude",
                          env={"AI_UPDATE_FETCH_CMD": "ai-fetch-stub --mode html"})
        self.assertEqual(self.calls_to("curl"), [])
        self.assert_row(run, "claude", "2.1.89", "?", "native:latest", "unknown")

    def test_a_trailing_newline_or_carriage_return_is_stripped(self):
        self.fetch({CLAUDE_RELEASE + "latest": {"body": "2.1.296\r\n"}})
        self.assert_row(self.update("--check", "claude"), "claude", latest="2.1.296")

    def test_codex_reads_the_dist_tags_pointer(self):
        self.add_tool("codex", self.home / ".local/bin/codex", version="0.154.0")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1","alpha":"0.163.0-alpha.5"}'}})
        run = self.update("--check", "codex")
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "native", "OUTDATED")
        self.assertEqual(self.fetched(), [CODEX_DIST])

    def test_an_install_ahead_of_the_release_is_left_alone(self):
        self.add_tool("codex", self.home / ".local/bin/codex", version="0.163.0-alpha.5")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1"}'}})
        check = self.update("--check", "codex")
        self.assert_row(check, "codex", "0.163.0-alpha.5", "0.162.1", "native", "ahead")
        self.assertEqual(check.returncode, 0, check.stdout)
        run = self.update("codex")
        self.assertIn("0.163.0-alpha.5 is newer than 0.162.1; leaving it alone.", run.stdout)
        self.assertEqual(run.returncode, 0, run.stdout)
        self.assert_no_upgrade_ran()


class UpgradeTests(UpdateFixture):
    """Section 3: what actually runs, what it is told, and what happens after."""

    def brew_codex(self, prefix=None, bump=None, **config):
        prefix = prefix or self.root / "opt/brew"
        codex = self.cask_install("codex", prefix)
        config.setdefault("outdated", {"codex": {"rc": 1, "stdout": OUTDATED_CASK}})
        if bump:
            config.setdefault("upgrade_sets",
                              {"codex": [str(self.version_files[str(codex)]), bump]})
        brew = self.add_brew(prefix, **config)
        return brew, codex, {"HOMEBREW_PREFIX": str(prefix)}

    def test_a_cask_upgrade_is_exactly_brew_upgrade_cask(self):
        brew, codex, env = self.brew_codex(bump="0.162.1")
        run = self.update("codex", env=env)
        self.assert_display(run.stdout, "cask", "codex", prefix="codex:")
        self.assertEqual(len(self.upgrades()), 1)
        self.assert_upgrade_argv(self.upgrades()[0], "cask", "codex")
        self.assertIn("0.154.0 -> 0.162.1  OK", run.stdout)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_check_runs_no_command_at_all(self):
        brew, codex, env = self.brew_codex()
        run = self.update("--check", "codex", env=env)
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()
        self.assertNotIn("upgrade", self.brew_subcommands())

    def test_a_failing_upgrade_changes_nothing_and_says_so(self):
        brew, codex, env = self.brew_codex(upgrade_rc=1)
        run = self.update("codex", env=env)
        self.assert_display(run.stdout, "cask", "codex", prefix="FAILED (")
        self.assertIn("exited 1) — nothing was changed.", run.stdout)
        self.assertIn("1 failed.", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_an_upgrade_that_does_not_move_the_version_names_the_path_shadow(self):
        # brew reports success, `codex --version` does not move: in the wild
        # this is always a second copy earlier on PATH.
        shadow_dir = self.root / "stale commands"
        brew, codex, env = self.brew_codex()
        shadow = self.add_tool("codex", shadow_dir / "codex", version="0.100.0", link=False)
        env = dict(env, PATH=str(self.fakebin) + os.pathsep + str(shadow_dir))
        run = self.update("codex", env=env)
        self.assertIn("upgrade reported success, but 'codex --version' still says 0.154.0.",
                      run.stdout)
        self.assertIn("Another copy resolves earlier on your PATH:", run.stdout)
        self.assertIn(str(self.fakebin / "codex"), run.stdout)
        self.assertIn(str(shadow), run.stdout)
        self.assertIn("Fix your PATH or remove the stale copy.", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_a_single_copy_that_does_not_move_says_so_instead(self):
        brew, codex, env = self.brew_codex()
        run = self.update("codex", env=env)
        self.assertIn("Nothing else on your PATH shadows it", run.stdout)
        self.assertNotIn("Another copy resolves earlier", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_the_watchdog_kills_a_stuck_upgrade_and_names_the_setting(self):
        brew, codex, env = self.brew_codex(upgrade_sleep=60)
        run = self.update("codex", env=dict(env, AGENT_UPDATE_TIMEOUT="2"), timeout=90)
        self.assertIn("TIMED OUT after 2s", run.stdout)
        self.assertIn("AGENT_UPDATE_TIMEOUT=0 ai update codex", run.stdout)
        self.assertIn("builds", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_a_fast_crash_is_not_reported_as_a_timeout(self):
        import signal
        brew, codex, env = self.brew_codex(upgrade_signal=int(signal.SIGKILL))
        run = self.update("codex", env=dict(env, AGENT_UPDATE_TIMEOUT="2"), timeout=90)
        self.assertNotIn("TIMED OUT", run.stdout)
        self.assertIn("FAILED", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_a_standalone_tool_whose_version_cannot_be_read_is_a_failure(self):
        # Its own updater ran and reported success, but nothing can confirm
        # what is installed now. That is not 'already current'.
        self.add_tool("codex", self.home / ".local/bin/codex", banner="codex-cli (dev build)")
        run = self.update("codex")
        self.assertIn(["codex", "update"], self.commands())
        self.assertNotIn("already current", run.stdout)
        self.assertIn("1 failed.", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_mixed_outcomes_are_counted_by_what_happened(self):
        prefix = self.root / "opt/brew"
        codex = self.cask_install("codex", prefix)
        self.add_brew(prefix, outdated={"codex": {"rc": 1, "stdout": OUTDATED_CASK}},
                      upgrade_sets={"codex": [str(self.version_files[str(codex)]), "0.162.1"]})
        run = self.update(env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "claude", "-", "-", "-", "NOT INSTALLED")
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assertIn("1 upgraded, 1 not installed.", run.stdout)
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_nothing_to_do_exits_0(self):
        prefix = self.root / "opt/brew"
        self.cask_install("codex", prefix, version="0.162.1")
        self.add_brew(prefix, outdated={"codex": {"rc": 0, "stdout": CURRENT_JSON}})
        for args in (["--check", "codex"], ["codex"]):
            with self.subTest(args=args):
                run = self.update(*args, env={"HOMEBREW_PREFIX": str(prefix)})
                self.assertEqual(run.returncode, 0, run.stdout)
                self.assert_no_upgrade_ran()

    def test_via_standalone_overrides_the_refusal_outside_home(self):
        # The one safety rule --via relaxes, and only because the user is
        # asserting precisely that. It still never reaches for sudo.
        codex = self.add_tool("codex", self.root / "usr/bin/codex", update_sets="0.162.1")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1"}'}})
        run = self.update("codex", "--via", "standalone")
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "native", "OUTDATED")
        self.assertEqual([e["argv"] for e in self.upgrades()],
                         [[str(self.fakebin / "codex"), "update"]])
        self.assertIn("0.154.0 -> 0.162.1  OK", run.stdout)
        self.assertEqual(run.returncode, 0, run.stdout)

    def test_via_brew_refuses_when_no_known_package_is_installed(self):
        self.add_tool("codex", self.root / "usr/bin/codex")
        self.add_brew(self.root / "opt/empty brew", installed={})
        run = self.update("codex", "--via", "brew",
                          env={"HOMEBREW_PREFIX": str(self.root / "opt/empty brew")})
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("--via brew: Homebrew has none of these installed: codex", run.stderr)
        self.assert_no_upgrade_ran()

    def test_via_brew_finds_the_brew_that_actually_has_the_package(self):
        # Two Homebrews; only the second has the cask. The first must not be
        # the answer merely because it was discovered first.
        empty = self.root / "opt/brew without it"
        owner = self.root / "opt/brew with it"
        codex = self.add_tool("codex", self.root / "usr/bin/codex")
        self.add_brew(empty, installed={})
        brew = self.add_brew(
            owner, on_path=True, installed={"codex": "cask"},
            outdated={"codex": {"rc": 1, "stdout": OUTDATED_CASK}},
            upgrade_sets={"codex": [str(self.version_files[str(codex)]), "0.162.1"]})
        run = self.update("codex", "--via", "brew", env={"HOMEBREW_PREFIX": str(empty)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "brew-cask:codex", "OUTDATED")
        self.assertEqual(len(self.upgrades()), 1)
        self.assert_upgrade_argv(self.upgrades()[0], "cask", "codex")
        self.assertEqual(os.path.realpath(self.upgrades()[0]["argv"][0]), str(brew))
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_the_lib_names_no_forbidden_command(self):
        import re
        code = "\n".join(line for line in self.lib.read_text().splitlines()
                         if not line.lstrip().startswith("#"))
        for forbidden in (r"(?<![\w-])sudo\b", r"claude install",
                          r"npm (update|upgrade)", r"brew install codex\b",
                          r"readlink -", r"(?<![\w_])realpath\b", r"sort -V"):
            self.assertIsNone(re.search(forbidden, code),
                              "forbidden in update.sh: " + forbidden)

    def test_the_launcher_still_makes_no_network_call_of_its_own(self):
        # 'update' is the only part of the package that reaches the network, and
        # it lives in the lazily-sourced lib. bin/ai must carry no URL and must
        # never put curl or wget in command position. (Naming them in the manual
        # is fine -- that is documentation, not a call.)
        import re
        source = (self.package / "bin/ai").read_text()
        self.assertIsNone(re.search(r"https?://", source), "bin/ai gained a URL")
        self.assertIsNone(re.search(r"(?m)(^|[;&|(]|\$\()\s*(curl|wget)\b", source),
                          "bin/ai invokes a network client")

    def test_the_installer_hint_names_the_cask(self):
        installer = (PACKAGE / "install.sh").read_text()
        self.assertNotIn("brew install codex", installer,
                         "there is no codex formula; the hint must say --cask")


class BinaryOverrideTests(UpdateFixture):
    """AI_KIT_CLAUDE_BINARY / AI_KIT_CODEX_BINARY name the binary, full stop.

    A set-but-unusable override is a hard error for that tool and never a
    silent fall back to PATH: a user who points this at one binary must not
    get a different one upgraded.
    """

    def setUp(self):
        super().setUp()
        self.on_path = self.add_tool("codex", self.root / "usr/bin/codex", version="0.100.0")

    def test_the_override_is_what_gets_measured_and_upgraded(self):
        chosen = self.add_tool("codex", self.home / "opt/chosen/bin/codex",
                               version="0.154.0", link=False, update_sets="0.162.1")
        self.fetch({CODEX_DIST: {"body": '{"latest":"0.162.1"}'}})
        run = self.update("codex", env={"AI_KIT_CODEX_BINARY": str(chosen)})
        self.assert_row(run, "codex", "0.154.0", "0.162.1", "native", "OUTDATED")
        self.assertNotIn("0.100.0", run.stdout, "the PATH copy was measured instead")
        self.assertEqual([e["argv"] for e in self.upgrades()], [[str(chosen), "update"]])
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_an_override_naming_nothing_is_a_hard_error_for_that_tool(self):
        missing = self.root / "nowhere at all/codex"
        run = self.update("codex", env={"AI_KIT_CODEX_BINARY": str(missing)})
        self.assert_row(run, "codex", "-", "-", "broken", "BROKEN")
        self.assertIn("AI_KIT_CODEX_BINARY names %s, which is not an executable file" % missing,
                      run.stdout)
        self.assertNotIn("0.100.0", run.stdout, "it fell back to PATH")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()

    def test_an_override_that_is_not_executable_is_a_hard_error(self):
        unusable = self.root / "not executable/codex"
        unusable.parent.mkdir()
        unusable.write_text("#!/bin/sh\necho 0.154.0\n")
        unusable.chmod(0o644)
        run = self.update("codex", env={"AI_KIT_CODEX_BINARY": str(unusable)})
        self.assert_row(run, "codex", "-", "-", "broken", "BROKEN")
        self.assertIn("which is not an executable file", run.stdout)
        self.assertNotIn("0.100.0", run.stdout, "it fell back to PATH")
        self.assertEqual(run.returncode, 1, run.stdout)
        self.assert_no_upgrade_ran()

    def test_one_broken_override_does_not_disturb_the_other_tool(self):
        self.add_tool("claude", self.home / ".local/bin/claude", version="2.1.296",
                      doctor="Auto-update channel: latest")
        self.fetch({CLAUDE_RELEASE + "latest": {"body": "2.1.296"},
                    CODEX_DIST: {"body": '{"latest":"0.100.0"}'}})
        run = self.update(env={"AI_KIT_CODEX_BINARY": str(self.root / "gone/codex")})
        self.assert_row(run, "claude", "2.1.296", "2.1.296", "native:latest", "current")
        self.assert_row(run, "codex", "-", "-", "broken", "BROKEN")
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_the_override_suppresses_the_path_shadow_listing(self):
        # The named binary is exactly what was measured, so a PATH shadow
        # cannot be the explanation and listing copies would misdirect.
        prefix = self.root / "opt/brew"
        (self.fakebin / "codex").unlink()
        codex = self.cask_install("codex", prefix)
        extra = self.root / "extra commands"
        self.add_tool("codex", extra / "codex", version="0.100.0", link=False)
        self.add_brew(prefix, outdated={"codex": {"rc": 1, "stdout": OUTDATED_CASK}})
        env = {"HOMEBREW_PREFIX": str(prefix),
               "PATH": str(self.fakebin) + os.pathsep + str(extra)}
        without = self.update("codex", env=env)
        self.assertIn("Another copy resolves earlier on your PATH:", without.stdout)
        with_override = self.update("codex", env=dict(env, AI_KIT_CODEX_BINARY=str(codex)))
        self.assertIn("upgrade reported success", with_override.stdout)
        self.assertNotIn("Another copy resolves earlier", with_override.stdout)
        self.assertNotIn(str(extra / "codex"), with_override.stdout)
        self.assertIn("AI_KIT_CODEX_BINARY", with_override.stdout)
        self.assertEqual(with_override.returncode, 1, with_override.stdout)


class ReportTests(UpdateFixture):
    """Section 7: the table is ASCII, <= 80 columns, and says only what it knows."""

    def npm_global(self, tool, package, version, latest):
        path = self.add_tool(
            tool, self.home / (".npm-global/lib/node_modules/%s/bin/%s" % (package, tool)),
            version=version, doctor="Auto-update channel: latest")
        if tool == "claude":
            self.fetch({CLAUDE_RELEASE + "latest": {"body": latest}})
        else:
            self.fetch({CODEX_DIST: {"body": '{"latest":"%s"}' % latest}})
        return path

    def test_every_table_row_fits_in_eighty_columns(self):
        self.npm_global("claude", "@anthropic-ai/claude-code", "2.1.89", "2.1.296")
        self.npm_global("codex", "@openai/codex", "0.154.0", "0.162.1")
        run = self.update("--check")
        self.assert_row(run, "claude", "2.1.89", "2.1.296")
        self.assert_table_fits_eighty_columns(run)

    def test_the_summary_never_ends_with_a_header_and_nothing_under_it(self):
        # Every out-of-date tool here is one we refuse to drive, so there is no
        # command to offer: the header must not be printed at all.
        self.npm_global("codex", "@openai/codex", "0.154.0", "0.162.1")
        run = self.update("--check", "codex")
        self.assertEqual(run.returncode, 1, run.stdout)
        lines = [line for line in run.stdout.splitlines() if line.strip()]
        for index, line in enumerate(lines):
            if line.endswith("To upgrade it:") or line.endswith("To upgrade them:"):
                self.assertGreater(len(lines), index + 1,
                                   "a dangling header with nothing under it:\n" + run.stdout)

    def test_the_report_is_plain_ascii(self):
        self.npm_global("codex", "@openai/codex", "0.154.0", "0.162.1")
        run = self.update("--check", "codex")
        self.assertNotIn("\x1b[", run.stdout, "the report must carry no colour")


class WrapperTests(UpdateFixture):
    """The *-wt wrappers, whose own argument order decides what 'update' means."""

    def setUp(self):
        super().setUp()
        self.add_tool("claude", self.root / "system bin/claude", version="2.1.296")
        self.add_tool("codex", self.root / "system bin/codex", version="0.154.0")

    def git_repo(self):
        repo = self.root / "a git repo"
        repo.mkdir()
        def git(*args):
            subprocess.run(["git", "-C", str(repo), "-c", "user.email=t@example.invalid",
                            "-c", "user.name=Update tests", "-c", "commit.gpgsign=false",
                            *args], env=self.env, check=True, capture_output=True)
        subprocess.run(["git", "init", "-q", str(repo)], env=self.env, check=True,
                       capture_output=True)
        (repo / "seed.txt").write_text("seed\n")
        git("add", "seed.txt")
        git("commit", "-qm", "fixture")
        return repo

    def test_agent_wt_update_is_a_usage_error(self):
        # agent-wt passes a bare 'wt', which is an EXPLICIT mode request.
        run = self.run_ai("update", launcher=self.package / "bin/agent-wt")
        self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
        self.assertIn("runs no agent and cuts no worktree", run.stderr)
        self.assertIsNone(self.launch())

    def test_codex_wt_update_launches_the_agent_rather_than_updating(self):
        # codex-wt passes '--agent codex' BEFORE 'update' is seen, so 'update'
        # is prompt text, in worktree mode. Documented elsewhere as working;
        # this records what it actually does.
        repo = self.git_repo()
        run = self.run_ai("update", launcher=self.package / "bin/codex-wt", cwd=repo)
        launched = self.launch()
        self.assertIsNotNone(launched, run.stdout + run.stderr)
        self.assertEqual(launched["task"], "update")
        self.assertEqual(launched["tool"], "codex")
        self.assertNotEqual(launched["cwd"], str(repo), "it should be in a worktree")
        self.assertNotIn("checking:", run.stdout)

    def test_a_wt_named_symlink_still_reaches_the_subcommand(self):
        # An implicit mode (the wrapper's own name) is ignored by 'update'.
        wrapper = self.fakebin / "kit-wt"
        wrapper.symlink_to(self.ai)
        run = self.run_ai("update", "--check", "codex", launcher=wrapper)
        self.assertIn("checking:  codex", run.stdout)
        self.assertIsNone(self.launch())


class ExitCodeTests(UpdateFixture):
    """Design section 8, with precedence 2 > 1 > 3 > 0."""

    def codex_with_brew_answering(self, rc, document, version="0.154.0"):
        self.setUp()
        prefix = self.root / "opt/brew"
        self.cask_install("codex", prefix, version=version)
        self.add_brew(prefix, outdated={"codex": {"rc": rc, "stdout": document}})
        return {"HOMEBREW_PREFIX": str(prefix)}

    def test_zero_when_there_is_nothing_left_to_do(self):
        env = self.codex_with_brew_answering(0, CURRENT_JSON)
        self.assertEqual(self.update("--check", "codex", env=env).returncode, 0)
        self.assertEqual(self.update("codex", env=env).returncode, 0)

    def test_one_when_something_is_actionable_and_unresolved(self):
        env = self.codex_with_brew_answering(1, OUTDATED_CASK)
        self.assertEqual(self.update("--check", "codex", env=env).returncode, 1)
        env = self.codex_with_brew_answering(0, CURRENT_JSON)
        self.assertEqual(self.update("--check", "claude", env=env).returncode, 1)

    def test_three_when_the_latest_version_could_not_be_determined(self):
        env = self.codex_with_brew_answering(1, "")
        self.assertEqual(self.update("--check", "codex", env=env).returncode, 3)
        self.assertEqual(self.update("codex", env=env).returncode, 3)

    def test_one_outranks_three_when_both_apply(self):
        self.setUp()
        prefix = self.root / "opt/brew"
        self.cask_install("codex", prefix)
        self.add_brew(prefix, outdated={"codex": {"rc": 1, "stdout": OUTDATED_CASK}})
        run = self.update("--check", env={"HOMEBREW_PREFIX": str(prefix)})
        self.assert_row(run, "claude", status="NOT INSTALLED")
        self.assert_row(run, "codex", status="OUTDATED")
        self.assertEqual(run.returncode, 1, run.stdout)

    def test_two_outranks_everything(self):
        env = self.codex_with_brew_answering(1, OUTDATED_CASK)
        self.assertEqual(self.update("--check", "codex", "--via", "apt", env=env).returncode, 2)


if __name__ == "__main__":
    unittest.main()
