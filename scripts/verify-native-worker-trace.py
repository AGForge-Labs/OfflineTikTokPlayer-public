#!/usr/bin/env python3
"""Require one bounded calibration of the exact current native decode worker.

Input is the dedicated capture helper's stdout, not mixed xcodebuild output.
The caller owns freshness and native/UI test acceptance. Never echo trace data,
identifiers, paths or parser exception text into diagnostic gate output.
"""

import argparse
import math
from pathlib import Path
import re
import sys
import uuid


MAX_LOG_BYTES = 1024 * 1024
MAX_SECTION_BYTES = 65536
MAX_ELAPSED_SECONDS = 4.5
MAX_LOOKUP_SECONDS = 1.5
INTEGER = rb"(?:0|[1-9][0-9]*|-[1-9][0-9]*)"
SECONDS = rb"-?(?:0|[1-9][0-9]*)\.[0-9]{6}"
HEADER = re.compile(
    rb"NativeWorkerTraceResult requestID=(?P<request>[^ \t\r\n]+)"
    rb" purposeCode=(?P<purpose>" + INTEGER + rb") workerID=(?P<worker>[^ \t\r\n]+)"
    rb" statusCode=(?P<status>" + INTEGER + rb") nativeReturnCode=(?P<native>" + INTEGER + rb")"
    rb" bytes=(?P<size>" + INTEGER + rb") truncated=(?P<truncated>" + INTEGER + rb")"
    rb" decoderQueueCount=(?P<queues>" + INTEGER + rb") startUptime=(?P<start>" + SECONDS + rb")"
    rb" elapsedSeconds=(?P<elapsed>" + SECONDS + rb")"
    rb" stageCode=(?P<stage>" + INTEGER + rb") ownershipCode=(?P<ownership>" + INTEGER + rb")"
    rb" psReturnCode=(?P<ps_return>" + INTEGER + rb") bundleReturnCode=(?P<bundle_return>" + INTEGER + rb")"
    rb" psElapsedSeconds=(?P<ps_elapsed>" + SECONDS + rb")"
    rb" bundleElapsedSeconds=(?P<bundle_elapsed>" + SECONDS + rb")"
    rb" bundleCacheHit=(?P<cache_hit>" + INTEGER + rb")")
CAPTURE = re.compile(
    rb"SimulatorCaptureResult errorCode=" + INTEGER + rb" startUptime=" + SECONDS
    + rb" elapsedSeconds=" + SECONDS)
THREAD = re.compile(r"^\s*(?:\d+\s+)?Thread[_ ](?:0x)?[0-9a-fA-F]+\b", re.ASCII)
QUEUE = re.compile(r"\bDispatchQueue[_ ]\d+:\s*([^\s(]+)", re.ASCII)
FRAME = re.compile(r"^\s*(?:[+!:|]\s*)*[1-9][0-9]*\s+(?P<symbol>\S.*)", re.ASCII)


class EvidenceError(ValueError):
    def __init__(self, code):
        self.code = code
        super().__init__()


def require(condition, code):
    if not condition:
        raise EvidenceError(code)


class SafeArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        raise EvidenceError(1)


def canonical_uuid(raw):
    try:
        value = raw.decode("ascii")
        require(str(uuid.UUID(value)) == value, 3)
        return value
    except (UnicodeError, ValueError, AttributeError):
        raise EvidenceError(3) from None


def verify_trace(raw):
    require(len(raw) <= MAX_LOG_BYTES, 2)
    records, boundaries, offset = [], [], 0
    for physical in raw.splitlines(keepends=True):
        line = physical.rstrip(b"\r\n")
        if b"NativeWorkerTraceResult" in line:
            require(len(line) <= 2048, 3)
            match = HEADER.fullmatch(line)
            require(match is not None, 3)
            fields = match.groupdict()
            fields["request"] = canonical_uuid(fields["request"])
            fields["worker"] = canonical_uuid(fields["worker"])
            try:
                for key in ("purpose", "status", "native", "size", "truncated", "queues",
                            "stage", "ownership", "ps_return", "bundle_return", "cache_hit"):
                    fields[key] = int(fields[key])
                for key in ("start", "elapsed", "ps_elapsed", "bundle_elapsed"):
                    fields[key] = float(fields[key])
            except (ValueError, OverflowError):
                raise EvidenceError(3) from None
            require(fields["purpose"] in (0, 1, 2), 3)
            require(0 <= fields["stage"] <= 8 and 0 <= fields["ownership"] <= 6
                    and fields["cache_hit"] in (0, 1), 3)
            require(all(math.isfinite(fields[key]) for key in ("start", "elapsed", "ps_elapsed", "bundle_elapsed")), 3)
            records.append((offset, offset + len(physical), fields))
            boundaries.append(offset)
        elif b"SimulatorCaptureResult" in line:
            require(CAPTURE.fullmatch(line) is not None, 3)
            boundaries.append(offset)
        offset += len(physical)

    calibrations = [record for record in records if record[2]["purpose"] == 2]
    # Count unsuccessful calibrations too. A retry must never rescue an earlier
    # failed/malformed observation or silently exceed the helper's sampling quota.
    require(len(calibrations) == 1, 4)
    header_offset, section_start, fields = calibrations[0]
    require(fields["status"] == 0 and fields["native"] == 0, 5)
    require(0 < fields["size"] <= MAX_SECTION_BYTES
            and fields["truncated"] == 0 and fields["queues"] >= 1, 6)
    require(fields["start"] > 0 and 0 < fields["elapsed"] <= MAX_ELAPSED_SECONDS, 7)
    require(fields["stage"] == 8 and fields["ownership"] == 1 and fields["ps_return"] == 0, 10)
    require(0 < fields["ps_elapsed"] <= MAX_LOOKUP_SECONDS, 11)
    if fields["cache_hit"] == 0:
        require(fields["bundle_return"] == 0 and 0 < fields["bundle_elapsed"] <= MAX_LOOKUP_SECONDS, 11)
    else:
        require(fields["bundle_return"] == -1 and fields["bundle_elapsed"] == 0, 11)
    section_end = next((position for position in boundaries if position > header_offset), len(raw))
    section = raw[section_start:section_end]
    require(len(section) == fields["size"] and len(section) <= MAX_SECTION_BYTES, 8)
    try:
        selected = section.decode("utf-8")
    except UnicodeError:
        raise EvidenceError(8) from None

    expected_queue = "OfflineTikTokPlayer.PCMDecode." + fields["worker"]
    matching_headers, stack_frames = 0, 0
    in_worker = False
    # Inspect only the selected calibration section. A current queue found in a
    # different purpose or beyond the next result record supplies no evidence.
    for line in selected.splitlines():
        if THREAD.match(line):
            require(QUEUE.findall(line) == [expected_queue], 9)
            matching_headers += 1
            in_worker = True
        elif in_worker:
            frame = FRAME.match(line)
            if frame and any(character.isalpha() or character in "_?" for character in frame.group("symbol")):
                stack_frames += 1
    require(0 < matching_headers <= fields["queues"] and stack_frames > 0, 9)


def main(argv=None):
    parser = SafeArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, type=Path)
    try:
        args = parser.parse_args(argv)
        with args.log.open("rb") as stream:
            raw = stream.read(MAX_LOG_BYTES + 1)
        verify_trace(raw)
    except EvidenceError as error:
        print(f"NativeWorkerTraceEvidence statusCode={error.code}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError):
        print("NativeWorkerTraceEvidence statusCode=2", file=sys.stderr)
        return 1
    print("NativeWorkerTraceEvidence statusCode=0 calibrationCount=1")
    return 0


if __name__ == "__main__":
    sys.exit(main())
