"""Synthetic crash evidence checks; no SDK calls.

Run on POSIX with FD/O_NOFOLLOW support.
Override PREROLL_PARSER_MODULE_PATH, PREROLL_COLLECTOR_MODULE_PATH and
PREROLL_EXPORTER_MODULE_PATH for final reviewed public module locations.
"""

from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
UDID = "11111111-2222-4333-8444-555555555555"
START = datetime(2026, 10, 22, 2, 19, 37, tzinfo=timezone.utc)
NONCES = ("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222")
ATTACHMENT_HELP = (
    b"OPTIONS:\n  --path <path> Result bundle.\n"
    b"  --output-path <output-path> Local output.\n"
    b"  --test-id <test-id> The test identifier.\n"
    b"  --only-failures Export only failures.\n"
)
HELP = {
    (): b"SUBCOMMANDS:\n  export Export result data.\n",
    ("export",): b"SUBCOMMANDS:\n  attachments Export attachments.\n",
    ("export", "attachments"): ATTACHMENT_HELP,
}


def load_module(name, environment, fallback):
    path = Path(os.environ.get(environment, str(fallback))).resolve(strict=True)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class PrototypeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The import boundary is guarded too; no candidate import may launch an SDK.
        with mock.patch("subprocess.Popen", side_effect=AssertionError("real child forbidden")):
            cls.p = load_module("preroll_parser_tested", "PREROLL_PARSER_MODULE_PATH",
                                ROOT / "scripts" / "preroll-crash-excerpt.py")
            cls.c = load_module("preroll_collector_tested", "PREROLL_COLLECTOR_MODULE_PATH",
                                ROOT / "scripts" / "export-preroll-crash-evidence.py")
            cls.e = load_module("preroll_exporter_tested", "PREROLL_EXPORTER_MODULE_PATH",
                                ROOT / "scripts" / "export-native-xcresult.py")

    def setUp(self):
        guard = mock.patch("subprocess.Popen", side_effect=AssertionError("real child forbidden"))
        self.popen_guard = guard.start()
        self.addCleanup(guard.stop)
        self.ids = self.p.CASE_IDS

    def binding(self, ordinal=0):
        return self.p.CaseBinding(self.ids[ordinal], 101 + ordinal, NONCES[ordinal], START)

    def body(self, ordinal=0, frames=None):
        frames = frames if frames is not None else [
            {"imageIndex": 1, "imageOffset": 123, "symbol": "swift_task_dealloc", "symbolLocation": 7},
            {"imageIndex": 0, "imageOffset": 456},  # Missing symbol must remain explicit.
        ]
        return {
            "pid": 101 + ordinal, "bundleInfo": {"CFBundleIdentifier": self.p.BUNDLE_ID},
            "procLaunch": (START - timedelta(seconds=30)).isoformat(),
            "captureTime": (START + timedelta(seconds=9)).isoformat(), "faultingThread": 1,
            "exception": {"type": "EXC_CRASH", "signal": "SIGABRT", "codes": "0x0, 0x0"},
            "termination": {"namespace": "SIGNAL", "code": 6, "flags": 0},
            "threads": [
                {"triggered": False, "frames": [{"imageIndex": 0, "imageOffset": 1, "symbol": "DECOY_THREAD"}]},
                {"triggered": True, "frames": frames, "threadState": {"private": "DO_NOT_EMIT"}},
            ],
            "lastExceptionBacktrace": [{"imageIndex": 0, "imageOffset": 789, "symbol": "synthetic_throw"}],
            "usedImages": [{"name": "OfflineTikTokPlayer", "path": "/private/DO_NOT_EMIT"},
                           {"name": "libswift_Concurrency.dylib"}],
            "crashReporterKey": "DO_NOT_EMIT", "procPath": "/private/DO_NOT_EMIT",
            "asi": {"CoreFoundation": ["DO_NOT_EMIT"]},
        }

    def raw(self, body=None, metadata=None):
        metadata = metadata if metadata is not None else {
            "bug_type": "309", "platform": 7, "bundleID": self.p.BUNDLE_ID}
        return (json.dumps(metadata) + "\n" + json.dumps(body if body is not None else self.body())).encode()

    def parsed(self, raws, ordinal=0):
        result = self.p.parse_case_ips(raws, self.binding(ordinal), case_scoped_export_confirmed=True)
        return result, json.loads(result)

    def host(self, ordinal=0):
        return {"schema": 1, "testName": self.c.CASE_NAMES[self.ids[ordinal]], "pid": 101 + ordinal,
                "bundleIdentifier": self.p.BUNDLE_ID, "simulatorUDID": UDID,
                "moduleNonce": NONCES[ordinal], "caseStartUTC": START.isoformat()}

    def log(self, records=None):
        records = records if records is not None else [self.host(0), self.host(1)]
        return b"unrelated native output\n" + b"".join(
            b"NativeRuntimeHost " + json.dumps(record).encode() + b"\n" for record in records)

    def nodes(self):
        return {"devices": [{"deviceId": UDID, "platform": "iOS Simulator"}],
                "testNodes": [{"name": "Synthetic suite", "children": [
                    {"nodeIdentifier": case_id, "nodeIdentifierURL": "test://DO_NOT_USE_URL/" + str(index),
                     "name": case_id.split("/", 1)[1], "nodeType": "Test Case", "result": "Failed"}
                    for index, case_id in enumerate(self.ids)]}]}

    @contextmanager
    def repository(self, log=None):
        with tempfile.TemporaryDirectory(prefix="preroll-unittest-") as directory:
            root = Path(directory).resolve()
            native = root / "artifacts" / "native"
            native.mkdir(parents=True)
            (native / "Tests-20261022-020638.xcresult").mkdir()
            (native / "xcresult-tests.json").write_text(json.dumps(self.nodes()), encoding="utf-8")
            (native / "xcodebuild-test.log").write_bytes(log if log is not None else self.log())
            yield root, native

    def fake_xcode(self, attachment_help=ATTACHMENT_HELP):
        calls = []

        def run(argv, root, work, deadline, limit, case_roots, parser, owner, **_):
            calls.append(tuple(argv))
            if argv[-1] == "--help":
                branch = tuple(argv[2:-1])
                return 0, attachment_help if branch == ("export", "attachments") else HELP[branch]
            self.assertEqual(argv[:4], ["xcrun", "xcresulttool", "export", "attachments"])
            self.assertEqual(argv[-1], "--only-failures")
            selector = argv[argv.index("--test-id") + 1]
            self.assertIn(selector, self.ids)
            self.assertNotIn("test://", selector)
            ordinal = self.ids.index(selector)
            output = Path(argv[argv.index("--output-path") + 1])
            (output / "synthetic.ips").write_bytes(self.raw(self.body(ordinal)))
            (output / "unread.crash").write_bytes(b"DO_NOT_EMIT_UNSUPPORTED_CRASH_CONTENT")
            return 0, b"DO_NOT_ECHO_EXPORT_STDOUT"

        return calls, run

    def test_01_two_objects_selects_faulting_and_qualified_language_frames(self):
        encoded, result = self.parsed([self.raw()])
        self.assertEqual(result["availability"], "available")
        self.assertEqual(result["faultingThreadIndex"], 1)
        self.assertEqual(result["faultingThread"]["frames"][0]["module"], "libswift_Concurrency.dylib")
        self.assertEqual(result["faultingThread"]["frames"][1]["symbolAvailability"], "missing")
        self.assertEqual(result["lastExceptionBacktrace"]["qualification"],
                         "documentationTableTypeString_runtimeValidatedFrameArray")
        self.assertNotIn(b"DECOY_THREAD", encoded)
        self.assertNotIn(b"DO_NOT_EMIT", encoded)
        self.assertFalse(result["testAcceptance"])

    def test_02_attribution_filters_and_duplicate_matching_are_unavailable(self):
        wrong_pid = self.body(); wrong_pid["pid"] = 999
        wrong_bundle = self.body(); wrong_bundle["bundleInfo"]["CFBundleIdentifier"] = "synthetic.foreign"
        late = self.body(); late["captureTime"] = (START + timedelta(seconds=121)).isoformat()
        early_launch = self.body(); early_launch["procLaunch"] = (START + timedelta(seconds=1)).isoformat()
        for raw in [self.raw(wrong_pid), self.raw(wrong_bundle), self.raw(late), self.raw(early_launch)]:
            with self.subTest(kind=hashlib.sha256(raw).hexdigest()[:8]):
                self.assertEqual(self.parsed([raw])[1]["availability"], "unavailable")
        duplicate = self.parsed([self.raw(), self.raw()])[1]
        self.assertEqual(duplicate["reason"], "ambiguous-attributed-reports")

    def test_03_unknown_schema_and_language_shapes_do_not_guess(self):
        bad_header = {"bug_type": 309, "platform": 7, "bundleID": self.p.BUNDLE_ID}
        self.assertEqual(self.parsed([self.raw(metadata=bad_header)])[1]["availability"], "unavailable")
        duplicate_key = self.raw().replace(b'"bug_type": "309"', b'"bug_type": "309", "bug_type": "309"', 1)
        self.assertEqual(self.parsed([duplicate_key])[1]["availability"], "unavailable")
        for value, shape, count in [("DO_NOT_EMIT", "string", 11), ({"private": "DO_NOT_EMIT"}, "object", 1),
                                    ([{"imageIndex": 999, "imageOffset": 1}], "array", 1)]:
            with self.subTest(shape=shape):
                body = self.body(); body["lastExceptionBacktrace"] = value
                encoded, result = self.parsed([self.raw(body)])
                self.assertEqual(result["availability"], "available")
                language = result["lastExceptionBacktrace"]
                self.assertEqual((language["actualShape"], language["actualCount"]), (shape, count))
                self.assertEqual(language["availability"], "unavailable")
                self.assertNotIn(b"DO_NOT_EMIT", encoded)

    def test_04_output_bound_is_valid_json_with_explicit_prefix_truncation(self):
        frame = {"imageIndex": 0, "imageOffset": 50, "symbol": "synthetic_" + "s" * 1000}
        frames = [dict(frame) for _ in range(180)]  # Duplicate frames must not break prefix retention.
        outputs = []
        for ordinal in range(2):
            body = self.body(ordinal, frames)
            body["lastExceptionBacktrace"] = frames
            encoded, result = self.parsed([self.raw(body)], ordinal)
            self.assertLessEqual(len(encoded), 64 * 1024)
            self.assertTrue(encoded.endswith(b"\n"))
            self.assertTrue(result["truncated"])
            for key in ("faultingThread", "lastExceptionBacktrace"):
                excerpt = result[key]
                self.assertGreater(excerpt["retainedFrameCount"], 1)
                self.assertLess(excerpt["retainedFrameCount"], excerpt["frameCount"])
                self.assertEqual(len(excerpt["frames"]), excerpt["retainedFrameCount"])
            outputs.append(encoded)
        self.assertLessEqual(sum(map(len, outputs)), 128 * 1024)

    def test_05_input_caps_and_unclassified_extra_report_fail_closed(self):
        self.assertEqual(self.parsed([b"x" * (self.p.MAX_IPS_BYTES + 1)])[1]["availability"], "unavailable")
        aggregate = [b"x" * self.p.MAX_IPS_BYTES for _ in range(9)]
        self.assertEqual(self.parsed(aggregate)[1]["reason"], "input-budget")
        self.assertEqual(self.parsed([self.raw(), b"not json"])[1]["reason"], "unclassified-report")

    def test_06_fresh_host_start_repeats_consistently_or_is_rejected(self):
        good = self.c._bindings(self.log([self.host(0), self.host(0), self.host(1)]), UDID, self.p)
        self.assertEqual(set(good), set(self.ids))
        self.assertEqual(good[self.ids[0]].case_start_utc, START)
        for field, value in [("caseStartUTC", (START + timedelta(seconds=1)).isoformat()),
                             ("pid", 404), ("moduleNonce", NONCES[1])]:
            changed = self.host(0); changed[field] = value
            with self.subTest(field=field), self.assertRaises(self.c.Unavailable):
                self.c._bindings(self.log([self.host(0), changed, self.host(1)]), UDID, self.p)
        missing = self.host(0); del missing["caseStartUTC"]
        with self.assertRaises(self.c.Unavailable):
            self.c._bindings(self.log([missing, self.host(1)]), UDID, self.p)

    def aq_suffix(self, pid=101):
        return ("2026-10-22 02:19:37.123456+0000 OfflineTikTokPlayer[%d:321] [AQ]"
                "        LoudnessManager.mm:1215  IsHardwareSupported: no plist loaded, returning false"
                % pid).encode("ascii")

    def test_06a_exact_prior_receipt_with_known_same_pid_aq_is_discarded(self):
        payload = json.dumps(self.host(0)).encode()
        duplicate = b"NativeRuntimeHost " + payload + self.aq_suffix() + b"\n"
        log = self.log([self.host(0)]) + duplicate + self.log([self.host(1)])
        stream = io.BytesIO(); output = self.c.Output(stream)
        result = self.c._bindings(log, UDID, self.p, output=output)
        self.assertEqual(set(result), set(self.ids))
        self.assertEqual((result[self.ids[0]].pid, result[self.ids[1]].pid), (101, 102))
        self.assertEqual(result[self.ids[0]].case_start_utc, START)
        rows = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["event"], "host-receipt-recovery")
        self.assertEqual((rows[0]["count"], rows[0]["firstNativeLogLine"],
                          rows[0]["priorNativeLogLine"]), (1, 3, 2))
        self.assertEqual(rows[0]["firstInputSHA256"],
                         hashlib.sha256(payload + self.aq_suffix()).hexdigest())
        self.assertFalse(rows[0]["testAcceptance"])
        self.assertNotIn(b"LoudnessManager", stream.getvalue())

    def test_06b_suffix_recovery_rejects_first_conflicting_and_unrecognized_receipts(self):
        payload = json.dumps(self.host(0)).encode()
        line = b"NativeRuntimeHost " + payload
        suffix = self.aq_suffix()
        changed = self.host(0); changed["pid"] = 404
        changed_nonce = self.host(0); changed_nonce["moduleNonce"] = NONCES[1]
        changed_start = self.host(0); changed_start["caseStartUTC"] = (START + timedelta(seconds=1)).isoformat()
        bad_lines = [
            line + b" arbitrary suffix", line + b"{}", line + b" " + suffix,
            line + self.aq_suffix(102), line + suffix + b"{}", line + suffix + b" trailing",
            line + suffix.replace(b"[AQ]", b"[Fig]"),
            line + suffix.replace(b"mm:1215", b"mm:1216"),
            line + suffix.replace(b"2026-10-22", b"2026-13-22"),
            line + suffix.replace(b"+0000", b"+0100"), line + b"\xff",
            b"NativeRuntimeHost " + json.dumps(changed).encode() + self.aq_suffix(404),
            b"NativeRuntimeHost " + json.dumps(changed_nonce).encode() + suffix,
            b"NativeRuntimeHost " + json.dumps(changed_start).encode() + suffix,
            b"NativeRuntimeHost " + json.dumps(self.host(0), separators=(",", ":")).encode() + suffix,
        ]
        for bad in bad_lines:
            with self.subTest(input=hashlib.sha256(bad).hexdigest()[:8]):
                stream = io.BytesIO()
                with self.assertRaises(self.c.Unavailable) as failure:
                    self.c._bindings(self.log([self.host(0)]) + bad + b"\n" + self.log([self.host(1)]),
                                     UDID, self.p, output=self.c.Output(stream))
                self.assertEqual(failure.exception.reason, "invalid-json")
                metadata = json.loads(stream.getvalue())
                self.assertEqual(metadata["stage"], "native-host-receipt-json")
                self.assertEqual(metadata["nativeLogLine"], 3)
                self.assertEqual(metadata["inputSHA256"],
                                 hashlib.sha256(bad[len(b"NativeRuntimeHost "):]).hexdigest())
        # A later clean receipt cannot retroactively validate the first malformed one.
        with self.assertRaises(self.c.Unavailable) as failure:
            self.c._bindings(line + suffix + b"\n" + self.log(), UDID, self.p)
        self.assertEqual(failure.exception.reason, "invalid-json")

    def test_06c_recovered_duplicates_still_obey_original_host_caps(self):
        line = b"NativeRuntimeHost " + json.dumps(self.host(0)).encode()
        for log in [self.log() + (line + self.aq_suffix() + b"\n") * 1023,
                    self.log() + line + self.aq_suffix() + b"x" * 8193 + b"\n"]:
            with self.subTest(bytes=len(log)), self.assertRaises(self.c.Unavailable) as failure:
                self.c._bindings(log, UDID, self.p)
            self.assertEqual(failure.exception.reason, "host-receipt-limit")

    def test_06d_fake_export_recovery_and_early_json_failure_provenance(self):
        line = b"NativeRuntimeHost " + json.dumps(self.host(0)).encode()
        log = self.log([self.host(0)]) + line + self.aq_suffix() + b"\n" + self.log([self.host(1)])
        calls, runner = self.fake_xcode()
        stream = io.BytesIO()
        with self.repository(log) as (root, _):
            records = self.c.collect(root, UDID, True, self.c.Output(stream),
                                     parser=self.p, exporter=self.e, run_child=runner)
        self.assertEqual(len(calls), 5)
        self.assertTrue(all(json.loads(record)["availability"] == "available" for record in records))
        metadata = [json.loads(row) for row in stream.getvalue().splitlines()]
        self.assertEqual(sum(row["event"] == "host-receipt-recovery" for row in metadata), 1)
        self.assertTrue(any(row["event"] == "collection-provenance" for row in metadata))
        calls.clear(); stream = io.BytesIO()
        with self.repository() as (root, native):
            (native / "xcresult-tests.json").write_bytes(b"{")
            with self.assertRaises(self.c.Unavailable) as failure:
                self.c.collect(root, UDID, True, self.c.Output(stream),
                               parser=self.p, exporter=self.e, run_child=runner)
        self.assertEqual(failure.exception.reason, "invalid-json")
        self.assertEqual(calls, [])
        metadata = json.loads(stream.getvalue())
        self.assertEqual(metadata["stage"], "xcresult-tests-json")
        self.assertIsNone(metadata["nativeLogLine"])
        self.assertEqual(metadata["inputSHA256"], hashlib.sha256(b"{").hexdigest())
        self.popen_guard.assert_not_called()

    def test_07_exact_returned_nodes_and_destination_are_required(self):
        found = self.c._nodes(self.nodes(), UDID)
        self.assertEqual(tuple(sorted(found)), tuple(sorted(self.ids)))
        for case_id in self.ids:
            self.assertEqual(found[case_id]["nodeIdentifier"], case_id)
        foreign = self.nodes(); foreign["devices"][0]["deviceId"] = NONCES[0]
        duplicate = self.nodes(); duplicate["testNodes"][0]["children"].append(
            dict(duplicate["testNodes"][0]["children"][0]))
        for document in (foreign, duplicate):
            with self.subTest(document="foreign-or-duplicate"), self.assertRaises(self.c.Unavailable):
                self.c._nodes(document, UDID)

    def test_08_active_help_semantics_and_bounds_fail_closed(self):
        owner = {"child": None, "cleanup_ok": True}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            for text, valid in [(ATTACHMENT_HELP, True),
                                (ATTACHMENT_HELP.replace(b"The test identifier.", b"An opaque lookup key."), False),
                                (ATTACHMENT_HELP.replace(b"--only-failures", b"--other"), False),
                                (b"x" * (self.c.HELP_BYTES + 1), False)]:
                calls, runner = self.fake_xcode(text)
                stream = io.BytesIO(); output = self.c.Output(stream)
                clock = Clock()
                with self.subTest(valid=valid, bytes=len(text)):
                    if valid:
                        rule = self.c._discover_help(runner, path, path, 60, self.p, owner, output, clock)
                        self.assertEqual(rule, "literal-returned-nodeIdentifier")
                        evidence = json.loads(stream.getvalue())
                        self.assertEqual(evidence["stdoutSHA256"], hashlib.sha256(text).hexdigest())
                        self.assertLessEqual(evidence["stdoutBytes"], 8 * 1024)
                    else:
                        with self.assertRaises(self.c.Unavailable):
                            self.c._discover_help(runner, path, path, 60, self.p, owner, output, clock)
                    self.assertEqual(len(calls), 3)
                    self.assertTrue(all(call[-1] == "--help" for call in calls))

    def test_09_full_fake_export_preserves_scope_provenance_and_local_cleanup(self):
        calls, runner = self.fake_xcode()
        stream = io.BytesIO(); output = self.c.Output(stream)
        with self.repository() as (root, native):
            records = self.c.collect(root, UDID, True, output, parser=self.p, exporter=self.e, run_child=runner)
            output.cases(records)
            rows = [json.loads(line) for line in stream.getvalue().splitlines()]
            self.assertEqual(len(calls), 5)
            self.assertEqual([call[call.index("--test-id") + 1] for call in calls if "--test-id" in call],
                             list(self.ids))
            self.assertEqual({row["caseID"] for row in rows if "caseID" in row}, set(self.ids))
            self.assertTrue(all(not row["testAcceptance"] for row in rows))
            self.assertTrue(all(json.loads(raw)["availability"] == "available" for raw in records))
            provenance = next(row for row in rows if row.get("event") == "collection-provenance")
            self.assertFalse(provenance["instantaneousFilesystemQuota"])
            self.assertEqual(provenance["ipsCandidateFiles"], 2)
            self.assertEqual(provenance["exportFileTypes"], {"ips": 2, "crash": 2, "json": 0, "txt": 0, "other": 0})
            self.assertEqual(provenance["testsSHA256"],
                             hashlib.sha256((native / "xcresult-tests.json").read_bytes()).hexdigest())
            self.assertEqual(list(native.glob("preroll-crash-*")), [])
        self.assertNotIn(b"DO_NOT_EMIT", stream.getvalue())
        self.assertNotIn(b"DO_NOT_ECHO_EXPORT_STDOUT", stream.getvalue())
        self.assertLessEqual(output.metadata_used, self.c.METADATA_BYTES)
        self.assertLessEqual(sum(map(len, records)), 128 * 1024)
        self.popen_guard.assert_not_called()

    def test_public_module_paths_load_without_injected_support_modules(self):
        calls, runner = self.fake_xcode()
        with self.repository() as (root, _):
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "preroll-crash-excerpt.py").write_bytes(Path(self.p.__file__).read_bytes())
            (scripts / "export-native-xcresult.py").write_bytes(Path(self.e.__file__).read_bytes())
            records = self.c.collect(root, UDID, True, self.c.Output(io.BytesIO()), run_child=runner)
            self.assertEqual([json.loads(row)["availability"] for row in records], ["available", "available"])
            self.assertEqual(len(calls), 5)
        self.popen_guard.assert_not_called()

    def test_10_missing_export_or_start_never_exports_and_cli_remains_diagnostic(self):
        calls, runner = self.fake_xcode()
        missing = self.host(0); del missing["caseStartUTC"]
        with self.repository(self.log([missing, self.host(1)])) as (root, _):
            for exported in (False, True):
                with self.subTest(exported=exported), self.assertRaises(self.c.Unavailable):
                    self.c.collect(root, UDID, exported, self.c.Output(io.BytesIO()),
                                   parser=self.p, exporter=self.e, run_child=runner)
            self.assertEqual(calls, [])
            stream = io.BytesIO()
            with mock.patch.object(self.c.sys, "platform", "darwin"):
                code = self.c.main(["--repo-root", str(root), "--simulator-udid", UDID], stream=stream)
            self.assertEqual(code, 0)
            rows = [json.loads(line) for line in stream.getvalue().splitlines()]
            self.assertEqual(len(rows), 2)
            self.assertTrue(all(row["testAcceptance"] is False and row["availability"] == "unavailable"
                                for row in rows))
        self.popen_guard.assert_not_called()

    def test_11_real_fd_walk_rejects_symlink_entry_and_byte_caps(self):
        self.assertTrue(hasattr(os, "O_NOFOLLOW") and hasattr(os, "O_DIRECTORY"),
                        "Run FD tests under the requested WSL/POSIX environment")
        for mode in ("symlink", "entries", "bytes"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                base = Path(directory).resolve(); root = base / "case"; root.mkdir()
                if mode == "symlink":
                    target = base / "outside.ips"; target.write_bytes(self.raw())
                    (root / "link.ips").symlink_to(target)
                elif mode == "entries":
                    for index in range(self.c.ENTRY_LIMIT + 1):
                        (root / str(index)).touch()
                else:
                    with (root / "synthetic-large.bin").open("wb") as stream:
                        stream.truncate(self.c.EXPORT_BYTES + 1)
                info = root.stat()
                with self.assertRaises(self.c.Unavailable):
                    self.c._scan(((self.ids[0], root, (info.st_dev, info.st_ino)),),
                                 self.p.MAX_IPS_BYTES, read=True)

    def test_12_owned_timeout_escalates_and_reaps_only_the_fake_child_group(self):
        clock = Clock(); alive = {"group": True}; signals = []
        child = mock.Mock(pid=45454, returncode=None)
        child.poll.side_effect = lambda: child.returncode

        def wait(timeout=None):
            if child.returncode is None:
                raise subprocess.TimeoutExpired("synthetic-child", timeout)
            return child.returncode

        def killpg(pid, sent_signal):
            self.assertEqual(pid, child.pid)
            if not alive["group"]:
                raise ProcessLookupError()
            if sent_signal:
                signals.append(sent_signal)
                if sent_signal == signal.SIGKILL:
                    alive["group"] = False
                    child.returncode = -9

        child.wait.side_effect = wait
        owner = {"child": None, "cleanup_ok": True}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory).resolve()
            with mock.patch.object(self.c.subprocess, "Popen", return_value=child) as launch, \
                    mock.patch.object(self.c.os, "killpg", side_effect=killpg), \
                    mock.patch.object(self.c.time, "sleep", side_effect=clock.sleep):
                with self.assertRaises(self.c.Unavailable) as failure:
                    self.c._owned_child(["synthetic-child"], path, path, 0.05, 8192, (),
                                        self.p, owner, monotonic=clock)
                self.assertEqual(failure.exception.reason, "child-timeout")
                self.assertEqual(signals, [signal.SIGTERM, signal.SIGKILL])
                self.assertTrue(owner["cleanup_ok"])
                self.assertIsNone(owner["child"])
                self.assertTrue(launch.call_args.kwargs["start_new_session"])
                self.assertFalse(launch.call_args.kwargs["shell"])
                self.assertEqual(launch.call_args.kwargs["stderr"], subprocess.DEVNULL)
        child.wait.assert_called()
        self.assertLessEqual(clock.now, 1.1)


if __name__ == "__main__":
    unittest.main()
