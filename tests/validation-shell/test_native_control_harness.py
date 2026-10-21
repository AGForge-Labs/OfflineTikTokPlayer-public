"""Focused stdlib tests; no SDK command or real process termination is permitted."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HARNESS = Path(os.environ.get("NATIVE_CONTROL_HARNESS_SOURCE", ROOT / "scripts/check-native-playback-targeted.sh"))
VERIFIER = ROOT / "scripts/verify-native-test-log.py"
REAL_SUBPROCESS_RUN = subprocess.run
SIMULATOR = "11111111-2222-4333-8444-555555555555"
CONTAINER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
OTHER_CONTAINER = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
SOURCE, TREE = "1" * 40, "2" * 40


class NativeControlHarnessTests(unittest.TestCase):
    def setUp(self):
        # Extract Python only. Never run the Bash launcher or its mode dispatch
        # while loading definitions, and fail closed on every unmocked process.
        shell = HARNESS.read_text(encoding="utf-8").replace("\r\n", "\n")
        payload = shell.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        marker = "\ntry:\n    mode, *args = sys.argv[1:]"
        definitions, suffix = payload.split(marker, 1)
        self.dispatch = marker.lstrip("\n") + suffix
        self.ns = {"__name__": "native_control_evidence_unit"}
        exec(compile(definitions, str(HARNESS), "exec"), self.ns)
        self.cases = tuple(self.ns["CASES"])
        self.assertTrue(self.cases)
        self.assertEqual(len(self.cases), len(set(self.cases)))
        forbidden = mock.patch("subprocess.run", side_effect=AssertionError("Real process execution is forbidden"))
        forbidden.start()
        self.addCleanup(forbidden.stop)
        environment = mock.patch.dict(os.environ, {"GITHUB_RUN_ID": "123", "GITHUB_RUN_ATTEMPT": "1"})
        environment.start()
        self.addCleanup(environment.stop)
        temporary = tempfile.TemporaryDirectory(prefix="native-control-unit-", dir=ROOT / "artifacts")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.native = self.root / "artifacts/native"
        self.products = self.root / "artifacts/DerivedData/Build/Products"
        self.controls = self.native / "native-playback-controls"
        self.products.mkdir(parents=True)
        self.controls.mkdir(parents=True)
        self.receipt = self.native / "native-playback-build.json"
        self.statuses = self.controls / "statuses.tsv"
        self.ns.update(ROOT=self.root, NATIVE=self.native, PRODUCTS=self.products,
                       RECEIPT=self.receipt, CONTROL_ROOT=self.controls, STATUSES=self.statuses)
        scripts = self.root / "scripts"
        scripts.mkdir()
        (scripts / VERIFIER.name).write_text(VERIFIER.read_text(encoding="utf-8"), encoding="utf-8")
        self.write_manifest(self.cases)
        self.plan = self.products / "Owned.xctestrun"

    def write_manifest(self, cases):
        native = self.root / "ios/OfflineTikTokPlayerTests"
        ui = self.root / "ios/OfflineTikTokPlayerUITests"
        native.mkdir(parents=True, exist_ok=True)
        ui.mkdir(parents=True, exist_ok=True)
        methods = "\n".join("    func %s() {}" % name for name in cases)
        (native / "Controls.swift").write_text(
            "import XCTest\nfinal class PlaybackSelectionVideoRegressionTests: XCTestCase {\n" + methods + "\n}\n")
        (ui / "UI.swift").write_text(
            "import XCTest\nfinal class FixtureUITests: XCTestCase {\n    func testFixtureUI() {}\n}\n")

    def make_receipt(self):
        self.plan.write_bytes(b"original compiled plan\n")
        value = dict(schema=1, source=SOURCE, iosTree=TREE, simulator=SIMULATOR,
                     run="123", attempt="1", plan=self.ns["plan_info"](),
                     benchmarkNativeExit=65, benchmarkTeeExit=0)
        self.receipt.write_text(json.dumps(value), encoding="utf-8")
        return value

    def log(self, name, status="passed"):
        owner = "OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests"
        return ("Test Case '-[%s %s]' started.\n" % (owner, name)
                + "Test Case '-[%s %s]' %s (0.001 seconds).\n" % (owner, name, status)
                + "** TEST SUCCEEDED **\n")

    def mode(self, name, *arguments):
        output, error = io.StringIO(), io.StringIO()
        with mock.patch.object(sys, "argv", ["evidence", name, *map(str, arguments)]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
            try:
                exec(compile(self.dispatch, str(HARNESS), "exec"), self.ns)
            except SystemExit as result:
                return result.code, output.getvalue() + error.getvalue()
        return 0, output.getvalue() + error.getvalue()

    def app(self, container=CONTAINER, *, simulator=SIMULATOR, identifier=None, executable=None):
        bundle = (self.root / "Devices" / simulator / "data/Containers/Bundle/Application"
                  / container / "OfflineTikTokPlayer.app")
        bundle.mkdir(parents=True, exist_ok=True)
        with (bundle / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": identifier or self.ns["BUNDLE"],
                          "CFBundleExecutable": executable or self.ns["EXECUTABLE"]}, stream)
        (bundle / "OfflineTikTokPlayer").write_bytes(b"")
        return bundle

    @contextlib.contextmanager
    def fake_sdk(self, bundle, inventories, *, fallback="", lookup_code=0, ps_code=0):
        calls, pending = [], iter(inventories)
        def run(arguments, **_kwargs):
            calls.append(list(arguments))
            if len(calls) > 128:
                raise AssertionError("Fake command bound exceeded")
            if arguments[:3] == ["xcrun", "simctl", "get_app_container"]:
                return subprocess.CompletedProcess(arguments, lookup_code, str(bundle) + "\n", "")
            if arguments == ["/bin/ps", "-ww", "-axo", "pid=,command="]:
                return subprocess.CompletedProcess(arguments, ps_code, next(pending, fallback), "")
            if arguments == ["xcrun", "simctl", "terminate", SIMULATOR, self.ns["BUNDLE"]]:
                return subprocess.CompletedProcess(arguments, 0, "", "")
            raise AssertionError("Unexpected external command: %r" % (arguments,))
        clock = types.SimpleNamespace(now=0.0)
        clock.monotonic = lambda: clock.now
        clock.sleep = lambda seconds: setattr(clock, "now", clock.now + seconds)
        with mock.patch("subprocess.run", side_effect=run), mock.patch.dict(self.ns, time=clock):
            yield calls

    def test_live_control_inventory_and_source_manifest_are_required(self):
        spec = importlib.util.spec_from_file_location("real_native_evidence_unit", VERIFIER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        expected = {self.ns["PREFIX"] + name for name in self.cases}
        self.assertTrue(expected.issubset(module.source_manifest(ROOT)))
        self.ns["verifier"]()
        self.write_manifest(self.cases[:-1])
        with self.assertRaises(ValueError):
            self.ns["verifier"]()

    def test_receipt_rejects_missing_or_changed_plan_and_wrong_source(self):
        receipt = self.make_receipt()
        # An assertion-failed benchmark may still supply compiled products;
        # its separate strict benchmark gate remains failed.
        self.assertEqual(self.ns["read_receipt"](SOURCE, TREE, SIMULATOR)["benchmarkNativeExit"], 65)
        for mutation in ("missing-plan", "mutated-plan", "duplicate-plan", "source", "tree", "missing-receipt"):
            with self.subTest(mutation=mutation):
                self.make_receipt()
                extra = self.products / "Other.xctestrun"
                if mutation == "missing-plan": self.plan.unlink()
                elif mutation == "mutated-plan": self.plan.write_bytes(b"modified compiled plan\n")
                elif mutation == "duplicate-plan": extra.write_bytes(b"another plan")
                elif mutation == "missing-receipt": self.receipt.unlink()
                else:
                    changed = dict(receipt)
                    changed["source" if mutation == "source" else "iosTree"] = "f" * 40
                    self.receipt.write_text(json.dumps(changed))
                with self.assertRaises((OSError, ValueError)):
                    self.ns["read_receipt"](SOURCE, TREE, SIMULATOR)
                extra.unlink(missing_ok=True)

    @unittest.skipUnless(os.name == "posix", "Simulator executable inventory uses POSIX absolute paths")
    def test_process_inventory_requires_exact_udid_plist_and_container_family(self):
        current, retained = self.app(), self.app(OTHER_CONTAINER)
        foreign = self.app(simulator="99999999-2222-4333-8444-555555555555")
        inventory = "11 %s/OfflineTikTokPlayer -arg\n12 %s/OfflineTikTokPlayer\n13 %s/OfflineTikTokPlayer\n" % (current, retained, foreign)
        with self.fake_sdk(current, [inventory]) as calls:
            self.assertEqual(self.ns["owned_processes"](SIMULATOR), [11, 12])
        self.assertFalse(any("terminate" in call for call in calls))
        self.assertEqual(calls[0], ["xcrun", "simctl", "get_app_container", SIMULATOR, self.ns["BUNDLE"], "app"])

    @unittest.skipUnless(os.name == "posix", "Simulator executable inventory uses POSIX absolute paths")
    def test_unknown_ownership_fails_before_any_termination(self):
        for mutation in ("bundle", "executable", "udid", "candidate-bundle", "unqualified", "lookup-failure", "ps-failure"):
            with self.subTest(mutation=mutation):
                bundle = self.app(identifier="wrong.bundle" if mutation == "bundle" else None,
                                  executable="Wrong" if mutation == "executable" else None)
                if mutation == "udid": bundle = self.app(simulator="99999999-2222-4333-8444-555555555555")
                inventory = "11 %s/OfflineTikTokPlayer\n" % bundle
                if mutation == "candidate-bundle":
                    bad = self.app(OTHER_CONTAINER, identifier="wrong.bundle")
                    inventory += "12 %s/OfflineTikTokPlayer\n" % bad
                if mutation == "unqualified": inventory += "12 OfflineTikTokPlayer\n"
                with self.fake_sdk(bundle, [inventory], lookup_code=int(mutation == "lookup-failure"),
                                   ps_code=int(mutation == "ps-failure")) as calls:
                    with self.assertRaises((OSError, ValueError)):
                        self.ns["boundary"](SIMULATOR, "before-01")
                self.assertFalse(any("terminate" in call for call in calls))

    @unittest.skipUnless(os.name == "posix", "Simulator executable inventory uses POSIX absolute paths")
    def test_boundary_requires_two_adjacent_absences_and_only_exact_bundle_termination(self):
        bundle = self.app()
        present = "11 %s/OfflineTikTokPlayer\n" % bundle
        label = "after-%02d" % len(self.cases)
        with self.fake_sdk(bundle, [present, "", present, "", ""]) as calls, contextlib.redirect_stdout(io.StringIO()):
            self.ns["boundary"](SIMULATOR, label)
        self.assertEqual(sum(call[0] == "/bin/ps" for call in calls), 5)
        self.assertEqual([call for call in calls if "terminate" in call],
                         [["xcrun", "simctl", "terminate", SIMULATOR, self.ns["BUNDLE"]]])
        with self.fake_sdk(bundle, [present, ""], fallback=present) as calls:
            with self.assertRaises(ValueError):
                self.ns["boundary"](SIMULATOR, label)
        self.assertEqual(sum("terminate" in call for call in calls), 1)

    def test_singleton_logs_reject_wrong_duplicate_and_failed_cases(self):
        name = self.cases[0]
        path = self.ns["raw_log"](1, name)
        good = self.log(name)
        for label, text, accepted in (("valid", good, True), ("wrong", self.log(self.cases[-1]), False),
                                      ("duplicate", good + good, False), ("failed", self.log(name, "failed"), False)):
            with self.subTest(label=label):
                path.write_text(text)
                status, _output = self.mode("verify-one", 1, name)
                self.assertEqual(status == 0, accepted)

    @unittest.skipUnless(os.name == "posix", "The launcher contract uses Bash")
    def test_benchmark_builds_one_immutable_plan_before_testing_and_fails_closed(self):
        shell = HARNESS.read_text(encoding="utf-8").replace("\r\n", "\n")
        payload = shell.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        start = shell.index('if [ "$mode" = benchmark ]; then\n')
        end = shell.index('\nfi\n\ntest_plan=', start) + len('\nfi')
        benchmark = shell[start:end]
        names = shlex.split(re.search(r"benchmark\) cases=\((.*?)\) ;;", shell).group(1))
        self.assertEqual(len(names), 2)
        fake_xcode = '''import json, os, sys
from pathlib import Path
root = Path(os.environ['HARNESS_UNIT_ROOT'])
args = sys.argv[1:]
with (root / 'commands.jsonl').open('a') as stream:
    stream.write(json.dumps(args) + '\\n')
products = root / 'artifacts/DerivedData/Build/Products'
plan = products / 'Owned.xctestrun'
scenario = os.environ['HARNESS_UNIT_SCENARIO']
if 'build-for-testing' in args:
    products.mkdir(parents=True, exist_ok=True)
    if scenario != 'missing': plan.write_bytes(b'original compiled plan\\n')
    if scenario == 'duplicate': (products / 'Other.xctestrun').write_bytes(b'another plan')
    raise SystemExit(23 if scenario == 'build-failure' else 0)
if 'test-without-building' in args:
    if scenario == 'mutated': plan.write_bytes(b'changed after build\\n')
    raise SystemExit(65 if scenario == 'benchmark-failure' else 0)
raise SystemExit(89)
'''
        fake_tee = '''import os, sys
from pathlib import Path
root = Path(os.environ['HARNESS_UNIT_ROOT'])
count = root / 'tee-count'
n = int(count.read_text()) + 1 if count.exists() else 1
count.write_text(str(n))
data = sys.stdin.buffer.read()
Path(sys.argv[1]).write_bytes(data)
sys.stdout.buffer.write(data)
raise SystemExit(17 if os.environ['HARNESS_UNIT_SCENARIO'] == 'tee-failure' and n == 1 else 0)
'''
        scenarios = ("valid", "benchmark-failure", "build-failure", "tee-failure", "missing", "duplicate", "mutated")
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory(dir=self.root) as directory:
                root = Path(directory)
                (root / "artifacts/native").mkdir(parents=True)
                (root / "fake-xcode.py").write_text(fake_xcode)
                (root / "fake-tee.py").write_text(fake_tee)
                preamble = '\n'.join((
                    'set -euo pipefail', 'cd "$HARNESS_UNIT_ROOT"',
                    'mode=benchmark', 'expected_code_source=' + SOURCE, 'expected_ios_tree=' + TREE,
                    'simulator_id=' + SIMULATOR,
                    'native_log=artifacts/native/native-playback-benchmark.log',
                    'cases=(' + ' '.join(shlex.quote(name) for name in names) + ')',
                    'xcodebuild() { "$HARNESS_UNIT_PYTHON" "$HARNESS_UNIT_ROOT/fake-xcode.py" "$@"; }',
                    'tee() { "$HARNESS_UNIT_PYTHON" "$HARNESS_UNIT_ROOT/fake-tee.py" "$@"; }',
                    'evidence_tool() {', '  "$HARNESS_UNIT_PYTHON" - "$@" <<\'PY\'', payload, 'PY', '}', ''))
                script = root / "benchmark.sh"
                script.write_text(preamble + benchmark + '\n')
                environment = dict(os.environ, HARNESS_UNIT_ROOT=str(root), HARNESS_UNIT_PYTHON=sys.executable,
                                   HARNESS_UNIT_SCENARIO=scenario)
                # Only this disposable Bash process is real. Every xcodebuild/tee
                # call is shadowed above; evidence modes perform local file I/O only.
                result = REAL_SUBPROCESS_RUN(['/bin/bash', str(script)], env=environment,
                                             text=True, capture_output=True, timeout=10)
                commands = [json.loads(line) for line in (root / "commands.jsonl").read_text().splitlines()]
                build = commands[0]
                self.assertIn('build-for-testing', build)
                self.assertIn('-project', build); self.assertIn('-scheme', build)
                self.assertIn('-derivedDataPath', build)
                self.assertFalse(any(arg.startswith('-only-testing:') for arg in build))
                for command in commands:
                    self.assertEqual(command[command.index('-jobs') + 1], '1')
                    self.assertEqual(command[command.index('-parallel-testing-enabled') + 1], 'NO')
                    self.assertIn('CODE_SIGNING_ALLOWED=NO', command)
                receipt = root / 'artifacts/native/native-playback-build.json'
                if scenario in ('valid', 'benchmark-failure', 'mutated'):
                    self.assertEqual(len(commands), 2)
                    testing = commands[1]
                    self.assertIn('test-without-building', testing)
                    self.assertNotIn('-project', testing); self.assertNotIn('-scheme', testing)
                    self.assertEqual(testing[testing.index('-xctestrun') + 1],
                                     'artifacts/DerivedData/Build/Products/Owned.xctestrun')
                    self.assertEqual({arg for arg in testing if arg.startswith('-only-testing:')},
                                     {'-only-testing:' + self.ns['PREFIX'].replace('.', '/', 1) + name for name in names})
                else:
                    self.assertEqual(len(commands), 1)
                if scenario in ('valid', 'benchmark-failure'):
                    self.assertEqual(result.returncode, 65 if scenario == 'benchmark-failure' else 0,
                                     result.stdout + result.stderr)
                    saved = json.loads(receipt.read_text())
                    self.assertEqual(saved['benchmarkNativeExit'], result.returncode)
                    self.assertEqual(saved['benchmarkTeeExit'], 0)
                    self.assertEqual(saved['plan']['path'], 'artifacts/DerivedData/Build/Products/Owned.xctestrun')
                else:
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertFalse(receipt.exists(), 'Failed build/plan validation must not authorize controls')
                    if scenario == 'build-failure': self.assertEqual(result.returncode, 23)
                    if scenario == 'tee-failure': self.assertEqual(result.returncode, 17)

    def test_aggregate_rejects_nonzero_missing_and_duplicate_control_receipts(self):
        self.make_receipt()
        rows = []
        for ordinal, name in enumerate(self.cases, 1):
            self.ns["raw_log"](ordinal, name).write_text(self.log(name))
            rows.append([str(ordinal), name, "0", "0", "0", "0"])
        def verify(values):
            self.statuses.write_text("".join("\t".join(row) + "\n" for row in values))
            return self.mode("verify-controls", SOURCE, TREE)[0]
        self.assertEqual(verify(rows), 0)
        for column in range(2, len(rows[0])):
            with self.subTest(status_column=column):
                changed = [row[:] for row in rows]
                changed[0][column] = "65"
                self.assertNotEqual(verify(changed), 0)
        self.assertNotEqual(verify(rows[:-1]), 0)
        self.assertNotEqual(verify(rows[:-1] + [rows[0]]), 0)


if __name__ == "__main__":
    unittest.main()
