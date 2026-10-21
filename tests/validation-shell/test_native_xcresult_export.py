"""Mocked extraction only: no Xcode, SDK, Simulator or real child process."""
import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "export-native-xcresult.py"
BUNDLE = "Tests-20261021-193000.xcresult"


class Clock:
    def __init__(self):
        self.now = 0

    def __call__(self):
        return self.now


class Runner:
    def __init__(self, clock, actions):
        self.clock = clock
        self.actions = list(actions)
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append((command, kwargs))
        action = self.actions.pop(0)
        if isinstance(action, BaseException):
            raise action
        raw, code, seconds = action
        kwargs["stdout"].write(raw)
        self.clock.now += seconds
        return SimpleNamespace(returncode=code)


class NativeXCResultExportTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("native_xcresult_export", SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        # Explicit repository-local fixtures avoid platform temp permissions.
        (ROOT / "artifacts").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="xcresult-unit-", dir=ROOT / "artifacts")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.native = self.root / "artifacts" / "native"
        self.native.mkdir(parents=True)
        self.bundle = self.native / BUNDLE
        self.bundle.mkdir()
        self.clock = Clock()
        self.stdout, self.stderr = io.StringIO(), io.StringIO()
        process_guard = mock.patch.object(self.module.subprocess, "Popen",
                                          side_effect=AssertionError("real processes forbidden"))
        process_guard.start()
        self.addCleanup(process_guard.stop)

    def invoke(self, actions, *, argv=None):
        runner = Runner(self.clock, actions)
        code = self.module.main(["--repo-root", str(self.root)] if argv is None else argv,
                                run=runner, monotonic=self.clock,
                                stdout=self.stdout, stderr=self.stderr)
        return code, runner

    def output_paths(self):
        return [self.native / f"xcresult-{mode}.json" for mode in ("summary", "tests")]

    def assert_failure(self, code, expected):
        self.assertEqual(code, expected)
        self.assertEqual(self.stdout.getvalue(), "")
        self.assertEqual(self.stderr.getvalue(), f"{expected}\n")
        self.assertTrue(all(not path.exists() for path in self.output_paths()))

    def test_exact_commands_and_byte_exact_chunk_roundtrip_with_failed_statuses(self):
        self.assertEqual(self.module.MAX_BYTES, 2 * 1024 * 1024)
        summary = b'{ "status": "Failed", "count": 9 }\n'
        tests = ('[\n{"status":"Failed","detail":"failed 30 assertions",'
                 '"name":"caf\u00e9","padding":"' + "x" * 2100 + '"}\n]\n').encode("utf-8")
        code, runner = self.invoke([(summary, 0, 1), (tests, 0, 2)])
        self.assertEqual(code, 0)
        self.assertEqual(self.stderr.getvalue(), "")
        self.assertEqual(len(runner.calls), 2)
        records = [json.loads(line[len(self.module.PREFIX):])
                   for line in self.stdout.getvalue().splitlines()]
        for number, (mode, raw) in enumerate(zip(("summary", "tests"), (summary, tests))):
            command, kwargs = runner.calls[number]
            self.assertEqual(command, ["xcrun", "xcresulttool", "get", "test-results", mode,
                                       "--path", str(self.bundle)])
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertIs(kwargs["shell"], False)
            self.assertIs(kwargs["check"], False)
            self.assertEqual(kwargs["timeout"], 60)
            self.assertNotEqual(kwargs["stdout"], subprocess.PIPE)
            self.assertTrue(kwargs["stdout"].closed)
            selected = [record for record in records if record["mode"] == mode]
            metadata = selected[0]
            chunks = selected[1:]
            self.assertEqual(metadata["event"], "metadata")
            self.assertEqual(metadata["bundle"], BUNDLE)
            self.assertEqual(metadata["bytes"], len(raw))
            self.assertEqual(metadata["sha256"], hashlib.sha256(raw).hexdigest())
            self.assertEqual(metadata["chunks"], len(chunks))
            self.assertEqual(metadata["childReturnCode"], 0)
            self.assertEqual(metadata["elapsedMilliseconds"], (number + 1) * 1000)
            self.assertEqual([chunk["index"] for chunk in chunks], list(range(len(chunks))))
            self.assertTrue(all(chunk["event"] == "chunk" for chunk in chunks))
            self.assertTrue(all(0 < len(chunk["base64"]) <= 1024 for chunk in chunks))
            restored = base64.b64decode("".join(chunk["base64"] for chunk in chunks), validate=True)
            self.assertEqual(restored, raw)
            self.assertEqual(self.output_paths()[number].read_bytes(), raw)
        self.assertTrue(all(record["testAcceptance"] is False for record in records))
        self.assertNotIn("PASS", self.stdout.getvalue())
        self.assertEqual(json.loads(self.output_paths()[1].read_bytes())[0]["status"], "Failed")

    def test_zero_multiple_malformed_timestamp_and_regular_file_bundles_are_rejected(self):
        self.bundle.rmdir()
        cases = ((), (BUNDLE, "Tests-20261021-193001.xcresult"), (BUNDLE, "Other.xcresult"),
                 ("Other.xcresult",), ("Tests-20260230-193000.xcresult",),
                 ("Tests-20261021-250000.xcresult",), ("Tests-20261021-193000.XCRESULT",))
        for names in cases:
            with self.subTest(names=names):
                for name in names:
                    (self.native / name).mkdir()
                self.stdout.seek(0); self.stdout.truncate()
                self.stderr.seek(0); self.stderr.truncate()
                code, runner = self.invoke([])
                self.assert_failure(code, 2)
                self.assertEqual(runner.calls, [])
                for name in names:
                    (self.native / name).rmdir()
        self.bundle.write_bytes(b"not a directory")
        self.stderr.seek(0); self.stderr.truncate()
        code, runner = self.invoke([])
        self.assert_failure(code, 2)
        self.assertEqual(runner.calls, [])

    def test_symlink_bundle_and_noncanonical_native_ancestor_are_rejected_without_child(self):
        original = self.module.Path.is_symlink
        with mock.patch.object(self.module.Path, "is_symlink", autospec=True,
                               side_effect=lambda path: path == self.bundle or original(path)):
            code, runner = self.invoke([])
        self.assert_failure(code, 2)
        self.assertEqual(runner.calls, [])
        self.stderr.seek(0); self.stderr.truncate()
        resolve = self.module.Path.resolve
        def aliased(path, *args, **kwargs):
            return self.root / "elsewhere" if path == self.native else resolve(path, *args, **kwargs)
        with mock.patch.object(self.module.Path, "resolve", autospec=True, side_effect=aliased):
            code, runner = self.invoke([])
        self.assert_failure(code, 2)
        self.assertEqual(runner.calls, [])

    def test_nonzero_first_or_second_child_is_numeric_and_leaves_no_outputs(self):
        for actions in ([(b'{"raw":"secret diagnostic"}', 65, 1)],
                        [(b"{}", 0, 1), (b'{"status":"Failed"}', 9, 1)]):
            with self.subTest(actions=actions):
                self.stdout.seek(0); self.stdout.truncate()
                self.stderr.seek(0); self.stderr.truncate()
                code, runner = self.invoke(actions)
                self.assert_failure(code, 3)
                self.assertTrue(all(kwargs["stdout"].closed for _, kwargs in runner.calls))

    def test_timeout_is_numeric_and_cleans_first_valid_export(self):
        code, _ = self.invoke([(b"{}", 0, 1),
                               subprocess.TimeoutExpired("private native detail", 60)])
        self.assert_failure(code, 4)

    def test_post_command_deadline_is_checked_even_when_runner_returns_zero(self):
        code, _ = self.invoke([(b"{}", 0, 60)])
        self.assert_failure(code, 4)

    def test_shared_budget_reduces_second_timeout_and_checks_after_validation(self):
        loads = self.module.json.loads
        def expensive_validation(*args, **kwargs):
            value = loads(*args, **kwargs)
            self.clock.now += 2
            return value
        with mock.patch.object(self.module.json, "loads", side_effect=expensive_validation):
            code, runner = self.invoke([(b"{}", 0, 59), (b"[]", 0, 58)])
        self.assert_failure(code, 4)
        self.assertEqual([kwargs["timeout"] for _, kwargs in runner.calls], [60, 59])

    def test_oversized_second_stdout_is_rejected_and_temporary_streams_close(self):
        code, runner = self.invoke([(b"{}", 0, 1),
                                    (b" " * (self.module.MAX_BYTES + 1), 0, 1)])
        self.assert_failure(code, 5)
        self.assertTrue(all(kwargs["stdout"].closed for _, kwargs in runner.calls))

    def test_exact_byte_limit_is_accepted_without_truncation(self):
        raw = b"{}" + b" " * (self.module.MAX_BYTES - 2)
        code, _ = self.invoke([(raw, 0, 1), (b"[]", 0, 1)])
        self.assertEqual(code, 0)
        self.assertEqual(self.stderr.getvalue(), "")
        self.assertEqual(self.output_paths()[0].read_bytes(), raw)

    def test_invalid_utf8_json_scalars_and_non_json_constants_are_rejected(self):
        for raw in (b"\xff", b"{", b"1", b"null", b"true", b'"text"',
                    b'{"value":NaN}', b'{"value":Infinity}', b"[] trailing"):
            with self.subTest(raw=raw):
                self.stdout.seek(0); self.stdout.truncate()
                self.stderr.seek(0); self.stderr.truncate()
                code, _ = self.invoke([(b"{}", 0, 1), (raw, 0, 1)])
                self.assert_failure(code, 6)

    def test_stale_fixed_outputs_are_removed_before_discovery_and_before_children(self):
        for path in self.output_paths():
            path.write_bytes(b'{"stale":true}')
        self.bundle.rmdir()
        code, runner = self.invoke([])
        self.assert_failure(code, 2)
        self.assertEqual(runner.calls, [])
        self.bundle.mkdir()
        self.stderr.seek(0); self.stderr.truncate()
        for path in self.output_paths():
            path.write_bytes(b'{"stale":true}')
        def inspect(command, **kwargs):
            self.assertTrue(all(not path.exists() for path in self.output_paths()))
            kwargs["stdout"].write(b"{}")
            return SimpleNamespace(returncode=3)
        code = self.module.main(["--repo-root", str(self.root)], run=inspect,
                                monotonic=self.clock, stdout=self.stdout, stderr=self.stderr)
        self.assert_failure(code, 3)

    def test_second_fixed_output_write_failure_removes_both_without_console_success(self):
        write_bytes = self.module.Path.write_bytes
        def fail_second(path, raw):
            if path == self.output_paths()[1]:
                raise OSError("private filesystem detail")
            return write_bytes(path, raw)
        with mock.patch.object(self.module.Path, "write_bytes", autospec=True, side_effect=fail_second):
            code, _ = self.invoke([(b"{}", 0, 1), (b"[]", 0, 1)])
        self.assert_failure(code, 7)

    def test_launch_error_and_bad_arguments_are_quiet_numeric_failures(self):
        code, _ = self.invoke([OSError("private launch detail")])
        self.assert_failure(code, 7)
        self.stderr.seek(0); self.stderr.truncate()
        code, runner = self.invoke([], argv=["--unknown", "private argument"])
        self.assert_failure(code, 2)
        self.assertEqual(runner.calls, [])


if __name__ == "__main__":
    unittest.main()
