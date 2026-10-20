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
