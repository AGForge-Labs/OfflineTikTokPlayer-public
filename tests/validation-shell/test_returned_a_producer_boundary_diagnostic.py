"""Disposable fake tools only; imports the existing harness, never an SDK/app."""
import importlib.util
import os
from pathlib import Path
import re
import sys
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("RETURNED_A_PRODUCER_BOUNDARY_SOURCE",
                             ROOT / "scripts/check-returned-a-producer-boundary-diagnostic.sh"))
WORKFLOW = Path(os.environ.get("RETURNED_A_PRODUCER_BOUNDARY_WORKFLOW",
                               ROOT / ".github/workflows/returned-a-producer-boundary-diagnostic.yml"))
ARM_ENV = "RETURNED_A_DIAGNOSTIC_ARM"
PREFIX = (
    "OfflineTikTokPlayerTests/NativeMediaTests/testPromotingPreviousRefusesConflictsAndHonorsSavedEligibility",
    "OfflineTikTokPlayerTests/NativeMediaTests/testPromotingPreviousRevalidatesLiveLocalityBeforeCommit",
    "OfflineTikTokPlayerTests/NativeMediaTests/testPromotingPreviousRevalidatesOwnerAfterNativeInsertionEligibility",
    "OfflineTikTokPlayerTests/NativeMediaTests/testPromotingPreviousToNextPreservesExactPreparationAndPlayerPolicy",
)
ARMS = {
    "trace-off": "OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testReturnedAProducerBoundaryTraceDisabled",
    "trace-on": "OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testReturnedAProducerBoundaryTraceEnabled",
    "service-reuse": "OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testReturnedForwardVideoReusesItsPreparedNativeItemAndOutput",
}
spec = importlib.util.spec_from_file_location("returned_a_fake_frame_harness",
    ROOT / "tests/validation-shell/test_native_frame_read_diagnostic.py")
_base = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = _base
spec.loader.exec_module(_base)


class ReturnedAProducerBoundaryDiagnosticTests(unittest.TestCase):
    def exercise(self, arm="trace-off", scenario="success", mode=None,
                 receipt_mutation=None, benchmark_first=False, benchmark_outcome=None,
                 prefix_swapped=False):
        self.assertTrue(SOURCE.is_file(), "The new launcher must exist before this fixture can pass")
        cases = PREFIX + (ARMS.get(arm, ARMS["trace-off"]),)
        observed = {}
        changed_output = False
        real_run = _base.subprocess.run

        def invoke(command, *args, **kwargs):
            nonlocal changed_output
            environment = kwargs.get("env", {})
            directory = Path(environment["FRAME_READ_ROOT"])
            receipt = directory / "artifacts/native/frame-read-prepared-source.tsv"
            if receipt_mutation is not None and "--prepared-native" in command:
                rows = receipt.read_text().splitlines()
                self.assertEqual(len(rows), 1)
                fields = rows[0].split("\t")
                self.assertEqual(len(fields), 5, "Preparation must bind source/tree/arm/both exits")
                field = {"source": 0, "tree": 1, "arm": 2, "native-status": 3, "tee-status": 4}[receipt_mutation]
                fields[field] = ("trace-on" if arm == "trace-off" else "trace-off") if field == 2 else (
                    "0" * 40 if field < 2 else "29")
                receipt.write_text("\t".join(fields) + "\n", encoding="utf-8", newline="\n")
            if (benchmark_first or benchmark_outcome is not None or prefix_swapped) and not changed_output:
                output = directory / "native-output.log"
                lines = output.read_text().splitlines()
                self.assertEqual(len(lines), 2 * len(cases) + 1)
                if benchmark_first:
                    lines = lines[-3:-1] + lines[:-3] + lines[-1:]
                elif prefix_swapped:
                    lines = lines[2:4] + lines[:2] + lines[4:]
                elif benchmark_outcome == "missing":
                    lines = lines[:-3] + lines[-1:]
                elif benchmark_outcome == "skipped":
                    lines[-2] = lines[-2].replace(" passed ", " skipped ")
                elif benchmark_outcome == "duplicate":
                    lines = lines[:-1] + [lines[-2]] + lines[-1:]
                else:
                    self.fail("Unknown bounded fake benchmark outcome")
                output.write_text("\n".join(lines) + "\n",
                                  encoding="utf-8", newline="\n")
                changed_output = True
            result = real_run(command, *args, **kwargs)
            # These are only files owned by the disposable original harness.
            observed.update(
                preparation=receipt.read_text() if receipt.exists() else None,
                order=(directory / "order.log").read_text() if (directory / "order.log").exists() else None,
                build=(directory / "build.args").exists(), helper=(directory / "helper.pid").exists(),
                attempted=(directory / "step.outputs").exists(), host=(directory / "host.args").exists())
            return result

        # Reuse the original bounded fake executables, stale-evidence injection,
        # native/tee receipts, helper closure and exact serial argument assertions.
        # Do not inherit/discover its twelve-case tests or alter its tracked file.
        case = _base.NativeFrameReadDiagnosticTests("test_source_inventory_and_workflow_are_dedicated_and_bounded")
        with mock.patch.multiple(_base, SOURCE=SOURCE, WORKFLOW=WORKFLOW, CASES=cases), mock.patch.dict(os.environ):
            if arm is None:
                os.environ.pop(ARM_ENV, None)
            else:
                os.environ[ARM_ENV] = arm
            with mock.patch.object(_base.subprocess, "run", side_effect=invoke):
                return (*case.exercise(scenario=scenario, mode=mode), observed)

    def test_each_arm_uses_exact_fixed_prefix_and_only_its_singleton(self):
        for arm, selector in ARMS.items():
            with self.subTest(arm=arm):
                result, arguments, receipt, verified, _ = self.exercise(arm)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
                self.assertEqual(receipt, "0\t0\n")
                self.assertEqual([a for a in arguments if a.startswith("-only-testing:")],
                                 ["-only-testing:" + value for value in PREFIX + (selector,)])
                self.assertIn(f"DiagnosticScope arm={arm}", result.stdout)
                self.assertIn("role=" + ("independent-cache-proof" if arm == "service-reuse" else "trace-comparison"), result.stdout)
                self.assertIn("expectedNative=5 prefixNative=4 benchmarkNative=1 expectedUI=0 expectedCore=105", result.stdout)
                self.assertIn("prefixPassRequired=true prefixPrecededBenchmark=true prefixDeclaredOrder=true fullAcceptance=false", result.stdout)
                for flag, value in (("-jobs", "1"), ("-parallel-testing-enabled", "NO"),
                                    ("-test-timeouts-enabled", "YES"),
                                    ("-default-test-execution-time-allowance", "120"),
                                    ("-maximum-test-execution-time-allowance", "120"),
                                    ("-destination", f"platform=iOS Simulator,id={_base.SIMULATOR}")):
                    self.assertEqual(arguments[arguments.index(flag) + 1], value)
                self.assertTrue({"CODE_SIGNING_ALLOWED=NO", "SWIFTC_MAXIMUM_DETERMINISM=1",
                                 "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO", "test"}.issubset(arguments))
                self.assertNotIn("test-without-building", arguments)
                self.assertRegex(arguments[arguments.index("-resultBundlePath") + 1],
                                 r"^artifacts/native/Tests-[0-9]{8}-[0-9]{6}\.xcresult$")

    def test_missing_skipped_or_duplicate_prefix_case_cannot_be_success(self):
        for arm in ARMS:
            for scenario in ("missing", "skipped", "duplicate"):
                with self.subTest(arm=arm, scenario=scenario):
                    result, _, receipt, verified, _ = self.exercise(arm, scenario)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertNotEqual(verified.returncode, 0)
                    self.assertEqual(receipt, "0\t0\n")
                    self.assertNotIn("ReturnedAProducerBoundaryDiagnosticEvidence", result.stdout)

    def test_passing_prefix_after_benchmark_is_not_the_required_history(self):
        for arm in ARMS:
            with self.subTest(arm=arm):
                result, _, receipt, verified, _ = self.exercise(arm, benchmark_first=True)
                self.assertNotEqual(result.returncode, 0); self.assertNotEqual(verified.returncode, 0)
                self.assertEqual(receipt, "0\t0\n")
                self.assertIn("must precede the selected benchmark start", result.stderr)

    def test_missing_skipped_or_duplicate_singleton_cannot_hide_behind_passing_prefix(self):
        for arm in ARMS:
            for outcome in ("missing", "skipped", "duplicate"):
                with self.subTest(arm=arm, outcome=outcome):
                    result, _, receipt, verified, _ = self.exercise(arm, benchmark_outcome=outcome)
                    self.assertNotEqual(result.returncode, 0); self.assertNotEqual(verified.returncode, 0)
                    self.assertEqual(receipt, "0\t0\n")
                    self.assertNotIn("ReturnedAProducerBoundaryDiagnosticEvidence", result.stdout)

    def test_passing_prefix_permutation_is_not_the_required_history(self):
        for arm in ARMS:
            with self.subTest(arm=arm):
                result, _, receipt, verified, _ = self.exercise(arm, prefix_swapped=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotEqual(verified.returncode, 0)
                self.assertEqual(receipt, "0\t0\n")
                self.assertIn("declared serial order", result.stderr)

    def test_native_and_tee_failures_survive_passing_text_and_reap_helper(self):
        for arm in ARMS:
            for scenario, expected, receipt in (("native-failure", 65, "65\t0\n"),
                                                ("tee-failure", 17, "0\t17\n")):
                with self.subTest(arm=arm, scenario=scenario):
                    result, _, actual, verified, _ = self.exercise(arm, scenario)
                    self.assertEqual(result.returncode, expected)
                    self.assertEqual(actual, receipt); self.assertNotEqual(verified.returncode, 0)

    def test_preflight_failures_revoke_stale_evidence_before_native_attempt(self):
        for arm in ARMS:
            for scenario, expected in (("core-failure", 19), ("driver-failure", 31),
                                       ("stale-bundle", 2), ("pending-pins", 2)):
                with self.subTest(arm=arm, scenario=scenario):
                    result, arguments, _, verified, _ = self.exercise(arm, scenario)
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertEqual(arguments, []); self.assertIsNone(verified)
                    if scenario == "driver-failure":
                        self.assertIn("remark: SWIFTC_MAXIMUM_DETERMINISM overriding -j", result.stdout)

    def test_preparation_binds_arm_source_tree_and_successful_exits(self):
        for arm in ARMS:
            with self.subTest(arm=arm):
                result, arguments, _, verified, observed = self.exercise(arm, mode="--prepare")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(arguments, []); self.assertIsNone(verified)
                fields = observed["preparation"].strip().split("\t")
                self.assertEqual(len(fields), 5)
                self.assertRegex(fields[0], r"^[0-9a-f]{40}$"); self.assertRegex(fields[1], r"^[0-9a-f]{40}$")
                self.assertEqual(fields[2:], [arm, "0", "0"])
                self.assertIn(f"ReturnedAProducerBoundaryPreparedEvidence arm={arm}", result.stdout)
                self.assertFalse(observed["helper"]); self.assertFalse(observed["attempted"])
                result, arguments, _, verified, _ = self.exercise(arm, "prepared-success", "--prepared-native")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
                self.assertEqual([a for a in arguments if a.startswith("-only-testing:")],
                                 ["-only-testing:" + value for value in PREFIX + (ARMS[arm],)])

    def test_failed_or_stale_preparation_cannot_authorize_native_work(self):
        for arm in ARMS:
            for scenario, expected in (("build-failure", 29), ("build-tee-failure", 17), ("stale-bundle", 2)):
                with self.subTest(arm=arm, scenario=scenario):
                    result, arguments, _, verified, observed = self.exercise(arm, scenario, "--prepare")
                    self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
                    self.assertEqual(arguments, []); self.assertIsNone(verified)
                    self.assertEqual(observed["preparation"], "")
            for scenario in ("success", "prepared-wrong-source", "prepared-nonzero", "prepared-extra-line"):
                with self.subTest(arm=arm, scenario=scenario):
                    result, arguments, _, verified, _ = self.exercise(arm, scenario, "--prepared-native")
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertEqual(arguments, []); self.assertIsNone(verified)
                    self.assertIn("Exact successful preparation required", result.stderr)

    def test_other_arm_or_same_shape_wrong_source_tree_status_receipt_is_rejected(self):
        for arm in ARMS:
            for mutation in ("arm", "source", "tree", "native-status", "tee-status"):
                with self.subTest(arm=arm, mutation=mutation):
                    result, arguments, _, verified, _ = self.exercise(arm, "prepared-success", "--prepared-native",
                                                                     receipt_mutation=mutation)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertEqual(arguments, []); self.assertIsNone(verified)
                    self.assertIn("Exact successful preparation required", result.stderr)

    def test_missing_or_unknown_arm_is_rejected_before_host_core_sdk_or_attempt(self):
        for arm in (None, "", "unknown", "trace-off trace-on"):
            with self.subTest(arm=arm):
                result, arguments, _, verified, observed = self.exercise(arm)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(arguments, []); self.assertIsNone(verified)
                self.assertIn("must be exactly trace-off, trace-on, or service-reuse", result.stderr)
                self.assertIsNone(observed["order"]); self.assertFalse(observed["host"])
                self.assertFalse(observed["build"]); self.assertFalse(observed["helper"])
                self.assertFalse(observed["attempted"]); self.assertEqual(observed["preparation"], "")

    def test_architecture_queries_and_prepared_host_rechecks_fail_closed(self):
        for arm in ARMS:
            for scenario, mode in (("wrong-host", None), ("wrong-host", "--prepare"),
                                   ("host-query-failure", "--prepare"), ("prepared-wrong-host", "--prepared-native")):
                with self.subTest(arm=arm, scenario=scenario, mode=mode):
                    result, arguments, _, verified, _ = self.exercise(arm, scenario, mode)
                    self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                    self.assertEqual(arguments, []); self.assertIsNone(verified)

    def test_workflow_is_three_fresh_serial_public_unsigned_jobs_on_same_source(self):
        self.assertTrue(SOURCE.is_file()); self.assertTrue(WORKFLOW.is_file())
        source = SOURCE.read_text(encoding="utf-8")
        workflow = WORKFLOW.read_text(encoding="utf-8").replace("\r\n", "\n")
        for name in ("expected_code_source", "expected_ios_tree"):
            self.assertRegex(source, rf"(?m)^{name}=(?:PENDING|[0-9a-f]{{40}})$")
        self.assertIn("Final committed source pins required.", source)
        self.assertIn('git diff --quiet -- ios', source); self.assertIn('git diff --cached --quiet -- ios', source)
        self.assertEqual(re.findall(r"^  ([a-z][a-z-]*):\s*$", workflow.split("jobs:\n", 1)[1], re.MULTILINE),
                         ["returned-a-producer-boundary-diagnostic"])
        self.assertEqual(re.findall(r"^    runs-on: (.+)$", workflow, re.MULTILINE), ["macos-26"])
        self.assertEqual(re.findall(r"^    timeout-minutes: (\d+)$", workflow, re.MULTILINE), ["30"])
        self.assertIn("    strategy:\n      max-parallel: 1\n      fail-fast: false\n      matrix:\n        arm: [trace-off, trace-on, service-reuse]\n", workflow)
        self.assertIn("    env:\n      RETURNED_A_DIAGNOSTIC_ARM: ${{ matrix.arm }}\n", workflow)
        self.assertIn("ref: ${{ github.sha }}", workflow); self.assertIn("persist-credentials: false", workflow)
        self.assertIn("fetch-depth: 2", workflow)
        self.assertIn("permissions:\n  contents: read", workflow)
        self.assertIn("concurrency:\n  group: offline-player-native-validation\n  cancel-in-progress: true\n", workflow)
        self.assertIn("github.event.repository.private == false", workflow)
        self.assertIn("github.repository == 'AGForge-Labs/OfflineTikTokPlayer-public'", workflow)
        self.assertIn("github.event_name == 'push'", workflow)
        self.assertIn("github.ref == 'refs/heads/diagnostic/native-reader-isolation'", workflow)
        paths = re.search(r"^    paths: \[(.*?)\]$", workflow, re.MULTILINE)
        self.assertEqual(set(re.findall(r"'([^']+)'", paths.group(1))), {
            ".github/workflows/returned-a-producer-boundary-diagnostic.yml",
            "scripts/check-returned-a-producer-boundary-diagnostic.sh",
            "tests/validation-shell/test_returned_a_producer_boundary_diagnostic.py"})
        self.assertEqual(workflow.count("steps.native.outputs.attempted == 'true'"), 2)
        self.assertIn("python3 scripts/export-native-xcresult.py", workflow)
        self.assertLess(workflow.index("--prepare"), workflow.index("python3 scripts/ensure-simulator-booted.py"))
        self.assertIn("--prepared-native", workflow); self.assertIn("--verify-results", workflow)
        self.assertNotIn("upload-artifact", workflow); self.assertNotIn("secrets.", workflow)
        self.assertNotIn("continue-on-error", workflow); self.assertNotIn("actions/cache", workflow)


if __name__ == "__main__":
    unittest.main()
