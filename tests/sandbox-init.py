"""Exercise the CyDo binary as PID 1 in a real Bubblewrap namespace."""

import os
import select
import signal
import subprocess
import sys
import time
import unittest
from contextlib import contextmanager
from pathlib import Path


TIMEOUT = 5


def reap_orphan():
    pid_read, pid_write = os.pipe()
    release_read, release_write = os.pipe()
    parent = os.fork()
    if parent == 0:
        orphan = os.fork()
        if orphan == 0:
            os.close(pid_write)
            os.close(release_write)
            os.read(release_read, 1)
            os._exit(0)
        os.write(pid_write, str(orphan).encode())
        os._exit(0)

    os.close(pid_write)
    os.close(release_read)
    os.waitpid(parent, 0)
    with os.fdopen(pid_read) as child_pid:
        orphan = Path("/proc") / child_pid.read()
    status = dict(line.split(":", 1) for line in (orphan / "status").read_text().splitlines())
    if status["PPid"].strip() != "1":
        raise AssertionError(f"{orphan} was not adopted by namespace init")

    os.write(release_write, b"x")
    os.close(release_write)
    deadline = time.monotonic() + TIMEOUT
    while orphan.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"namespace init did not reap {orphan}")
        time.sleep(0.01)


def leave_background_process():
    if os.fork() == 0:
        # Keep the output pipe open until the namespace is torn down.
        print("ready", flush=True)
        while True:
            signal.pause()
    if sys.stdin.buffer.read(1) != b"x":
        raise AssertionError("test driver closed stdin before releasing the agent")


def forward_term():
    def on_term(signum, frame):
        sys.exit(42)

    if os.getppid() != 1:
        raise AssertionError("agent is not a child of namespace init")
    signal.signal(signal.SIGTERM, on_term)
    # The init hands us the launcher's signal mask unchanged.
    signal.pthread_sigmask(signal.SIG_UNBLOCK, {signal.SIGTERM})
    os.kill(1, signal.SIGTERM)
    while True:
        signal.pause()


class SandboxInitTests(unittest.TestCase):
    @contextmanager
    def sandbox(self, *command, init_launcher=()):
        with subprocess.Popen(
            [
                "bwrap", "--unshare-pid", "--as-pid-1", "--die-with-parent",
                "--ro-bind", "/", "/", "--proc", "/proc", "--",
                *init_launcher, CYDO, "sandbox-init", "--", *command,
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        ) as process:
            try:
                yield process
            finally:
                if process.returncode is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait(timeout=TIMEOUT)

    def agent(self, function):
        return self.sandbox(sys.executable, __file__, "--agent", function.__name__)

    def wait_until_ready(self, process):
        # The agent emits exactly one line after the background child starts.
        readable, _, _ = select.select([process.stdout], [], [], TIMEOUT)
        self.assertTrue(readable, "background child did not become ready")
        self.assertEqual(process.stdout.readline(), b"ready\n")

    def assert_exit(self, process, expected, input_data=None, *, timeout=TIMEOUT):
        _, stderr = process.communicate(input_data, timeout=timeout)
        self.assertEqual(process.returncode, expected, stderr.decode(errors="replace"))

    def test_reaps_adopted_orphan_while_agent_runs(self):
        with self.agent(reap_orphan) as process:
            self.assert_exit(process, 0, timeout=TIMEOUT + 2)

    def test_exit_kills_live_background_process(self):
        with self.agent(leave_background_process) as process:
            self.wait_until_ready(process)
            self.assert_exit(process, 0, b"x")

    def test_propagates_exit_code(self):
        with self.sandbox(sys.executable, "-c", "raise SystemExit(37)") as process:
            self.assert_exit(process, 37)

    def test_reaps_main_child_with_inherited_sigchld_ignored(self):
        init_launcher = (
            sys.executable, "-c",
            "import os, signal, sys; "
            "signal.signal(signal.SIGCHLD, signal.SIG_IGN); "
            "os.execv(sys.argv[1], sys.argv[1:])",
        )
        with self.sandbox(
            sys.executable, "-c", "raise SystemExit(37)", init_launcher=init_launcher,
        ) as process:
            self.assert_exit(process, 37)

    def test_forwards_inherited_ignored_and_blocked_sigterm(self):
        init_launcher = (
            sys.executable, "-c",
            "import os, signal, sys; "
            "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
            "signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM}); "
            "os.execv(sys.argv[1], sys.argv[1:])",
        )
        with self.sandbox(
            sys.executable, __file__, "--agent", "forward_term", init_launcher=init_launcher,
        ) as process:
            self.assert_exit(process, 42)

    def test_maps_signal_death_to_exit_status(self):
        with self.sandbox(
            sys.executable, "-c", "import os, signal; os.kill(os.getpid(), signal.SIGTERM)",
        ) as process:
            self.assert_exit(process, 128 + signal.SIGTERM)

    def test_forwards_sigterm_sent_directly_to_init(self):
        with self.agent(forward_term) as process:
            self.assert_exit(process, 42)

    def test_outer_bwrap_death_kills_namespace(self):
        with self.agent(leave_background_process) as process:
            self.wait_until_ready(process)
            process.kill()
            # Leave stdin open so its EOF cannot make the agent exit. EOF on
            # stdout proves that the background child lost its pipe writer.
            readable, _, _ = select.select([process.stdout], [], [], TIMEOUT)
            self.assertTrue(readable, "namespace survived the death of outer bwrap")
            self.assertEqual(process.stdout.read(1), b"")
            self.assertEqual(process.wait(timeout=TIMEOUT), -signal.SIGKILL)

    def test_exec_failure_exits_with_diagnostic(self):
        command = "/cydo-test-nonexistent-command"
        with self.sandbox(command) as process:
            _, stderr = process.communicate(timeout=TIMEOUT)
            self.assertEqual(process.returncode, 127, stderr.decode(errors="replace"))
            self.assertIn(command.encode(), stderr)


if __name__ == "__main__":
    if sys.argv[1] == "--agent":
        globals()[sys.argv[2]]()
    else:
        CYDO = sys.argv.pop(1)
        unittest.main(verbosity=2)
