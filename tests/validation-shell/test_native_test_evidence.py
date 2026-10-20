import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-native-test-log.py"
TARGETS = ("OfflineTikTokPlayerTests", "OfflineTikTokPlayerUITests")
FOCUSED_CLASSES = {
    "PlaybackSelectionFailureTests", "PlaybackSelectionVideoRegressionTests",
    "ContinuousAudioPlayerTests", "ContinuousPCMDecoderTests",
}


def current_manifest():
    """Independent inventory of the repository's ordinary XCTest declarations."""
    result = []
    for target in TARGETS:
        for source in sorted((ROOT / "ios" / target).glob("*.swift")):
            text = source.read_text(encoding="utf-8")
            classes = re.findall(r"final class (\w+): XCTestCase \{", text)
            if not classes:
                continue
            if len(classes) != 1:
                raise AssertionError(f"Update this test's inventory for {source}")
            for method in re.findall(r"^\s+func (test\w+)\(\)", text, re.MULTILINE):
                result.append(f"{target}.{classes[0]}/{method}")
    if not all(any(name.startswith(target + ".") for name in result) for target in TARGETS):
        raise AssertionError("The current native and UI inventories must both be nonempty")
    return sorted(result)


def case_line(identity, status="passed", timestamp=False):
    owner, method = identity.split("/")
    prefix = "2026-10-20T07:32:32.5974910Z " if timestamp else ""
    return f"{prefix}Test Case '-[{owner} {method}]' {status} (0.001 seconds)."


def split_case(identity, status="passed", timestamp=False):
    owner, method = identity.split("/")
    prefix = "2026-10-20T10:06:44.0489010Z " if timestamp else ""
    return [f"{prefix}Test Case '-[{owner} {method}]'"
            "2026-10-20 10:06:43.416902+0000 OfflineTikTokPlayer[14643:52859] [] <<<< VRP >>>> signalled err=-12852 at <>:2246",
            prefix + f" {status} (1.774 seconds)."]


def split_identifier_case(identity, status="passed", timestamp=False):
    owner, method = identity.split("/")
    target, name = owner.split(".", 1)
    prefix = "2026-10-20T22:03:36.3966460Z " if timestamp else ""
    return [prefix + f"Test Case '-[{target}.{name[:2]}"
            "2026-10-20 22:03:28.182264+0000 OfflineTikTokPlayer[18188:61328] [AQ]        LoudnessManager.mm:1215  IsHardwareSupported: no plist loaded, returning false",
            prefix + f"{name[2:]} {method}]' {status} (0.645 seconds)."]


def split_method_case(identity, status="passed", timestamp=False):
    owner, method = identity.split("/")
    split_at = min(len("testSlowPreparationFallsBackWi"), len(method) - 1)
    prefix = "2026-10-20T22:30:19.4370040Z " if timestamp else ""
    return [prefix + f"Test Case '-[{owner} {method[:split_at]}"
            "2026-10-20 22:30:19.057819+0000 OfflineTikTokPlayer[9066:53104] [AQ]        LoudnessManager.mm:1215  IsHardwareSupported: no plist loaded, returning false",
            prefix + f"{method[split_at:]}]' {status} (0.050 seconds)."]


def split_diagnostic_timestamp_case(identity, status="passed", timestamp=False):
    """The complete terminal interrupts one observed AQ diagnostic after its time."""
    owner, method = identity.split("/")
    prefix = "2026-10-20T23:27:28.8600140Z " if timestamp else ""
    tail_prefix = "2026-10-20T23:27:28.8703530Z " if timestamp else ""
    return [prefix + "2026-10-20 23:27:28.141014+0000"
            + f"Test Case '-[{owner} {method}]' {status} (0.224 seconds).",
            tail_prefix + " OfflineTikTokPlayer[9852:36737] [AQ]        "
            "LoudnessManager.mm:1215  IsHardwareSupported: no plist loaded, returning false"]


class NativeTestEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.expected = current_manifest()

    def check_log(self, lines, *, root=ROOT, selection_only=False):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "xcodebuild.log"
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            args = [sys.executable, str(SCRIPT), "--repo-root", str(root), "--log", str(log)]
            if selection_only:
                args.append("--selection-only")
            return subprocess.run(args, capture_output=True, text=True, check=False)

    def full_log(self):
        lines = []
        for identity in self.expected:
            lines.extend((case_line(identity, "started"), case_line(identity, timestamp=True)))
        return lines + ["** TEST SUCCEEDED **"]

    def test_accepts_full_current_manifest_and_reports_each_identity(self):
        result = self.check_log(self.full_log())
        self.assertEqual(result.returncode, 0, result.stderr)
        native = sum(name.startswith(TARGETS[0] + ".") for name in self.expected)
        ui = len(self.expected) - native
        self.assertIn(f"native={native} ui={ui} total={len(self.expected)}", result.stdout)
        for identity in self.expected:
            self.assertIn("PASS " + identity + "\n", result.stdout)

    def test_rejects_empty_and_core_only_logs(self):
        for lines in ([], [case_line("PlayerCoreTests.QueueTests/testQueue"), "** TEST SUCCEEDED **"]):
            with self.subTest(lines=lines):
                result = self.check_log(lines)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing", result.stderr.lower())

    def test_rejects_partial_or_missing_ui_and_started_only(self):
        for missing in (self.expected[0], next(x for x in self.expected if x.startswith(TARGETS[1] + "."))):
            with self.subTest(missing=missing):
                lines = [case_line(x) for x in self.expected if x != missing]
                result = self.check_log(lines + [case_line(missing, "started"), "** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(missing, result.stderr)

    def test_rejects_skips_failures_and_retry_passes(self):
        for status in ("skipped", "failed"):
            with self.subTest(status=status):
                result = self.check_log([case_line(self.expected[0], status)] + self.full_log())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(status, result.stderr.lower())

    def test_rejects_duplicate_passes_or_starts(self):
        for status in ("passed", "started"):
            with self.subTest(status=status):
                result = self.check_log([case_line(self.expected[0], status)] + self.full_log())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr.lower())

    def test_rejects_unexpected_native_or_ui_cases(self):
        for target in TARGETS:
            with self.subTest(target=target):
                result = self.check_log([case_line(target + ".NewTests/testUnexpected")] + self.full_log())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected", result.stderr.lower())
                unexpected = target + ".NewTests/testUnexpected"
                result = self.check_log([case_line(unexpected, "started")] + split_case(unexpected) + self.full_log())
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("unexpected", result.stderr.lower())

    def test_requires_one_success_marker_after_results_and_no_failure_marker(self):
        cases = [case_line(x) for x in self.expected]
        for lines in (cases, ["** TEST SUCCEEDED **"] + cases,
                      cases + ["** TEST SUCCEEDED **", "** TEST SUCCEEDED **"],
                      cases + ["** TEST FAILED **", "** TEST SUCCEEDED **"]):
            with self.subTest(tail=lines[-2:]):
                result = self.check_log(lines)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("TEST", result.stderr)

    def test_aggregate_summaries_do_not_supply_or_duplicate_case_evidence(self):
        summary = ["Executed 89 tests, with 0 failures (0 unexpected)", "Test run with 89 tests passed."]
        self.assertNotEqual(self.check_log(summary + ["** TEST SUCCEEDED **"]).returncode, 0)
        result = self.check_log(self.full_log()[:-1] + summary + ["** TEST SUCCEEDED **"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_accepts_only_adjacent_interleaved_case_result_with_process_diagnostic(self):
        for timestamp in (False, True):
            with self.subTest(timestamp=timestamp):
                lines = [case_line(x) for x in self.expected[1:]]
                lines += [case_line(self.expected[0], "started")] + split_case(self.expected[0], timestamp=timestamp)
                result = self.check_log(lines + ["** TEST SUCCEEDED **"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PASS " + self.expected[0], result.stdout)

    def test_interleaved_failure_skip_duplicate_and_retry_still_fail(self):
        others = [case_line(x) for x in self.expected[1:]]
        started = [case_line(self.expected[0], "started")]
        for status in ("failed", "skipped"):
            with self.subTest(status=status):
                result = self.check_log(others + started + split_case(self.expected[0], status) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(status, result.stderr.lower())
        for status in ("failed", "passed"):
            with self.subTest(retry_or_duplicate=status):
                result = self.check_log(others + started + split_case(self.expected[0], status)
                                        + [case_line(self.expected[0]), "** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr.lower())

    def test_split_result_cannot_borrow_across_any_other_record(self):
        header, result = split_case(self.expected[0])
        for intervening in ("unrelated output", case_line(self.expected[1], "started"),
                            "** TEST SUCCEEDED **", "** TEST FAILED **", ""):
            with self.subTest(intervening=intervening):
                lines = [case_line(x) for x in self.expected[1:]] + [case_line(self.expected[0], "started")]
                checked = self.check_log(lines + [header, intervening, result, "** TEST SUCCEEDED **"])
                self.assertNotEqual(checked.returncode, 0)
                self.assertIn(self.expected[0], checked.stderr)

    def test_split_case_rejects_unknown_noise_missing_result_and_embedded_test_markers(self):
        header, result = split_case(self.expected[0])
        for fragment in ([header], [header.replace("2026-10-20 10:06:43.416902+0000", "unknown-noise"), result],
                         [header + " ** TEST FAILED **", result],
                         [header + " " + case_line(self.expected[1], "failed"), result]):
            with self.subTest(fragment=fragment):
                lines = [case_line(x) for x in self.expected[1:]] + [case_line(self.expected[0], "started")]
                checked = self.check_log(lines + fragment + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(checked.returncode, 0)

    def test_split_terminal_requires_its_own_unique_started_case(self):
        others = [case_line(x) for x in self.expected[1:]]
        for extra in (split_case(self.expected[0]),
                      [case_line(self.expected[0], "started")] * 2 + split_case(self.expected[0])):
            with self.subTest(extra=extra):
                checked = self.check_log(others + extra + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(checked.returncode, 0)
                self.assertIn("Ambiguous", checked.stderr)
        checked = self.check_log([" passed (1.774 seconds)."] + self.full_log())
        self.assertNotEqual(checked.returncode, 0)
        self.assertIn("Orphan", checked.stderr)

    def test_accepts_adjacent_identity_split_by_the_observed_loudness_diagnostic(self):
        identity = TARGETS[0] + ".PlaybackSelectionFailureTests/testFailedChosenSavedClipStopsOldAudioAndRetriesTheSameSelection"
        self.assertIn(identity, self.expected)
        for timestamp in (False, True):
            with self.subTest(timestamp=timestamp):
                others = [case_line(x) for x in self.expected if x != identity]
                lines = others + [case_line(identity, "started")] + split_identifier_case(identity, timestamp=timestamp)
                result = self.check_log(lines + ["** TEST SUCCEEDED **"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PASS " + identity + "\n", result.stdout)

    def test_identity_split_failures_skips_retries_and_duplicates_still_fail(self):
        identity = self.expected[0]
        others = [case_line(x) for x in self.expected if x != identity]
        started = [case_line(identity, "started")]
        for status in ("failed", "skipped"):
            with self.subTest(status=status):
                result = self.check_log(others + started + split_identifier_case(identity, status) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(status, result.stderr.lower())
        for status in ("failed", "passed"):
            with self.subTest(retry_or_duplicate=status):
                result = self.check_log(others + started + split_identifier_case(identity, status)
                                        + [case_line(identity), "** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr.lower())

    def test_identity_split_cannot_borrow_a_tail_across_another_record(self):
        identity = self.expected[0]
        header, tail = split_identifier_case(identity)
        others = [case_line(x) for x in self.expected if x != identity]
        for intervening in ("unrelated output", case_line(self.expected[1], "started"),
                            "** TEST SUCCEEDED **", "** TEST FAILED **", ""):
            with self.subTest(intervening=intervening):
                result = self.check_log(others + [case_line(identity, "started"), header,
                                                 intervening, tail, "** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(identity, result.stderr)

    def test_identity_split_rejects_malformed_noise_orphan_tails_and_missing_tails(self):
        identity = self.expected[0]
        header, tail = split_identifier_case(identity)
        fragments = ([header], [tail],
                     [header.replace("LoudnessManager.mm:1215", "OtherManager.mm:1215"), tail],
                     [header.replace("returning false", "returning true"), tail],
                     [header.replace("2026-10-20 22:03:28.182264+0000", "unknown-time"), tail],
                     [header.replace("OfflineTikTokPlayer[18188:61328]", "OtherPlayer[18188:61328]"), tail],
                     [header + " ** TEST FAILED **", tail],
                     [header, tail.replace(" passed ", " passed-with-noise ")],
                     [header, tail + " unrelated output"],
                     [header, tail + " " + case_line(self.expected[1])])
        for fragment in fragments:
            with self.subTest(fragment=fragment):
                # Include an otherwise complete pass: malformed extra records
                # must not disappear merely because another result exists.
                result = self.check_log(self.full_log()[:-1] + list(fragment) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)

    def test_identity_split_requires_one_prior_start_and_an_expected_identity(self):
        identity = self.expected[0]
        others = [case_line(x) for x in self.expected if x != identity]
        for before, after in (([], []), ([case_line(identity, "started")] * 2, []),
                              ([], [case_line(identity, "started")])):
            with self.subTest(before=before, after=after):
                result = self.check_log(others + before + split_identifier_case(identity) + after + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ambiguous", result.stderr)
        for target in TARGETS:
            unexpected = target + ".NewTests/testUnexpected"
            result = self.check_log([case_line(unexpected, "started")] + split_identifier_case(unexpected) + self.full_log())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected", result.stderr.lower())

    def test_identity_split_does_not_hide_another_real_case_failure(self):
        identity, failed = self.expected[:2]
        others = [case_line(x) for x in self.expected if x not in (identity, failed)]
        lines = others + [case_line(identity, "started")] + split_identifier_case(identity)
        result = self.check_log(lines + [case_line(failed, "failed"), "** TEST FAILED **"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(failed, result.stderr)
        self.assertIn("TEST FAILED", result.stderr)

    def test_accepts_adjacent_method_split_by_the_observed_loudness_diagnostic(self):
        identity = TARGETS[0] + ".SpeakerAudioTests/testSlowPreparationFallsBackWithoutInstallingAMixAfterEnqueue"
        self.assertIn(identity, self.expected)
        for timestamp in (False, True):
            with self.subTest(timestamp=timestamp):
                others = [case_line(x) for x in self.expected if x != identity]
                lines = others + [case_line(identity, "started")] + split_method_case(identity, timestamp=timestamp)
                result = self.check_log(lines + ["** TEST SUCCEEDED **"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PASS " + identity + "\n", result.stdout)

    def test_method_split_preserves_status_unique_prior_start_and_expected_identity(self):
        identity = self.expected[0]
        others = [case_line(x) for x in self.expected if x != identity]
        started = [case_line(identity, "started")]
        for status in ("failed", "skipped"):
            with self.subTest(status=status):
                result = self.check_log(others + started + split_method_case(identity, status) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(status + " case", result.stderr)
        for prior in ("passed", "failed"):
            with self.subTest(prior=prior):
                result = self.check_log(others + started + [case_line(identity, prior)]
                                        + split_method_case(identity) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr.lower())
        for before, after in (([], []), (started * 2, []), ([], started)):
            with self.subTest(before=before, after=after):
                result = self.check_log(others + before + split_method_case(identity) + after + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ambiguous", result.stderr)
        for target in TARGETS:
            unexpected = target + ".NewTests/testUnexpected"
            result = self.check_log([case_line(unexpected, "started")] + split_method_case(unexpected) + self.full_log())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected", result.stderr.lower())

    def test_method_split_rejects_malformed_nonadjacent_orphan_fragments_and_real_failure(self):
        identity, failed = self.expected[:2]
        header, tail = split_method_case(identity)
        class_header, class_tail = split_identifier_case(identity)
        fragments = ([header], [tail], [header, "unrelated output", tail],
                     [class_header, tail], [header, class_tail],
                     [header, case_line(failed, "started"), tail],
                     [header, "** TEST SUCCEEDED **", tail],
                     [header, "** TEST FAILED **", tail], [header, "", tail],
                     [header.replace("LoudnessManager.mm:1215", "OtherManager.mm:1215"), tail],
                     [header.replace("returning false", "returning true"), tail],
                     [header.replace("2026-10-20 22:30:19.057819+0000", "unknown-time"), tail],
                     [header.replace("OfflineTikTokPlayer[9066:53104]", "OtherPlayer[9066:53104]"), tail],
                     [header + " ** TEST FAILED **", tail],
                     [header, tail + " unrelated output"], [header, tail + " " + case_line(failed)])
        for fragment in fragments:
            with self.subTest(fragment=fragment):
                result = self.check_log(self.full_log()[:-1] + list(fragment) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
        others = [case_line(x) for x in self.expected if x not in (identity, failed)]
        result = self.check_log(others + [case_line(identity, "started")] + split_method_case(identity)
                                + [case_line(failed, "failed"), "** TEST FAILED **"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(failed, result.stderr)
        self.assertIn("TEST FAILED", result.stderr)

    def test_accepts_terminal_inside_the_observed_split_diagnostic_timestamp(self):
        identity = TARGETS[0] + ".PlaybackContinuityTests/testPausedRestoreAndSeekUseRequestedAudioPositionBeforeEngineStarts"
        self.assertIn(identity, self.expected)
        others = [case_line(x) for x in self.expected if x != identity]
        for timestamp in (False, True):
            with self.subTest(timestamp=timestamp):
                lines = others + [case_line(identity, "started")]
                lines += split_diagnostic_timestamp_case(identity, timestamp=timestamp)
                result = self.check_log(lines + ["** TEST SUCCEEDED **"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PASS " + identity + "\n", result.stdout)

    def test_timestamp_split_requires_the_exact_immediate_diagnostic_tail(self):
        identity = self.expected[0]
        terminal, tail = split_diagnostic_timestamp_case(identity)
        fragments = ([terminal], [tail], [terminal, "", tail],
                     [terminal, "unrelated output", tail],
                     [terminal, case_line(self.expected[1], "started"), tail],
                     [terminal, "** TEST SUCCEEDED **", tail],
                     [terminal, "** TEST FAILED **", tail],
                     [terminal, tail.replace("OfflineTikTokPlayer[9852:36737]", "OtherPlayer[9852:36737]")],
                     [terminal, tail.replace("LoudnessManager.mm:1215", "OtherManager.mm:1215")],
                     [terminal, tail.replace("returning false", "returning true")],
                     [terminal, tail + " unrelated output"],
                     [terminal + " unrelated output", tail],
                     [terminal.replace("2026-10-20 23:27:28.141014+0000", "unknown-time"), tail],
                     [terminal, tail + " " + case_line(self.expected[1])])
        for fragment in fragments:
            with self.subTest(fragment=fragment):
                # A malformed extra terminal must remain an error even when
                # every expected identity already has an ordinary passing result.
                result = self.check_log(self.full_log()[:-1] + list(fragment) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)

    def test_timestamp_split_requires_one_prior_start_and_no_prior_outcome(self):
        identity = self.expected[0]
        others = [case_line(x) for x in self.expected if x != identity]
        started = [case_line(identity, "started")]
        for before, after in (([], []), (started * 2, []), ([], started)):
            with self.subTest(before=before, after=after):
                result = self.check_log(others + before + split_diagnostic_timestamp_case(identity)
                                        + after + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ambiguous", result.stderr)
        for prior in ("passed", "failed"):
            with self.subTest(prior=prior):
                result = self.check_log(others + started + [case_line(identity, prior)]
                                        + split_diagnostic_timestamp_case(identity) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ambiguous", result.stderr)
        for target in TARGETS:
            unexpected = target + ".NewTests/testUnexpected"
            result = self.check_log([case_line(unexpected, "started")]
                                    + split_diagnostic_timestamp_case(unexpected) + self.full_log())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected", result.stderr.lower())

    def test_timestamp_split_preserves_failed_skipped_and_duplicate_results(self):
        identity = self.expected[0]
        others = [case_line(x) for x in self.expected if x != identity]
        started = [case_line(identity, "started")]
        for status in ("failed", "skipped"):
            with self.subTest(status=status):
                result = self.check_log(others + started + split_diagnostic_timestamp_case(identity, status)
                                        + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(status + " case", result.stderr)
        for status in ("passed", "failed"):
            with self.subTest(retry_or_duplicate=status):
                result = self.check_log(others + started + split_diagnostic_timestamp_case(identity, status)
                                        + [case_line(identity), "** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr.lower())

    def test_timestamp_split_does_not_hide_other_case_failures(self):
        identity = self.expected[0]
        failed = self.expected[1:4]
        others = [case_line(x) for x in self.expected if x not in [identity] + failed]
        lines = others + [case_line(identity, "started")] + split_diagnostic_timestamp_case(identity)
        result = self.check_log(lines + [case_line(x, "failed") for x in failed] + ["** TEST FAILED **"])
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(identity, result.stderr)
        for failure in failed:
            self.assertIn(failure, result.stderr)
        self.assertIn("TEST FAILED", result.stderr)

    def test_selection_only_requires_exactly_the_four_focused_classes_and_no_ui(self):
        focused = [x for x in self.expected if x.split(".", 1)[1].split("/")[0] in FOCUSED_CLASSES]
        lines = [case_line(x) for x in focused] + ["** TEST SUCCEEDED **"]
        result = self.check_log(lines, selection_only=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"native={len(focused)} ui=0 total={len(focused)}", result.stdout)
        self.assertNotEqual(self.check_log(lines).returncode, 0)
        self.assertNotEqual(self.check_log(self.full_log(), selection_only=True).returncode, 0)
        self.assertNotEqual(self.check_log(lines[1:], selection_only=True).returncode, 0)

    def test_manifest_ignores_comment_string_and_helper_test_names(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            native = root / "ios" / TARGETS[0]
            ui = root / "ios" / TARGETS[1]
            native.mkdir(parents=True)
            ui.mkdir(parents=True)
            (native / "RealTests.swift").write_text('''
// final class FakeTests: XCTestCase { func testFake() {} }
final class RealTests: XCTestCase {
    let message = "func testFake() { }"
    /* nested /* func testFake() {} */ comment */
    func testReal() async throws {
        let message = "nested \\(String(\"{\")) text"
    }
}
final class Helper { func testHelper() {} }
''', encoding="utf-8")
            (ui / "ScreenTests.swift").write_text("final class ScreenTests: XCTestCase { func testScreen() {} }", encoding="utf-8")
            result = self.check_log([case_line(TARGETS[0] + ".RealTests/testReal"),
                                     case_line(TARGETS[1] + ".ScreenTests/testScreen"),
                                     "** TEST SUCCEEDED **"], root=root)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_manifest_rejects_conditional_test_declarations(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for target in TARGETS:
                folder = root / "ios" / target
                folder.mkdir(parents=True)
                (folder / "Tests.swift").write_text('''final class Tests: XCTestCase {
#if os(iOS)
    func testConditional() {}
#endif
}''', encoding="utf-8")
            result = self.check_log(["** TEST SUCCEEDED **"], root=root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("conditional", result.stderr.lower())


if __name__ == "__main__":
    unittest.main()
