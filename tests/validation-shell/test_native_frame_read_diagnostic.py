"""Disposable Bash/fake tools only; never execute an SDK, Simulator or real app."""
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("NATIVE_FRAME_READ_DIAGNOSTIC_SOURCE",
                             ROOT / "scripts/check-native-frame-read-diagnostic.sh"))
WORKFLOW = Path(os.environ.get("NATIVE_FRAME_READ_DIAGNOSTIC_WORKFLOW",
                               ROOT / ".github/workflows/native-frame-read-diagnostic.yml"))
CASES = (
    'OfflineTikTokPlayerTests/ContinuousAudioPlayerTests/testSameTokenRenderAnchorWaitsForFreshPublicationAfterRealPauseResume',
    'OfflineTikTokPlayerTests/ContinuousAudioPlayerTests/testRenderAnchorRejectsOldAndInactivePublicationsAfterResume',
    'OfflineTikTokPlayerTests/ContinuousAudioPlayerTests/testRepeatedPlayingPreservesAnchorButEngineRestartRequiresFreshInterval',
    'OfflineTikTokPlayerTests/ContinuousAudioPlayerTests/testExplicitPauseDuringActualLatencyReadRejectsTheOldClock',
    'OfflineTikTokPlayerTests/ContinuousAudioPlayerTests/testReentrantPlaybackControlPreservesNewerPauseResumeAndGraphOwner',
    'OfflineTikTokPlayerTests/ContinuousAudioPlayerTests/testPlaybackClockAuthorityExhaustionCannotReuseAnOldInterval',
    'OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testTapExecutionTraceRejectsMalformedClockOrderAndOverflow',
    'OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testDefaultProductionSelectionLatencyAndStreamingContinuityWithoutCapture',
    'OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testSourceCallbackExecutionTimingOffThenOn',
)
SIMULATOR = "00000000-0000-0000-0000-000000000001"


def bash_path():
    explicit = os.environ.get("NATIVE_FRAME_READ_BASH")
    if explicit:
        return explicit
    if os.name == "posix":
        return "/bin/bash"
    for candidate in (Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe",
                      Path(os.environ.get("LOCALAPPDATA", "")) / "Programs/Git/bin/bash.exe"):
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError("Set NATIVE_FRAME_READ_BASH to a working Git Bash executable on Windows")


def write(path, content):
    path.write_text(content, encoding="utf-8", newline="\n")
    path.chmod(0o755)


class NativeFrameReadDiagnosticTests(unittest.TestCase):
    def exercise(self, scenario="success", mode=None):
        (ROOT / "artifacts").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="frame-read-unit-", dir=ROOT / "artifacts") as directory:
            root = Path(directory)
            scripts, tools, native = root / "scripts", root / "bin", root / "artifacts/native"
            for folder in (scripts, tools, native):
                folder.mkdir(parents=True)
            source = SOURCE.read_text(encoding="utf-8")
            if scenario == "pending-pins":
                # Exercise the real rejection guard rather than substituting pins.
                source = re.sub(r"^expected_code_source=.*$", "expected_code_source=PENDING",
                                source, flags=re.MULTILINE)
                source = re.sub(r"^expected_ios_tree=.*$", "expected_ios_tree=PENDING",
                                source, flags=re.MULTILINE)
                tree = "b" * 40
            else:
                # Only this disposable fake-git fixture substitutes review pins.
                source = re.sub(r"^expected_code_source=PENDING$", "expected_code_source=" + "a" * 40,
                                source, flags=re.MULTILINE)
                source = re.sub(r"^expected_ios_tree=PENDING$", "expected_ios_tree=" + "b" * 40,
                                source, flags=re.MULTILINE)
                tree = re.search(r"^expected_ios_tree=([0-9a-f]{40})$", source, re.MULTILINE).group(1)
            launcher = scripts / "check-native-frame-read-diagnostic.sh"
            write(launcher, source)
            shutil.copyfile(ROOT / "scripts/verify-native-test-log.py", scripts / "verify-native-test-log.py")
            unit = root / "ios/OfflineTikTokPlayerTests"
            ui = root / "ios/OfflineTikTokPlayerUITests"
            unit.mkdir(parents=True); ui.mkdir(parents=True)
            owners = {}
            for selector in CASES:
                target, owner, method = selector.split("/")
                self.assertEqual(target, "OfflineTikTokPlayerTests")
                owners.setdefault(owner, []).append(method)
            write(unit / "SelectedTests.swift", "\n".join(
                f"final class {owner}: XCTestCase {{\n" +
                "\n".join(f"    func {method}() {{}}" for method in methods) + "\n}"
                for owner, methods in owners.items()) + "\n")
            write(ui / "ScreenTests.swift", "final class ScreenTests: XCTestCase { func testScreen() {} }\n")
            log = native / "native-frame-read.log"
            receipt = native / "native-frame-read-status.tsv"
            write(log, "** TEST SUCCEEDED ** stale evidence\n")
            write(receipt, "0\t0\n")
            if scenario == "stale-bundle":
                (native / "Tests-20261022-010000.xcresult").mkdir()
            lines = []
            for number, selector in enumerate(CASES):
                if scenario == "missing" and number == 0:
                    continue
                target, owner, method = selector.split("/")
                identity = f"-[{target}.{owner} {method}]"
                lines.append(f"Test Case '{identity}' started.")
                status = "skipped" if scenario == "skipped" and number == 0 else "passed"
                lines.append(f"Test Case '{identity}' {status} (0.001 seconds).")
                if scenario == "duplicate" and number == 0:
                    lines.append(f"Test Case '{identity}' passed (0.001 seconds).")
            lines.append("** TEST SUCCEEDED **")
            write(root / "native-output.log", "\n".join(lines) + "\n")
            write(scripts / "test-core.sh", '#!/usr/bin/env bash\nprintf "core\\n" >> "$FRAME_READ_ROOT/order.log"\nexit "${FRAME_READ_CORE_EXIT}"\n')
            write(scripts / "test-apple-buffer.sh", '#!/usr/bin/env bash\nprintf "apple\\n" >> "$FRAME_READ_ROOT/order.log"\nexit 0\n')
            write(tools / "uname", '''#!/usr/bin/env bash
printf '%s\\n' "$@" > "$FRAME_READ_ROOT/host.args"
if [ "$*" != -m ]; then exit 98; fi
printf '%s\\n' "$FRAME_READ_HOST"
exit "$FRAME_READ_HOST_EXIT"
''')
            write(tools / "git", '''#!/usr/bin/env bash
if [ "$1" = rev-parse ]; then printf '%s\\n' "$FRAME_READ_TREE"; fi
exit 0
''')
            write(tools / "python3", '''#!/usr/bin/env bash
case "$1" in
  scripts/run-owned-xcodebuild.py)
    if [ "$3" = build ]; then
      printf '%s\\n' "$@" > "$FRAME_READ_ROOT/build.args"
      printf 'build\\n' >> "$FRAME_READ_ROOT/order.log"
      printf '%s\\n' 'Owned build receipt retained' '** TEST BUILD SUCCEEDED **'
      exit "$FRAME_READ_BUILD_EXIT"
    fi
    printf '%s\\n' "$@" > "$FRAME_READ_ROOT/driver.args"
    printf 'driver\\n' >> "$FRAME_READ_ROOT/order.log"
    printf '%s\\n' 'remark: SWIFTC_MAXIMUM_DETERMINISM overriding -j'
    exit "$FRAME_READ_DRIVER_EXIT" ;;
  scripts/generate-ios-project.py) exit 0 ;;
  scripts/capture-simulator-test-frames.py)
    printf '%s\\n' "$@" >> "$FRAME_READ_ROOT/capture.args"
    if [ "$2" = --resolve-destination ]; then printf '%s\\n' "$FRAME_READ_SIMULATOR"; exit 0; fi
    printf '%s\\n' "$$" > "$FRAME_READ_ROOT/helper.pid"
    trap 'printf stopped > "$FRAME_READ_ROOT/helper.stopped"; exit 0' TERM
    trap 'printf stopped > "$FRAME_READ_ROOT/helper.stopped"' EXIT
    while :; do sleep 0.05; done ;;
  -) exec "$FRAME_READ_PYTHON" "$@" ;;
  *) printf '%s\\n' 'Unexpected fake Python command' >&2; exit 99 ;;
esac
''')
            write(tools / "xcodebuild", '''#!/usr/bin/env bash
printf '%s\\n' "$@" > "$FRAME_READ_ROOT/native.args"
printf '%s\\n' "${SWIFTC_MAXIMUM_DETERMINISM-unset}" > "$FRAME_READ_ROOT/swift.limit"
for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$FRAME_READ_ROOT/helper.pid" ] && break
  sleep 0.01
done
previous=''
for argument in "$@"; do
  if [ "$previous" = -resultBundlePath ]; then mkdir -p "$argument"; fi
  previous="$argument"
done
cat "$FRAME_READ_ROOT/native-output.log"
exit "$FRAME_READ_NATIVE_EXIT"
''')
            write(tools / "tee", '''#!/usr/bin/env bash
cat > "$1"
cat "$1"
exit "$FRAME_READ_TEE_EXIT"
''')
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                FRAME_READ_ROOT=root.as_posix(), FRAME_READ_PYTHON=Path(sys.executable).as_posix(),
                FRAME_READ_TREE=tree, FRAME_READ_SIMULATOR=SIMULATOR,
                FRAME_READ_HOST="x86_64" if scenario == "wrong-host" else "arm64",
                FRAME_READ_HOST_EXIT="7" if scenario == "host-query-failure" else "0",
                FRAME_READ_NATIVE_EXIT="65" if scenario == "native-failure" else "0",
                FRAME_READ_TEE_EXIT="17" if scenario in ("tee-failure", "build-tee-failure") else "0",
                FRAME_READ_CORE_EXIT="19" if scenario == "core-failure" else "0",
                FRAME_READ_DRIVER_EXIT="31" if scenario == "driver-failure" else "0",
                FRAME_READ_BUILD_EXIT="29" if scenario == "build-failure" else "0",
                GITHUB_OUTPUT=(root / "step.outputs").as_posix(),
                SIMULATOR_DESTINATION=f"platform=iOS Simulator,id={SIMULATOR}")
            # Git Bash puts /usr/bin before the inherited Windows PATH. Put the
            # disposable tools first after shell startup, so real tee (or an SDK
            # command on a development Mac) cannot replace an injected failure.
            command = [bash_path(), "-c",
                       'export PATH="$(cd "$FRAME_READ_ROOT/bin" && pwd):$PATH"; source "$0" "$@"',
                       launcher.as_posix()]
            prepared_receipt = native / "frame-read-prepared-source.tsv"
            if mode == "--prepare" and scenario == "stale-bundle":
                prepared_receipt.write_text("a" * 40 + "\t" + tree + "\t0\t0\n")
            if mode == "--prepared-native" and scenario.startswith("prepared-"):
                prepared = subprocess.run(command + ["--prepare"], env=environment,
                                          text=True, capture_output=True, timeout=15)
                self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
                self.assertFalse((root / "native.args").exists())
                self.assertFalse((root / "step.outputs").exists())
                if scenario == "prepared-wrong-host":
                    environment["FRAME_READ_HOST"] = "x86_64"
                elif scenario == "prepared-wrong-source":
                    prepared_receipt.write_text("0" * 40 + "\t" + tree + "\t0\t0\n")
                elif scenario == "prepared-nonzero":
                    prepared_receipt.write_text(prepared_receipt.read_text().replace("\t0\t0", "\t29\t0"))
                elif scenario == "prepared-extra-line":
                    with prepared_receipt.open("a") as stream:
                        stream.write("0\t0\n")
            result = subprocess.run(command + ([mode] if mode else []), env=environment,
                                    text=True, capture_output=True, timeout=15)
            if mode == "--prepare" and scenario == "stale-bundle":
                self.assertEqual(prepared_receipt.read_text(), "", "Failed early preparation must revoke its previous authorization")
            args_file = root / "native.args"
            arguments = args_file.read_text().splitlines() if args_file.exists() else []
            if scenario in ("build-failure", "build-tee-failure", "success") and mode == "--prepare":
                build = (root / "build.args").read_text().splitlines()
                self.assertEqual(build[:4], ["scripts/run-owned-xcodebuild.py", "--phase", "build", "--"])
                self.assertEqual(build[4], "xcodebuild")
                self.assertEqual(build[build.index("-jobs") + 1], "1")
                self.assertEqual(build[build.index("-destination") + 1], "generic/platform=iOS Simulator")
                self.assertIn("build-for-testing", build)
                for setting in ("ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"):
                    self.assertEqual(build.count(setting), 1)
                self.assertFalse(any(value.startswith("ARCHS=") and value != "ARCHS=arm64" for value in build))
                self.assertEqual((root / "host.args").read_text().splitlines(), ["-m"])
                self.assertIn("CODE_SIGNING_ALLOWED=NO", build)
                self.assertEqual((root / "order.log").read_text().splitlines(), ["driver", "core", "apple", "build"])
                self.assertNotIn("-resultBundlePath", build, "Build bundles cannot contaminate native-only export")
                self.assertIn("Owned build receipt retained", result.stdout)
                if scenario != "success":
                    self.assertEqual(prepared_receipt.read_text(), "", "A failed build cannot authorize native execution")
            if scenario == "prepared-success":
                self.assertEqual((root / "order.log").read_text().splitlines(), ["driver", "core", "apple", "build"])
            if scenario in ("wrong-host", "host-query-failure", "prepared-wrong-host"):
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("An arm64 host is required", result.stderr)
                self.assertEqual((root / "host.args").read_text().splitlines(), ["-m"])
                self.assertEqual(arguments, [])
                if not scenario.startswith("prepared-"):
                    self.assertFalse((root / "order.log").exists(), "Host rejection must precede driver/Core/SDK work")
                    self.assertFalse((root / "build.args").exists())
                else:
                    self.assertEqual((root / "order.log").read_text().splitlines(), ["driver", "core", "apple", "build"])
            if arguments:
                self.assertEqual((root / "host.args").read_text().splitlines(), ["-m"])
                for setting in ("ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES"):
                    self.assertEqual(arguments.count(setting), 1)
                self.assertFalse(any(value.startswith("ARCHS=") and value != "ARCHS=arm64" for value in arguments))
                self.assertTrue((root / "helper.pid").is_file(), result.stdout + result.stderr)
                self.assertTrue((root / "helper.stopped").is_file(), "Owned capture helper must be reaped")
                self.assertEqual((root / "step.outputs").read_text(), "attempted=true\n")
                self.assertEqual((root / "swift.limit").read_text().strip(), "1")
                capture = (root / "capture.args").read_text().splitlines()
                self.assertIn("--lifetime", capture)
                self.assertEqual(capture[capture.index("--lifetime") + 1], "1200")
                self.assertEqual(capture[capture.index("--udid") + 1], SIMULATOR)
                verified = subprocess.run(command + ["--verify-results"],
                                          env=environment, text=True, capture_output=True, timeout=10)
                return result, arguments, receipt.read_text(), verified
            self.assertFalse((root / "helper.pid").exists(), "Rejected preflight must prevent capture")
            self.assertFalse((root / "step.outputs").exists(), "Rejected preflight cannot claim an attempt")
            self.assertEqual(log.read_text(), "", result.stdout + result.stderr)
            self.assertEqual(receipt.read_text(), "", result.stdout + result.stderr)
            return result, arguments, "", None

    def test_exact_singleton_selector_limits_and_cleanup(self):
        result, arguments, receipt, verified = self.exercise()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("expectedNative=9", result.stdout)
        self.assertIn("expectedCore=110", result.stdout)
        self.assertIn("NativeFrameReadDiagnosticEvidence native=9 ui=0 nativeExit=0 teeExit=0", result.stdout)
        self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
        self.assertEqual(receipt, "0\t0\n")
        self.assertEqual([value for value in arguments if value.startswith("-only-testing:")],
                         [f"-only-testing:{selector}" for selector in CASES])
        for flag, value in (("-jobs", "1"), ("-parallel-testing-enabled", "NO"),
                            ("-test-timeouts-enabled", "YES"),
                            ("-default-test-execution-time-allowance", "120"),
                            ("-maximum-test-execution-time-allowance", "120"),
                            ("-destination", f"platform=iOS Simulator,id={SIMULATOR}")):
            self.assertEqual(arguments[arguments.index(flag) + 1], value)
        self.assertTrue({"CODE_SIGNING_ALLOWED=NO", "SWIFTC_MAXIMUM_DETERMINISM=1",
                         "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO", "test"}.issubset(arguments))
        self.assertRegex(arguments[arguments.index("-resultBundlePath") + 1],
                         r"^artifacts/native/Tests-[0-9]{8}-[0-9]{6}\.xcresult$")

    def test_native_failure_survives_passing_text_and_cleanup(self):
        result, _, receipt, verified = self.exercise("native-failure")
        self.assertEqual(result.returncode, 65, result.stdout + result.stderr)
        self.assertEqual(receipt, "65\t0\n")
        self.assertNotEqual(verified.returncode, 0)

    def test_tee_failure_cannot_become_success(self):
        result, _, receipt, verified = self.exercise("tee-failure")
        self.assertEqual(result.returncode, 17, result.stdout + result.stderr)
        self.assertEqual(receipt, "0\t17\n")
        self.assertNotEqual(verified.returncode, 0)

    def test_missing_skipped_and_duplicate_cases_fail_strict_verification(self):
        for scenario in ("missing", "skipped", "duplicate"):
            with self.subTest(scenario=scenario):
                result, _, receipt, verified = self.exercise(scenario)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(receipt, "0\t0\n")
                self.assertNotEqual(verified.returncode, 0)
                self.assertNotIn("NativeFrameReadDiagnosticEvidence native=9", result.stdout)

    def test_failed_preflights_clear_stale_evidence_and_prevent_launch(self):
        for scenario, expected in (("core-failure", 19), ("driver-failure", 31),
                                   ("stale-bundle", 2), ("pending-pins", 2)):
            with self.subTest(scenario=scenario):
                result, arguments, _, _ = self.exercise(scenario)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(arguments, [])
                if scenario == "pending-pins":
                    self.assertIn("Final committed source pins required.", result.stderr)

    def test_driver_failure_exposes_its_original_output_and_exit_without_launch(self):
        result, arguments, _, verified = self.exercise("driver-failure")
        self.assertEqual(result.returncode, 31, result.stdout + result.stderr)
        self.assertEqual(arguments, [])
        self.assertIsNone(verified)
        self.assertIn("remark: SWIFTC_MAXIMUM_DETERMINISM overriding -j", result.stdout)

    def test_prepare_builds_exact_source_before_boot_without_claiming_native_attempt(self):
        result, arguments, _, verified = self.exercise(mode="--prepare")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(arguments, [])
        self.assertIsNone(verified)
        self.assertIn("NativeFrameReadPreparedEvidence", result.stdout)

    def test_failed_prepare_build_exposes_receipt_and_preserves_exit(self):
        for scenario, expected in (("build-failure", 29), ("build-tee-failure", 17)):
            with self.subTest(scenario=scenario):
                result, arguments, _, verified = self.exercise(scenario, mode="--prepare")
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                self.assertEqual(arguments, [])
                self.assertIsNone(verified)

    def test_prepared_native_requires_the_exact_successful_preparation_receipt(self):
        for scenario in ("success", "prepared-wrong-source", "prepared-nonzero", "prepared-extra-line"):
            with self.subTest(scenario=scenario):
                result, arguments, _, _ = self.exercise(scenario, mode="--prepared-native")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(arguments, [])
                self.assertIn("Exact successful preparation required", result.stderr)

    def test_prepared_native_uses_only_the_qualified_source_with_original_test_action(self):
        result, arguments, receipt, verified = self.exercise("prepared-success", mode="--prepared-native")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
        self.assertEqual(receipt, "0\t0\n")
        self.assertIn("test", arguments)
        self.assertNotIn("test-without-building", arguments)
        self.assertEqual([v for v in arguments if v.startswith("-only-testing:")],
                         [f"-only-testing:{selector}" for selector in CASES])

    def test_early_prepare_failure_revokes_previous_success(self):
        result, arguments, _, _ = self.exercise("stale-bundle", mode="--prepare")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(arguments, [])

    def test_source_inventory_and_workflow_are_dedicated_and_bounded(self):
        source = SOURCE.read_text(encoding="utf-8")
        declaration = re.search(r"^cases=\((.*?)\)\s*$", source, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(declaration)
        self.assertEqual(len(CASES), 9)
        self.assertEqual(tuple(shlex.split(declaration.group(1))), CASES)
        workflow = WORKFLOW.read_text(encoding="utf-8").replace("\r\n", "\n")
        self.assertIn("fetch-depth: 2", workflow)
        self.assertEqual(re.findall(r"^    runs-on: (.+)$", workflow, re.MULTILINE), ["macos-26"])
        self.assertEqual(re.findall(r"^    timeout-minutes: (\d+)$", workflow, re.MULTILINE), ["30"])
        self.assertEqual(re.findall(r"^  ([a-z][a-z-]*):\s*$", workflow.split("jobs:\n", 1)[1],
                                    re.MULTILINE), ["native-frame-read-diagnostic"])
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("concurrency:\n  group: offline-player-native-validation\n"
                      "  cancel-in-progress: true\njobs:\n", workflow)
        self.assertIn("persist-credentials: false", workflow)
        self.assertIn("github.event.repository.private == false", workflow)
        self.assertEqual(workflow.count("steps.native.outputs.attempted == 'true'"), 2)
        self.assertIn("python3 scripts/export-native-xcresult.py", workflow)
        self.assertIn("bash scripts/check-native-frame-read-diagnostic.sh --verify-results", workflow)
        self.assertLess(workflow.index("bash scripts/check-native-frame-read-diagnostic.sh --prepare"),
                        workflow.index("python3 scripts/ensure-simulator-booted.py"))
        self.assertIn("bash scripts/check-native-frame-read-diagnostic.sh --prepared-native", workflow)
        self.assertNotIn("upload-artifact", workflow)
        self.assertNotIn("secrets.", workflow)
        paths = re.search(r"^    paths: \[(.*?)\]$", workflow, re.MULTILINE)
        self.assertEqual(set(re.findall(r"'([^']+)'", paths.group(1))),
                         {".github/workflows/native-frame-read-diagnostic.yml",
                          "scripts/check-native-frame-read-diagnostic.sh",
                          "tests/validation-shell/test_native_frame_read_diagnostic.py"})


    def test_non_arm64_host_cannot_prepare_or_launch_native_work(self):
        for mode in (None, "--prepare"):
            with self.subTest(mode=mode):
                result, arguments, _, verified = self.exercise("wrong-host", mode=mode)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(arguments, []); self.assertIsNone(verified)

    def test_failed_host_query_cannot_authorize_prepare_even_with_arm64_stdout(self):
        result, arguments, _, verified = self.exercise("host-query-failure", mode="--prepare")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(arguments, []); self.assertIsNone(verified)

    def test_prepared_native_rechecks_host_before_helper_or_native_attempt(self):
        result, arguments, _, verified = self.exercise("prepared-wrong-host", mode="--prepared-native")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(arguments, []); self.assertIsNone(verified)


if __name__ == "__main__":
    unittest.main()
