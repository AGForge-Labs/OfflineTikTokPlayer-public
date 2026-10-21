#!/usr/bin/env python3
"""Retain bounded original synthetic XCTest attachments after the test process."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time


IOS_TREE = "dd80aec49eedf710fd50fcdb61bcf4e0bbe5578a"
REPOSITORY = "AGForge-Labs/OfflineTikTokPlayer-public"
MAX_FILES, MAX_IMAGES = 32, 24
MAX_TOTAL_BYTES, MAX_PNG_BYTES = 32 * 1024 * 1024, 8 * 1024 * 1024
MAX_STDOUT_BYTES = 32 * 1024


class EvidenceError(Exception):
    def __init__(self, status_code):
        self.status_code = status_code
        super().__init__(status_code)


def _regular(path, directory=False):
    value = path.lstat()
    if stat.S_ISLNK(value.st_mode) or getattr(value, "st_file_attributes", 0) & 0x400:
        raise EvidenceError(2)
    if not (stat.S_ISDIR(value.st_mode) if directory else stat.S_ISREG(value.st_mode)):
        raise EvidenceError(2)
    return value


def _lineage(root, path):
    try:
        parts = path.relative_to(root).parts
    except ValueError:
        raise EvidenceError(2) from None
    _regular(root, directory=True)
    current = root
    for part in parts:
        current = current / part
        _regular(current, directory=True)


def _inventory(root):
    """Inspect only our dedicated export directory; stop at the first bound."""
    pending, files, names, inodes = [(root, 0)], [], set(), set()
    entries = total = 0
    _regular(root, directory=True)
    while pending:
        directory, depth = pending.pop()
        with os.scandir(directory) as children:
            for child in children:
                entries += 1
                if entries > 64 or depth > 8:
                    raise EvidenceError(5)
                path = Path(child.path)
                value = path.lstat()
                if stat.S_ISLNK(value.st_mode) or getattr(value, "st_file_attributes", 0) & 0x400:
                    raise EvidenceError(2)
                relative = path.relative_to(root).as_posix()
                if len(relative) > 512 or "\\" in relative or any(ord(c) < 32 for c in relative):
                    raise EvidenceError(2)
                if relative.casefold() in names:
                    raise EvidenceError(2)
                names.add(relative.casefold())
                if stat.S_ISDIR(value.st_mode):
                    pending.append((path, depth + 1))
                    continue
                identity = (value.st_dev, value.st_ino)
                if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1 or identity in inodes):
                    raise EvidenceError(2)
                inodes.add(identity)
                files.append((relative, path, value))
                total += value.st_size
                if len(files) > MAX_FILES or total > MAX_TOTAL_BYTES:
                    raise EvidenceError(5)
    return sorted(files)


def run_bounded(argv, *, timeout_seconds, export_root=None):
    """One owned process group; bounded spool and polling, never unbounded PIPEs.

    Polling limits observed temporary output. It is not an operating-system disk
    quota: a native tool can write between polls. Nothing is published on failure.
    """
    with tempfile.TemporaryFile() as spool:
        process = subprocess.Popen(argv, stdout=spool, stderr=subprocess.STDOUT,
                                   start_new_session=(os.name == "posix"))
        deadline = time.monotonic() + timeout_seconds
        try:
            while True:
                if os.fstat(spool.fileno()).st_size > MAX_STDOUT_BYTES:
                    raise EvidenceError(5)
                if export_root is not None:
                    _inventory(Path(export_root))
                code = process.poll()
                if code is not None:
                    break
                if time.monotonic() >= deadline:
                    raise EvidenceError(4)
                time.sleep(0.02)
        finally:
            # Also terminate any native descendants remaining after the leader.
            try:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                elif process.poll() is None:
                    process.kill()
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
        spool.seek(0)
        output = spool.read(MAX_STDOUT_BYTES + 1)
        if len(output) > MAX_STDOUT_BYTES:
            raise EvidenceError(5)
        return subprocess.CompletedProcess(argv, code, output)


def export_evidence(repo_root, environment, *, runner=run_bounded, platform_name=None):
    root = Path(repo_root).absolute()
    destination = root / "artifacts/compositor-evidence"
    try:
        required = dict(GITHUB_ACTIONS="true", GITHUB_SERVER_URL="https://github.com",
                        GITHUB_REPOSITORY=REPOSITORY, RUNNER_OS="macOS",
                        RUNNER_ENVIRONMENT="github-hosted", GITHUB_WORKSPACE=str(root))
        if (platform_name or platform.system()) != "Darwin" or any(
                environment.get(key) != value for key, value in required.items()):
            raise EvidenceError(1)
        source = environment.get("GITHUB_SHA", "")
        run_id, attempt = environment.get("GITHUB_RUN_ID", ""), environment.get("GITHUB_RUN_ATTEMPT", "")
        if not re.fullmatch(r"[0-9a-f]{40}", source) or any(
                not re.fullmatch(r"[1-9][0-9]{0,19}", value) for value in (run_id, attempt)):
            raise EvidenceError(1)
        native = root / "artifacts/native"
        _lineage(root, native)
        if os.path.lexists(destination):
            raise EvidenceError(2)
        bundles = []
        with os.scandir(native) as children:
            for index, child in enumerate(children):
                if index >= 256:
                    raise EvidenceError(5)
                if child.name.startswith("StartupGrace-") and child.name.endswith(".xcresult"):
                    bundles.append(Path(child.path))
        if len(bundles) != 1:
            raise EvidenceError(2)
        bundle = bundles[0]
        _lineage(root, bundle)

        def tool(arguments, *, operation, export_root=None, timeout=10):
            # Fixed operation names only; never publish native output or paths.
            print(f"CompositorEvidenceTool operation={operation} state=begin", flush=True)
            result = runner(arguments, timeout_seconds=timeout, export_root=export_root)
            print(f"CompositorEvidenceTool operation={operation} state=returned returnCode={result.returncode} stdoutBytes={len(result.stdout)}", flush=True)
            if result.returncode != 0 or len(result.stdout) > MAX_STDOUT_BYTES:
                raise EvidenceError(3)
            return result.stdout

        for expression, expected in (("HEAD", source), ("HEAD:ios", IOS_TREE)):
            actual = tool(["/usr/bin/git", "-C", str(root), "rev-parse", expression],
                          operation="source-head" if expression == "HEAD" else "source-ios-tree")
            if actual.decode("ascii").strip() != expected:
                raise EvidenceError(1)
        command = ["/usr/bin/xcrun", "xcresulttool", "export", "attachments"]
        help_text = tool(command + ["--help"], operation="installed-attachments-help")
        if b"--path" not in help_text or b"--output-path" not in help_text:
            raise EvidenceError(3)
        # Raw exports and staging never inhabit the workflow's upload path.
        with tempfile.TemporaryDirectory(prefix=".compositor-export-", dir=root / "artifacts") as temporary:
            temporary = Path(temporary)
            exported, staged = temporary / "native", temporary / "staged"
            exported.mkdir()
            tool(command + ["--path", str(bundle), "--output-path", str(exported)],
                 operation="attachments-export", export_root=exported, timeout=60)
            print("CompositorEvidenceStage operation=validate-export state=begin", flush=True)
            files = _inventory(exported)
            images = metadata = total = 0
            records = []
            staged.mkdir()
            for relative, path, before in files:
                extension = path.suffix.lower()
                if extension == ".png":
                    with path.open("rb") as stream:
                        if stream.read(8) != b"\x89PNG\r\n\x1a\n":
                            raise EvidenceError(6)
                    if before.st_size > MAX_PNG_BYTES:
                        raise EvidenceError(5)
                    images += 1
                    format_name = "png"
                elif extension == ".json":
                    json.loads(path.read_text(encoding="utf-8"))  # Syntax only; no Apple field assumptions.
                    metadata += 1
                    format_name = "json"
                else:
                    raise EvidenceError(6)
                target = staged / "attachments" / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
                digest = hashlib.sha256()
                with target.open("rb") as stream:
                    for chunk in iter(lambda: stream.read(65536), b""):
                        digest.update(chunk)
                after = _regular(path)
                if (after.st_size, after.st_mtime_ns, after.st_ino) != (
                        before.st_size, before.st_mtime_ns, before.st_ino):
                    raise EvidenceError(2)
                records.append(dict(path="attachments/" + relative, bytes=after.st_size,
                                    sha256=digest.hexdigest(), format=format_name))
                total += after.st_size
            if not 1 <= images <= MAX_IMAGES or metadata < 1 or len(records) + 1 > MAX_FILES:
                raise EvidenceError(5)
            manifest = dict(schemaVersion=1, sourceSHA=source, iosTree=IOS_TREE,
                            runID=run_id, runAttempt=attempt, repository=REPOSITORY,
                            resultBundle=bundle.relative_to(root).as_posix(),
                            nativeMetadataInterpreted=False, files=records)
            encoded = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
            if total + len(encoded) > MAX_TOTAL_BYTES:
                raise EvidenceError(5)
            (staged / "evidence-manifest.json").write_bytes(encoded)
            if os.path.lexists(destination):
                raise EvidenceError(2)
            print("CompositorEvidenceStage operation=publish-validated state=begin", flush=True)
            os.rename(staged, destination)
            return manifest
    except EvidenceError:
        raise
    except (OSError, ValueError, UnicodeError, RecursionError, subprocess.SubprocessError):
        raise EvidenceError(3) from None


def main():
    try:
        manifest = export_evidence(Path(__file__).resolve().parents[1], os.environ)
    except EvidenceError as error:
        print(f"CompositorEvidence statusCode={error.status_code}", file=sys.stderr)
        return 1
    print(f"CompositorEvidence statusCode=0 fileCount={len(manifest['files']) + 1}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
