#!/usr/bin/env python3
"""Project two exact production resource declarations for the non-DEBUG Mac adapter."""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


MAX_SOURCE_BYTES = 256 * 1024
SOURCE = Path("ios/OfflineTikTokPlayer/Playback/ContinuousPictureInPicture.swift")
OUTPUT = Path("artifacts/apple-buffer/production-video-resources.swift")
PROVENANCE = Path("artifacts/apple-buffer/production-video-resources.provenance.json")
NAMES = ("PreparedVideoResource", "VideoResourcePreparation")
OUTER = re.compile(r"(?m)^[ \t]*@MainActor\s+final\s+class\s+ContinuousPictureInPicture\s*:\s*NSObject\s*\{")
RESOURCE = re.compile(r"(?m)^[ \t]*@MainActor\s+final\s+class\s+(PreparedVideoResource|VideoResourcePreparation)\s*\{")
NAMED = re.compile(r"\b(?:class|struct|enum|actor|typealias)\s+(ContinuousPictureInPicture|PreparedVideoResource|VideoResourcePreparation)\b")


class ProjectionError(ValueError):
    pass


def verifier():
    path = Path(__file__).with_name("verify-native-test-log.py")
    spec = importlib.util.spec_from_file_location("_apple_buffer_swift_mask", path)
    if spec is None or spec.loader is None:
        raise ProjectionError("Swift mask unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def project_resources(raw):
    if not isinstance(raw, bytes) or len(raw) > MAX_SOURCE_BYTES:
        raise ProjectionError("Source byte limit")
    try:
        text = raw.decode("utf-8")
        parser = verifier()
        code = parser.swift_code(text)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise ProjectionError("Invalid Swift source") from error
    depth, conditionals = 0, 0
    for character in code:
        depth += (character == "{") - (character == "}")
        if depth < 0:
            raise ProjectionError("Unbalanced braces")
    for line in code.splitlines():
        if re.match(r"\s*#if\b", line):
            conditionals += 1
        elif re.match(r"\s*#endif\b", line):
            conditionals -= 1
        elif re.match(r"\s*#(?:else|elseif)\b", line) and conditionals == 0:
            raise ProjectionError("Unbalanced conditional")
        if conditionals < 0:
            raise ProjectionError("Unbalanced conditional")
    if depth or conditionals:
        raise ProjectionError("Unbalanced source")
    declarations = [match.group(1) for match in NAMED.finditer(code)]
    if any(declarations.count(name) != 1 for name in ("ContinuousPictureInPicture", *NAMES)):
        raise ProjectionError("Missing or duplicate declaration")
    outers = list(OUTER.finditer(code))
    if len(outers) != 1:
        raise ProjectionError("Unexpected outer declaration")
    outer = outers[0]

    def depth_at(position):
        return code.count("{", 0, position) - code.count("}", 0, position)

    try:
        outer_end = parser.class_end(code, outer.end())
        if depth_at(outer.start()) != 0 or parser.conditional_at(code, outer.start()):
            raise ProjectionError("Outer must be unconditional top level")
        matches = list(RESOURCE.finditer(code))
        if len(matches) != 2 or {match.group(1) for match in matches} != set(NAMES):
            raise ProjectionError("Unexpected resource declarations")
        blocks, ranges = [], {}
        for match in matches:
            end = parser.class_end(code, match.end()) + 1
            if not outer.end() <= match.start() < end <= outer_end:
                raise ProjectionError("Resource outside outer")
            if depth_at(match.start()) != depth_at(outer.end()) or parser.conditional_at(code, match.start()):
                raise ProjectionError("Resource must be an unconditional immediate member")
            block = text[match.start():end].encode("utf-8")
            blocks.append(block)
            ranges[match.group(1)] = (len(text[:match.start()].encode("utf-8")), block)
    except parser.EvidenceError as error:
        raise ProjectionError("Unbalanced declaration") from error
    header = (b"import Foundation\nimport AVFoundation\nimport CoreVideo\n\n"
              b"#if DEBUG\n#error(\"Production resource projection is non-DEBUG only\")\n#endif\n\n"
              b"@MainActor\nfinal class ContinuousPictureInPicture: NSObject {\n")
    output = header + b"\n".join(blocks) + b"\n}\n"
    provenance = {"schema": 1, "statusCode": 0, "blocks": 2, "nonDEBUGOnly": True,
                  "sourceBytes": len(raw), "sourceSHA256": hashlib.sha256(raw).hexdigest(),
                  "outputBytes": len(output), "outputSHA256": hashlib.sha256(output).hexdigest()}
    for label, name in zip(("prepared", "preparation"), NAMES):
        start, block = ranges[name]
        provenance[label + "OffsetBytes"] = start
        provenance[label + "LengthBytes"] = len(block)
        provenance[label + "SHA256"] = hashlib.sha256(block).hexdigest()
    return output, provenance


def generate(root):
    root = Path(root).resolve(strict=True)
    output, manifest = root / OUTPUT, root / PROVENANCE
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.parent.resolve() != output.parent or output.is_symlink() or manifest.is_symlink():
        raise ProjectionError("Unsafe output")
    # Failure cannot leave a previous valid projection available as a fallback.
    output.unlink(missing_ok=True)
    manifest.unlink(missing_ok=True)
    source = root / SOURCE
    if source.is_symlink() or source.resolve(strict=True) != source or source.stat().st_size > MAX_SOURCE_BYTES:
        raise ProjectionError("Unsafe source or source byte limit")
    with source.open("rb") as stream:
        raw = stream.read(MAX_SOURCE_BYTES + 1)
    projected, provenance = project_resources(raw)
    output.write_bytes(projected)
    manifest.write_bytes((json.dumps(provenance, sort_keys=True, separators=(",", ":")) + "\n").encode("ascii"))
    return provenance


def main():
    try:
        if len(sys.argv) != 1:
            raise ProjectionError("No arguments supported")
        result = generate(Path(__file__).resolve().parents[1])
    except (ProjectionError, OSError):
        print('{"schema":1,"statusCode":1,"blocks":0}')
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
