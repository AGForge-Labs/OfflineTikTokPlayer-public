import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "verify-native-worker-trace.py"
REQUEST = "12345678-9abc-4def-8abc-123456789abc"
OTHER_REQUEST = "22345678-9abc-4def-8abc-123456789abc"
WORKER = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
OTHER_WORKER = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
CAPTURE = "SimulatorCaptureResult errorCode=0 startUptime=200.000000 elapsedSeconds=0.250000\n"


def worker_section(worker=WORKER):
    return (f"    100 Thread_0x1234: DispatchQueue_5: OfflineTikTokPlayer.PCMDecode.{worker} (serial)\n"
            "    + 100 calibration_hold (in OfflineTikTokPlayer)\n")


def trace(section=None, **overrides):
    if section is None:
        section = worker_section()
    fields = dict(requestID=REQUEST, purposeCode=2, workerID=WORKER, statusCode=0,
                  nativeReturnCode=0, bytes=len(section.encode("utf-8")), truncated=0,
                  decoderQueueCount=1, startUptime="100.000000", elapsedSeconds="1.000000")
    fields.update(overrides)
    header = "NativeWorkerTraceResult " + " ".join(f"{key}={value}" for key, value in fields.items())
    return header + "\n" + section


class NativeWorkerTraceTests(unittest.TestCase):
    def check_log(self, text):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "host-helper.log"
            log.write_bytes(text.encode("utf-8") if isinstance(text, str) else text)
            return subprocess.run([sys.executable, str(SCRIPT), "--log", str(log)],
                                  capture_output=True, text=True, check=False)

    def assert_rejected(self, text):
        result = self.check_log(text)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertRegex(result.stderr, r"\ANativeWorkerTraceEvidence statusCode=[1-9][0-9]*\n\Z")
        return result

    def test_accepts_one_successful_calibration_and_emits_only_fixed_metadata(self):
        result = self.check_log(trace())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "NativeWorkerTraceEvidence statusCode=0 calibrationCount=1\n")
        self.assertEqual(result.stderr, "")

    def test_ordinary_trace_and_capture_results_do_not_replace_or_duplicate_calibration(self):
        ordinary = trace(worker_section(OTHER_WORKER), purposeCode=0, workerID=OTHER_WORKER)
        failed_ordinary = trace("", requestID=OTHER_REQUEST, purposeCode=1, statusCode=11,
                                nativeReturnCode=-1, decoderQueueCount=0,
                                startUptime="-1.000000", elapsedSeconds="4.000000")
        result = self.check_log(ordinary + CAPTURE + trace(decoderQueueCount=3) + CAPTURE + failed_ordinary)
        self.assertEqual(result.returncode, 0, result.stderr)
        for text in ("", CAPTURE, worker_section(), ordinary + failed_ordinary):
            with self.subTest(text=text):
                self.assert_rejected(text)

    def test_rejects_duplicate_calibrations_including_a_failed_one_before_success(self):
        for first in (trace(), trace(statusCode=3), trace(nativeReturnCode=1)):
            with self.subTest(first=first):
                self.assert_rejected(first + trace(requestID=OTHER_REQUEST))

    def test_rejects_unsuccessful_truncated_or_zero_queue_count_calibration(self):
        for values in ({"statusCode": 3}, {"statusCode": 11}, {"nativeReturnCode": 1},
                       {"nativeReturnCode": -1}, {"truncated": 1}, {"truncated": 2},
                       {"decoderQueueCount": 0}, {"decoderQueueCount": -1}):
            with self.subTest(values=values):
                self.assert_rejected(trace(**values))

    def test_requires_canonical_request_and_worker_uuids(self):
        for field, value in (("requestID", REQUEST.upper()), ("workerID", WORKER.upper()),
                             ("requestID", REQUEST.replace("-", "")), ("workerID", "not-a-uuid")):
            with self.subTest(field=field, value=value):
                self.assert_rejected(trace(**{field: value}))

    def test_enforces_positive_finite_times_and_the_four_point_five_second_ceiling(self):
        result = self.check_log(trace(elapsedSeconds="4.500000"))
        self.assertEqual(result.returncode, 0, result.stderr)
        for field, value in (("startUptime", "-1.000000"), ("startUptime", "0.000000"),
                             ("startUptime", "nan"), ("startUptime", "inf"),
                             ("elapsedSeconds", "0.000000"), ("elapsedSeconds", "-0.100000"),
                             ("elapsedSeconds", "4.500001"), ("elapsedSeconds", "nan"),
                             ("elapsedSeconds", "inf"), ("elapsedSeconds", "1e309")):
            with self.subTest(field=field, value=value):
                self.assert_rejected(trace(**{field: value}))

    def test_requires_exact_nonempty_utf8_byte_length_with_a_65536_byte_limit(self):
        for size in (0, -1, 65537, len(worker_section().encode("utf-8")) + 1):
            with self.subTest(size=size):
                self.assert_rejected(trace(bytes=size))
        self.assert_rejected(trace(""))
        section = worker_section()
        prefix = "    + 1 "
        section += prefix + "x" * (65536 - len(section.encode("utf-8")) - len(prefix) - 1) + "\n"
        self.assertEqual(len(section.encode("utf-8")), 65536)
        result = self.check_log(trace(section))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_rejected(trace(section + "x"))

    def test_multibyte_text_uses_bytes_and_invalid_utf8_does_not_escape_as_a_traceback(self):
        section = worker_section() + "    + 1 calibration_µ\n"
        result = self.check_log(trace(section))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_rejected(trace(section, bytes=len(section)))
        bad = worker_section().encode("utf-8") + b"\xff"
        self.assert_rejected(trace("", bytes=len(bad)).encode("utf-8") + bad)

    def test_requires_the_exact_worker_queue_in_a_thread_header(self):
        for section in (worker_section(OTHER_WORKER),
                        worker_section().replace("." + WORKER, ""),
                        worker_section(WORKER + "0"),
                        "    + 100 OfflineTikTokPlayer.PCMDecode." + WORKER + "\n",
                        worker_section(OTHER_WORKER) + "    + 100 " + WORKER + "\n"):
            with self.subTest(section=section):
                self.assert_rejected(trace(section))

    def test_rejects_a_worker_header_without_an_actual_stack_frame(self):
        header = worker_section().splitlines()[0] + "\n"
        for section in (header, header + "\n", header + "    +\n", header + "    100\n",
                        header + "    100 100\n", header + "    + 100 +\n",
                        "    + 100 borrowed_frame\n" + header):
            with self.subTest(section=section):
                self.assert_rejected(trace(section))

    def test_accepts_counted_frames_with_or_without_call_graph_markers(self):
        header = worker_section().splitlines()[0] + "\n"
        for frame in ("    + 100 calibration_hold\n", "    100 calibration_hold\n"):
            with self.subTest(frame=frame):
                result = self.check_log(trace(header + frame))
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_a_mixed_worker_section_even_if_the_expected_worker_is_present(self):
        self.assert_rejected(trace(worker_section() + worker_section(OTHER_WORKER)))

    def test_never_borrows_a_queue_from_another_purpose_or_past_a_result_boundary(self):
        wrong = trace(worker_section(OTHER_WORKER))
        self.assert_rejected(trace(purposeCode=0) + wrong)
        self.assert_rejected(wrong + CAPTURE + worker_section())
        header_only = trace("", bytes=len(worker_section().encode("utf-8")))
        self.assert_rejected(header_only + CAPTURE + worker_section())

    def test_malformed_calibration_headers_cannot_disappear_beside_a_valid_one(self):
        valid = trace()
        header, section = valid.split("\n", 1)
        malformed = (header.replace("purposeCode=2", "purposeCode=2 purposeCode=0"),
                     header.replace("purposeCode=2", "purposeCode=2x"),
                     header.replace("workerID=" + WORKER + " ", ""),
                     header + " extra=SECRET_SENTINEL", " " + header,
                     header.replace("statusCode=0", "statusCode=0 statusCode=0"))
        for item in malformed:
            with self.subTest(header=item):
                self.assert_rejected(item + "\n" + section + valid)

    def test_errors_and_success_never_echo_input_sections_or_paths(self):
        secret = "SECRET_MEDIA_SENTINEL"
        section = worker_section() + "    + 1 " + secret + "\n"
        result = self.check_log(trace(section))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)
        result = self.assert_rejected(trace(section, statusCode=9))
        self.assertNotIn(secret, result.stdout + result.stderr)
        result = subprocess.run([sys.executable, str(SCRIPT), "--log", secret + "/missing.log"],
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 1)
        self.assertRegex(result.stderr, r"\ANativeWorkerTraceEvidence statusCode=[1-9][0-9]*\n\Z")
        self.assertNotIn(secret, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
