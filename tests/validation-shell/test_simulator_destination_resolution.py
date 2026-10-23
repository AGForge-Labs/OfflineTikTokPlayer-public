"""Bounded destination bootstrap; fake SDK responses, no process or wait."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
IDENTIFIER = "11111111-2222-4333-8444-555555555555"
OTHER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
DESTINATION = "platform=iOS Simulator,id=" + IDENTIFIER


class SimulatorDestinationResolutionTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location(
            "destination_unit", ROOT / "scripts/capture-simulator-test-frames.py")
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.clock = patch.object(self.module.time, "monotonic", return_value=1000.0)
        self.clock.start()
        self.addCleanup(self.clock.stop)
        self.calls = []

    def listing(self, *, identifier=IDENTIFIER, available=True, name="iPhone 17 Pro Max"):
        return {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
            {"udid": identifier, "isAvailable": available, "name": name, "state": "Booted"}]}}

    def backend(self, payload=None, *, duration=0, status=0, raw=None):
        if payload is None:
            payload = self.listing()

        def invoke(command, *, capture_output, text, timeout, check):
            self.calls.append((command, timeout))
            self.assertTrue(capture_output)
            self.assertTrue(text)
            self.assertFalse(check)
            if duration > timeout:
                raise subprocess.TimeoutExpired(command, timeout)
            return subprocess.CompletedProcess(command, status,
                stdout=json.dumps(payload) if raw is None else raw, stderr="")

        return patch.object(self.module.subprocess, "run", side_effect=invoke)

    def test_thirty_second_exact_device_list_resolves_with_one_bounded_query(self):
        with self.backend(duration=30):
            self.assertEqual(self.module.resolve_destination(DESTINATION), IDENTIFIER)
        self.assertEqual(self.calls, [(["xcrun", "simctl", "list", "devices", "available", "--json"], 60)])

    def test_query_exceeding_sixty_seconds_times_out_without_retry_or_fallback(self):
        with self.backend(duration=61), self.assertRaises(subprocess.TimeoutExpired) as failure:
            self.module.resolve_destination(DESTINATION)
        self.assertEqual(failure.exception.timeout, 60)
        self.assertEqual(len(self.calls), 1)

    def test_existing_shared_deadline_still_caps_bootstrap_query(self):
        self.module.DEADLINE = 1007.5
        with self.backend(duration=8), self.assertRaises(subprocess.TimeoutExpired) as failure:
            self.module.resolve_destination(DESTINATION)
        self.assertEqual(failure.exception.timeout, 7.5)
        self.assertEqual(len(self.calls), 1)

    def test_expired_deadline_prevents_sdk_call(self):
        self.module.DEADLINE = 1000.0
        with self.backend(), self.assertRaises(subprocess.TimeoutExpired):
            self.module.resolve_destination(DESTINATION)
        self.assertEqual(self.calls, [])

    def test_runtime_capture_lookup_keeps_fifteen_second_default(self):
        with self.backend(duration=16), self.assertRaises(subprocess.TimeoutExpired) as failure:
            self.module.run("list", "devices", "booted", "--json")
        self.assertEqual(failure.exception.timeout, 15)
        self.assertEqual(self.calls[0][1], 15)

    def test_wrong_uuid_unavailable_device_and_non_ios_runtime_are_rejected(self):
        for payload in [self.listing(identifier=OTHER), self.listing(available=False),
                        {"devices": {"com.apple.CoreSimulator.SimRuntime.tvOS-26-5":
                                     next(iter(self.listing()["devices"].values()))}}]:
            with self.subTest(payload=payload), self.backend(payload), self.assertRaises(ValueError):
                self.module.resolve_destination(DESTINATION)

    def test_exact_name_os_and_identifier_constraints_are_all_retained(self):
        for suffix in [",name=Other", ",OS=25.0", ",OS=invalid"]:
            with self.subTest(suffix=suffix), self.backend(), self.assertRaises(ValueError):
                self.module.resolve_destination(DESTINATION + suffix)
        with self.backend():
            self.assertEqual(self.module.resolve_destination(DESTINATION + ",name=iPhone 17 Pro Max,OS=26.5"), IDENTIFIER)

    def test_ambiguous_name_is_rejected_and_latest_runtime_selection_is_retained(self):
        payload = self.listing()
        runtime = next(iter(payload["devices"]))
        payload["devices"][runtime].append(dict(payload["devices"][runtime][0], udid=OTHER))
        with self.backend(payload), self.assertRaises(ValueError):
            self.module.resolve_destination("platform=iOS Simulator,name=iPhone 17 Pro Max")
        payload["devices"][runtime].pop()
        payload["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-26-4"] = [
            dict(payload["devices"][runtime][0], udid=OTHER)]
        with self.backend(payload):
            self.assertEqual(self.module.resolve_destination("platform=iOS Simulator,name=iPhone 17 Pro Max"), IDENTIFIER)

    def test_failed_or_malformed_list_does_not_return_an_identifier(self):
        for arguments in [{"status": 1}, {"raw": "not-json"}]:
            with self.subTest(arguments=arguments), self.backend(**arguments), self.assertRaises(ValueError):
                self.module.resolve_destination(DESTINATION)

    def test_cli_stdout_remains_only_exact_identifier(self):
        output = io.StringIO()
        with self.backend(duration=30), patch.object(sys,
                "argv", ["capture-simulator-test-frames.py", "--resolve-destination", DESTINATION]), contextlib.redirect_stdout(output):
            self.assertEqual(self.module.main(), 0)
        self.assertEqual(output.getvalue(), IDENTIFIER + "\n")


    def lifecycle_rows(self, output):
        prefix = "SimulatorCaptureLifecycle "
        rows = []
        for line in output.getvalue().splitlines():
            self.assertTrue(line.startswith(prefix))
            row = json.loads(line[len(prefix):])
            self.assertEqual(set(row), {"schema", "eventCode", "reasonCode", "startUptime",
                "deadlineUptime", "effectiveLifetimeSeconds", "observedUptime", "elapsedSeconds"})
            self.assertTrue(all(type(value) in (int, float) for value in row.values()))
            self.assertEqual(row["schema"], 1)
            rows.append(row)
        self.assertNotIn(IDENTIFIER, output.getvalue())
        self.assertNotIn("PRIVATE", output.getvalue())
        return rows

    def test_capture_lifecycle_deadline_and_cap_require_no_discovery(self):
        for requested, effective in [(1800, 1800), (999999, 3600)]:
            with self.subTest(requested=requested):
                output = io.StringIO()
                with patch.object(sys, "argv", ["capture-simulator-test-frames.py",
                        "--udid", IDENTIFIER, "--lifetime", str(requested)]), \
                     patch.object(self.module.time, "monotonic",
                                  side_effect=[1000.0, 1000.0 + effective, 1000.0 + effective]), \
                     patch.object(self.module.time, "sleep", side_effect=AssertionError("no wait")), \
                     patch.object(self.module, "locate", side_effect=AssertionError("no discovery")) as locate, \
                     patch.object(self.module.subprocess, "run", side_effect=AssertionError("no SDK")) as run, \
                     contextlib.redirect_stdout(output):
                    self.assertEqual(self.module.main(), 0)
                rows = self.lifecycle_rows(output)
                self.assertEqual(len(rows), 2)
                self.assertEqual([(row["eventCode"], row["reasonCode"]) for row in rows], [(0, 0), (1, 1)])
                self.assertEqual([row["effectiveLifetimeSeconds"] for row in rows], [effective, effective])
                self.assertEqual([row["startUptime"] for row in rows], [1000.0, 1000.0])
                self.assertEqual([row["deadlineUptime"] for row in rows], [1000.0 + effective] * 2)
                self.assertEqual([row["elapsedSeconds"] for row in rows], [0, effective])
                self.assertEqual(self.module.DEADLINE, 1000.0 + effective)
                locate.assert_not_called(); run.assert_not_called()

    def test_capture_start_precedes_discovery_and_exit_does_not_hide_python_failure(self):
        for failure, reason in [(KeyboardInterrupt(), 3), (RuntimeError("PRIVATE"), 2)]:
            with self.subTest(reason=reason):
                output = io.StringIO()
                def lookup(_):
                    rows = self.lifecycle_rows(output)
                    self.assertEqual([(row["eventCode"], row["reasonCode"]) for row in rows], [(0, 0)])
                    raise failure
                with patch.object(sys, "argv", ["capture-simulator-test-frames.py",
                        "--udid", IDENTIFIER, "--lifetime", "1800"]), \
                     patch.object(self.module.time, "monotonic",
                                  side_effect=[1000.0, 1000.0, 1000.0, 1000.0, 1001.0]), \
                     patch.object(self.module.time, "sleep", side_effect=AssertionError("no wait")), \
                     patch.object(self.module, "locate", side_effect=lookup) as locate, \
                     patch.object(self.module.subprocess, "run", side_effect=AssertionError("no SDK")) as run, \
                     contextlib.redirect_stdout(output):
                    with self.assertRaises(type(failure)) as raised:
                        self.module.main()
                self.assertIs(raised.exception, failure)
                rows = self.lifecycle_rows(output)
                self.assertEqual([(row["eventCode"], row["reasonCode"]) for row in rows], [(0, 0), (1, reason)])
                self.assertEqual(rows[-1]["elapsedSeconds"], 1)
                locate.assert_called_once_with(IDENTIFIER); run.assert_not_called()

    def test_lifecycle_write_failure_does_not_replace_keyboard_interrupt(self):
        failure = KeyboardInterrupt()
        with patch.object(sys, "argv", ["capture-simulator-test-frames.py", "--udid", IDENTIFIER]), \
             patch.object(self.module.time, "monotonic",
                          side_effect=[1000.0, 1000.0, 1000.0, 1000.0, 1001.0]), \
             patch.object(self.module, "locate", side_effect=failure), \
             patch.object(self.module.subprocess, "run", side_effect=AssertionError("no SDK")) as run, \
             patch("builtins.print", side_effect=BrokenPipeError):
            with self.assertRaises(KeyboardInterrupt) as raised:
                self.module.main()
        self.assertIs(raised.exception, failure)
        run.assert_not_called()

if __name__ == "__main__":
    unittest.main()
