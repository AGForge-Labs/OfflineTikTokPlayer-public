"""Post-test evidence export contracts; fake native tools never open an xcresult."""
import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/export-compositor-evidence.py"
SHA = "a" * 40
IOS_TREE = "f15663a48e48fe25fb66d5506042a1ce49c91459"
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6WQAAAAASUVORK5CYII=")
NATIVE_JSON = b'{"unknownAppleManifestShape":[{"name":"synthetic capture"}]}\n'


class CompositorEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("compositor_evidence", SCRIPT)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="compositor-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.native = self.root / "artifacts/native"
        self.native.mkdir(parents=True)
        self.bundle = self.native / "StartupGrace-20261021-120000.xcresult"
        self.bundle.mkdir()
        self.output = self.root / "artifacts/compositor-evidence"
        self.environment = dict(GITHUB_ACTIONS="true", GITHUB_SERVER_URL="https://github.com",
                                GITHUB_REPOSITORY="AGForge-Labs/OfflineTikTokPlayer-public",
                                GITHUB_WORKSPACE=str(self.root), RUNNER_OS="macOS",
                                RUNNER_ENVIRONMENT="github-hosted", GITHUB_SHA=SHA,
                                GITHUB_RUN_ID="39564560391", GITHUB_RUN_ATTEMPT="2")
        self.calls = []
        self.head = SHA
        self.tree = IOS_TREE
        self.help = b"USAGE: xcresulttool export attachments --path <path> --output-path <path>\n"
        self.help_status = 0
        self.export_status = 0
        self.payloads = {"capture.png": PNG, "manifest.json": NATIVE_JSON}
        self.export_hook = None
        self.export_roots = []

    def runner(self, argv, *, timeout_seconds, export_root=None):
        self.calls.append((list(argv), timeout_seconds, export_root))
        self.assertGreater(timeout_seconds, 0)
        self.assertLessEqual(timeout_seconds, 60)
        if argv[:2] == ["/usr/bin/git", "-C"]:
            self.assertEqual(argv[2], str(self.root))
            value = self.tree if argv[-1] == "HEAD:ios" else self.head
            return subprocess.CompletedProcess(argv, 0, (value + "\n").encode())
        self.assertEqual(argv[:4], ["/usr/bin/xcrun", "xcresulttool", "export", "attachments"])
        if argv[-1] == "--help":
            return subprocess.CompletedProcess(argv, self.help_status, self.help)
        self.assertEqual(argv[4:], ["--path", str(self.bundle), "--output-path", str(export_root)])
        self.assertNotIn("--test-id", argv)
        self.assertIsNotNone(export_root)
        export_root = Path(export_root)
        self.assertTrue(export_root.is_dir())
        self.assertEqual(list(export_root.iterdir()), [])
        self.export_roots.append(export_root)
        for name, data in self.payloads.items():
            path = export_root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        if self.export_hook:
            self.export_hook(export_root)
        return subprocess.CompletedProcess(argv, self.export_status, b"native output is not published\n")

    def export(self):
        return self.module.export_evidence(self.root, self.environment,
                                           runner=self.runner, platform_name="Darwin")

    def assert_rejected(self):
        with self.assertRaises(self.module.EvidenceError) as caught:
            self.export()
        self.assertGreater(caught.exception.status_code, 0)
        self.assertFalse(self.output.exists(), "Rejected or partial evidence must not be uploadable")
        self.assertTrue(all(not path.exists() for path in self.export_roots))

    def test_preserves_original_png_and_attributes_native_bytes_without_mapping_labels(self):
        result = self.export()
        saved = json.loads((self.output / "evidence-manifest.json").read_text())
        self.assertEqual(result, saved)
        for key, value in dict(schemaVersion=1, sourceSHA=SHA, iosTree=IOS_TREE,
                               runID="39564560391", runAttempt="2",
                               repository=self.environment["GITHUB_REPOSITORY"],
                               resultBundle="artifacts/native/" + self.bundle.name,
                               nativeMetadataInterpreted=False).items():
            self.assertEqual(saved[key], value)
        files = {entry["path"]: entry for entry in saved["files"]}
        for name, data in self.payloads.items():
            relative = "attachments/" + name
            self.assertEqual((self.output / relative).read_bytes(), data)
            self.assertEqual(files[relative]["sha256"], hashlib.sha256(data).hexdigest())
            self.assertEqual(files[relative]["bytes"], len(data))
        self.assertEqual(files["attachments/capture.png"]["format"], "png")
        self.assertEqual(files["attachments/manifest.json"]["format"], "json")
        self.assertEqual(len(files), 2)
        self.assertTrue(all(not path.exists() for path in self.export_roots))

    def test_rejects_untrusted_execution_or_attribution_before_native_tool(self):
        bad = dict(GITHUB_ACTIONS="false", GITHUB_SERVER_URL="https://other.invalid",
                   GITHUB_REPOSITORY="AGForge-Labs/private", RUNNER_OS="Linux",
                   RUNNER_ENVIRONMENT="self-hosted", GITHUB_SHA="bad",
                   GITHUB_RUN_ID="0", GITHUB_RUN_ATTEMPT="../2", GITHUB_WORKSPACE="/elsewhere")
        for key, value in bad.items():
            with self.subTest(key=key), mock.patch.dict(self.environment, {key: value}):
                self.calls.clear()
                self.assert_rejected()
                self.assertFalse(any(call[0][0] == "/usr/bin/xcrun" for call in self.calls))
        self.head = "b" * 40
        self.assert_rejected()
        self.head, self.tree = SHA, "c" * 40
        self.assert_rejected()
        with self.assertRaises(self.module.EvidenceError):
            self.module.export_evidence(self.root, self.environment,
                                         runner=self.runner, platform_name="Windows")

    def test_requires_one_scoped_bundle_and_fresh_output(self):
        self.bundle.rmdir()
        outside = self.root / "StartupGrace-outside.xcresult"
        outside.mkdir()
        self.assert_rejected()
        self.bundle.mkdir()
        second = self.native / "StartupGrace-other.xcresult"
        second.mkdir()
        self.assert_rejected()
        second.rmdir()
        self.output.mkdir()
        existing = self.output / "previous.png"
        existing.write_bytes(PNG)
        with self.assertRaises(self.module.EvidenceError):
            self.export()
        self.assertEqual(existing.read_bytes(), PNG, "Do not overwrite or delete pre-existing evidence")

    def test_requires_installed_help_capability_and_successful_native_export(self):
        original_help = self.help
        for help_bytes, help_status, export_status in ((b"unsupported", 0, 0),
                                                      (original_help, 1, 0),
                                                      (original_help, 0, 7)):
            with self.subTest(help_status=help_status, export_status=export_status):
                self.help, self.help_status, self.export_status = help_bytes, help_status, export_status
                self.assert_rejected()

    def test_rejects_unknown_types_format_mismatch_and_missing_metadata(self):
        original = self.payloads.copy()
        cases = ({"extra.txt": b"not metadata"}, {"capture.png": b"not PNG"},
                 {"capture.jpeg": PNG}, {"manifest.json": b"not JSON"},
                 {"nested/opaque.bin": b"unknown"})
        for changes in cases:
            with self.subTest(changes=list(changes)):
                self.payloads = dict(original, **changes)
                self.assert_rejected()
        self.payloads = {"capture.png": PNG}
        self.assert_rejected()
        self.payloads = {"manifest.json": NATIVE_JSON}
        self.assert_rejected()

    def test_rejects_casefold_collision_with_controlled_directory_entries(self):
        directory = self.root / "case-collision"
        directory.mkdir()
        paths = [directory / "capture.png", directory / "CAPTURE.PNG"]
        for path in paths:
            path.write_bytes(PNG)
        # Windows resolves these spellings to one file; case-sensitive hosts
        # create distinct inodes, so removing casefold rejection fails there.
        entries = [mock.Mock(path=str(path)) for path in paths]
        @contextlib.contextmanager
        def listing(path):
            self.assertEqual(Path(path), directory)
            yield iter(entries)
        with mock.patch.object(self.module.os, "scandir", listing):
            with self.assertRaises(self.module.EvidenceError):
                self.module._inventory(directory)
        # Restore real scandir before the fixture's directory cleanup.

    def test_format_rejection_reports_numeric_reason_without_names_or_contents(self):
        original = self.payloads.copy()
        cases = (
            ({"capture.png": b"private"}, 1, 1, 1, 7),
            ({"extra-private.txt": b"private"}, 2, 3, 2, 7),
            ({"extra-private.jpeg": PNG}, 2, 4, 2, len(PNG)),
            ({"extra-private.secret": b"private"}, 2, 0, 2, 7),
        )
        for changes, reason, format_code, ordinal, size in cases:
            with self.subTest(reason=reason, format_code=format_code):
                self.payloads = dict(original, **changes)
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    with self.assertRaises(self.module.EvidenceError) as caught:
                        self.export()
                self.assertEqual(caught.exception.status_code, 6)
                rows = [row for row in output.getvalue().splitlines()
                        if row.startswith("CompositorEvidenceFormat ")]
                self.assertEqual(rows, [f"CompositorEvidenceFormat rejectionCode={reason} "
                                        f"formatCode={format_code} ordinal={ordinal} bytes={size}"])
                self.assertNotIn("private", output.getvalue())
                self.assertFalse(self.output.exists())
                self.assertTrue(all(not path.exists() for path in self.export_roots))

    def test_enforces_image_file_count_per_file_and_total_retained_caps(self):
        original = self.payloads.copy()
        self.payloads = {f"{index}.png": PNG for index in range(25)}
        self.payloads["manifest.json"] = NATIVE_JSON
        self.assert_rejected()
        self.payloads = {f"{index}.json": b"{}" for index in range(32)}
        self.payloads["capture.png"] = PNG
        self.assert_rejected()
        self.payloads = original
        def too_large(directory):
            with (directory / "capture.png").open("r+b") as stream:
                stream.truncate(8 * 1024 * 1024 + 1)
        self.export_hook = too_large
        self.assert_rejected()
        def total_too_large(directory):
            for index in range(4):
                path = directory / f"large-{index}.png"
                path.write_bytes(PNG)
                with path.open("r+b") as stream:
                    stream.truncate(8 * 1024 * 1024)
        self.export_hook = total_too_large
        self.assert_rejected()

    def test_rejects_export_symlinks_and_path_escape(self):
        outside = self.root / "unrelated.png"
        outside.write_bytes(PNG)
        def symbolic(directory):
            try:
                (directory / "escaped.png").symlink_to(outside)
            except OSError as error:
                self.skipTest(f"OS does not permit unprivileged symlink: {error.__class__.__name__}")
        self.export_hook = symbolic
        self.assert_rejected()
        self.assertEqual(outside.read_bytes(), PNG)

    def test_rejects_duplicate_inodes_without_requiring_symlink_privileges(self):
        def linked(directory):
            os.link(directory / "capture.png", directory / "duplicate.png")
        self.export_hook = linked
        self.assert_rejected()

    def test_rejects_bundle_symlink(self):
        self.bundle.rmdir()
        target = self.root / "unrelated.xcresult"
        target.mkdir()
        try:
            self.bundle.symlink_to(target, target_is_directory=True)
        except OSError as error:
            self.skipTest(f"OS does not permit unprivileged symlink: {error.__class__.__name__}")
        self.assert_rejected()

    def test_rejects_windows_reparse_attributes_without_symlink_privileges(self):
        original = Path.lstat
        def reparse(path, *args, **kwargs):
            result = original(path, *args, **kwargs)
            if path == self.native:
                proxy = mock.Mock(wraps=result)
                proxy.st_mode, proxy.st_file_attributes = result.st_mode, 0x400
                return proxy
            return result
        with mock.patch.object(Path, "lstat", reparse):
            self.assert_rejected()

    def test_native_timeout_or_os_failure_never_publishes_partial_output(self):
        for error in (subprocess.TimeoutExpired("native", 1), FileNotFoundError("private/path")):
            def failed(argv, *, timeout_seconds, export_root=None):
                if argv[0] == "/usr/bin/xcrun":
                    raise error
                return self.runner(argv, timeout_seconds=timeout_seconds, export_root=export_root)
            with self.subTest(error=type(error).__name__), self.assertRaises(self.module.EvidenceError):
                self.module.export_evidence(self.root, self.environment,
                                             runner=failed, platform_name="Darwin")
            self.assertFalse(self.output.exists())

    def test_real_runner_bounds_stdout_timeout_and_export_file_growth(self):
        result = self.module.run_bounded([sys.executable, "-c", "raise SystemExit(7)"],
                                          timeout_seconds=2)
        self.assertEqual(result.returncode, 7)
        programs = ("import time; time.sleep(2)",
                    "import sys; sys.stdout.buffer.write(b'x' * (1024 * 1024)); sys.stdout.flush()")
        for program in programs:
            with self.subTest(program=program), self.assertRaises(self.module.EvidenceError):
                self.module.run_bounded([sys.executable, "-c", program], timeout_seconds=0.2)
        export_root = self.root / "bounded-export"
        export_root.mkdir()
        program = ("from pathlib import Path; import sys,time; p=Path(sys.argv[1]); "
                   "[(p / str(n)).touch() for n in range(40)]; time.sleep(2)")
        with self.assertRaises(self.module.EvidenceError):
            self.module.run_bounded([sys.executable, "-c", program, str(export_root)],
                                     timeout_seconds=1, export_root=export_root)

    def test_cli_failure_prints_fixed_numeric_status_without_native_output_or_paths(self):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(self.module, "export_evidence", side_effect=self.module.EvidenceError(9)), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            result = self.module.main()
        self.assertEqual(result, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertEqual(errors.getvalue(), "CompositorEvidence statusCode=9\n")


if __name__ == "__main__":
    unittest.main()
