"""Portable SDK setup contracts; these never invoke Xcode or claim SDK compatibility."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]


class ProbeSDKTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('probe_sdk', ROOT / 'scripts/check-native-reader-probe-sdk.py')
        self.module = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.module)
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sdk = self.root / 'iPhoneSimulator.sdk'; self.sdk.mkdir()
        self.source = self.root / 'NativeReaderWaitProbe.m'; self.source.write_text('int probe;\n')

    def test_resolved_versionless_and_versioned_sdk_directories_are_accepted(self):
        self.assertEqual(self.module.resolve_sdk(str(self.sdk)), self.sdk.resolve())
        versioned = self.root / 'iPhoneSimulator26.5.sdk'; versioned.mkdir()
        self.assertEqual(self.module.resolve_sdk(str(versioned)), versioned.resolve())

    def test_versioned_alias_resolves_to_versionless_sdk(self):
        alias = self.root / 'iPhoneSimulator26.5.sdk'
        try: alias.symlink_to(self.sdk, target_is_directory=True)
        except OSError as error: self.skipTest('OS cannot create a disposable SDK symlink: ' + type(error).__name__)
        self.assertEqual(self.module.resolve_sdk(str(alias)), self.sdk.resolve())

    def test_unrelated_relative_missing_and_regular_file_paths_are_rejected(self):
        other = self.root / 'MacOSX.sdk'; other.mkdir()
        for path in ['iPhoneSimulator.sdk', str(other), str(self.root / 'iPhoneSimulator27.sdk'), str(self.source)]:
            with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                self.module.resolve_sdk(path)

    def invoke(self, lookup, owned):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(self.module.sys, 'platform', 'darwin'), mock.patch.object(self.module.sys, 'argv', ['probe']), \
             mock.patch.object(self.module, 'SOURCE', self.source), mock.patch.object(self.module.subprocess, 'run', side_effect=lookup), \
             mock.patch.object(self.module, 'load_owned', return_value=owned), mock.patch.object(self.module.signal, 'signal'), \
             contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            code = self.module.cli()
        return code, output.getvalue(), errors.getvalue()

    def test_fixed_owned_compiler_arguments_and_exit_are_preserved(self):
        for exit_code in [0, 65, 124]:
            owned = types.SimpleNamespace(run_owned=mock.Mock(return_value=dict(wrapperExit=exit_code, timedOut=exit_code==124, elapsedMilliseconds=1)))
            lookup = lambda *a, **k: subprocess.CompletedProcess(a[0], 0, str(self.sdk)+'\n', '')
            code, output, errors = self.invoke(lookup, owned)
            self.assertEqual(code, exit_code); self.assertEqual(errors, '')
            args, kwargs = owned.run_owned.call_args
            self.assertEqual(args[1:3], (60, 9)); self.assertEqual(kwargs['stdin'], subprocess.DEVNULL)
            self.assertEqual(args[0], ['xcrun','--sdk','iphonesimulator','clang','-target','arm64-apple-ios26.0-simulator',
                '-isysroot',str(self.sdk.resolve()),'-fobjc-arc','-fmodules','-fsyntax-only','-ferror-limit=12',
                '-Werror=implicit-function-declaration',str(self.source)])
            rows = [json.loads(line.split(' ',1)[1]) for line in output.splitlines()]
            self.assertEqual(rows[-1]['wrapperExit'], exit_code)
            self.assertTrue(all(row['nativeTestsExecuted']==0 for row in rows))

    def test_lookup_timeout_reports_exact_stage_without_launch_or_sensitive_text(self):
        owned = types.SimpleNamespace(run_owned=mock.Mock())
        def timeout(*a, **k): raise subprocess.TimeoutExpired('private-path-or-environment', 15)
        code, output, errors = self.invoke(timeout, owned)
        self.assertEqual(code,2); self.assertEqual(output,''); owned.run_owned.assert_not_called()
        row=json.loads(errors.split(' ',1)[1]); self.assertEqual(row['stage'],'sdk-lookup')
        self.assertEqual(row['errorType'],'TimeoutExpired'); self.assertNotIn('private-path',errors)

    def test_invalid_sdk_reports_path_stage_and_does_not_launch(self):
        owned=types.SimpleNamespace(run_owned=mock.Mock())
        lookup=lambda *a, **k: subprocess.CompletedProcess(a[0],0,'private-relative-path','')
        code, output, errors=self.invoke(lookup,owned)
        self.assertEqual(code,2); owned.run_owned.assert_not_called(); self.assertEqual(output,'')
        row=json.loads(errors.split(' ',1)[1]); self.assertEqual(row['stage'],'sdk-path')
        self.assertNotIn('private-relative-path',errors)


if __name__ == '__main__': unittest.main()
