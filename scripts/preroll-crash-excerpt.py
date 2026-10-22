"""Bounded crash excerpt parsing; no filesystem, subprocess or CLI behavior.

Source: https://developer.apple.com/documentation/xcode/interpreting-the-json-format-of-a-crash-report; Apple Xcode article
"Interpreting the JSON format of a crash report".
The collector contract supplies canonical case-scoped .ips bytes and fresh bindings.
No test outcome, original exit code, or production behavior is changed here.
"""

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
import re
from uuid import UUID

BUNDLE_ID = "dev.galaxybigbird.OfflineTikTokPlayer"
CASE_IDS = (
    "PlaybackSelectionVideoRegressionTests/testPreparedNextVideoPrerollCapabilityOffThenOn()",
    "PlaybackSelectionVideoRegressionTests/testPreparedNextVideoPrerollCapabilityOnThenOff()",
)
MAX_IPS_BYTES = 1024 * 1024
MAX_INPUT_BYTES = 8 * 1024 * 1024
MAX_IPS_FILES = 32
MAX_RECORD_BYTES = 64 * 1024  # Includes the terminating newline; two records <=128KiB.
FRAME_BYTES = 24 * 1024      # Separate budgets for faulting and language backtraces.
CASE_SECONDS = 120
STAMP = re.compile(
    r"([0-9]{4}-[0-9]{2}-[0-9]{2})[ T]"
    r"([0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?) ?"
    r"(Z|[+-][0-9]{2}:?[0-9]{2})\Z"
)


@dataclass(frozen=True)
class CaseBinding:
    case_id: str
    pid: int
    module_nonce: str
    case_start_utc: datetime


class _Problem(Exception):
    def __init__(self, reason, attributed=False):
        self.reason = reason
        self.attributed = attributed


def _uint(value):
    return type(value) is int and 0 <= value <= (1 << 64) - 1


def _text(value, maximum):
    if type(value) is not str:
        raise _Problem("invalid-scalar")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError:
        raise _Problem("invalid-scalar") from None
    if size > maximum or any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise _Problem("invalid-scalar")
    return value


def _utc(value):
    # A deliberately narrow numeric, timezone-bearing profile; no locale/zone inference.
    if type(value) is not str or len(value) > 64:
        raise _Problem("unsupported-time")
    match = STAMP.fullmatch(value)
    if match is None:
        raise _Problem("unsupported-time")
    offset = "+00:00" if match[3] == "Z" else match[3]
    try:
        return datetime.fromisoformat(match[1] + "T" + match[2] + offset).astimezone(timezone.utc)
    except (ValueError, OverflowError):
        raise _Problem("unsupported-time") from None


def _binding_base(binding):
    if type(binding) is not CaseBinding or binding.case_id not in CASE_IDS:
        raise _Problem("invalid-binding")
    if not _uint(binding.pid) or binding.pid == 0 or type(binding.module_nonce) is not str:
        raise _Problem("invalid-binding")
    try:
        if str(UUID(binding.module_nonce)) != binding.module_nonce:
            raise ValueError()
        start = binding.case_start_utc
        if type(start) is not datetime or start.tzinfo is None or start.utcoffset() != timedelta(0):
            raise ValueError()
        start + timedelta(seconds=CASE_SECONDS)
    except (ValueError, TypeError, OverflowError):
        raise _Problem("invalid-binding") from None
    return {
        "schema": 1, "testAcceptance": False, "caseID": binding.case_id,
        "pid": binding.pid, "moduleNonce": binding.module_nonce,
        "bundleIdentifier": BUNDLE_ID, "caseStartUTC": start.isoformat(),
        "caseWindowSeconds": CASE_SECONDS,
    }


def _encoded(record):
    return (json.dumps(record, ensure_ascii=True, allow_nan=False,
                       sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def _unavailable(base, reason, problems=None):
    record = dict(base, availability="unavailable", attributionAvailability="unavailable",
                  reason=reason, truncated=False)
    if problems:
        record["problemCounts"] = problems  # Controlled reason names and integer counts only.
    return _encoded(record)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _Problem("duplicate-json-key")
        result[key] = value
    return result


def _reject_constant(_):
    raise _Problem("non-json-constant")


def _objects(raw):
    if type(raw) is not bytes or not raw or len(raw) > MAX_IPS_BYTES:
        raise _Problem("ips-size")
    header, separator, body = raw.partition(b"\n")
    if not separator or not body.strip():
        raise _Problem("not-two-json-objects")
    try:
        options = dict(object_pairs_hook=_unique_object, parse_constant=_reject_constant)
        metadata = json.loads(header.decode("utf-8"), **options)
        report = json.loads(body.decode("utf-8"), **options)
    except (UnicodeError, ValueError, RecursionError, OverflowError):
        raise _Problem("invalid-json") from None
    if type(metadata) is not dict or type(report) is not dict:
        raise _Problem("not-two-json-objects")
    return metadata, report


def _frames(value, images):
    if type(value) is not list:
        raise _Problem("invalid-frame-array")
    retained, used = [], 2  # Count brackets and commas in the serialized frames array.
    for ordinal, frame in enumerate(value):  # Validate EVERY entry, even after the excerpt fills.
        if type(frame) is not dict:
            raise _Problem("invalid-frame")
        index, offset = frame.get("imageIndex"), frame.get("imageOffset")
        if not _uint(index) or index >= len(images) or not _uint(offset):
            raise _Problem("invalid-frame")
        image = images[index]
        if type(image) is not dict:
            raise _Problem("invalid-image")
        module = None
        if "name" in image:
            if type(image["name"]) is not str:
                raise _Problem("invalid-image")
            module = _text(image["name"].replace("\\", "/").rsplit("/", 1)[-1], 256) or None
        safe = {
            "module": module, "moduleAvailability": "provided" if module else "missing",
            "imageOffset": offset,
            "symbolAvailability": "provided" if "symbol" in frame else "missing",
        }
        if "symbol" in frame:
            safe["symbol"] = _text(frame["symbol"], 2048)
            if not safe["symbol"]:
                safe["symbolAvailability"] = "empty"
        if "symbolLocation" in frame:
            if not _uint(frame["symbolLocation"]):
                raise _Problem("invalid-frame")
            safe["symbolLocation"] = frame["symbolLocation"]
        size = len(_encoded(safe))  # Newline byte conservatively accounts for a comma.
        if used + size <= FRAME_BYTES and len(retained) == ordinal:
            retained.append(safe)
            used += size
    return {
        "availability": "available" if value else "empty",
        "frameCount": len(value), "retainedFrameCount": len(retained),
        "truncated": len(retained) != len(value), "frames": retained,
    }


def _shape_count(value):
    if value is None:
        return "null", None
    if type(value) is list:
        return "array", len(value)
    if type(value) is dict:
        return "object", len(value)
    if type(value) is str:
        return "string", len(value)
    if type(value) is bool:
        return "boolean", None
    return "number", None


def _language(report, images):
    if "lastExceptionBacktrace" not in report:
        return {"availability": "absent", "actualShape": "absent", "actualCount": 0,
                "truncated": False}
    value = report["lastExceptionBacktrace"]
    shape, count = _shape_count(value)
    result = {"availability": "unavailable", "actualShape": shape, "actualCount": count,
              "truncated": False, "reason": "unsupported-language-backtrace-shape"}
    if type(value) is list:
        try:
            result.update(_frames(value, images))
            result.pop("reason", None)
            result["qualification"] = "documentationTableTypeString_runtimeValidatedFrameArray"
        except _Problem as failure:
            result["reason"] = failure.reason
    return result  # A native string/object is never copied, searched, or guessed.


def _selected_scalars(report):
    exception, termination = {}, {}
    for container, target, fields in (
        ("exception", exception, ("type", "signal", "codes")),
        ("termination", termination, ("namespace", "code", "flags")),
    ):
        value = report.get(container, {})
        if type(value) is not dict:
            raise _Problem("invalid-exception-or-termination")
        for key in fields:
            if key not in value:
                continue
            if container == "termination" and key in ("code", "flags"):
                if not _uint(value[key]):
                    raise _Problem("invalid-exception-or-termination")
                target[key] = value[key]
            else:
                target[key] = _text(value[key], 256)
    return exception, termination


def _parse_one(raw, binding, base):
    metadata, report = _objects(raw)
    if type(metadata.get("bug_type")) is not str or type(metadata.get("platform")) is not int:
        raise _Problem("unsupported-attribution-shape")
    if metadata["bug_type"] != "309" or metadata["platform"] != 7:
        raise _Problem("unsupported-report-kind")
    bundle = report.get("bundleInfo")
    if (type(metadata.get("bundleID")) is not str or type(bundle) is not dict
            or type(bundle.get("CFBundleIdentifier")) is not str
            or not _uint(report.get("pid")) or report["pid"] == 0):
        raise _Problem("unsupported-attribution-shape")
    if metadata["bundleID"] != BUNDLE_ID or bundle["CFBundleIdentifier"] != BUNDLE_ID:
        raise _Problem("bundle-mismatch")
    if report["pid"] != binding.pid:
        raise _Problem("pid-mismatch")
    launch, capture = _utc(report.get("procLaunch")), _utc(report.get("captureTime"))
    start = binding.case_start_utc
    if not launch <= start <= capture <= start + timedelta(seconds=CASE_SECONDS):
        raise _Problem("case-window-mismatch")
    # From here, even a malformed excerpt counts as an attributed report for ambiguity.
    try:
        threads, images, fault = report.get("threads"), report.get("usedImages"), report.get("faultingThread")
        if (type(threads) is not list or type(images) is not list
                or not _uint(fault) or fault >= len(threads) or type(threads[fault]) is not dict):
            raise _Problem("invalid-faulting-thread")
        thread = threads[fault]
        if "triggered" in thread and thread["triggered"] is not True:
            raise _Problem("conflicting-faulting-thread")
        faulting = _frames(thread.get("frames"), images)
        if faulting["frameCount"] == 0:
            raise _Problem("missing-faulting-frames")
        language = _language(report, images)
        exception, termination = _selected_scalars(report)
        return dict(
            base, availability="available", attributionAvailability="unique-case-pid-bundle-window",
            procLaunchUTC=launch.isoformat(), captureTimeUTC=capture.isoformat(),
            exception=exception, termination=termination, faultingThreadIndex=fault,
            exceptionAvailability="selected-fields" if exception else "no-selected-fields",
            terminationAvailability="selected-fields" if termination else "no-selected-fields",
            faultingThread=faulting, lastExceptionBacktrace=language,
            applicationSpecificInformation={"availability": "unavailable", "reason": "not-selected-in-prototype"},
            truncated=faulting["truncated"] or language["truncated"],
            symbolication="report-provided-fields-only-no-atos",
        )
    except _Problem as failure:
        failure.attributed = True
        raise


def parse_case_ips(raw_reports, binding, *, case_scoped_export_confirmed=False):
    """Return ONE <=64KiB JSON line; input is already canonical, case-exported .ips bytes.

    The caller must first help-confirm the exact --test-id export, validate fresh
    host/start bindings, and reject symlinks/non-.ips files before reading bytes.
    Calling once for each allowlisted case produces at most128KiB in total.
    """
    try:
        base = _binding_base(binding)
    except _Problem:
        return _unavailable({"schema": 1, "testAcceptance": False}, "invalid-binding")
    if case_scoped_export_confirmed is not True:
        return _unavailable(base, "case-export-unconfirmed")
    if (type(raw_reports) not in (tuple, list) or len(raw_reports) > MAX_IPS_FILES
            or any(type(raw) is not bytes for raw in raw_reports)):
        return _unavailable(base, "invalid-input-set")
    if sum(len(raw) for raw in raw_reports) > MAX_INPUT_BYTES:
        return _unavailable(base, "input-budget")
    attributed, problems, unclassified = [], {}, False
    definite_filters = {"unsupported-report-kind", "bundle-mismatch", "pid-mismatch", "case-window-mismatch"}
    for raw in raw_reports:
        try:
            attributed.append(("ok", _parse_one(raw, binding, base)))
        except _Problem as failure:
            problems[failure.reason] = problems.get(failure.reason, 0) + 1
            if failure.attributed:
                attributed.append(("error", failure.reason))
            elif failure.reason not in definite_filters:
                unclassified = True
    if unclassified:
        return _unavailable(base, "unclassified-report", problems)
    if len(attributed) != 1:
        reason = "ambiguous-attributed-reports" if attributed else "no-attributed-report"
        return _unavailable(base, reason, problems)
    status, result = attributed[0]
    if status != "ok":
        return _unavailable(base, result, problems)
    encoded = _encoded(result)
    return encoded if len(encoded) <= MAX_RECORD_BYTES else _unavailable(base, "excerpt-size")
