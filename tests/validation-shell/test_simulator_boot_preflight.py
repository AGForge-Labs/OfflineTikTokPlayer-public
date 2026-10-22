"""Mocked native CLI contracts; no Simulator or child process is started."""
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch


SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "ensure-simulator-booted.py"
SPEC = importlib.util.spec_from_file_location("simulator_boot_preflight", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
UDID = "01234567-89AB-CDEF-0123-456789ABCDEF"
OTHER = "11234567-89AB-CDEF-0123-456789ABCDEF"


def inventory(state="Booted", available=True, udid=UDID, extra=None):
    devices = [{"udid": udid, "state": state, "isAvailable": available,
                "name": "PRIVATE-NAME-MUST-NOT-BE-PRINTED"}]
    if extra is not None:
        devices.append(extra)
    return json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-26-0": devices}}).encode()


class Clock:
    value = 0.0

    def __call__(self):
        return self.value


class SimulatorBootPreflightTests(unittest.TestCase):
    def runner(self, outcomes, clock=None):
        values = iter(outcomes)

        def invoke(arguments, **kwargs):
            outcome = next(values)
            if isinstance(outcome, BaseException):
                raise outcome
            code, output, elapsed = outcome
            if elapsed > kwargs["timeout"]:
                if clock is not None:
                    clock.value += kwargs["timeout"]
                raise subprocess.TimeoutExpired(arguments, kwargs["timeout"])
            if clock is not None:
                clock.value += elapsed
            if output:
                kwargs["stdout"].write(output)
            self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
            self.assertFalse(kwargs["check"])
            self.assertGreater(kwargs["timeout"], 0)
            self.assertLessEqual(kwargs["timeout"], 240)
            return subprocess.CompletedProcess(arguments, code)

        return Mock(side_effect=invoke)

    def call(self, outcomes, *, identifier=UDID, clock=None):
        clock = clock or Clock()
        runner = self.runner(outcomes, clock)
        result = MODULE.prepare_simulator(identifier, run=runner, monotonic=clock)
        return result, runner

    def test_invalid_identity_is_rejected_before_any_native_command(self):
        for value in ["", "booted", UDID.replace("-", ""), "{" + UDID + "}",
                      "00000000-0000-0000-0000-000000000000", UDID + "\n"]:
            with self.subTest(value=value):
                result, runner = self.call([], identifier=value)
                self.assertEqual(result["statusCode"], 1)
                runner.assert_not_called()

    def test_wrong_or_missing_exact_device_fails_without_boot(self):
        for payload in [inventory(udid=OTHER), b'{"devices":{}}']:
            result, runner = self.call([(0, payload, 0)])
            self.assertEqual(result["statusCode"], 4)
            self.assertEqual(runner.call_count, 1)
            self.assertFalse(result["bootRequested"])

    def test_duplicate_exact_identity_is_rejected_case_insensitively(self):
        payload = inventory(extra={"udid": UDID.lower(), "state": "Booted", "isAvailable": True})
        result, runner = self.call([(0, payload, 0)])
        self.assertEqual(result["statusCode"], 5)
        self.assertEqual(runner.call_count, 1)

    def test_unavailable_and_non_boolean_availability_are_rejected(self):
        for available in [False, "true", 1, None]:
            result, runner = self.call([(0, inventory(available=available), 0)])
            self.assertEqual(result["statusCode"], 6)
            self.assertEqual(runner.call_count, 1)

    def test_malformed_or_oversize_inventory_fails_closed(self):
        too_many_groups = json.dumps({"devices": {str(index): [] for index in range(65)}}).encode()
        too_many_devices = json.dumps({"devices": {"runtime": [
            {"udid": UDID, "state": "Booted", "isAvailable": True}] * 513}}).encode()
        for payload in [b"not json", b"[]", b'{"devices":[]}',
                        b'{"devices":{"runtime":[false]}}', b" " * 262145,
                        too_many_groups, too_many_devices, b"[" * 2000 + b"0" + b"]" * 2000]:
            result, runner = self.call([(0, payload, 0)])
            self.assertEqual(result["statusCode"], 3)
            self.assertEqual(runner.call_count, 1)

    def test_already_booted_waits_and_rechecks_exact_device_without_boot(self):
        result, runner = self.call([(0, inventory(), 0), (0, b"", 0), (0, inventory(), 0)],
                                   identifier=UDID.lower())
        self.assertEqual(result["statusCode"], 0)
        self.assertEqual(result["queryCount"], 2)
        self.assertEqual(result["initialStateCode"], 1)
        self.assertEqual(result["finalStateCode"], 1)
        self.assertFalse(result["bootRequested"])
        self.assertEqual([call.args[0] for call in runner.call_args_list], [
            ["xcrun", "simctl", "list", "devices", "--json"],
            ["xcrun", "simctl", "bootstatus", UDID, "-b"],
            ["xcrun", "simctl", "list", "devices", "--json"]])
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertTrue(all(type(value) in (int, float, bool) for value in result.values()))

    def test_shutdown_boots_only_exact_device_then_waits_and_rechecks(self):
        result, runner = self.call([(0, inventory("Shutdown"), 0), (0, b"", 0),
                                   (0, b"", 0), (0, inventory(), 0)])
        self.assertEqual(result["statusCode"], 0)
        self.assertTrue(result["bootRequested"])
        self.assertEqual(result["initialStateCode"], 2)
        self.assertEqual(runner.call_args_list[1].args[0], ["xcrun", "simctl", "boot", UDID])
        self.assertEqual(runner.call_args_list[2].args[0], ["xcrun", "simctl", "bootstatus", UDID, "-b"])

    def test_other_initial_states_and_boot_failure_never_proceed(self):
        for state in ["Booting", "Creating", "Deleting", "Unknown", None, [], {}]:
            result, runner = self.call([(0, inventory(state), 0)])
            self.assertEqual(result["statusCode"], 7)
            self.assertEqual(runner.call_count, 1)
        result, runner = self.call([(0, inventory("Shutdown"), 0), (17, b"", 0)])
        self.assertEqual(result["statusCode"], 8)
        self.assertEqual(result["bootReturnCode"], 17)
        self.assertEqual(runner.call_count, 2)

    def test_query_failure_and_query_timeout_have_fixed_results(self):
        result, runner = self.call([(9, b"", 0)])
        self.assertEqual(result["statusCode"], 2)
        self.assertEqual(result["lastQueryReturnCode"], 9)
        self.assertEqual(runner.call_count, 1)
        result, runner = self.call([subprocess.TimeoutExpired("private raw command", 15)])
        self.assertEqual(result["statusCode"], 10)
        self.assertEqual(result["stageCode"], 2)
        self.assertEqual(runner.call_count, 1)
        result, runner = self.call([OSError("private native error must not escape")])
        self.assertEqual(result["statusCode"], 11)
        self.assertNotIn("private", json.dumps(result))
        self.assertEqual(runner.call_count, 1)

    def test_wait_timeout_or_nonzero_never_claims_final_booted(self):
        for outcome, status in [(subprocess.TimeoutExpired("private raw command", 240), 10),
                                ((12, b"", 0), 9)]:
            result, runner = self.call([(0, inventory(), 0), outcome])
            self.assertEqual(result["statusCode"], status)
            self.assertEqual(result["stageCode"], 4)
            self.assertEqual(result["finalStateCode"], 0)
            self.assertEqual(runner.call_count, 2)

    def test_final_exact_identity_availability_and_booted_state_are_required(self):
        for payload, status in [(inventory(udid=OTHER), 4), (inventory(available=False), 6),
                                (inventory("Shutdown"), 7)]:
            result, runner = self.call([(0, inventory(), 0), (0, b"", 0), (0, payload, 0)])
            self.assertEqual(result["statusCode"], status)
            self.assertEqual(result["stageCode"], 5)
            self.assertEqual(runner.call_count, 3)
        result, runner = self.call([(0, inventory(), 0), (0, b"", 0),
                                   subprocess.TimeoutExpired("private raw command", 15),
                                   subprocess.TimeoutExpired("private raw command", 15)])
        self.assertEqual(result["statusCode"], 10)
        self.assertEqual(result["stageCode"], 5)
        self.assertEqual(result["lastQueryReturnCode"], -1)
        self.assertEqual(result["finalStateCode"], 0)
        self.assertEqual(runner.call_count, 4)

    def test_one_total_deadline_covers_all_commands_and_rejects_late_return(self):
        clock = Clock()
        result, runner = self.call([(0, inventory("Shutdown"), 1), (0, b"", 20),
                                   (0, b"", 200), (0, inventory(), 1)], clock=clock)
        self.assertEqual(result["statusCode"], 0)
        self.assertEqual(result["elapsedMs"], 222000)
        self.assertEqual([call.kwargs["timeout"] for call in runner.call_args_list], [60, 30, 219, 19])
        result, runner = self.call([(0, inventory(), 241)], clock=Clock())
        self.assertEqual(result["statusCode"], 10)
        self.assertEqual(runner.call_count, 1)
        runner = self.runner([(0, inventory(), 0), (0, b"", 0), (0, inventory(), 0)])
        monotonic = Mock(side_effect=[0, 0, 0, 0, 0, 0, 239, 241, 241])
        result = MODULE.prepare_simulator(UDID, run=runner, monotonic=monotonic)
        self.assertEqual(result["statusCode"], 10)
        self.assertEqual(result["stageCode"], 5)
        self.assertEqual(runner.call_count, 3)

    def test_malformed_cli_still_emits_only_the_fixed_result(self):
        result = {"schema": 1, "statusCode": 1, "stageCode": 1}
        for arguments in [[], ["--help"], ["--udid", UDID, "PRIVATE-EXTRA"], ["--other", UDID]]:
            output = io.StringIO()
            with patch.object(MODULE, "prepare_simulator", return_value=result) as prepare:
                with contextlib.redirect_stdout(output):
                    self.assertEqual(MODULE.main(arguments), 1)
                prepare.assert_called_once_with(None)
            self.assertEqual(json.loads(output.getvalue()), result)
            self.assertNotIn("PRIVATE", output.getvalue())

    def test_slow_final_identity_query_can_use_remaining_shared_budget(self):
        result, runner = self.call([(0, inventory("Shutdown"), 1), (0, b"", 1),
                                   (0, b"", 100), (0, inventory(), 30)])
        self.assertEqual(result["statusCode"], 0)
        self.assertEqual(result["finalStateCode"], 1)
        self.assertEqual(result["identityChecksPassed"], 2)
        self.assertEqual(result["elapsedMs"], 132000)
        self.assertEqual(runner.call_count, 4)

    def test_only_one_final_query_timeout_can_retry_within_the_original_budget(self):
        result, runner = self.call([(0, inventory("Shutdown"), 1), (0, b"", 1),
                                   (0, b"", 100), (0, inventory(), 61), (0, inventory(), 2)])
        self.assertEqual(result["statusCode"], 0)
        self.assertEqual(result["stageCode"], 6)
        self.assertEqual(result["elapsedMs"], 164000)
        self.assertEqual(result["budgetSeconds"], 240)
        self.assertEqual(result["queryCount"], 3)
        self.assertEqual(result["identityChecksPassed"], 2)
        self.assertEqual(result["finalQueryTimeouts"], 1)
        self.assertEqual(result["finalQueryRetries"], 1)
        self.assertEqual([call.kwargs["timeout"] for call in runner.call_args_list], [60, 30, 238, 60, 60])
        self.assertEqual([call.args[0][2] for call in runner.call_args_list],
                         ["list", "boot", "bootstatus", "list", "list"])

    def test_repeated_final_timeouts_are_terminal_without_a_third_query(self):
        result, runner = self.call([(0, inventory(), 1), (0, b"", 100),
                                   (0, b"", 61), (0, b"", 61)])
        self.assertEqual(result["statusCode"], 10)
        self.assertEqual(result["stageCode"], 5)
        self.assertEqual(result["elapsedMs"], 221000)
        self.assertEqual(result["finalStateCode"], 0)
        self.assertEqual(result["queryCount"], 3)
        self.assertEqual(result["finalQueryTimeouts"], 2)
        self.assertEqual(result["finalQueryRetries"], 1)
        self.assertEqual(runner.call_count, 4)

    def test_final_timeout_retry_shares_remaining_budget_and_never_runs_after_expiry(self):
        for last, expected, elapsed in [(10, 0, 211000), (40, 10, 240000)]:
            with self.subTest(last=last):
                result, runner = self.call([(0, inventory(), 1), (0, b"", 140),
                                           (0, b"", 61), (0, inventory(), last)])
                self.assertEqual(result["statusCode"], expected)
                self.assertEqual(result["elapsedMs"], elapsed)
                self.assertEqual(runner.call_args_list[-1].kwargs["timeout"], 39)
                self.assertEqual(result["finalQueryRetries"], 1)
        result, runner = self.call([(0, inventory(), 1), (0, b"", 200), (0, b"", 40)])
        self.assertEqual(result["statusCode"], 10)
        self.assertEqual(result["elapsedMs"], 240000)
        self.assertEqual(result["finalQueryRetries"], 0)
        self.assertEqual(runner.call_count, 3)

    def test_retry_requires_fresh_exact_inventory_and_never_reuses_partial_output(self):
        for payload, expected in [(b"", 3), (b"invalid", 3), (inventory(udid=OTHER), 4),
                                  (inventory(available=False), 6), (inventory("Shutdown"), 7)]:
            with self.subTest(expected=expected):
                clock = Clock()
                invoke = self.runner([(0, inventory(), 1), (0, b"", 10),
                                      (0, payload, 1)], clock)
                calls = []
                def run(arguments, **kwargs):
                    calls.append(arguments)
                    if len(calls) == 3:
                        kwargs["stdout"].write(inventory())
                        clock.value += 60
                        raise subprocess.TimeoutExpired("PRIVATE", 60, output=inventory())
                    return invoke(arguments, **kwargs)
                result = MODULE.prepare_simulator(UDID, run=run, monotonic=clock)
                self.assertEqual(result["statusCode"], expected)
                self.assertEqual(result["stageCode"], 5)
                self.assertEqual(result["finalStateCode"], 0 if expected != 7 else 2)
                self.assertEqual(result["finalQueryRetries"], 1)
                self.assertEqual(len(calls), 4)
                self.assertNotIn("PRIVATE", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
