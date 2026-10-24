"""Real bounded POSIX child/session controls; never run Xcode or Simulator."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/run-owned-xcodebuild.py"


class OwnedXcodebuildDeadlineTests(unittest.TestCase):
    def setUp(self):
        self.assertEqual(os.name, "posix", "Owned-session tests require POSIX; unsupported is not a passing skip")
        spec = importlib.util.spec_from_file_location("owned_deadline", SCRIPT)
        self.module = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def active(self, pid):
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=1).stdout.strip()
        return bool(state) and not state.startswith("Z")

    def payload(self, hold):
        descendant = self.root / "descendant.pid"
        ready = self.root / "native.ready"
        child = "import os,signal,time;from pathlib import Path;signal.signal(signal.SIGTERM,signal.SIG_IGN);Path(%r).write_text(str(os.getpid()));time.sleep(8)" % str(descendant)
        native = "import os,subprocess,sys,time;from pathlib import Path;Path(%r).write_text(str(os.getpgrp()));subprocess.Popen([sys.executable,'-c',%r]);p=Path(%r);limit=time.monotonic()+2\nwhile not p.exists() and time.monotonic()<limit: time.sleep(.01)\nPath(%r).touch()\n%s" % (str(self.root / "native.group"), child, str(descendant), str(ready), "time.sleep(8)" if hold else "raise SystemExit(0)")
        return native, descendant, ready

    def test_driver_cli_is_exact_readonly_empty_stdin_and_preserves_exit(self):
        receipt = self.root / "driver-receipt.json"
        fake = self.root / "xcrun"
        fake.write_text("#!" + sys.executable + "\nimport json,os,sys\nfrom pathlib import Path\nPath(os.environ['DRIVER_UNIT_RECEIPT']).write_text(json.dumps(dict(argv=sys.argv[1:],stdin=sys.stdin.read(),determinism=os.environ.get('SWIFTC_MAXIMUM_DETERMINISM'))))\nraise SystemExit(int(os.environ['DRIVER_UNIT_EXIT']))\n")
        fake.chmod(0o700)
        command = ["xcrun", "swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"]
        env = dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""),
                   DRIVER_UNIT_RECEIPT=str(receipt), SWIFTC_MAXIMUM_DETERMINISM="1")
        for code in (0, 23):
            with self.subTest(code=code):
                result = subprocess.run([sys.executable, str(SCRIPT), "--phase", "driver", "--"] + command,
                    input="Caller input must not reach Swift\n", env=dict(env, DRIVER_UNIT_EXIT=str(code)),
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                observed = json.loads(receipt.read_text())
                self.assertEqual(observed, dict(argv=command[1:], stdin="", determinism="1"))
                completed = [json.loads(line.split(" ", 1)[1]) for line in result.stdout.splitlines()
                             if line.startswith("OwnedXcodebuildCommand ") and '"event": "complete"' in line]
                self.assertEqual(len(completed), 1); self.assertEqual(completed[0]["phase"], 3)
                self.assertEqual(completed[0]["deadlineSeconds"], 60)
                self.assertEqual(completed[0]["childReturnCode"], code); self.assertTrue(completed[0]["leaderReaped"])
        wrong = (["xcrun", "simctl", "list"], command + ["-c"], command[:-1],
                 ["xcrun", "swiftc", "-driver-print-jobs", "-j1", "-j8", "-typecheck", "-"],
                 ["xcodebuild", "test-without-building"])
        for arguments in wrong:
            with self.subTest(arguments=arguments):
                receipt.unlink(missing_ok=True)
                result = subprocess.run([sys.executable, str(SCRIPT), "--phase", "driver", "--"] + arguments,
                    env=dict(env, DRIVER_UNIT_EXIT="0"), capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 2); self.assertFalse(receipt.exists())

    def test_normal_zero_and_nonzero_child_exit_are_preserved(self):
        for code in (0, 7, 65):
            with self.subTest(code=code):
                report = self.module.run_owned([sys.executable, "-c", "raise SystemExit(%d)" % code], 3, 1, grace_seconds=.05)
                self.assertEqual(report["childReturnCode"], code); self.assertEqual(report["wrapperExit"], code)
                self.assertFalse(report["timedOut"]); self.assertTrue(report["leaderReaped"])

    def test_timeout_cleans_the_owned_child_and_its_term_resistant_descendant(self):
        payload, descendant, ready = self.payload(True)
        report = self.module.run_owned([sys.executable, "-c", payload], 2, 1, grace_seconds=.05)
        self.assertTrue(ready.exists(), "The real native surrogate must run before the deadline")
        self.assertTrue(report["timedOut"]); self.assertEqual(report["wrapperExit"], 124)
        self.assertIsNone(report["childReturnCode"]); self.assertTrue(report["termSent"]); self.assertTrue(report["killSent"])
        self.assertFalse(self.active(int(descendant.read_text())))

    def test_early_child_exit_cannot_leave_a_descendant_holding_stdout(self):
        payload, descendant, ready = self.payload(False)
        report = self.module.run_owned([sys.executable, "-c", payload], 3, 1, grace_seconds=.05)
        self.assertTrue(ready.exists()); self.assertEqual(report["childReturnCode"], 0)
        self.assertEqual(report["wrapperExit"], 0); self.assertFalse(report["timedOut"])
        self.assertFalse(self.active(int(descendant.read_text())))

    def test_group_signals_never_target_an_unrelated_owned_test_session(self):
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
        try:
            with mock.patch.object(self.module.os, "killpg", wraps=os.killpg) as signals:
                report = self.module.run_owned([sys.executable, "-c", "raise SystemExit(7)"], 3, 1, grace_seconds=.05)
            self.assertEqual(report["wrapperExit"], 7); self.assertIsNone(unrelated.poll())
            self.assertTrue(signals.call_args_list)
            self.assertTrue(all(call.args[0] == report["pid"] and call.args[0] != unrelated.pid for call in signals.call_args_list))
        finally:
            unrelated.terminate(); unrelated.wait(timeout=3)

    def test_launch_failure_is_explicit_and_never_a_native_success(self):
        report = self.module.run_owned([str(self.root / "missing-executable")], 3, 1, grace_seconds=.05)
        self.assertEqual(report["wrapperExit"], 127); self.assertNotEqual(report["launchErrno"], 0)
        self.assertIsNone(report["childReturnCode"]); self.assertTrue(report["leaderReaped"])

    def test_cancellation_before_go_never_authorizes_the_native_child(self):
        calls = [0]
        def cancelled():
            calls[0] += 1
            return signal.SIGTERM if calls[0] >= 2 else 0
        payload, descendant, ready = self.payload(True)
        report = self.module.run_owned([sys.executable, "-c", payload], 3, 1, cancelled, grace_seconds=.05)
        self.assertEqual(report["wrapperExit"], 143); self.assertEqual(report["xcodebuildPID"], 0)
        self.assertFalse(ready.exists()); self.assertFalse(descendant.exists())

    def test_parent_sigkill_is_detected_by_guardian_and_cleans_only_its_group(self):
        payload, descendant, ready = self.payload(True)
        fake = self.root / "xcodebuild"
        fake.write_text("#!" + sys.executable + "\nimport os,sys\nos.execv(sys.executable,[sys.executable,'-c',os.environ['OWNED_UNIT_PROGRAM']])\n")
        fake.chmod(0o700)
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
        wrapper = subprocess.Popen([sys.executable, str(SCRIPT), "--phase", "case-01", "--", "xcodebuild", "test-without-building"],
            env=dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""), OWNED_UNIT_PROGRAM=payload),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            limit = time.monotonic() + 3
            while not ready.exists() and wrapper.poll() is None and time.monotonic() < limit: time.sleep(.01)
            self.assertTrue(ready.exists()); group = int((self.root / "native.group").read_text())
            wrapper.kill(); wrapper.communicate(timeout=5)
            self.assertEqual(wrapper.returncode, -signal.SIGKILL)
            self.assertFalse(self.active(group)); self.assertFalse(self.active(int(descendant.read_text())))
            self.assertIsNone(unrelated.poll())
        finally:
            if wrapper.poll() is None:
                wrapper.send_signal(signal.SIGTERM); wrapper.communicate(timeout=5)
            unrelated.terminate(); unrelated.wait(timeout=3)

    def test_guardian_deadline_cleans_live_children_while_parent_is_stopped(self):
        payload, descendant, ready = self.payload(True)
        native_pid_file = self.root / "native.pid"
        payload = "import os;from pathlib import Path;Path(%r).write_text(str(os.getpid()))\n" % str(native_pid_file) + payload
        driver_path = self.root / "driver.py"
        driver_path.write_text("import importlib.util,sys\nspec=importlib.util.spec_from_file_location('owned',%r)\nm=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)\nr=m.run_owned([sys.executable,'-c',%r],1,1)\nraise SystemExit(r['wrapperExit'])\n" % (str(SCRIPT), payload))
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
        driver = subprocess.Popen([sys.executable, str(driver_path)], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True)
        def stopped():
            return subprocess.run(["ps", "-o", "stat=", "-p", str(driver.pid)], capture_output=True,
                text=True, timeout=1).stdout.strip().startswith("T")
        try:
            limit = time.monotonic() + 3
            while not ready.exists() and driver.poll() is None and time.monotonic() < limit: time.sleep(.005)
            self.assertTrue(ready.exists(), "Actual surrogate and descendant must start before stopping driver")
            native_pid, descendant_pid = int(native_pid_file.read_text()), int(descendant.read_text())
            group = int((self.root / "native.group").read_text())
            self.assertIsNone(driver.poll())
            driver.send_signal(signal.SIGSTOP)
            limit = time.monotonic() + .5
            while not stopped() and driver.poll() is None and time.monotonic() < limit: time.sleep(.005)
            self.assertTrue(stopped(), "Only the known driver must be alive but unable to monitor its deadline")
            self.assertTrue(self.active(native_pid)); self.assertTrue(self.active(descendant_pid))
            observation_started = time.monotonic()
            limit, observed_dead = observation_started + 6, None
            while time.monotonic() < limit:
                if not any(self.active(pid) for pid in (group, native_pid, descendant_pid)):
                    observed_dead = time.monotonic(); break
                time.sleep(.05)
            self.assertIsNotNone(observed_dead)
            self.assertLessEqual(observed_dead - observation_started, 6)
            self.assertFalse(self.active(group)); self.assertFalse(self.active(native_pid)); self.assertFalse(self.active(descendant_pid))
            self.assertIsNone(driver.poll()); self.assertTrue(stopped()); self.assertIsNone(unrelated.poll())
            driver.send_signal(signal.SIGCONT)
            stdout, stderr = driver.communicate(timeout=4)
            self.assertEqual(driver.returncode, 124, stdout + stderr)
            completed = [json.loads(line.split(" ", 1)[1]) for line in stdout.splitlines()
                         if line.startswith("OwnedXcodebuildCommand ") and '"event": "complete"' in line]
            self.assertEqual(len(completed), 1); self.assertTrue(completed[0]["timedOut"])
            self.assertTrue(completed[0]["leaderReaped"]); self.assertIsNone(completed[0]["childReturnCode"])
        finally:
            if driver.poll() is None:
                driver.send_signal(signal.SIGCONT)
                driver.terminate(); driver.communicate(timeout=5)
            unrelated.terminate(); unrelated.wait(timeout=3)

    def test_parent_sigterm_and_sigint_cleanup_only_the_owned_group(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum):
                self.root.joinpath("native.ready").unlink(missing_ok=True)
                self.root.joinpath("descendant.pid").unlink(missing_ok=True)
                payload, descendant, ready = self.payload(True)
                fake = self.root / "xcodebuild"
                fake.write_text("#!" + sys.executable + "\nimport os,sys\nos.execv(sys.executable,[sys.executable,'-c',os.environ['OWNED_UNIT_PROGRAM']])\n")
                fake.chmod(0o700)
                unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
                wrapper = subprocess.Popen([sys.executable, str(SCRIPT), "--phase", "case-01", "--", "xcodebuild", "test-without-building"],
                    env=dict(os.environ, PATH=str(self.root) + os.pathsep + os.environ.get("PATH", ""), OWNED_UNIT_PROGRAM=payload),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                try:
                    limit = time.monotonic() + 3
                    while not ready.exists() and wrapper.poll() is None and time.monotonic() < limit: time.sleep(.01)
                    self.assertTrue(ready.exists(), "Owned real child and descendant must have started")
                    wrapper.send_signal(signum)
                    stdout, stderr = wrapper.communicate(timeout=5)
                    self.assertEqual(wrapper.returncode, 128 + signum, stdout + stderr)
                    completed = [json.loads(line.split(" ", 1)[1]) for line in stdout.splitlines() if line.startswith("OwnedXcodebuildCommand ") and '"event": "complete"' in line]
                    self.assertEqual(len(completed), 1); self.assertEqual(completed[0]["cancellationSignal"], signum)
                    self.assertTrue(completed[0]["leaderReaped"]); self.assertTrue(completed[0]["killSent"])
                    self.assertFalse(self.active(int(descendant.read_text()))); self.assertIsNone(unrelated.poll())
                finally:
                    if wrapper.poll() is None:
                        wrapper.send_signal(signal.SIGTERM); wrapper.communicate(timeout=5)
                    unrelated.terminate(); unrelated.wait(timeout=3)


    def test_full_test_cli_uses_only_the_fixed_combined_action_and_budget(self):
        expected = {"build": (0, 1080), "case-01": (1, 300), "case-02": (2, 300),
                    "driver": (3, 60), "full-test": (4, 4500)}
        self.assertEqual(self.module.PHASES, expected)
        self.assertEqual(self.module.MAX_SESSION_SECONDS, 4500)
        command = ["xcodebuild", "-project", "owned.xcodeproj", "-jobs", "1", "test"]
        with mock.patch.object(sys, "argv", [str(SCRIPT), "--phase", "full-test", "--"] + command), \
             mock.patch.object(self.module.shutil, "which", return_value="/owned/xcodebuild"), \
             mock.patch.object(self.module.signal, "signal"), \
             mock.patch.object(self.module, "run_owned", return_value={"wrapperExit": 65}) as run:
            self.assertEqual(self.module.main(), 65)
        self.assertEqual(run.call_args.args[:3], (["/owned/xcodebuild"] + command[1:], 4500, 4))
        self.assertIsNone(run.call_args.kwargs["stdin"])
        wrong = (["xcodebuild", "build-for-testing"], ["xcodebuild", "test-without-building"],
                 ["xcodebuild", "test", "archive"], ["xcodebuild", "test", "build"],
                 ["xcodebuild", "clean", "test"], ["xcodebuild", "test", "test"],
                 ["xcrun", "test"], ["xcodebuild"])
        for arguments in wrong:
            with self.subTest(arguments=arguments), \
                 mock.patch.object(sys, "argv", [str(SCRIPT), "--phase", "full-test", "--"] + arguments), \
                 mock.patch.object(self.module.shutil, "which") as lookup, \
                 mock.patch.object(self.module, "run_owned") as run:
                with self.assertRaises(SystemExit) as failure: self.module.main()
                self.assertEqual(failure.exception.code, 2)
                lookup.assert_not_called(); run.assert_not_called()

    def test_guardian_admits_the_full_window_but_rejects_any_larger_window(self):
        # No child, signal or real wait: prove the guardian reaches its control
        # gate at the configured maximum rather than silently rejecting >720s.
        for seconds, admitted in ((4500, True), (4501, False), (0, False), (-1, False)):
            with self.subTest(seconds=seconds), \
                 mock.patch.object(self.module.os, "getpid", return_value=101), \
                 mock.patch.object(self.module.os, "getpgid", return_value=101), \
                 mock.patch.object(self.module.os, "getsid", return_value=101), \
                 mock.patch.object(self.module.signal, "signal"), \
                 mock.patch.object(self.module.select, "select", return_value=([], [], [])) as wait, \
                 mock.patch.object(self.module.os, "read") as read, \
                 mock.patch.object(self.module.os, "killpg") as kill, \
                 mock.patch.object(self.module.subprocess, "Popen") as child:
                self.assertEqual(self.module.session(10, 11, seconds, ["never-launch"]), 125)
                if admitted: wait.assert_called_once_with([10], [], [], 4503)
                else: wait.assert_not_called()
                read.assert_not_called(); kill.assert_not_called(); child.assert_not_called()

    def test_full_phase_timeout_cleans_real_children_without_signaling_other_sessions(self):
        # Internal two-second control exercises phase4 cleanup; the public CLI
        # remains fixed at 4500s and no SDK executable is run by this unit.
        payload, descendant, ready = self.payload(True)
        unrelated = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(20)"], start_new_session=True)
        try:
            with mock.patch.object(self.module.os, "killpg", wraps=os.killpg) as signals:
                report = self.module.run_owned([sys.executable, "-c", payload], 2, 4, grace_seconds=.05)
            self.assertTrue(ready.exists(), "The real surrogate must start before the timeout")
            self.assertEqual(report["phase"], 4); self.assertEqual(report["deadlineSeconds"], 2)
            self.assertEqual(report["wrapperExit"], 124); self.assertTrue(report["timedOut"])
            self.assertIsNone(report["childReturnCode"]); self.assertTrue(report["groupVerified"])
            self.assertTrue(report["leaderReaped"]); self.assertTrue(report["termSent"]); self.assertTrue(report["killSent"])
            self.assertFalse(self.active(int(descendant.read_text()))); self.assertFalse(self.active(report["pid"]))
            self.assertIsNone(unrelated.poll()); self.assertTrue(signals.call_args_list)
            self.assertTrue(all(call.args[0] == report["pid"] and call.args[0] != unrelated.pid
                                for call in signals.call_args_list))
        finally:
            unrelated.terminate(); unrelated.wait(timeout=3)


if __name__ == "__main__": unittest.main()
