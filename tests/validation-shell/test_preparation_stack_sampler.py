import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("preparation_sampler", ROOT / "scripts/sample-native-preparation.py")
sampler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sampler)
UDID = "36E2B8D9-F7DC-43ED-8383-C3824D1485A8"


class PreparationSamplerTests(unittest.TestCase):
    def event(self, **updates):
        value = dict(schema=1, bundleIdentifier=sampler.BUNDLE, pid=5497,
                     moduleNonce="4be68eaf-b60b-449d-802c-a12c22302532", simulatorUDID=UDID,
                     testName=sampler.CASE)
        value.update(updates)
        return "NativeRuntimeHost " + json.dumps(value)

    def test_only_the_exact_synthetic_host_is_admitted(self):
        self.assertEqual(sampler.parse_host(self.event(), UDID)["pid"], 5497)
        for changes in [dict(bundleIdentifier="another.app"), dict(pid=True), dict(pid=1),
                        dict(simulatorUDID="46E2B8D9-F7DC-43ED-8383-C3824D1485A8"),
                        dict(moduleNonce="missing"), dict(moduleNonce=None), dict(simulatorUDID=7),
                        dict(schema=2), dict(testName="another test"),
                        dict(extra="unexpected")]:
            with self.subTest(changes=changes):
                with self.assertRaises(ValueError):
                    sampler.parse_host(self.event(**changes), UDID)

    def test_duplicate_or_interleaved_host_headers_are_rejected(self):
        duplicate = self.event().replace('"pid": 5497', '"pid": 5497, "pid": 5498')
        for line in [duplicate, "prefix " + self.event(), self.event() + " suffix"]:
            with self.assertRaises(ValueError):
                sampler.parse_host(line, UDID)

    def test_executable_attestation_cannot_accept_a_same_named_foreign_app(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "one" / "OfflineTikTokPlayer.app"
            other = root / "two" / "OfflineTikTokPlayer.app"
            for directory in [app, other]:
                directory.mkdir(parents=True)
                (directory / "OfflineTikTokPlayer").write_bytes(b"synthetic executable")
            self.assertTrue(sampler.matches_executable(str(app / "OfflineTikTokPlayer"), str(app)))
            self.assertFalse(sampler.matches_executable(str(other / "OfflineTikTokPlayer"), str(app)))
            self.assertFalse(sampler.matches_executable(str(app), str(app)))

    def test_completion_before_observation_cannot_be_called_a_startup_trace(self):
        for status in ["passed", "failed"]:
            self.assertTrue(sampler.target_finished(
                "Test Case '-[OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests "
                + sampler.METHOD + "]' " + status + " (1.000 seconds)."))
        self.assertFalse(sampler.target_finished("Test Case '-[Other testSomething]' passed (1.000 seconds)."))
        self.assertFalse(sampler.target_finished("Test Case '-[OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests "
            + sampler.METHOD + "]' started."))


if __name__ == "__main__":
    unittest.main()
