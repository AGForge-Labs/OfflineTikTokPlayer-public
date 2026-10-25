import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('initial_run', ROOT / 'scripts/enable-initial-main-thread-stack.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class InitialRunTests(unittest.TestCase):
    def run_file(self):
        return {'__xctestrun_metadata__': {'FormatVersion': 1},
                'OfflineTikTokPlayerTests': {'TestBundlePath': '__TESTHOST__/PlugIns/OfflineTikTokPlayerTests.xctest',
                    'EnvironmentVariables': {'existing': 'value'}, 'TestHostPath': '__TESTROOT__/native.app'},
                'OfflineTikTokPlayerUITests': {'EnvironmentVariables': {'existing-ui': 'value'}}}

    def test_only_one_native_environment_value_changes(self):
        value = self.run_file()
        expected = copy.deepcopy(value)
        expected['OfflineTikTokPlayerTests']['EnvironmentVariables']['OP_INITIAL_MAIN_THREAD_STACK'] = '1'
        module.enable(value)
        self.assertEqual(value, expected)

    def test_reject_duplicate_opt_in_without_mutation(self):
        value = self.run_file(); module.enable(value)
        expected = copy.deepcopy(value)
        with self.assertRaises(ValueError): module.enable(value)
        self.assertEqual(value, expected)

    def test_reject_unknown_format_or_target_or_bundle(self):
        variants = [self.run_file() for _ in range(3)]
        variants[0]['__xctestrun_metadata__']['FormatVersion'] = 2
        variants[1]['other'] = {}
        variants[2]['OfflineTikTokPlayerTests']['TestBundlePath'] = 'unowned.xctest'
        for value in variants:
            expected = copy.deepcopy(value)
            with self.subTest(value=value), self.assertRaises(ValueError): module.enable(value)
            self.assertEqual(value, expected)

if __name__ == '__main__': unittest.main()
