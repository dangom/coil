# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Daniel Gomez

"""The bridge with a real kernel: completion, and the idle watch.

Run with `make test-bridge PYTHON=...', a Python with ipykernel (a pixi
project's, say: .pixi/envs/default/bin/python).  Skipped without it.  The idle watch is tested with a limit of COIL_TEST_IDLE
seconds (8), so this takes about a minute.
"""

import json
import os
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

BRIDGE = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                      "bridge", "coil_bridge.py")
KERNEL = json.dumps(["{python}", "-m", "ipykernel_launcher", "-f", "{connection_file}"])
IDLE = float(os.environ.get("COIL_TEST_IDLE", "8"))

try:
    import ipykernel  # noqa: F401
    import jupyter_client  # noqa: F401
    HAVE_KERNEL = True
except ImportError:
    HAVE_KERNEL = False


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except (ProcessLookupError, PermissionError, TypeError):
        return False


def wait_for(condition, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.2)
    return condition()


class Bridge:
    """The bridge as Emacs runs it: a subprocess, JSON lines both ways."""

    def __init__(self, state, idle=0):
        self.process = subprocess.Popen(
            [sys.executable, "-I", BRIDGE, "--state", state, "--cwd", state,
             "--kernel", KERNEL, "--idle", str(idle)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.pending = b""
        self.next_id = 0
        self.ready = self.wait("ready", timeout=60)

    def send(self, op, **fields):
        self.next_id += 1
        line = json.dumps({"id": self.next_id, "op": op, **fields}) + "\n"
        self.process.stdin.write(line.encode())
        self.process.stdin.flush()
        return self.next_id

    def wait(self, event, id=None, timeout=30):
        """The next EVENT (for request ID), or None after TIMEOUT seconds."""
        deadline = time.monotonic() + timeout
        fd = self.process.stdout.fileno()
        while time.monotonic() < deadline:
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                message = json.loads(line)
                if message["event"] == event and (id is None or message.get("id") == id):
                    return message
            if select.select([fd], [], [], 0.2)[0]:
                chunk = os.read(fd, 1 << 20)
                if not chunk:
                    return None
                self.pending += chunk
        return None

    def run(self, code, timeout=60):
        return self.wait("done", self.send("execute", code=code), timeout)

    def detach(self):
        """As when Emacs goes: the bridge ends, the kernel stays."""
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()

    def shutdown(self):
        self.send("shutdown")
        self.wait("shutdown", timeout=15)
        self.process.wait(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()


@unittest.skipUnless(HAVE_KERNEL, "no ipykernel in this environment")
class BridgeTest(unittest.TestCase):
    def setUp(self):
        # Short: Unix socket paths have a length limit.
        self.state = tempfile.mkdtemp(prefix="coil-")
        self.pids = []

    def tearDown(self):
        for pid in self.pids:
            if alive(pid):
                os.kill(pid, signal.SIGKILL)
        shutil.rmtree(self.state, ignore_errors=True)

    def start(self, idle=0):
        bridge = Bridge(self.state, idle)
        self.assertIsNotNone(bridge.ready, "the bridge never said ready")
        self.pids.append(bridge.ready["pid"])
        return bridge

    def test_completion_of_live_objects(self):
        bridge = self.start()
        bridge.run("d = {'gamma': 1}\nclass C: pass\nc = C(); c.made_at_run_time = 1")
        for code, expected in (("c.made_", "made_at_run_time"), ("d['g", "gamma")):
            reply = bridge.wait("reply", bridge.send("complete", code=code, pos=len(code)))
            self.assertEqual(reply["content"]["status"], "ok")
            self.assertTrue(any(expected in m for m in reply["content"]["matches"]),
                            reply["content"]["matches"])
        bridge.shutdown()

    def test_idle_kernel_attached_is_shut_down_and_says_why(self):
        bridge = self.start(IDLE)
        pid = bridge.ready["pid"]
        self.assertTrue(bridge.run("x = 1"))
        died = bridge.wait("died", timeout=IDLE + 30)
        self.assertIsNotNone(died, "the idle kernel was not shut down")
        self.assertEqual(died["ended"]["idle"], IDLE)
        self.assertFalse(alive(pid))
        bridge.detach()
        # Its files are gone with it, but its log.
        wait_for(lambda: os.listdir(self.state) == ["kernel.log"], 10)
        self.assertEqual(os.listdir(self.state), ["kernel.log"])

    def test_run_longer_than_the_limit_is_not_cut_short(self):
        bridge = self.start(IDLE)
        pid = bridge.ready["pid"]
        # Sent at once, before the watch listens: it must find out by asking.
        started = time.monotonic()
        done = bridge.run(f"import time; time.sleep({IDLE * 3})", timeout=IDLE * 3 + 30)
        self.assertEqual(done["status"], "ok")
        self.assertGreaterEqual(time.monotonic() - started, IDLE * 3 - 1)
        self.assertTrue(alive(pid), "the kernel was shut down as the run ended")
        bridge.shutdown()

    def test_detached_kernel_is_shut_down_and_the_next_start_says_so(self):
        bridge = self.start(IDLE)
        pid = bridge.ready["pid"]
        bridge.run("x = 1")
        bridge.detach()
        self.assertTrue(alive(pid), "the kernel did not outlive its bridge")
        self.assertTrue(wait_for(lambda: not alive(pid), IDLE + 40),
                        "the detached idle kernel was not shut down")
        bridge = self.start(0)
        self.assertTrue(bridge.ready["fresh"])
        self.assertEqual(bridge.ready["ended"]["idle"], IDLE)
        bridge.shutdown()

    def test_no_watch_without_a_limit(self):
        bridge = self.start(0)
        time.sleep(2)
        self.assertFalse(os.path.exists(os.path.join(self.state, "watch.pid")))
        bridge.shutdown()


if __name__ == "__main__":
    unittest.main(verbosity=2)
