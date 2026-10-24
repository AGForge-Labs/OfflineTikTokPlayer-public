#!/usr/bin/env python3
"""Transport unsigned test products from the same source and SDK; never sign or deploy."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import platform
import posixpath
import subprocess
import tarfile

def digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(512 * 1024), b""): value.update(chunk)
    return value.hexdigest()

def safe_member(member):
    parts = PurePosixPath(member.name).parts
    if not parts or parts[0] != "Products" or any(p in ("..", ".") for p in parts) or "\\" in member.name or ":" in member.name:
        raise ValueError("Invalid build-product path")
    if member.issym():
        target = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), member.linkname))
        if target != "Products" and not target.startswith("Products/"):
            raise ValueError("External build-product symlink")
    elif not member.isfile() and not member.isdir():
        raise ValueError("Unsupported build-product entry")

def inventory(tar):
    records = {}; seen = set()
    for member in tar.getmembers():
        if member.name in seen: raise ValueError("Duplicate build-product entry")
        seen.add(member.name)
        if member.name == "build-context.json":
            if not member.isfile(): raise ValueError("Invalid build context")
            continue
        safe_member(member)
        if member.isdir(): continue
        row = dict(mode=member.mode & 0o777)
        if member.issym(): row.update(kind="symlink", target=member.linkname)
        else:
            with tar.extractfile(member) as stream: sha = digest(stream)
            row.update(kind="file", bytes=member.size, sha256=sha)
        records[member.name] = row
    if not records: raise ValueError("Empty compiled-product bundle")
    return records

def pack(products, archive, context):
    if products.name != "Products" or not products.is_dir(): raise ValueError("Missing compiled products")
    archive.parent.mkdir(parents=True, exist_ok=True)
    # Inventory and archive the very same bytes; no second read of live binaries.
    with tarfile.open(archive, "w:gz", compresslevel=1) as tar: tar.add(products, arcname="Products")
    with tarfile.open(archive) as tar: records = inventory(tar)
    payload = json.dumps(dict(schema=1, context=context, products=records), sort_keys=True).encode()
    # gzip tar cannot append. Copy existing archive members, preserving executable
    # modes and internal framework symlinks, then append the small context record.
    temporary = archive.with_suffix(".packing")
    try:
        with tarfile.open(archive) as source, tarfile.open(temporary, "w:gz", compresslevel=1) as target:
            for member in source:
                stream = source.extractfile(member) if member.isfile() else None
                try: target.addfile(member, stream)
                finally:
                    if stream is not None: stream.close()
            member = tarfile.TarInfo("build-context.json"); member.size = len(payload); member.mode = 0o644
            target.addfile(member, io.BytesIO(payload))
        temporary.replace(archive)
    finally:
        if temporary.exists(): temporary.unlink()
    print("NativeProfileProducts " + json.dumps(dict(mode="pack", files=len(records), source=context["source"])))

def unpack(archive, products, context):
    if products.name != "Products" or products.exists(): raise ValueError("Refuse existing compiled products")
    with tarfile.open(archive) as tar:
        records = inventory(tar)
        try:
            with tar.extractfile("build-context.json") as stream: manifest = json.load(stream)
        except (KeyError, TypeError, json.JSONDecodeError) as error: raise ValueError("Missing build context") from error
        if manifest != dict(schema=1, context=context, products=records):
            raise ValueError("Source, SDK, profile or compiled-product checksum mismatch")
        # All identity and payload checks finish before the first extraction.
        products.parent.mkdir(parents=True, exist_ok=True)
        tar.extractall(products.parent, members=[m for m in tar.getmembers() if m.name != "build-context.json"], filter="data")
    print("NativeProfileProducts " + json.dumps(dict(mode="unpack", files=len(records), source=context["source"], verified=True)))

def build_context(root):
    def read(args): return subprocess.check_output(args, cwd=root, text=True, timeout=30).strip()
    subprocess.run(["git", "diff", "--quiet", "HEAD", "--", "ios", "scripts", "tests"], cwd=root, check=True, timeout=30)
    return dict(source=read(["git", "rev-parse", "HEAD"]), xcode=read(["xcodebuild", "-version"]),
        sdk=read(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"]), architecture=platform.machine(),
        profile=hashlib.sha256((root / "tests/playback-acceptance.json").read_bytes()).hexdigest(),
        optimization="-O", debugHooks=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("pack", "unpack"))
    parser.add_argument("--products", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    args = parser.parse_args(); root = Path(__file__).resolve().parents[1]
    try: globals()[args.mode](args.products, args.archive, build_context(root))
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        parser.exit(1, "Unsigned build-product check failed: " + str(error) + "\n")

if __name__ == "__main__": main()
