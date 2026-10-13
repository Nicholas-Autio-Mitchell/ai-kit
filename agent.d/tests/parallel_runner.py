"""Run one unittest TestCase across worker processes.

A suite ends with `parallel_runner.main(TheTestCase)`. Without arguments its
tests are dealt round-robin to worker processes (one per CPU, at most 8;
AI_TEST_JOBS=N overrides, and 1 runs everything in a single worker), and each
worker's report is printed as one block when the worker finishes. With
arguments (-k NAME, -v, --durations N, ...) unittest runs in this process as
usual, which is the way to run or debug a single test.

The suites spend nearly all their time waiting on child processes (Git, the
launcher, and on some hosts an endpoint-security scan of every exec), so the
workers overlap well. Every test builds its own temporary fixtures, and each
worker builds its own shared ones, so no worker can see another's state.
"""

import os
import re
import subprocess
import sys
import unittest


def main(case):
    shard = os.environ.get("AI_TEST_SHARD")
    if shard:
        index, count = (int(part) for part in shard.split("/"))
        names = unittest.defaultTestLoader.getTestCaseNames(case)[index::count]
        result = unittest.TextTestRunner(stream=sys.stdout, verbosity=2).run(
            unittest.TestSuite(case(name) for name in names))
        sys.exit(0 if result.wasSuccessful() else 1)
    if len(sys.argv) > 1:
        unittest.main(module="__main__", verbosity=2)
        return

    total = len(unittest.defaultTestLoader.getTestCaseNames(case))
    jobs = int(os.environ.get("AI_TEST_JOBS") or min(8, os.cpu_count() or 1))
    jobs = max(1, min(jobs, total))
    workers = [
        subprocess.Popen(
            [sys.executable, sys.argv[0]],
            env=dict(os.environ, AI_TEST_SHARD="%d/%d" % (index, jobs)),
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True,
        )
        for index in range(jobs)
    ]
    ran, failed = 0, []
    for index, worker in enumerate(workers):
        output, _ = worker.communicate()
        sys.stdout.write("---- worker %d/%d ----\n%s\n" % (index + 1, jobs, output))
        ran += sum(int(n) for n in re.findall(r"^Ran (\d+) tests? in", output, re.M))
        if worker.returncode != 0:
            failed.append(index + 1)
    sys.stdout.flush()
    if ran != total:
        failed.append("(ran %d of %d tests)" % (ran, total))
    if failed:
        print("FAILED: %s, worker(s) %s" % (case.__name__, ", ".join(map(str, failed))))
        sys.exit(1)
    print("OK: %s, %d tests in %d workers" % (case.__name__, ran, jobs))
