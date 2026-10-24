import importlib.util
import json
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


def aq_word_case(identity, status="passed", timestamp=False):
    prefix = "2026-10-21T13:06:39.5431950Z " if timestamp else ""
    result = case_line(identity, status).replace("0.001 seconds", "0.104 seconds")
    return [prefix + "2026-10-21 13:06:38.051696+0000 OfflineTikTokPlayer[20057:82227] [AQ]        LoudnessMan" + result,
            prefix + "ager.mm:1215  IsHardwareSupported: no plist loaded, returning false"]


class NativeTestEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.expected = current_manifest()
        spec = importlib.util.spec_from_file_location("native_invocation_evidence", SCRIPT)
        cls.verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.verifier)

    def check_log(self, lines, *, root=ROOT, selection_only=False, invocation=None, profile=None):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "xcodebuild.log"
            log.write_text("\n".join(lines) + "\n", encoding="utf-8")
            args = [sys.executable, str(SCRIPT), "--repo-root", str(root), "--log", str(log)]
            if profile is not None:
                profile_path = Path(directory) / "profile.json"
                profile_path.write_text(json.dumps(dict(version=1, cases=profile)), encoding="utf-8")
                args.extend(("--profile", str(profile_path)))
            if selection_only:
                args.append("--selection-only")
            if invocation is not None:
                args.extend(("--invocation", invocation))
            return subprocess.run(args, capture_output=True, text=True, check=False)

    def full_log(self):
        lines = []
        for identity in self.expected:
            lines.extend((case_line(identity, "started"), case_line(identity, timestamp=True)))
        return lines + ["** TEST SUCCEEDED **"]

    def test_explicit_profile_requires_each_selected_case_and_does_not_claim_full_acceptance(self):
        native = next(x for x in self.expected if x.startswith(TARGETS[0] + "."))
        ui = next(x for x in self.expected if x.startswith(TARGETS[1] + "."))
        profile = [native, ui]
        lines = [line for identity in profile for line in (case_line(identity, "started"), case_line(identity))]
        result = self.check_log(lines + ["** TEST SUCCEEDED **"], profile=profile)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("fullAcceptance=false", result.stdout)
        for missing in profile:
            incomplete = [line for identity in profile if identity != missing
                          for line in (case_line(identity, "started"), case_line(identity))]
            result = self.check_log(incomplete + ["** TEST SUCCEEDED **"], profile=profile)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing passing cases", result.stderr)
        other = next(x for x in self.expected if x not in profile)
        result = self.check_log(lines + [case_line(other, "started"), case_line(other), "** TEST SUCCEEDED **"], profile=profile)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected", result.stderr)

    def test_profile_cannot_claim_a_case_absent_from_the_current_source(self):
        result = self.check_log(["** TEST SUCCEEDED **"],
            profile=["OfflineTikTokPlayerTests.InventedTests/testImaginaryPlayback"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absent from current source", result.stderr)

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

    def test_literal_execute_success_requires_explicit_invocation(self):
        # Retained39643110262 lines3912/4053/4076, excluding unrelated framework output.
        identity = ("OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/"
                    "testReturnedVideoWaitsForInitialReadyCallbackBeforeVisitOrDriftSeek")
        started = ("Test Case '-[OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests "
                   "testReturnedVideoWaitsForInitialReadyCallbackBeforeVisitOrDriftSeek]' started.")
        passed = ("Test Case '-[OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests "
                  "testReturnedVideoWaitsForInitialReadyCallbackBeforeVisitOrDriftSeek]' passed (10.392 seconds).")
        for lines in ((started, passed, "** TEST EXECUTE SUCCEEDED **"),
                      ("2026-10-21T17:34:53.9802640Z " + started,
                       "2026-10-21T17:35:04.0590810Z " + passed,
                       "2026-10-21T17:35:05.5860610Z ** TEST EXECUTE SUCCEEDED **")):
            text = "\n".join(lines)
            self.verifier.verify_log(text, {identity}, invocation="test-without-building")
            with self.assertRaises(ValueError):
                self.verifier.verify_log(text, {identity})

    def test_cli_invocation_keeps_exact_marker_and_complete_identity_gates(self):
        cases = self.full_log()[:-1]
        for invocation, marker, wrong in (
                (None, "** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"),
                ("test", "** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"),
                ("test-without-building", "** TEST EXECUTE SUCCEEDED **", "** TEST SUCCEEDED **")):
            with self.subTest(invocation=invocation):
                valid = self.check_log(cases + [marker], invocation=invocation)
                self.assertEqual(valid.returncode, 0, valid.stderr)
                for lines in (cases + [wrong], cases + [marker, wrong],
                              [line for line in cases if TARGETS[1] not in line] + [marker],
                              cases + [case_line(self.expected[0]), marker],
                              [case_line(self.expected[0], "failed")] + cases + [marker],
                              [case_line(self.expected[0], "skipped")] + cases + [marker]):
                    rejected = self.check_log(lines, invocation=invocation)
                    self.assertNotEqual(rejected.returncode, 0)
        self.assertNotEqual(self.check_log(cases + ["** TEST SUCCEEDED **"], invocation="unknown").returncode, 0)

    def test_each_invocation_rejects_early_duplicate_malformed_and_failed_markers(self):
        identity = self.expected[0]
        cases = [case_line(identity, "started"), case_line(identity)]
        for invocation, marker, wrong in (
                ("test", "** TEST SUCCEEDED **", "** TEST EXECUTE SUCCEEDED **"),
                ("test-without-building", "** TEST EXECUTE SUCCEEDED **", "** TEST SUCCEEDED **")):
            for lines in (cases, [marker] + cases, cases + [marker, marker], cases + [wrong, marker],
                          cases + ["prefix " + marker, marker], cases + ["** TEST BUILD SUCCEEDED **", marker],
                          cases + ["** TEST FAILED **", marker],
                          cases + ["** TEST EXECUTE FAILED **", marker]):
                with self.subTest(invocation=invocation, lines=lines):
                    with self.assertRaises(ValueError):
                        self.verifier.verify_log("\n".join(lines), {identity}, invocation=invocation)
        with self.assertRaises(ValueError):
            self.verifier.verify_log("\n".join(cases + ["** TEST SUCCEEDED **"]), {identity}, invocation="unknown")

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

    def test_accepts_exact_adjacent_aq_word_interleave_with_complete_case(self):
        target = "OfflineTikTokPlayerTests.SpeakerAudioTests/testTimedOutOptionalPreparationRetriesWhenTheItemBecomesReady"
        self.assertIn(target, self.expected)
        others = [case_line(x) for x in self.expected if x != target]
        for timestamp in (False, True):
            with self.subTest(timestamp=timestamp):
                result = self.check_log(others + [case_line(target, "started")]
                                        + aq_word_case(target, timestamp=timestamp) + ["** TEST SUCCEEDED **"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("PASS " + target + "\n", result.stdout)
        # The same diagnostic word can be split by unrelated SDK output. Its
        # tail alone is noise, never another XCTest event or proof of a result.
        sdk_only = ["2026-10-21 13:04:23.882411+0000 OfflineTikTokPlayer[20057:66683] [AQ]        LoudnessMan"
                    "2026-10-21 13:04:23.904062+0000 OfflineTikTokPlayer[20057:64049] [] (Fig) signalled err=-12710 at <>:987",
                    "ager.mm:1215  IsHardwareSupported: no plist loaded, returning false"]
        result = self.check_log(self.full_log()[:-1] + sdk_only + ["** TEST SUCCEEDED **"])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_aq_word_interleave_preserves_failed_skipped_and_failed_summary(self):
        target = self.expected[0]
        others = [case_line(x) for x in self.expected[1:]]
        summary = ["Executed 97 tests, with 0 failures (0 unexpected)"]
        for status in ("failed", "skipped"):
            with self.subTest(status=status):
                result = self.check_log(others + [case_line(target, "started")]
                                        + aq_word_case(target, status) + summary + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(status, result.stderr.lower())
        result = self.check_log(others + [case_line(target, "started")] + aq_word_case(target)
                                + ["** TEST FAILED **", "** TEST SUCCEEDED **"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TEST FAILED", result.stderr)

    def test_aq_word_interleave_rejects_wrong_identity_retry_and_duplicate(self):
        target = self.expected[0]
        others = [case_line(x) for x in self.expected[1:]]
        unexpected = TARGETS[0] + ".UnexpectedTests/testWrongIdentity"
        result = self.check_log(others + [case_line(target, "started"), case_line(unexpected, "started")]
                                + aq_word_case(unexpected) + ["** TEST SUCCEEDED **"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(unexpected, result.stderr)
        self.assertIn(target, result.stderr)
        for status in ("passed", "failed"):
            with self.subTest(status=status):
                result = self.check_log(others + [case_line(target, "started")] + aq_word_case(target, status)
                                        + [case_line(target), "** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("duplicate", result.stderr.lower())

    def test_aq_word_interleave_rejects_malformed_nonadjacent_and_orphan_records(self):
        header, tail = aq_word_case(self.expected[0])
        fragments = ([header], [header, "unrelated output", tail], [header, "", tail],
                     [header.replace("2026-10-21 13:06:38.051696+0000", "unknown-time"), tail],
                     [header.replace("OfflineTikTokPlayer[", "OtherProcess["), tail],
                     [header.replace("0.104 seconds", "unknown seconds"), tail],
                     [header, tail.replace("1215", "1216")],
                     [header + " ** TEST FAILED **", tail])
        # Every expected identity already passes, so malformed extra records must
        # be rejected directly rather than merely by a missing-target side effect.
        for fragment in fragments:
            with self.subTest(fragment=fragment):
                result = self.check_log(self.full_log()[:-1] + fragment + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)

    def test_aq_word_interleave_requires_one_prior_start_and_keeps_missing_ui_gate(self):
        target = self.expected[0]
        others = [case_line(x) for x in self.expected[1:]]
        for starts in ([], [case_line(target, "started")] * 2):
            with self.subTest(starts=starts):
                result = self.check_log(others + starts + aq_word_case(target) + ["** TEST SUCCEEDED **"])
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Ambiguous", result.stderr)
        native_others = [case_line(x) for x in self.expected[1:] if x.startswith(TARGETS[0] + ".")]
        result = self.check_log(native_others + [case_line(target, "started")]
                                + aq_word_case(target) + ["** TEST SUCCEEDED **"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(TARGETS[1], result.stderr)

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
