#!/usr/bin/env python3
"""Exercise the native-check launcher with isolated fake tools, including Bash 3."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NativeLauncherTests(unittest.TestCase):
    def exercise(self, arguments=(), status=0, expansion_error=False, preflight_failure=False,
                 driver_status=0, driver_remark=True, successful_output=None,
                 worker_output=None, worker_cleanup_output=None, worker_verifier_status=0,
                 worker_verifier_output="", expected_status=None):
        with tempfile.TemporaryDirectory(prefix="offline-ios-shell-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            (root / "artifacts/native").mkdir(parents=True)
            evidence_log = root / "artifacts/native/xcodebuild-test.log"
            evidence_log.write_text("** TEST SUCCEEDED ** stale previous evidence\n")
            worker_log = root / "artifacts/native/worker-trace.log"
            worker_log.write_text("NativeWorkerTraceResult stale previous worker evidence\n")
            if successful_output is not None:
                (root / "successful-output.log").write_text(successful_output)
            if worker_output is not None:
                (root / "worker-output.log").write_text(worker_output)
            if worker_cleanup_output is not None:
                (root / "worker-cleanup-output.log").write_text(worker_cleanup_output)
            launcher = (ROOT / "scripts/check-ios.sh").read_text()
            if expansion_error:
                # Inject the original failure category into a disposable copy after
                # cleanup is armed. It must fail before the native tool can launch.
                injection = '''for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$LAUNCHER_TEST_ROOT/helper.pid" ] && break
  sleep 0.01
done
: "${LAUNCHER_TEST_UNBOUND_VALUE}"
'''
                launcher = launcher.replace("xcodebuild -project", injection + "xcodebuild -project", 1)
            (root / "scripts/check-ios.sh").write_text(launcher)
            for script in ("test-core.sh", "test-apple-buffer.sh"):
                code = status if preflight_failure and script == "test-core.sh" else 0
                (root / "scripts" / script).write_text(f"#!/bin/bash\nexit {code}\n")
            python = root / "bin/python3"
            python.write_text("""#!/bin/bash
printf '%s\\n' "$*" >> "$LAUNCHER_TEST_ROOT/python.calls"
case "$*" in
  *--resolve-destination*) printf '%s\\n' '00000000-0000-0000-0000-000000000001' ;;
  *--udid*)
    if [ -f "$LAUNCHER_TEST_ROOT/worker-output.log" ]; then
      cat "$LAUNCHER_TEST_ROOT/worker-output.log"
    fi
    if [ -f "$LAUNCHER_TEST_ROOT/worker-cleanup-output.log" ]; then
      trap 'cat "$LAUNCHER_TEST_ROOT/worker-cleanup-output.log"; : > "$LAUNCHER_TEST_ROOT/helper.cleaned"; exit 0' TERM
      echo $$ > "$LAUNCHER_TEST_ROOT/helper.pid"
      while :; do sleep 0.05; done
    fi
    echo $$ > "$LAUNCHER_TEST_ROOT/helper.pid"
    exec sleep 60 ;;
  *verify-native-worker-trace.py*)
    printf '%s\\n' "$LAUNCHER_TEST_WORKER_VERIFIER_OUTPUT"
    exit "$LAUNCHER_TEST_WORKER_VERIFIER_STATUS" ;;
  *) exit 0 ;;
esac
""")
            xcode = root / "bin/xcodebuild"
            xcode.write_text("""#!/bin/bash
printf '%s\\n' "$@" > "$LAUNCHER_TEST_ROOT/xcode.args"
printf '%s\\n' "${SWIFTC_MAXIMUM_DETERMINISM-unset}" > "$LAUNCHER_TEST_ROOT/swift.limit"
for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$LAUNCHER_TEST_ROOT/helper.pid" ] && break
  sleep 0.01
done
if [ -f "$LAUNCHER_TEST_ROOT/successful-output.log" ]; then
  cat "$LAUNCHER_TEST_ROOT/successful-output.log"
fi
exit "$LAUNCHER_TEST_STATUS"
""")
            python.chmod(0o755)
            xcode.chmod(0o755)
            xcrun = root / "bin/xcrun"
            xcrun.write_text('''#!/bin/bash
printf '%s\\n' "$@" > "$LAUNCHER_TEST_ROOT/driver.args"
if [ "${SWIFTC_MAXIMUM_DETERMINISM-unset}" != 1 ]; then exit 42; fi
if [ "$LAUNCHER_TEST_DRIVER_REMARK" = 1 ]; then
  printf '%s\\n' 'remark: SWIFTC_MAXIMUM_DETERMINISM overriding -j'
fi
exit "$LAUNCHER_TEST_DRIVER_STATUS"
''')
            xcrun.chmod(0o755)
            environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                LAUNCHER_TEST_ROOT=str(root), LAUNCHER_TEST_STATUS=str(status),
                LAUNCHER_TEST_DRIVER_STATUS=str(driver_status),
                LAUNCHER_TEST_DRIVER_REMARK="1" if driver_remark else "0",
                LAUNCHER_TEST_WORKER_VERIFIER_STATUS=str(worker_verifier_status),
                LAUNCHER_TEST_WORKER_VERIFIER_OUTPUT=worker_verifier_output,
                SWIFTC_MAXIMUM_DETERMINISM="")
            environment.pop("LAUNCHER_TEST_UNBOUND_VALUE", None)
            result = subprocess.run(["/bin/bash", str(root / "scripts/check-ios.sh"), *arguments],
                env=environment, text=True, capture_output=True, timeout=10)
            actual = (root / "xcode.args").read_text().splitlines() if (root / "xcode.args").exists() else []
            pid_file = root / "helper.pid"
            calls = root / "python.calls"
            self.launcher_observation = {
                "stdout": result.stdout, "stderr": result.stderr,
                "worker_log": worker_log.read_text(), "native_log": evidence_log.read_text(),
                "python_calls": calls.read_text().splitlines() if calls.exists() else [],
                "helper_cleaned": (root / "helper.cleaned").exists(),
            }
            if driver_status != 0 or not driver_remark:
                self.assertEqual(result.returncode, driver_status or 1, result.stdout + result.stderr)
                self.assertEqual((root / "driver.args").read_text().splitlines(),
                    ["swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"])
                plan = (root / "artifacts/native/swift-driver-plan.log").read_text()
                self.assertEqual("SWIFTC_MAXIMUM_DETERMINISM overriding -j" in plan, driver_remark)
                if driver_status == 0:
                    self.assertIn("did not confirm its one-job override", result.stderr)
                self.assertFalse(pid_file.exists(), "A rejected driver preflight must prevent helper launch")
                self.assertEqual(actual, [], "A rejected driver preflight must prevent native launch")
                self.assertEqual(evidence_log.read_text(), "", "Old successful evidence must be cleared before the driver preflight")
                return actual
            if preflight_failure:
                self.assertEqual(result.returncode, status, result.stdout + result.stderr)
                self.assertFalse(pid_file.exists(), "A failed preflight must prevent helper launch")
                self.assertEqual(actual, [], "A failed preflight must prevent native launch")
                self.assertEqual(evidence_log.read_text(), "", "Old successful evidence must be cleared before preflights")
                return actual
            if pid_file.exists():
                pid = int(pid_file.read_text())
                for _ in range(50):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.01)
                else:
                    os.kill(pid, signal.SIGTERM)
                    self.fail("The launcher left its screenshot helper running")
            self.assertTrue(pid_file.exists(), "The isolated screenshot helper must actually start")
            self.assertEqual(result.returncode, status if expected_status is None else expected_status,
                             result.stdout + result.stderr)
            if successful_output is not None:
                self.assertIn(successful_output, result.stdout)
            if expansion_error:
                self.assertIn("unbound variable", result.stderr)
                self.assertEqual(actual, [], "An earlier error must prevent the native launch")
                return actual
            self.assertIn("CODE_SIGNING_ALLOWED=NO", actual)
            self.assertIn("SWIFTC_MAXIMUM_DETERMINISM=1", actual)
            self.assertIn("SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO", actual)
            self.assertEqual((root / "swift.limit").read_text().strip(), "1")
            self.assertEqual((root / "driver.args").read_text().splitlines(),
                ["swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"])
            self.assertEqual(actual[actual.index("-jobs") + 1], "1")
            self.assertEqual(actual[actual.index("-parallel-testing-enabled") + 1], "NO")
            self.assertEqual(actual[actual.index("-destination") + 1],
                "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001")
            return actual

    def test_full_suite_reaches_xcodebuild_without_filters(self):
        self.assertFalse(any(arg.startswith("-only-testing:") for arg in self.exercise()))

    def test_focused_suite_keeps_all_four_native_classes(self):
        arguments = self.exercise(("--selection-only",))
        self.assertEqual({arg for arg in arguments if arg.startswith("-only-testing:")}, {
            "-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionFailureTests",
            "-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests",
            "-only-testing:OfflineTikTokPlayerTests/ContinuousAudioPlayerTests",
            "-only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests",
        })

    def test_native_failure_survives_exit_cleanup(self):
        self.exercise(status=23)

    def test_full_passing_case_output_cannot_mask_native_exit_failure(self):
        from test_native_test_evidence import case_line, current_manifest
        output = "\n".join([case_line(identity) for identity in current_manifest()] + ["** TEST SUCCEEDED **"]) + "\n"
        self.exercise(status=23, successful_output=output)

    def test_first_expansion_error_survives_cleanup(self):
        self.exercise(status=1, expansion_error=True)

    def test_failed_preflight_cannot_reuse_previous_success_log(self):
        self.exercise(status=23, preflight_failure=True)

    def test_failed_driver_plan_rejects_even_with_override_remark(self):
        self.exercise(driver_status=37)

    def test_driver_plan_without_override_remark_fails_closed(self):
        self.exercise(driver_remark=False)

    def test_stale_worker_evidence_is_cleared_before_failed_preflight(self):
        for failure in ({"status": 23, "preflight_failure": True}, {"driver_status": 37}, {"driver_remark": False}):
            with self.subTest(failure=failure):
                self.exercise(**failure)
                observed = self.launcher_observation
                self.assertEqual(observed["worker_log"], "")
                self.assertNotIn("stale previous worker evidence", observed["stdout"])
                self.assertFalse(any("verify-native-worker-trace.py" in call for call in observed["python_calls"]))

    def test_full_mode_verifies_dedicated_worker_log_and_prints_after_helper_cleanup(self):
        self.exercise(successful_output="NATIVE_CURRENT_OUTPUT\n", worker_output="WORKER_CURRENT_OUTPUT\n",
                      worker_cleanup_output="WORKER_FINAL_AFTER_SIGTERM\n",
                      worker_verifier_output="WorkerCalibrationGateVerified")
        observed = self.launcher_observation
        native_verify = "scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log"
        worker_verify = "scripts/verify-native-worker-trace.py --log artifacts/native/worker-trace.log"
        self.assertIn(native_verify, observed["python_calls"])
        self.assertIn(worker_verify, observed["python_calls"])
        self.assertLess(observed["python_calls"].index(native_verify), observed["python_calls"].index(worker_verify))
        self.assertTrue(observed["helper_cleaned"], "The helper must actually execute its termination cleanup")
        self.assertIn("WORKER_CURRENT_OUTPUT", observed["worker_log"])
        self.assertIn("WORKER_FINAL_AFTER_SIGTERM", observed["worker_log"])
        self.assertNotIn("stale previous worker evidence", observed["worker_log"])
        self.assertNotIn("WORKER_CURRENT_OUTPUT", observed["native_log"])
        self.assertIn("WorkerCalibrationGateVerified", observed["stdout"])
        self.assertIn("WORKER_FINAL_AFTER_SIGTERM", observed["stdout"],
                      "EXIT must print the final worker log after waiting for helper cleanup")
        self.assertLess(observed["stdout"].index("NATIVE_CURRENT_OUTPUT"),
                        observed["stdout"].index("WORKER_FINAL_AFTER_SIGTERM"))

    def test_native_failure_still_prints_worker_evidence_after_cleanup_without_verifying(self):
        self.exercise(status=23, worker_output="WORKER_BEFORE_NATIVE_FAILURE\n",
                      worker_cleanup_output="WORKER_CLEANUP_ON_NATIVE_FAILURE\n")
        observed = self.launcher_observation
        self.assertTrue(observed["helper_cleaned"])
        self.assertIn("WORKER_BEFORE_NATIVE_FAILURE", observed["stdout"])
        self.assertIn("WORKER_CLEANUP_ON_NATIVE_FAILURE", observed["stdout"])
        self.assertNotIn("stale previous worker evidence", observed["worker_log"])
        self.assertFalse(any("verify-native-test-log.py" in call or "verify-native-worker-trace.py" in call
                             for call in observed["python_calls"]))

    def test_worker_verifier_failure_survives_exit_cleanup_and_prints_evidence(self):
        self.exercise(worker_output="WORKER_VERIFIER_FAILURE_EVIDENCE\n",
                      worker_cleanup_output="WORKER_CLEANUP_AFTER_VERIFIER_FAILURE\n",
                      worker_verifier_status=37, worker_verifier_output="WorkerCalibrationGateRejected",
                      expected_status=37)
        observed = self.launcher_observation
        self.assertIn("scripts/verify-native-worker-trace.py --log artifacts/native/worker-trace.log",
                      observed["python_calls"])
        self.assertTrue(observed["helper_cleaned"])
        self.assertIn("WorkerCalibrationGateRejected", observed["stdout"])
        self.assertIn("WORKER_VERIFIER_FAILURE_EVIDENCE", observed["stdout"])
        self.assertIn("WORKER_CLEANUP_AFTER_VERIFIER_FAILURE", observed["stdout"])

    def test_selection_only_skips_worker_calibration_gate_and_never_claims_it_passed(self):
        self.exercise(("--selection-only",), worker_output="WORKER_SELECTION_OBSERVATION\n",
                      worker_cleanup_output="WORKER_SELECTION_CLEANUP\n",
                      worker_verifier_status=37, worker_verifier_output="WorkerCalibrationGateVerified")
        observed = self.launcher_observation
        self.assertIn("scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log --selection-only",
                      observed["python_calls"])
        self.assertFalse(any("verify-native-worker-trace.py" in call for call in observed["python_calls"]))
        self.assertNotIn("WorkerCalibrationGateVerified", observed["stdout"])
        self.assertTrue(observed["helper_cleaned"])
        self.assertIn("WORKER_SELECTION_CLEANUP", observed["stdout"])


if __name__ == "__main__":
    print(subprocess.check_output(["/bin/bash", "--version"], text=True).splitlines()[0], flush=True)
    unittest.main(verbosity=2)
