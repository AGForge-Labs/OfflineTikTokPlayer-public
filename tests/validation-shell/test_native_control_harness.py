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
import textwrap
import types
import unittest
import uuid
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HARNESS = Path(os.environ.get("NATIVE_CONTROL_HARNESS_SOURCE", ROOT / "scripts/check-native-playback-targeted.sh"))
VERIFIER = ROOT / "scripts/verify-native-test-log.py"
CAPTURE_HELPER = Path(os.environ.get("SIMULATOR_CAPTURE_HELPER_SOURCE", ROOT / "scripts/capture-simulator-test-frames.py"))
TARGETED_WORKFLOW = Path(os.environ.get("NATIVE_TARGETED_WORKFLOW_SOURCE", ROOT / ".github/workflows/native-playback-targeted.yml"))
REAL_SUBPROCESS_RUN = subprocess.run
SIMULATOR = "11111111-2222-4333-8444-555555555555"
CONTAINER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
OTHER_CONTAINER = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
SOURCE, TREE = "1" * 40, "2" * 40
NATIVE_TEST_TIMEOUTS = (("-test-timeouts-enabled", "YES"),
                        ("-default-test-execution-time-allowance", "120"),
                        ("-maximum-test-execution-time-allowance", "120"))


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

    def runtime_host(self, name):
        owner = "PlaybackSelectionVideoRegressionTests"
        return dict(schema=1, simulatorUDID=SIMULATOR, pid=31, bundleIdentifier=self.ns["BUNDLE"],
                    moduleNonce=str(uuid.uuid5(uuid.NAMESPACE_URL, "native-control/" + name)),
                    testName="-[%s %s]" % (owner, name))

    def log(self, name, status="passed", runtime=True):
        owner = "OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests"
        receipt = self.runtime_host(name) if runtime is True else runtime
        host = "NativeRuntimeHost " + json.dumps(receipt) + "\n" if receipt is not False else ""
        return ("Test Case '-[%s %s]' started.\n" % (owner, name)
                + host
                + "Test Case '-[%s %s]' %s (0.001 seconds).\n" % (owner, name, status)
                + "** TEST EXECUTE SUCCEEDED **\n")

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
    def fake_sdk(self, bundle, inventories, *, fallback="", lookup_code=0, ps_code=0,
                 app_lookup_code=None, device_payload=None, device_state="Booted"):
        calls, pending = [], iter(inventories)
        if device_payload is None:
            device_payload = {"devices": {"test-runtime": [{"udid": SIMULATOR,
                "dataPath": str(bundle.parents[4]), "state": device_state}]}}
        def run(arguments, **_kwargs):
            calls.append(list(arguments))
            if len(calls) > 128:
                raise AssertionError("Fake command bound exceeded")
            if arguments[:3] == ["xcrun", "simctl", "get_app_container"]:
                code = lookup_code if app_lookup_code is None else app_lookup_code
                return subprocess.CompletedProcess(arguments, code, str(bundle) + "\n", "")
            if arguments == ["xcrun", "simctl", "list", "devices", "--json"]:
                return subprocess.CompletedProcess(arguments, lookup_code, json.dumps(device_payload), "")
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
        self.assertEqual(self.cases, (
            'testNativeReaderWaitSamplingOffFirst',
            'testNativeReaderWaitSamplingOnFirst',
            'testNativeReaderWaitSamplingOnSecond',
            'testNativeReaderWaitSamplingOffSecond'))
        shell = HARNESS.read_text(encoding="utf-8")
        control_names = shlex.split(re.search(r"controls\) cases=\((.*?)\) ;;", shell, re.DOTALL).group(1))
        self.assertEqual(tuple(control_names), self.cases)
        spec = importlib.util.spec_from_file_location("real_native_evidence_unit", VERIFIER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        expected = {self.ns["PREFIX"] + name for name in self.cases}
        self.assertTrue(expected.issubset(module.source_manifest(ROOT)))
        self.ns["verifier"]()
        self.write_manifest(self.cases[:-1])
        with self.assertRaises(ValueError):
            self.ns["verifier"]()
        # Exercise the real helper parser/deadline without SDK commands or waiting.
        capture_spec = importlib.util.spec_from_file_location("native_capture_lifetime_unit", CAPTURE_HELPER)
        capture = importlib.util.module_from_spec(capture_spec)
        capture_spec.loader.exec_module(capture)
        for requested, effective in ((None, 1200), ("60", 60), ("1800", 1800),
                                     ("1801", 1801), ("2400", 2400), ("2401", 2400), ("99999", 2400)):
            with self.subTest(requested=requested):
                argv = ["capture-helper", "--udid", SIMULATOR]
                if requested is not None:
                    argv += ["--lifetime", requested]
                clock = types.SimpleNamespace(
                    monotonic=mock.Mock(side_effect=[100.0, 100.0 + effective, 100.0 + effective]),
                    sleep=mock.Mock(side_effect=AssertionError("Real waiting is forbidden")))
                lifecycle = io.StringIO()
                with mock.patch.object(sys, "argv", argv), mock.patch.object(capture, "time", clock), \
                        mock.patch.object(capture, "locate", side_effect=AssertionError("SDK lookup is forbidden")) as lookup, \
                        contextlib.redirect_stdout(lifecycle):
                    self.assertEqual(capture.main(), 0)
                    self.assertEqual(capture.DEADLINE, 100.0 + effective)
                    lookup.assert_not_called()
                    clock.sleep.assert_not_called()
                events = [json.loads(line.split(" ", 1)[1]) for line in lifecycle.getvalue().splitlines()]
                self.assertEqual([event["eventCode"] for event in events], [0, 1])
                self.assertEqual(events[-1]["reasonCode"], 1)
                self.assertEqual(events[-1]["elapsedSeconds"], effective)
        for invalid in ("0", "-1", "nan", "inf"):
            with self.subTest(invalid_lifetime=invalid):
                with mock.patch.object(sys, "argv", ["capture-helper", "--udid", SIMULATOR, "--lifetime", invalid]), \
                        contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as rejected:
                    capture.main()
                self.assertEqual(rejected.exception.code, 2)

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
        self.assertEqual(calls[0], ["xcrun", "simctl", "list", "devices", "--json"])

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

    @unittest.skipUnless(os.name == "posix", "Simulator executable inventory uses POSIX absolute paths")
    def test_absent_app_without_container_lookup_can_prove_two_absent_hosts(self):
        data = self.root / "Devices" / SIMULATOR / "data"
        data.mkdir(parents=True)
        bundle = data / "Containers/Bundle/Application" / CONTAINER / "OfflineTikTokPlayer.app"
        self.assertFalse(bundle.exists())
        for state in ("Booted", "Shutdown"):
            with self.subTest(state=state):
                output = io.StringIO()
                with self.fake_sdk(bundle, ["", "", ""], app_lookup_code=1, device_state=state) as calls, \
                        contextlib.redirect_stdout(output):
                    self.ns["boundary"](SIMULATOR, "before-01")
                self.assertEqual(sum(call[0] == "/bin/ps" for call in calls), 3)
                self.assertEqual(sum(call[:4] == ["xcrun", "simctl", "list", "devices"] for call in calls), 3)
                self.assertFalse(any("terminate" in call or "get_app_container" in call for call in calls))
                self.assertNotIn(str(self.root), output.getvalue())
                self.assertRegex(output.getvalue(), r"NativeControlOwnership deviceLookupRC=0 stateCode=[0-9]+ psRC=0 categoryCode=[0-9]+")

    @unittest.skipUnless(os.name == "posix", "Simulator executable inventory uses POSIX absolute paths")
    def test_unknown_device_family_or_candidate_never_authorizes_termination(self):
        bundle = self.app()
        data = bundle.parents[4]
        device = {"udid": SIMULATOR, "dataPath": str(data), "state": "Shutdown"}
        for mutation in ("missing-device", "duplicate-device", "wrong-tail", "symlink-data", "family-alias", "missing-plist", "quoted-process"):
            with self.subTest(mutation=mutation):
                self.app()
                selected = dict(device)
                inventory = "11 %s/OfflineTikTokPlayer\n" % bundle
                devices = [selected]
                link = self.root / "data-link"
                alias = self.root / "application-alias"
                if mutation == "missing-device": devices = []
                elif mutation == "duplicate-device": devices.append(dict(selected))
                elif mutation == "wrong-tail": selected["dataPath"] = str(self.root)
                elif mutation == "symlink-data":
                    link.symlink_to(data, target_is_directory=True)
                    selected["dataPath"] = str(link)
                elif mutation == "family-alias":
                    alias.symlink_to(data / "Containers/Bundle/Application", target_is_directory=True)
                    inventory = "11 %s/%s/OfflineTikTokPlayer.app/OfflineTikTokPlayer\n" % (alias, CONTAINER)
                elif mutation == "missing-plist": (bundle / "Info.plist").unlink()
                elif mutation == "quoted-process": inventory = '11 "%s/OfflineTikTokPlayer"\n' % bundle
                with self.fake_sdk(bundle, [inventory], device_payload={"devices": {"test-runtime": devices}}) as calls:
                    with self.assertRaises((OSError, ValueError)):
                        self.ns["boundary"](SIMULATOR, "before-01")
                self.assertFalse(any("terminate" in call for call in calls))
                link.unlink(missing_ok=True)
                alias.unlink(missing_ok=True)

    def test_singleton_logs_reject_wrong_duplicate_and_failed_cases(self):
        self.make_receipt()
        name = self.cases[0]
        path = self.ns["raw_log"](1, name)
        good = self.log(name)
        for label, text, accepted in (("valid", good, True), ("wrong", self.log(self.cases[-1]), False),
                                      ("duplicate", good + good, False), ("failed", self.log(name, "failed"), False),
                                      ("wrong-invocation", good.replace("** TEST EXECUTE SUCCEEDED **", "** TEST SUCCEEDED **"), False)):
            with self.subTest(label=label):
                path.write_text(text)
                status, _output = self.mode("verify-one", 1, name, SOURCE, TREE, SIMULATOR)
                self.assertEqual(status == 0, accepted)

    def test_runtime_host_receipt_binds_exact_case_device_bundle_and_process(self):
        self.make_receipt()
        name = self.cases[0]
        path = self.ns["raw_log"](1, name)
        good = self.runtime_host(name)
        invalid = [("missing", self.log(name, runtime=False)),
                   ("duplicate", self.log(name).replace("** TEST EXECUTE SUCCEEDED **",
                    "NativeRuntimeHost " + json.dumps(good) + "\n** TEST EXECUTE SUCCEEDED **")),
                   ("malformed", self.log(name, runtime=False).replace("** TEST EXECUTE SUCCEEDED **",
                    "NativeRuntimeHost {broken}\n** TEST EXECUTE SUCCEEDED **"))]
        for field, value in (("simulatorUDID", "unknown"), ("simulatorUDID", CONTAINER),
                             ("simulatorUDID", SIMULATOR.replace("-", "")),
                             ("bundleIdentifier", "dev.wrong.App"), ("testName", self.cases[-1]),
                             ("pid", 0), ("pid", -1), ("pid", True), ("pid", 2147483648),
                             ("pid", "31"), ("moduleNonce", "unknown"), ("schema", True)):
            changed = dict(good); changed[field] = value
            invalid.append((field + "=" + str(value), self.log(name, runtime=changed)))
        changed = dict(good); del changed["testName"]
        invalid.append(("missing-field", self.log(name, runtime=changed)))
        changed = dict(good); changed["extra"] = "not permitted"
        invalid.append(("extra-field", self.log(name, runtime=changed)))
        duplicate_key = json.dumps(good)[:-1] + ', "pid": 31}'
        invalid.append(("duplicate-json-key", self.log(name, runtime=False).replace("** TEST EXECUTE SUCCEEDED **",
                        "NativeRuntimeHost " + duplicate_key + "\n** TEST EXECUTE SUCCEEDED **")))
        for label, text in [("valid", self.log(name))] + invalid:
            with self.subTest(label=label):
                path.write_text(text)
                status, output = self.mode("verify-one", 1, name, SOURCE, TREE, SIMULATOR)
                self.assertEqual(status, 0 if label == "valid" else 2, output)

    def test_qualified_runtime_host_does_not_replace_native_case_evidence(self):
        self.make_receipt()
        name = self.cases[0]
        path = self.ns["raw_log"](1, name)
        for label, text in (("failed", self.log(name, "failed")), ("skipped", self.log(name, "skipped")),
                            ("missing-terminal", self.log(name).replace(" passed (0.001 seconds).", " unfinished.")),
                            ("missing-success", self.log(name).replace("** TEST EXECUTE SUCCEEDED **", "")),
                            ("wrong-native-module", self.log(name).replace(
                                "Test Case '-[OfflineTikTokPlayerTests.", "Test Case '-[WrongModule."))):
            with self.subTest(label=label):
                path.write_text(text)
                status, _output = self.mode("verify-one", 1, name, SOURCE, TREE, SIMULATOR)
                self.assertEqual(status, 1)

    def test_observed_runtime_basename_receipt_and_exact_name_guards(self):
        # Retained F run39632207053 line2671: self.name omits the module,
        # while the independent XCTest terminal identity retains its module.
        name = "testProductionSelectionLatencyAndStreamingContinuityWithoutCapture"
        identity = self.ns["PREFIX"] + name
        observed = dict(schema=1, simulatorUDID="6EEDD2B9-6E06-4333-91B6-8661FDCCBA47", pid=6749,
                        bundleIdentifier="dev.galaxybigbird.OfflineTikTokPlayer",
                        moduleNonce="0f8a21a3-02e6-4e7e-b86c-c12f75a52462",
                        testName="-[PlaybackSelectionVideoRegressionTests " + name + "]")
        for prefix in ("", "2026-10-21T16:13:50.2195340Z "):
            with self.subTest(prefix=bool(prefix)):
                parsed = self.ns["runtime_host"](prefix + "NativeRuntimeHost " + json.dumps(observed),
                                                  identity, observed["simulatorUDID"])
                self.assertEqual(parsed["pid"], observed["pid"])
                self.assertEqual(parsed["moduleNonce"], observed["moduleNonce"])
        for wrong in ("-[OtherClass " + name + "]",
                      "-[PlaybackSelectionVideoRegressionTests testDifferentMethod]",
                      "-[OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests " + name + "]",
                      "-[PlaybackSelectionVideoRegressionTests " + name + "] trailing",
                      "[PlaybackSelectionVideoRegressionTests " + name + "]",
                      "-[PlaybackSelectionVideoRegressionTests " + name + " extra]"):
            with self.subTest(testName=wrong):
                changed = dict(observed, testName=wrong)
                with self.assertRaises(ValueError):
                    self.ns["runtime_host"]("NativeRuntimeHost " + json.dumps(changed),
                                            identity, observed["simulatorUDID"])

    def test_probe_sdk_preflight_must_pass_before_any_native_work(self):
        workflow = TARGETED_WORKFLOW.read_text(encoding="utf-8")
        blocks = re.split(r'^      - name: ', workflow, flags=re.MULTILINE)
        probe = [block for block in blocks if 'id: probe_sdk\n' in block]
        self.assertEqual(len(probe), 1)
        self.assertIn('run: python3 scripts/check-native-reader-probe-sdk.py', probe[0])
        native = [block for block in blocks if any(block.startswith(name) for name in (
            'Resolve within', 'Build one exact', 'Require the actual', 'Four context-only',
            'Require all four', 'Export each exact'))]
        self.assertEqual(len(native), 6)
        for block in native:
            condition = re.search(r'^        if: (.+)$', block, re.MULTILINE)
            self.assertIsNotNone(condition)
            self.assertIn("steps.source_pin.outcome == 'success'", condition.group(1))
            self.assertIn("steps.probe_sdk.outcome == 'success'", condition.group(1))
        self.assertLess(workflow.index('id: probe_sdk'), workflow.index('- name: Resolve within'))

    @unittest.skipUnless(os.name == "posix", "The launcher contract uses Bash")
    def test_benchmark_builds_one_immutable_plan_before_testing_and_fails_closed(self):
        shell = HARNESS.read_text(encoding="utf-8").replace("\r\n", "\n")
        payload = shell.split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
        start = shell.index('if [ "$mode" = benchmark ]; then\n')
        end = shell.index('\nfi\n\ntest_plan=', start) + len('\nfi')
        benchmark = shell[start:end]
        names = shlex.split(re.search(r"benchmark\) cases=\((.*?)\) ;;", shell, re.DOTALL).group(1))
        expected_selectors = ['OfflineTikTokPlayerTests/ContinuousPCMDecoderTests/testSameRetainedAssetAdmissionWaitsForActualRetiredReaderClose']
        self.assertEqual(names, expected_selectors)
        workflow = TARGETED_WORKFLOW.read_text(encoding="utf-8")
        self.assertEqual(re.findall(r'^\s*timeout-minutes:\s*(\d+)\s*$', workflow, re.MULTILINE), ['50'])
        # Execute only the workflow's expected-set/source-membership guard.
        # No imports, log reads, SDK invocation, or arbitrary workflow run body.
        scope = re.search(r'^          prefix = .*?(?=^          evidence\.verify_log\()',
                          workflow, re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(scope)
        scope = textwrap.dedent(scope.group(0))
        expected_identities = {selector.replace('/', '.', 1) for selector in expected_selectors}
        evidence = types.SimpleNamespace(source_manifest=lambda _root: expected_identities)
        namespace = dict(evidence=evidence, Path=Path)
        exec(compile(scope, str(TARGETED_WORKFLOW), 'exec'), namespace)
        self.assertEqual(namespace['expected'], expected_identities)
        for missing in expected_identities:
            with self.subTest(workflow_missing_identity=missing), self.assertRaises(SystemExit):
                evidence = types.SimpleNamespace(source_manifest=lambda _root: expected_identities - {missing})
                exec(compile(scope, str(TARGETED_WORKFLOW), 'exec'), dict(evidence=evidence, Path=Path))
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
                    for flag, value in NATIVE_TEST_TIMEOUTS:
                        self.assertEqual(testing.count(flag), 1)
                        index = testing.index(flag)
                        self.assertEqual(testing[index:index + 2], [flag, value])
                    self.assertNotIn('-project', testing); self.assertNotIn('-scheme', testing)
                    self.assertEqual(testing[testing.index('-xctestrun') + 1],
                                     'artifacts/DerivedData/Build/Products/Owned.xctestrun')
                    self.assertEqual([arg for arg in testing if arg.startswith('-only-testing:')],
                                     ['-only-testing:' + selector for selector in expected_selectors])
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

    def test_aggregate_rejects_reused_runtime_process_nonce(self):
        self.make_receipt()
        rows = []
        for ordinal, name in enumerate(self.cases, 1):
            self.ns["raw_log"](ordinal, name).write_text(self.log(name))
            rows.append([str(ordinal), name, "0", "0", "0", "0"])
        self.statuses.write_text("".join("\t".join(row) + "\n" for row in rows))
        self.assertEqual(self.mode("verify-controls", SOURCE, TREE)[0], 0)
        changed = self.runtime_host(self.cases[1])
        changed["moduleNonce"] = self.runtime_host(self.cases[0])["moduleNonce"]
        self.ns["raw_log"](2, self.cases[1]).write_text(self.log(self.cases[1], runtime=changed))
        self.assertNotEqual(self.mode("verify-controls", SOURCE, TREE)[0], 0)

    @unittest.skipUnless(os.name == "posix", "The launcher contract uses Bash")
    def test_unknown_runtime_identity_stops_later_controls_after_boundary_and_status(self):
        shell = HARNESS.read_text(encoding="utf-8").replace("\r\n", "\n")
        capture = re.search(r'^python3 scripts/capture-simulator-test-frames\.py --udid "\$simulator_id" --lifetime \d+ &$',
                            shell, re.MULTILINE)
        self.assertIsNotNone(capture, "The controls require their exact bounded capture-helper launch")
        capture_launch = capture.group(0) + "\ncapture_pid=$!\n"
        start = shell.index('for name in "${cases[@]}"; do\n')
        end = shell.index('\ndone\n', start) + len('\ndone')
        loop = shell[start:end]
        for verify_status in (1, 2):
            with self.subTest(verify_status=verify_status), tempfile.TemporaryDirectory(dir=self.root) as directory:
                root = Path(directory)
                controls = root / "artifacts/native/native-playback-controls"
                controls.mkdir(parents=True)
                preamble = '\n'.join((
                    'set -euo pipefail', 'cd "$HARNESS_UNIT_ROOT"',
                    'expected_code_source=' + SOURCE, 'expected_ios_tree=' + TREE,
                    'simulator_id=' + SIMULATOR, 'test_plan=unused', 'overall_status=0', 'ordinal=0',
                    'cases=(' + ' '.join(shlex.quote(name) for name in self.cases) + ')',
                    'xcodebuild() { printf "launch %s\\n" "$ordinal" >> events; '
                    'printf "%s\\n" "$@" > "xcode-args-$ordinal"; return 65; }',
                    'tee() { while IFS= read -r line; do :; done; }',
                    'python3() { printf "%s\\n" "$@" > capture-args; }',
                    'evidence_tool() {', '  case "$1" in',
                    '    read-plan) return 0 ;;',
                    '    verify-one) printf "verify %s\\n" "$ordinal" >> events; return "$HARNESS_UNIT_VERIFY_STATUS" ;;',
                    '    boundary) printf "boundary %s\\n" "$ordinal" >> events; return 0 ;;',
                    '    *) return 91 ;;', '  esac', '}', ''))
                script = root / "control-loop.sh"
                script.write_text(preamble + capture_launch + loop + '\nwait "$capture_pid"\n')
                environment = dict(os.environ, HARNESS_UNIT_ROOT=str(root),
                                   HARNESS_UNIT_VERIFY_STATUS=str(verify_status))
                result = REAL_SUBPROCESS_RUN(['/bin/bash', str(script)], env=environment,
                                             text=True, capture_output=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                expected = 1 if verify_status == 2 else len(self.cases)
                self.assertEqual((root / "capture-args").read_text().splitlines(),
                                 ["scripts/capture-simulator-test-frames.py", "--udid", SIMULATOR, "--lifetime", "2400"])
                events = (root / "events").read_text().splitlines()
                self.assertEqual(events, [event + " " + str(ordinal)
                    for ordinal in range(1, expected + 1) for event in ("launch", "verify", "boundary")])
                rows = (controls / "statuses.tsv").read_text().splitlines()
                self.assertEqual(len(rows), expected)
                for row in rows:
                    self.assertEqual(row.split('\t')[2:], ["65", "0", str(verify_status), "0"])
                for ordinal in range(1, expected + 1):
                    arguments = (root / ("xcode-args-%d" % ordinal)).read_text().splitlines()
                    self.assertIn("test-without-building", arguments)
                    for flag, value in NATIVE_TEST_TIMEOUTS:
                        self.assertEqual(arguments.count(flag), 1)
                        index = arguments.index(flag)
                        self.assertEqual(arguments[index:index + 2], [flag, value])


if __name__ == "__main__":
    unittest.main()
