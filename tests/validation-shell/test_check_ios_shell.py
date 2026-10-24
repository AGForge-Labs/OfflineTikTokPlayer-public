#!/usr/bin/env python3
"""Exercise the native-check launcher with isolated fake tools, including Bash 3."""
import os
import json
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NativeLauncherTests(unittest.TestCase):
    def exercise(self, arguments=(), status=0, expansion_error=False, preflight_failure=False,
                 driver_status=0, driver_remark=True, successful_output=None, tee_status=0):
        with tempfile.TemporaryDirectory(prefix="offline-ios-shell-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            (root / "artifacts/native").mkdir(parents=True)
            (root / "tests").mkdir()
            profile = json.loads((ROOT / "tests/playback-acceptance.json").read_text())
            (root / "tests/playback-acceptance.json").write_text(json.dumps(profile))
            profile_flags = ["-only-testing:" + identity.replace(".", "/", 1) for identity in sorted(profile["cases"])]
            (root / "profile-flags.txt").write_text("\n".join(profile_flags) + "\n")
            evidence_log = root / "artifacts/native/xcodebuild-test.log"
            evidence_log.write_text("** TEST SUCCEEDED ** stale previous evidence\n")
            if successful_output is not None:
                (root / "successful-output.log").write_text(successful_output)
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
                anchor = "python3 scripts/run-owned-xcodebuild.py --phase full-test -- xcodebuild -project"
                self.assertEqual(launcher.count(anchor), 1)
                launcher = launcher.replace(anchor, injection + anchor, 1)
            (root / "scripts/check-ios.sh").write_text(launcher)
            for script in ("test-core.sh", "test-apple-buffer.sh"):
                code = status if preflight_failure and script == "test-core.sh" else 0
                (root / "scripts" / script).write_text(f"#!/bin/bash\nexit {code}\n")
            python = root / "bin/python3"
            python.write_text("""#!/bin/bash
if [ "$1" = scripts/run-owned-xcodebuild.py ]; then
  phase="$3"
  printf '%s\\n' "$@" > "$LAUNCHER_TEST_ROOT/owned-$phase.args"
  shift 4
  case "$phase" in
    driver) phase_code=3; deadline=60 ;;
    full-test) phase_code=4; deadline=4500 ;;
    *) exit 92 ;;
  esac
  "$@"
  owned_status=$?
  timed_out=false
  if [ "$owned_status" -eq 124 ]; then timed_out=true; fi
  printf 'OwnedXcodebuildCommand {"schema":1,"event":"complete","phase":%s,"deadlineSeconds":%s,"timedOut":%s,"wrapperExit":%s}\\n' "$phase_code" "$deadline" "$timed_out" "$owned_status"
  exit "$owned_status"
fi
case "$*" in
  *verify-native-test-log.py*--print-xcode-tests*) cat "$LAUNCHER_TEST_ROOT/profile-flags.txt" ;;
  *verify-native-test-log.py*) printf '%s\\n' "$@" > "$LAUNCHER_TEST_ROOT/verifier.args" ;;
  *--resolve-destination*) printf '%s\\n' '00000000-0000-0000-0000-000000000001' ;;
  *--udid*) printf '%s\\n' "$@" > "$LAUNCHER_TEST_ROOT/capture.args"; echo $$ > "$LAUNCHER_TEST_ROOT/helper.pid"; exec sleep 60 ;;
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
            tee = root / "bin/tee"
            tee.write_text('''#!/bin/bash
cat > "$1"
cat "$1"
exit "$LAUNCHER_TEST_TEE_STATUS"
''')
            tee.chmod(0o755)
            environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                LAUNCHER_TEST_ROOT=str(root), LAUNCHER_TEST_STATUS=str(status),
                LAUNCHER_TEST_DRIVER_STATUS=str(driver_status), LAUNCHER_TEST_TEE_STATUS=str(tee_status),
                LAUNCHER_TEST_DRIVER_REMARK="1" if driver_remark else "0",
                SWIFTC_MAXIMUM_DETERMINISM="")
            environment.pop("LAUNCHER_TEST_UNBOUND_VALUE", None)
            result = subprocess.run(["/bin/bash", str(root / "scripts/check-ios.sh"), *arguments],
                env=environment, text=True, capture_output=True, timeout=10)
            if arguments in (("--playback-acceptance",), ("--optimized-playback-acceptance",)):
                self.assertEqual(result.returncode, status or tee_status, result.stdout + result.stderr)
            actual = (root / "xcode.args").read_text().splitlines() if (root / "xcode.args").exists() else []
            pid_file = root / "helper.pid"
            driver_command = ["swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"]
            self.assertEqual((root / "owned-driver.args").read_text().splitlines(),
                ["scripts/run-owned-xcodebuild.py", "--phase", "driver", "--", "xcrun"] + driver_command)
            if driver_status != 0 or not driver_remark:
                self.assertEqual(result.returncode, driver_status or 1, result.stdout + result.stderr)
                self.assertEqual((root / "driver.args").read_text().splitlines(),
                    ["swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"])
                plan = (root / "artifacts/native/swift-driver-plan.log").read_text()
                self.assertEqual("SWIFTC_MAXIMUM_DETERMINISM overriding -j" in plan, driver_remark)
                self.assertIn(plan, result.stdout, "Driver failure evidence must be printed before exit")
                self.assertIn('"phase":3,"deadlineSeconds":60', plan)
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
            self.assertEqual(result.returncode, status or tee_status, result.stdout + result.stderr)
            if successful_output is not None:
                self.assertIn(successful_output, result.stdout)
            if expansion_error:
                self.assertIn("unbound variable", result.stderr)
                self.assertEqual(actual, [], "An earlier error must prevent the native launch")
                return actual
            self.assertEqual((root / "capture.args").read_text().splitlines(),
                ["scripts/capture-simulator-test-frames.py", "--udid",
                 "00000000-0000-0000-0000-000000000001", "--lifetime", "4800"])
            self.assertEqual((root / "owned-full-test.args").read_text().splitlines(),
                ["scripts/run-owned-xcodebuild.py", "--phase", "full-test", "--", "xcodebuild"] + actual)
            self.assertIn('"phase":4,"deadlineSeconds":4500', evidence_log.read_text())
            self.assertEqual((root / "verifier.args").exists(), status == 0 and tee_status == 0,
                             "The strict verifier runs only after both command and tee succeed")
            if arguments in (("--playback-acceptance",), ("--optimized-playback-acceptance",)) and status == 0 and tee_status == 0:
                self.assertEqual((root / "verifier.args").read_text().splitlines(),
                    ["scripts/verify-native-test-log.py", "--log", "artifacts/native/xcodebuild-test.log",
                     "--profile", "tests/playback-acceptance.json"])
            self.assertEqual(actual[-1], "test")
            for limit in ("-default-test-execution-time-allowance", "-maximum-test-execution-time-allowance"):
                self.assertEqual(actual[actual.index(limit) + 1], "120")
            if arguments == ("--optimized-playback-acceptance",):
                self.assertEqual(actual.count("SWIFT_OPTIMIZATION_LEVEL=-O"), 1)
            else:
                self.assertFalse(any(arg.startswith("SWIFT_OPTIMIZATION_LEVEL=") for arg in actual),
                    "Existing full/profile modes must keep their original configuration")
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

    def test_playback_profile_executes_and_verifies_the_same_explicit_methods(self):
        arguments = self.exercise(("--playback-acceptance",))
        profile = json.loads((ROOT / "tests/playback-acceptance.json").read_text())
        expected = {"-only-testing:" + identity.replace(".", "/", 1) for identity in profile["cases"]}
        self.assertEqual({arg for arg in arguments if arg.startswith("-only-testing:")}, expected)
        self.assertTrue(all(arg.count("/") == 2 for arg in expected))

    def test_optimized_profile_keeps_all_cases_and_requests_codegen(self):
        arguments = self.exercise(("--optimized-playback-acceptance",))
        profile = json.loads((ROOT / "tests/playback-acceptance.json").read_text())
        expected = {"-only-testing:" + identity.replace(".", "/", 1) for identity in profile["cases"]}
        self.assertEqual({arg for arg in arguments if arg.startswith("-only-testing:")}, expected)
        self.assertEqual(arguments.count("SWIFT_OPTIMIZATION_LEVEL=-O"), 1)

    def test_optimized_profile_preserves_native_and_output_failures(self):
        self.exercise(("--optimized-playback-acceptance",), status=65)
        self.exercise(("--optimized-playback-acceptance",), tee_status=17)

    def test_optimized_preflight_failure_prevents_native_launch(self):
        self.exercise(("--optimized-playback-acceptance",), status=23, preflight_failure=True)

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


    def test_owned_timeout_cannot_be_masked_by_full_passing_case_output(self):
        from test_native_test_evidence import case_line, current_manifest
        output = "\n".join([case_line(identity) for identity in current_manifest()] + ["** TEST SUCCEEDED **"]) + "\n"
        self.exercise(status=124, successful_output=output)

    def test_native_status_wins_over_tee_failure(self):
        self.exercise(status=65, tee_status=17)

    def test_tee_failure_is_not_an_accepted_native_run(self):
        self.exercise(tee_status=17)

    def test_driver_timeout_receipt_is_visible_before_failure(self):
        self.exercise(driver_status=124)


if __name__ == "__main__":
    print(subprocess.check_output(["/bin/bash", "--version"], text=True).splitlines()[0], flush=True)
    unittest.main(verbosity=2)
