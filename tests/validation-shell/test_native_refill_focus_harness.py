"""Focused stdlib controls: SDK commands and process ownership are always mocked."""
import ast
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(os.environ.get("NATIVE_REFILL_FOCUS_HARNESS_SOURCE", ROOT / "scripts/check-native-refill-focus.sh"))
WORKFLOW = Path(os.environ.get("NATIVE_REFILL_FOCUS_WORKFLOW_SOURCE", ROOT / ".github/workflows/native-refill-focus.yml"))
EXPECTED = (
    "testFrameReadinessMonitorBenchmarkCurrentCustomFrameThenDefault",
    "testFrameReadinessMonitorBenchmarkDefaultThenCurrentCustomFrame",
    "testNativeRefillTraceCurrentCustomFrameThenDefault",
    "testNativeRefillTraceDefaultThenCurrentCustomFrame",
)
spec = importlib.util.spec_from_file_location("native_control_fixture", ROOT / "tests/validation-shell/test_native_control_harness.py")
legacy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(legacy)


class NativeRefillFocusHarnessTests(unittest.TestCase):
    def setUp(self):
        patcher = mock.patch.object(legacy, "HARNESS", SOURCE)
        patcher.start(); self.addCleanup(patcher.stop)
        self.fixture = legacy.NativeControlHarnessTests("test_live_control_inventory_and_source_manifest_are_required")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        original = self.fixture.make_receipt
        def build_receipt():
            receipt = original()
            receipt.pop("benchmarkNativeExit", None); receipt.pop("benchmarkTeeExit", None)
            receipt.update(buildNativeExit=0, buildTeeExit=0)
            self.fixture.receipt.write_text(json.dumps(receipt))
            return receipt
        self.fixture.make_receipt = build_receipt

    def test_clean_checkout_setup_precedes_harness_and_native_execution(self):
        text = WORKFLOW.read_text()
        self.assertIn('fetch-depth: 3', text)
        harness = text.index('python3 tests/validation-shell/test_check_ios_shell.py')
        self.assertLess(text.index('mkdir -p artifacts'), harness)
        self.assertIn('id: harness', text)
        warmup = text.index('id: simulator_inventory')
        self.assertGreater(warmup, harness)
        self.assertIn("['xcrun', 'simctl', 'list', 'devices', 'available', '--json']", text)
        self.assertIn('timeout=60', text)
        self.assertIn("steps.harness.outcome == 'success'", text)
        self.assertIn("steps.simulator_inventory.outcome == 'success'", text)
        self.assertNotIn("'boot'", text)
        self.assertNotIn("'launch'", text)

    def test_fixed_four_inventory_and_source_membership(self):
        f = self.fixture
        self.assertEqual(f.cases, EXPECTED)
        shell = SOURCE.read_text().replace("\r\n", "\n")
        declaration = re.search(r'^cases=\((.*?)\)\s*$', shell, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(declaration)
        self.assertEqual(tuple(shlex.split(declaration.group(1))), EXPECTED)
        f.ns["verifier"]()
        for missing in EXPECTED:
            with self.subTest(missing=missing):
                f.write_manifest(tuple(name for name in EXPECTED if name != missing))
                with self.assertRaises(ValueError): f.ns["verifier"]()
        f.write_manifest(EXPECTED)

    def test_runtime_boundary_and_log_functions_are_reused_verbatim(self):
        def functions(path):
            shell = path.read_text().replace("\r\n", "\n")
            text = shell.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
            lines = text.splitlines(keepends=True)
            return {node.name: "".join(lines[node.lineno - 1:node.end_lineno])
                    for node in ast.parse(text).body if isinstance(node, ast.FunctionDef)}
        old = functions(ROOT / "scripts/check-native-playback-targeted.sh")
        new = functions(SOURCE)
        for name in ("require", "runtime_host", "raw_log", "plan_info", "command", "owned_processes", "boundary"):
            with self.subTest(function=name): self.assertEqual(new[name], old[name])

    def test_strict_receipt_and_changed_product_guards(self):
        f = self.fixture
        value = f.make_receipt()
        self.assertEqual(f.ns["read_receipt"](legacy.SOURCE, legacy.TREE, legacy.SIMULATOR)["buildNativeExit"], 0)
        for mutation in ("missing-plan", "mutated-plan", "duplicate-plan", "source", "tree", "simulator", "missing-receipt"):
            with self.subTest(mutation=mutation):
                value = f.make_receipt()
                extra = f.products / "Other.xctestrun"
                if mutation == "missing-plan": f.plan.unlink()
                elif mutation == "mutated-plan": f.plan.write_bytes(b"modified compiled plan\n")
                elif mutation == "duplicate-plan": extra.write_bytes(b"another plan")
                elif mutation == "missing-receipt": f.receipt.unlink()
                else:
                    changed = dict(value)
                    changed[{"source": "source", "tree": "iosTree", "simulator": "simulator"}[mutation]] = "f" * 40
                    f.receipt.write_text(json.dumps(changed))
                with self.assertRaises((OSError, ValueError)):
                    f.ns["read_receipt"](legacy.SOURCE, legacy.TREE, legacy.SIMULATOR)
                extra.unlink(missing_ok=True)
        value = f.make_receipt()
        for field in ("buildNativeExit", "buildTeeExit"):
            with self.subTest(field=field):
                invalid = dict(value); invalid[field] = 65
                self.fixture.receipt.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    self.fixture.ns["read_receipt"](legacy.SOURCE, legacy.TREE, legacy.SIMULATOR)

    def test_wrong_duplicate_failed_or_missing_case_is_not_receipt_success(self):
        self.fixture.test_singleton_logs_reject_wrong_duplicate_and_failed_cases()

    def test_runtime_identity_and_nonce_guards(self):
        self.fixture.test_runtime_host_receipt_binds_exact_case_device_bundle_and_process()

    def test_aggregate_rejects_nonzero_missing_duplicate_receipts(self):
        self.fixture.test_aggregate_rejects_nonzero_missing_and_duplicate_control_receipts()

    def test_aggregate_rejects_reused_nonce(self):
        self.fixture.test_aggregate_rejects_reused_runtime_process_nonce()

    def test_ownership_unknown_never_authorizes_another_launch(self):
        self.fixture.test_unknown_ownership_fails_before_any_termination()

    def test_boundaries_require_exact_app_and_two_adjacent_absences(self):
        self.fixture.test_boundary_requires_two_adjacent_absences_and_only_exact_bundle_termination()

    def test_workflow_is_one_disjoint_unsigned_focused_job(self):
        text = WORKFLOW.read_text()
        self.assertEqual(re.findall(r'^    runs-on: (.+)$', text, re.MULTILINE), ['macos-26'])
        self.assertEqual(re.findall(r'^    timeout-minutes: (\d+)$', text, re.MULTILINE), ['30'])
        self.assertEqual(re.findall(r'^  ([a-z][a-z-]*):\s*$', text.split('jobs:\n', 1)[1], re.MULTILINE), ['native-refill-focus'])
        self.assertIn("permissions:\n  contents: read", text)
        self.assertIn("github.event.repository.private == false", text)
        self.assertIn("github.event_name == 'push'", text)
        self.assertIn("persist-credentials: false", text)
        self.assertNotIn("upload-artifact", text)
        self.assertNotIn("secrets.", text)
        focus_paths = re.search(r"^    paths: \[(.*?)\]$", text, re.MULTILINE)
        self.assertIsNotNone(focus_paths)
        focus_paths = set(re.findall(r"'([^']+)'", focus_paths.group(1)))
        self.assertEqual(focus_paths, {'.github/workflows/native-refill-focus.yml', 'scripts/check-native-refill-focus.sh'})
        original = (ROOT / '.github/workflows/native-playback-targeted.yml').read_text()
        old_paths = set(re.findall(r"'([^']+)'", re.search(r"^    paths: \[(.*?)\]$", original, re.MULTILINE).group(1)))
        self.assertFalse(focus_paths & old_paths)

    def test_actual_bash_builds_once_then_four_singletons_without_capture_and_preserves_exits(self):
        shell = SOURCE.read_text().replace("\r\n", "\n")
        self.assertNotRegex(shell, r'capture-simulator-test-frames\.py[^\n]*--udid')
        self.assertNotIn('capture_pid=', shell)
        self.assertIn('export SWIFTC_MAXIMUM_DETERMINISM=1', shell)
        self.assertIn('SWIFTC_MAXIMUM_DETERMINISM overriding -j', shell)
        self.assertIn('-driver-print-jobs -j1 -j3', shell)
        payload = shell.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        run = shell[shell.index('# Focused immutable build\n'):]
        fake_xcode = r'''import json, os, sys, uuid
from pathlib import Path
root=Path(os.environ['HARNESS_UNIT_ROOT']); args=sys.argv[1:]
with (root/'commands.jsonl').open('a') as stream: stream.write(json.dumps(args)+'\n')
scenario=os.environ['HARNESS_UNIT_SCENARIO']; products=root/'artifacts/DerivedData/Build/Products'
if 'build-for-testing' in args:
    products.mkdir(parents=True,exist_ok=True)
    if scenario!='missing-plan': (products/'Owned.xctestrun').write_bytes(b'compiled plan\n')
    raise SystemExit(23 if scenario=='build-failure' else 0)
selector=next(x.split(':',1)[1] for x in args if x.startswith('-only-testing:'))
name=selector.rsplit('/',1)[1]; first=not (root/'first-case').exists(); (root/'first-case').touch()
identity='OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests'
print("Test Case '-[%s %s]' started."%(identity,name))
if not (scenario=='unknown-host' and first):
    print('NativeRuntimeHost '+json.dumps(dict(schema=1,simulatorUDID=os.environ['HARNESS_UNIT_SIMULATOR'],pid=31,bundleIdentifier='dev.galaxybigbird.OfflineTikTokPlayer',moduleNonce=str(uuid.uuid5(uuid.NAMESPACE_URL,name)),testName='-[PlaybackSelectionVideoRegressionTests %s]'%name)))
failed=scenario=='native-failure' and first
print("Test Case '-[%s %s]' %s (0.001 seconds)."%(identity,name,'failed' if failed else 'passed'))
print('** TEST EXECUTE FAILED **' if failed else '** TEST EXECUTE SUCCEEDED **')
raise SystemExit(65 if failed else 0)
'''
        fake_tee = r'''import os, sys
from pathlib import Path
root=Path(os.environ['HARNESS_UNIT_ROOT']); count=root/'tee-count'
n=int(count.read_text())+1 if count.exists() else 1; count.write_text(str(n))
data=sys.stdin.buffer.read(); Path(sys.argv[1]).write_bytes(data); sys.stdout.buffer.write(data)
raise SystemExit(17 if os.environ['HARNESS_UNIT_SCENARIO']=='tee-failure' and n==2 else 0)
'''
        for scenario in ('valid','native-failure','tee-failure','unknown-host','build-failure','missing-plan'):
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(dir=self.fixture.root) as directory:
                root=Path(directory); (root/'artifacts/native').mkdir(parents=True)
                (root/'scripts').mkdir(); (root/'scripts/verify-native-test-log.py').write_text(legacy.VERIFIER.read_text())
                native=root/'ios/OfflineTikTokPlayerTests'; native.mkdir(parents=True)
                (root/'ios/OfflineTikTokPlayerUITests').mkdir()
                (root/'ios/OfflineTikTokPlayerUITests/UI.swift').write_text('import XCTest\nfinal class FixtureUITests: XCTestCase {\n func testFixtureUI() {}\n}\n')
                (native/'Controls.swift').write_text('import XCTest\nfinal class PlaybackSelectionVideoRegressionTests: XCTestCase {\n'+''.join(' func %s() {}\n'%name for name in EXPECTED)+'}\n')
                (root/'fake-xcode.py').write_text(fake_xcode); (root/'fake-tee.py').write_text(fake_tee)
                preamble='\n'.join(('set -euo pipefail','cd "$HARNESS_UNIT_ROOT"',
                    'expected_code_source='+legacy.SOURCE,'expected_ios_tree='+legacy.TREE,'simulator_id='+legacy.SIMULATOR,
                    'cases=('+' '.join(EXPECTED)+')',
                    'xcodebuild() { "$HARNESS_UNIT_PYTHON" "$HARNESS_UNIT_ROOT/fake-xcode.py" "$@"; }',
                    'tee() { "$HARNESS_UNIT_PYTHON" "$HARNESS_UNIT_ROOT/fake-tee.py" "$@"; }',
                    'evidence_tool() {',
                    ' if [ "$1" = boundary ]; then printf "%s\\n" "$3" >> boundary-events; return 0; fi',
                    ' "$HARNESS_UNIT_PYTHON" - "$@" <<\'PY\'',payload,'PY','}',''))
                script=root/'focus.sh'; script.write_text(preamble+run)
                env=dict(os.environ,HARNESS_UNIT_ROOT=str(root),HARNESS_UNIT_PYTHON=sys.executable,
                         HARNESS_UNIT_SIMULATOR=legacy.SIMULATOR,HARNESS_UNIT_SCENARIO=scenario,GITHUB_RUN_ID='123',GITHUB_RUN_ATTEMPT='1')
                result=legacy.REAL_SUBPROCESS_RUN(['/bin/bash',str(script)],env=env,text=True,capture_output=True,timeout=15)
                commands=[json.loads(line) for line in (root/'commands.jsonl').read_text().splitlines()]
                self.assertEqual(sum('build-for-testing' in args for args in commands),1)
                testing=[args for args in commands if 'test-without-building' in args]
                expected_count=0 if scenario in ('build-failure','missing-plan') else 1 if scenario=='unknown-host' else 4
                self.assertEqual(len(testing),expected_count,result.stdout+result.stderr)
                self.assertEqual([next(arg for arg in args if arg.startswith('-only-testing:')) for args in testing],
                    ['-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/'+name for name in EXPECTED[:expected_count]])
                for args in commands:
                    self.assertEqual(args[args.index('-jobs')+1],'1'); self.assertEqual(args[args.index('-parallel-testing-enabled')+1],'NO')
                    self.assertIn('CODE_SIGNING_ALLOWED=NO',args); self.assertIn('SWIFTC_MAXIMUM_DETERMINISM=1',args)
                    self.assertIn('SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO',args)
                for args in testing:
                    for flag,value in legacy.NATIVE_TEST_TIMEOUTS:
                        self.assertEqual(args.count(flag),1); self.assertEqual(args[args.index(flag)+1],value)
                if expected_count:
                    self.assertEqual((root/'boundary-events').read_text().splitlines(),['before-01']+['after-%02d'%n for n in range(1,expected_count+1)])
                    statuses=(root/'artifacts/native-refill-focus/native-playback-controls/statuses.tsv').read_text().splitlines()
                    self.assertEqual(len(statuses),expected_count)
                expected_exit={'valid':0,'native-failure':65,'tee-failure':17,'unknown-host':2,'build-failure':23}
                if scenario in expected_exit: self.assertEqual(result.returncode,expected_exit[scenario],result.stdout+result.stderr)
                else: self.assertNotEqual(result.returncode,0)


if __name__ == '__main__':
    unittest.main()
