import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("isolated_export", ROOT / "scripts/export-native-control-results.py")
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)


class IsolatedResultTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="isolated-export-", dir=ROOT / "artifacts")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.native = self.root / "artifacts/native"
        self.native.mkdir(parents=True)

    def bundle(self, ordinal, stamp="20261023-120000"):
        kind = "build" if ordinal == -1 else ("benchmark" if ordinal == 0 else "control-%s" % ordinal)
        path = self.native / ("Targeted-%s-%s.xcresult" % (kind, stamp))
        path.mkdir()
        return path

    def fake(self, fail=None):
        calls = []
        def run(args, **kwargs):
            self.assertEqual(args[:4], ["xcrun", "xcresulttool", "get", "test-results"])
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertFalse(kwargs["shell"])
            self.assertLessEqual(kwargs["timeout"], 60)
            mode = args[4]
            bundle = Path(args[-1]).name
            calls.append((bundle, mode))
            self.assertTrue(args[-1].startswith(str(self.native) + "/") or Path(args[-1]).parent == self.native)
            kwargs["stdout"].write(json.dumps(dict(mode=mode, bundle=bundle)).encode())
            return types.SimpleNamespace(returncode=9 if fail == (bundle, mode) else 0)
        return run, calls

    def test_exact_five_attempts_export_separate_hash_bound_records(self):
        for ordinal in range(-1, 5):
            self.bundle(ordinal)
        run, calls = self.fake()
        output = io.StringIO()
        self.assertEqual(EXPORT.export(self.root, run=run, monotonic=lambda: 1, stdout=output), 0)
        self.assertEqual(len(calls), 10)
        rows = [json.loads(line[len(EXPORT.PREFIX):]) for line in output.getvalue().splitlines()
                if line.startswith(EXPORT.PREFIX)]
        self.assertEqual({row["ordinal"] for row in rows}, set(range(5)))
        self.assertTrue(all(row["testAcceptance"] is False for row in rows))
        self.assertEqual(len(list(self.native.glob("control-*-xcresult-*.json"))), 10)

    def test_partial_execution_and_child_failure_never_manufacture_missing_results(self):
        self.bundle(0)
        bad = self.bundle(1)
        self.bundle(2)
        run, calls = self.fake((bad.name, "tests"))
        output = io.StringIO()
        self.assertEqual(EXPORT.export(self.root, run=run, monotonic=lambda: 1, stdout=output), 2)
        self.assertEqual(len(calls), 6)
        self.assertFalse((self.native / "control-01-xcresult-summary.json").exists())
        self.assertTrue((self.native / "control-02-xcresult-tests.json").is_file())
        census = json.loads(output.getvalue().splitlines()[-1].split(" ", 1)[1])
        self.assertEqual(census["missing"], [3, 4])
        self.assertEqual(census["completed"], [0, 2])
        self.assertEqual(census["errors"], [dict(ordinal=1, code=3)])
        self.assertFalse(census["complete"])

    def test_stale_duplicate_and_unknown_bundle_inputs_fail_before_sdk_calls(self):
        self.bundle(0)
        self.bundle(0, "20261023-120001")
        with self.assertRaises(EXPORT.BOUNDED.ExportError):
            EXPORT.discover(self.native)
        for path in self.native.iterdir():
            path.rmdir()
        self.bundle(5)
        with self.assertRaises(EXPORT.BOUNDED.ExportError):
            EXPORT.discover(self.native)


if __name__ == "__main__":
    unittest.main()
