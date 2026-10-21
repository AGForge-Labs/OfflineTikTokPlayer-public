#!/usr/bin/env python3
"""Require complete, unique XCTest evidence from one raw xcodebuild stdout log.

This verifies test identities/results, not physical device acceptance or the
authenticity/freshness of a log. The caller must tee the current invocation to a
fresh file. Aggregate summaries and GitHub job status are not case evidence.
"""

import argparse
from collections import Counter, defaultdict
from pathlib import Path
import re
import sys


TARGETS = ("OfflineTikTokPlayerTests", "OfflineTikTokPlayerUITests")
SELECTION_CLASSES = frozenset({
    "PlaybackSelectionFailureTests", "PlaybackSelectionVideoRegressionTests",
    "ContinuousAudioPlayerTests", "ContinuousPCMDecoderTests",
})
IDENTIFIER = re.compile(r"[A-Za-z_]\w*", re.ASCII)
CLASS = re.compile(r"\bclass\s+([A-Za-z_]\w*)\b([^{}]*)\{", re.ASCII)
METHOD = re.compile(r"\bfunc\s+(test[^\s(]*)\s*\(([^)]*)\)")
CASE = re.compile(r"\bTest Case '([^']+)' ([A-Za-z]+)(?:\s|\.)")
CASE_HEADER = re.compile(r"\bTest Case '([^']+)'")
CASE_ID = re.compile(r"^-\[([A-Za-z_]\w*)\.([A-Za-z_]\w*) ([^\]]+)\]$", re.ASCII)
GITHUB_TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT\S+Z ")
# Xcode can interleave one framework stderr record between the complete case
# identity and its result suffix. Recognize only the observed bounded shape;
# never search forward, discard arbitrary noise, or use a suite summary.
SPLIT_CASE = re.compile(
    r"Test Case '([^']+)'\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\+\d{4} "
    r"OfflineTikTokPlayer\[\d+:\d+\] \[\] <<<< VRP >>>> signalled err=-?\d+ at <>:\d+")
RESULT_SUFFIX = re.compile(r" (passed|failed|skipped) \(\d+(?:\.\d+)? seconds\)\.")
# One observed framework line was split inside the word LoudnessManager by a
# complete XCTest terminal record. Validate the exact adjacent diagnostic tail;
# do not relax CASE's word boundary or strip arbitrary process output.
AQ_WORD_CASE = re.compile(
    r"\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+\+\d{4} "
    r"OfflineTikTokPlayer\[\d+:\d+\] \[AQ\] {8}LoudnessMan"
    r"Test Case '([^']+)' (passed|failed|skipped) \(\d+(?:\.\d+)? seconds\)\.")
AQ_WORD_TAIL = re.compile(r"ager\.mm:1215  IsHardwareSupported: no plist loaded, returning false")
SUCCESS = re.compile(r"^(?:\d{4}-\d\d-\d\dT\S+\s+)?\s*\*\* TEST SUCCEEDED \*\*\s*$")
EXECUTE_SUCCESS = re.compile(r"^(?:\d{4}-\d\d-\d\dT\S+\s+)?\s*\*\* TEST EXECUTE SUCCEEDED \*\*\s*$")
ANY_SUCCESS = re.compile(r"\*\* TEST(?: [A-Z]+)* SUCCEEDED \*\*")
FAILURE = re.compile(r"\*\* TEST(?: [A-Z]+)* FAILED \*\*")


class EvidenceError(ValueError):
    pass


def swift_code(text):
    """Mask strings/comments, retaining positions, newlines and actual braces."""
    def comment_end(index):
        if text.startswith("//", index):
            end = text.find("\n", index)
            return len(text) if end < 0 else end
        depth, index = 1, index + 2
        while index < len(text) and depth:
            if text.startswith("/*", index):
                depth += 1
                index += 2
            elif text.startswith("*/", index):
                depth -= 1
                index += 2
            else:
                index += 1
        if depth:
            raise EvidenceError("Unterminated Swift block comment")
        return index

    def string_prefix(index):
        end = index
        while end < len(text) and text[end] == "#":
            end += 1
        if end >= len(text) or text[end] != '"':
            return None
        width = 3 if text.startswith('"""', end) else 1
        return text[index:end], width, end + width

    def interpolation_end(index):
        depth, index = 1, index + 1
        while index < len(text):
            if text.startswith(("//", "/*"), index):
                index = comment_end(index)
            elif string_prefix(index):
                index = string_end(index)
            else:
                if text[index] == "(":
                    depth += 1
                elif text[index] == ")":
                    depth -= 1
                    if depth == 0:
                        return index + 1
                index += 1
        raise EvidenceError("Unterminated Swift string interpolation")

    def string_end(index):
        hashes, width, index = string_prefix(index)
        closing, escape = '"' * width + hashes, "\\" + hashes
        while index < len(text):
            if text.startswith(closing, index):
                return index + len(closing)
            if text.startswith(escape, index):
                after = index + len(escape)
                if after < len(text) and text[after] == "(":
                    index = interpolation_end(after)
                else:
                    index = after + 1
            else:
                index += 1
        raise EvidenceError("Unterminated Swift string")

    result, index = list(text), 0
    while index < len(text):
        if text.startswith(("//", "/*"), index):
            end = comment_end(index)
        elif string_prefix(index):
            end = string_end(index)
        else:
            index += 1
            continue
        for position in range(index, end):
            if text[position] not in "\r\n":
                result[position] = " "
        index = end
    return "".join(result)


def conditional_at(code, position):
    depth = 0
    for line in code[:position].splitlines():
        if re.match(r"\s*#if\b", line):
            depth += 1
        elif re.match(r"\s*#endif\b", line):
            depth -= 1
    return depth != 0


def class_end(code, start):
    depth = 1
    for position in range(start, len(code)):
        if code[position] == "{":
            depth += 1
        elif code[position] == "}":
            depth -= 1
            if depth == 0:
                return position
    raise EvidenceError("Unbalanced Swift class braces")


def source_manifest(repo_root, selection_only=False):
    """Discover zero-argument instance tests on direct XCTestCase subclasses.

    Reject unsupported declarations instead of silently shrinking the manifest.
    Current sources have no conditional test methods or inherited test classes.
    """
    discovered, test_classes = set(), set()
    for target in TARGETS:
        folder = repo_root / "ios" / target
        sources = sorted(folder.glob("*.swift"))
        if not sources:
            raise EvidenceError(f"No Swift XCTest sources found in {folder}")
        parsed = []
        target_classes = set()
        for path in sources:
            code = swift_code(path.read_text(encoding="utf-8"))
            classes = []
            for match in CLASS.finditer(code):
                name, header = match.group(1, 2)
                direct = bool(re.search(r"\bXCTestCase\b", header))
                classes.append((match.end(), class_end(code, match.end()), name, header, direct))
                if direct:
                    if conditional_at(code, match.start()):
                        raise EvidenceError(f"Unsupported conditional XCTestCase declaration: {path}:{name}")
                    if name in target_classes:
                        raise EvidenceError(f"Duplicate XCTestCase class: {target}.{name}")
                    target_classes.add(name)
            parsed.append((path, code, classes))
        for path, code, classes in parsed:
            for _, _, name, header, direct in classes:
                if not direct and set(re.findall(r"[A-Za-z_]\w*", header)) & target_classes:
                    raise EvidenceError(f"Unsupported inherited XCTestCase: {path}:{name}")
            for match in METHOD.finditer(code):
                owners = [scope for scope in classes if scope[0] <= match.start() < scope[1]]
                if not owners:
                    raise EvidenceError(f"Unsupported test declaration outside an XCTestCase class: {path}:{match.group(1)}")
                start, _, name, _, direct = max(owners, key=lambda scope: scope[0])
                if not direct:
                    continue  # Ordinary helper classes are not XCTest cases.
                preceding = code[start:match.start()]
                if preceding.count("{") != preceding.count("}"):
                    continue  # A local helper function is not a test method.
                method, parameters = match.group(1, 2)
                modifier_start = max(start, code.rfind("\n", start, match.start()) + 1)
                modifiers = code[modifier_start:match.start()]
                if not IDENTIFIER.fullmatch(method) or parameters.strip() or re.search(r"\b(?:static|class)\b", modifiers):
                    raise EvidenceError(f"Unsupported XCTest method declaration: {path}:{method}")
                if conditional_at(code, match.start()):
                    raise EvidenceError(f"Unsupported conditional XCTest method: {path}:{method}")
                identity = f"{target}.{name}/{method}"
                if identity in discovered:
                    raise EvidenceError(f"Duplicate XCTest method declaration: {identity}")
                discovered.add(identity)
                test_classes.add((target, name))
        if not any(identity.startswith(target + ".") for identity in discovered):
            raise EvidenceError(f"No XCTest methods discovered for {target}")
    if selection_only:
        missing = SELECTION_CLASSES - {name for target, name in test_classes if target == TARGETS[0]}
        if missing:
            raise EvidenceError("Missing selection-only XCTest classes: " + ", ".join(sorted(missing)))
        discovered = {identity for identity in discovered if identity.startswith(TARGETS[0] + ".")
                      and identity.split(".", 1)[1].split("/", 1)[0] in SELECTION_CLASSES}
    return discovered


def verify_log(text, expected, *, invocation="test"):
    if invocation not in ("test", "test-without-building"):
        raise EvidenceError("Unsupported native test invocation")
    success = SUCCESS if invocation == "test" else EXECUTE_SUCCESS
    success_label = "TEST SUCCEEDED" if invocation == "test" else "TEST EXECUTE SUCCEEDED"
    starts, outcomes = Counter(), defaultdict(Counter)
    observed, problems, successes, last_case = set(), [], [], 0
    pending = None
    pending_word = None
    for number, line in enumerate(text.splitlines(), 1):
        if success.fullmatch(line):
            successes.append(number)
        elif ANY_SUCCESS.search(line):
            problems.append(f"Unexpected or malformed success marker for {invocation} at line {number}")
        if FAILURE.search(line):
            problems.append(f"TEST FAILED marker at line {number}")
        clean = GITHUB_TIMESTAMP.sub("", line, count=1)
        event, reconstructed = None, False
        if pending_word is not None:
            raw, status, header_line = pending_word
            pending_word = None
            if AQ_WORD_TAIL.fullmatch(clean):
                event, reconstructed = (raw, status), True
            else:
                problems.append(f"Unfinished AQ word interleave at line {header_line}: {raw}")
        if pending is not None:
            raw, header_line = pending
            pending = None
            suffix = RESULT_SUFFIX.fullmatch(clean)
            if suffix:
                event, reconstructed = (raw, suffix.group(1)), True
            else:
                problems.append(f"Unfinished interleaved case at line {header_line}: {raw}")
        if event is None:
            word = AQ_WORD_CASE.fullmatch(clean)
            if word:
                pending_word = (*word.groups(), number)
                continue
            if "LoudnessManTest Case '" in clean:
                problems.append(f"Malformed AQ word interleave at line {number}")
                continue
            match = CASE.search(line)
            if match:
                event = match.groups()
            else:
                header = CASE_HEADER.search(line)
                if header and any(target + "." in header.group(1) for target in TARGETS):
                    split = SPLIT_CASE.fullmatch(clean)
                    if split:
                        pending = (split.group(1), number)
                    else:
                        problems.append(f"Malformed native/UI case at line {number}: {header.group(1)}")
                elif RESULT_SUFFIX.fullmatch(clean):
                    problems.append(f"Orphan case result suffix at line {number}")
                continue
        raw, status = event
        parsed = CASE_ID.fullmatch(raw)
        if not parsed:
            if any(target + "." in raw for target in TARGETS):
                problems.append(f"Unsupported native/UI case identity at line {number}: {raw}")
            continue
        target, owner, method = parsed.groups()
        identity = f"{target}.{owner}/{method}"
        if status in ("failed", "skipped"):
            problems.append(f"{status} case at line {number}: {identity}")
        if target not in TARGETS:
            continue
        observed.add(identity)
        last_case = number
        if reconstructed and (starts[identity] != 1 or sum(outcomes[identity].values()) != 0):
            problems.append(f"Ambiguous interleaved case at line {number}: {identity}")
        if status == "started":
            starts[identity] += 1
        elif status in ("passed", "failed", "skipped"):
            outcomes[identity][status] += 1
        else:
            problems.append(f"Unsupported native/UI case status at line {number}: {status} {identity}")
    if pending is not None:
        raw, header_line = pending
        problems.append(f"Unfinished interleaved case at line {header_line}: {raw}")
    if pending_word is not None:
        raw, status, header_line = pending_word
        problems.append(f"Unfinished AQ word interleave at line {header_line}: {raw}")
    if len(successes) != 1:
        problems.append(f"Expected exactly one {success_label} marker; found {len(successes)}")
    elif successes[0] <= last_case:
        problems.append(f"{success_label} marker must follow every native/UI case result")
    missing = sorted(identity for identity in expected if outcomes[identity]["passed"] == 0)
    unexpected = sorted(observed - expected)
    duplicates = sorted(identity for identity in observed if starts[identity] > 1 or sum(outcomes[identity].values()) > 1)
    for label, identities in (("missing passing cases", missing), ("unexpected native/UI cases", unexpected), ("duplicate cases", duplicates)):
        if identities:
            problems.append(f"{label} ({len(identities)}):\n  " + "\n  ".join(identities))
    if problems:
        native = sum(identity.startswith(TARGETS[0] + ".") for identity in expected)
        raise EvidenceError(f"Expected native={native} ui={len(expected) - native} total={len(expected)}\n- " + "\n- ".join(problems))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--log", required=True, type=Path, help="fresh, raw stdout/stderr log from one xcodebuild test invocation")
    parser.add_argument("--selection-only", action="store_true", help="expect only the four explicit selection-regression classes; no UI tests")
    parser.add_argument("--invocation", choices=("test", "test-without-building"), default="test",
                        help="exact xcodebuild action whose success marker must finish this log")
    args = parser.parse_args(argv)
    try:
        expected = source_manifest(args.repo_root, args.selection_only)
        verify_log(args.log.read_text(encoding="utf-8", errors="replace"), expected, invocation=args.invocation)
    except (OSError, UnicodeError, EvidenceError) as error:
        print(f"Native test evidence failed: {error}", file=sys.stderr)
        return 1
    native = sum(identity.startswith(TARGETS[0] + ".") for identity in expected)
    print(f"Native test evidence verified: native={native} ui={len(expected) - native} total={len(expected)} mode={'selection-only' if args.selection_only else 'full'}")
    for identity in sorted(expected):
        print("PASS " + identity)
    return 0


if __name__ == "__main__":
    sys.exit(main())
