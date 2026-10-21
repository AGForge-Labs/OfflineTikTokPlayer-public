"""Two fixed render-accounting controls; native commands/ownership are mocked."""
import importlib.util
import os
from pathlib import Path
import re
import shlex
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("RENDER_ACCOUNTING_HARNESS_SOURCE", ROOT / "scripts/check-render-accounting-focus.sh"))
WORKFLOW = Path(os.environ.get("RENDER_ACCOUNTING_WORKFLOW_SOURCE", ROOT / ".github/workflows/render-accounting-focus.yml"))
EXPECTED = ("testDefaultProductionRenderAccountingBaseline", "testDefaultProductionRenderAccountingEnabled")
spec = importlib.util.spec_from_file_location("refill_fixture", ROOT / "tests/validation-shell/test_native_refill_focus_harness.py")
focus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(focus)


class RenderAccountingHarnessTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.multiple(focus, SOURCE=SOURCE, WORKFLOW=WORKFLOW, EXPECTED=EXPECTED)
        patcher.start(); self.addCleanup(patcher.stop)
        self.delegate = focus.NativeRefillFocusHarnessTests("test_fixed_four_inventory_and_source_membership")
        self.delegate.setUp(); self.addCleanup(self.delegate.doCleanups)
        self.fixture = self.delegate.fixture

    def test_fixed_two_inventory_and_source_membership(self):
        # The reusable fixture routine reads the patched exact tuple, not a count alias.
        self.delegate.test_fixed_four_inventory_and_source_membership()

    def test_strict_runtime_and_boundary_routines_remain_identical(self):
        self.delegate.test_runtime_boundary_and_log_functions_are_reused_verbatim()

    def test_build_receipt_and_changed_product_guards(self):
        self.delegate.test_strict_receipt_and_changed_product_guards()

    def test_wrong_duplicate_failed_or_missing_native_case_is_not_success(self):
        self.delegate.test_wrong_duplicate_failed_or_missing_case_is_not_receipt_success()

    def test_runtime_identity_is_exact(self):
        self.delegate.test_runtime_identity_and_nonce_guards()

    def test_aggregate_rejects_nonzero_missing_duplicate_receipts(self):
        self.delegate.test_aggregate_rejects_nonzero_missing_duplicate_receipts()

    def test_aggregate_rejects_reused_runtime_nonce(self):
        self.delegate.test_aggregate_rejects_reused_nonce()

    def test_unknown_ownership_never_authorizes_another_launch(self):
        self.delegate.test_ownership_unknown_never_authorizes_another_launch()

    def test_exact_app_and_two_absence_observations_remain_required(self):
        self.delegate.test_boundaries_require_exact_app_and_two_adjacent_absences()

    def test_one_clean_unsigned_job_and_disjoint_trigger_paths(self):
        text = WORKFLOW.read_text()
        self.assertIn('fetch-depth: 2', text)
        self.assertEqual(re.findall(r'^    runs-on: (.+)$', text, re.MULTILINE), ['macos-26'])
        self.assertEqual(re.findall(r'^    timeout-minutes: (\d+)$', text, re.MULTILINE), ['30'])
        self.assertEqual(re.findall(r'^  ([a-z][a-z-]*):\s*$', text.split('jobs:\n', 1)[1], re.MULTILINE), ['render-accounting-focus'])
        self.assertIn('permissions:\n  contents: read', text)
        self.assertIn("github.event.repository.private == false", text)
        self.assertIn("github.event_name == 'push'", text)
        self.assertIn('persist-credentials: false', text)
        self.assertNotIn('secrets.', text); self.assertNotIn('upload-artifact', text)
        harness = text.index('python3 tests/validation-shell/test_check_ios_shell.py')
        self.assertLess(text.index('mkdir -p artifacts'), harness)
        self.assertIn('id: harness', text)
        self.assertGreater(text.index('id: simulator_inventory'), harness)
        self.assertIn("['xcrun', 'simctl', 'list', 'devices', 'available', '--json']", text)
        self.assertIn('timeout=60', text)
        native_step = text[text.index('- name: Compile once'):]
        self.assertIn("steps.harness.outcome == 'success'", native_step)
        self.assertIn("steps.simulator_inventory.outcome == 'success'", native_step)
        paths = set(re.findall(r"'([^']+)'", re.search(r'^    paths: \[(.*?)\]$', text, re.MULTILINE).group(1)))
        self.assertEqual(paths, {'.github/workflows/render-accounting-focus.yml', 'scripts/check-render-accounting-focus.sh'})
        for name in ('native-playback-targeted.yml', 'native-refill-focus.yml', 'native-reader-full-validation.yml'):
            old = (ROOT / '.github/workflows' / name).read_text()
            old_paths = set(re.findall(r"'([^']+)'", re.search(r'^    paths: \[(.*?)\]$', old, re.MULTILINE).group(1)))
            self.assertFalse(paths & old_paths)

    def test_actual_bash_builds_once_two_singletons_and_preserves_all_exits_without_capture(self):
        shell = SOURCE.read_text().replace('\r\n', '\n')
        self.assertNotRegex(shell, r'capture-simulator-test-frames\.py[^\n]*--udid')
        self.assertNotIn('capture_pid=', shell)
        self.assertIn('export SWIFTC_MAXIMUM_DETERMINISM=1', shell)
        self.assertIn('-driver-print-jobs -j1 -j3', shell)
        self.assertIn('SWIFTC_MAXIMUM_DETERMINISM overriding -j', shell)
        run = shell[shell.index('# Focused immutable build\n'):]
        for scenario in ('valid', 'native-failure', 'tee-failure', 'build-failure', 'build-tee-failure', 'unknown-host', 'unknown-boundary'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(dir=self.fixture.root) as directory:
                root = Path(directory)
                preamble = '\n'.join((
                    'set -euo pipefail', 'cd "$HARNESS_UNIT_ROOT"',
                    'expected_code_source=' + focus.legacy.SOURCE, 'expected_ios_tree=' + focus.legacy.TREE,
                    'simulator_id=' + focus.legacy.SIMULATOR,
                    'cases=(' + ' '.join(map(shlex.quote, EXPECTED)) + ')',
                    'xcodebuild() {',
                    ' local n=0; if [ -f command-count ]; then read -r n < command-count; fi; n=$((n + 1)); printf "%s\\n" "$n" > command-count',
                    ' printf "%s\\n" "$@" > "args-$n"',
                    ' if [ "$n" -eq 1 ] && [ "$HARNESS_UNIT_SCENARIO" = build-failure ]; then return 23; fi',
                    ' if [ "$n" -eq 2 ] && [ "$HARNESS_UNIT_SCENARIO" = native-failure ]; then return 65; fi',
                    ' return 0; }',
                    'tee() { local n=0; if [ -f tee-count ]; then read -r n < tee-count; fi; n=$((n + 1)); printf "%s\\n" "$n" > tee-count; cat > "$1"',
                    ' if [ "$n" -eq 1 ] && [ "$HARNESS_UNIT_SCENARIO" = build-tee-failure ]; then return 17; fi',
                    ' if [ "$n" -eq 2 ] && [ "$HARNESS_UNIT_SCENARIO" = tee-failure ]; then return 17; fi; return 0; }',
                    'evidence_tool() { case "$1" in',
                    ' initialize-build) return 0 ;;',
                    ' generated-plan) printf "%s\\n" "{}" ;;',
                    ' plan-path|read-plan) printf "%s\\n" "owned.xctestrun" ;;',
                    ' record-build) printf "%s\\n" "$@" > build-receipt-events ;;',
                    ' initialize-controls) mkdir -p artifacts/render-accounting-focus/native-playback-controls ;;',
                    ' boundary) printf "%s\\n" "$3" >> boundary-events; if [ "$3" = after-01 ] && [ "$HARNESS_UNIT_SCENARIO" = unknown-boundary ]; then return 1; fi ;;',
                    ' verify-one) if [ "$ordinal" -eq 1 ] && [ "$HARNESS_UNIT_SCENARIO" = unknown-host ]; then return 2; fi ;;',
                    ' verify-controls) return 0 ;;',
                    ' *) return 91 ;; esac; }', ''))
                script = root / 'accounting.sh'; script.write_text(preamble + run)
                env = dict(os.environ, HARNESS_UNIT_ROOT=str(root), HARNESS_UNIT_SCENARIO=scenario)
                result = focus.legacy.REAL_SUBPROCESS_RUN(['/bin/bash', str(script)], env=env, text=True, capture_output=True, timeout=10)
                commands = [(root / ('args-%d' % n)).read_text().splitlines() for n in range(1, int((root / 'command-count').read_text()) + 1)]
                self.assertEqual(sum('build-for-testing' in args for args in commands), 1)
                tests = [args for args in commands if 'test-without-building' in args]
                count = 0 if scenario in ('build-failure', 'build-tee-failure') else 1 if scenario in ('unknown-host', 'unknown-boundary') else 2
                self.assertEqual(len(tests), count, result.stdout + result.stderr)
                self.assertEqual([next(arg for arg in args if arg.startswith('-only-testing:')) for args in tests],
                    ['-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/' + name for name in EXPECTED[:count]])
                for args in commands:
                    self.assertEqual(args[args.index('-jobs') + 1], '1'); self.assertEqual(args[args.index('-parallel-testing-enabled') + 1], 'NO')
                    for flag in ('CODE_SIGNING_ALLOWED=NO', 'SWIFTC_MAXIMUM_DETERMINISM=1', 'SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO'):
                        self.assertIn(flag, args)
                for args in tests:
                    for flag, value in focus.legacy.NATIVE_TEST_TIMEOUTS:
                        self.assertEqual(args.count(flag), 1); self.assertEqual(args[args.index(flag) + 1], value)
                if count:
                    self.assertEqual((root / 'boundary-events').read_text().splitlines(), ['before-01'] + ['after-%02d' % n for n in range(1, count + 1)])
                    rows = (root / 'artifacts/render-accounting-focus/native-playback-controls/statuses.tsv').read_text().splitlines()
                    self.assertEqual(len(rows), count)
                self.assertEqual((root / 'build-receipt-events').exists(), count > 0)
                expected_exit = {'valid': 0, 'native-failure': 65, 'tee-failure': 17, 'build-failure': 23,
                                 'build-tee-failure': 17, 'unknown-host': 2, 'unknown-boundary': 1}
                self.assertEqual(result.returncode, expected_exit[scenario], result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
