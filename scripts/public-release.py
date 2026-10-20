"""Owner-only public release gate. Never print signing output or publish signed artifacts."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

REPOSITORY = "AGForge-Labs/OfflineTikTokPlayer-public"
ROOT = Path(__file__).resolve().parents[1]
SECRETS = ("APPLE_PRIVATE_DELIVERY", "APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD",
           "APPLE_PROVISIONING_PROFILE_BASE64", "APPLE_SHARE_PROVISIONING_PROFILE_BASE64",
           "APP_STORE_CONNECT_KEY_BASE64")

def require(condition, message):
    if not condition:
        raise ValueError(message)

def validate_context(env, *, signing=False):
    expected = env.get("EXPECTED_COMMIT", "")
    checks = {
        "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
        "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_REF": "refs/heads/main",
        "GITHUB_WORKFLOW_REF": REPOSITORY + "/.github/workflows/public-testflight.yml@refs/heads/main",
        "GITHUB_WORKFLOW_SHA": expected, "GITHUB_SHA": expected,
        "GITHUB_ACTOR_ID": "105477711", "GITHUB_TRIGGERING_ACTOR": "Galaxybigbird",
        "GITHUB_RUN_ATTEMPT": "1", "RELEASE_AUTHORIZED": "true",
    }
    require(re.fullmatch(r"[0-9a-f]{40}", expected) is not None
            and all(env.get(name) == value for name, value in checks.items()),
            "Release requires the owner, first manual attempt, public repository main and exact reviewed workflow/source commit.")
    version = env.get("RELEASE_BUILD_NUMBER", "")
    require(re.fullmatch(r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}", version) is not None,
            "Provide an increasing Apple build number, for example 100.1.")
    if "OfflineTikTokPlayer" in REPOSITORY:
        numbers = tuple(map(int, version.split("."))) + (0,) * (3 - len(version.split(".")))
        require(numbers > (13, 1, 0), "Player build must be newer than the already uploaded 13.1.")
    if signing:
        require(env.get("RELEASE_ENVIRONMENT") == "release"
                and env.get("RELEASE_ACCEPTED_COMMIT") == expected,
                "Protected release environment must attest acceptance of this exact commit before signing.")
    return version

def reject_private_inputs(root, env):
    forbidden = ("private-data", "private-baselines", "local-data", "data/catalog.json",
                 "data/locations.geojson", "data/paths.geojson", ".env", "config.local.json")
    overrides = ("APARTMENTFINDER_PRIVATE_PACK_DIRECTORY", "APARTMENTFINDER_PRIVATE_SOURCE_DIRECTORY")
    require(not any((root / name).exists() or (root / name).is_symlink() for name in forbidden)
            and not any(env.get(name) for name in overrides),
            "Public release refuses private data, local sessions and private pack overrides.")

def verify_checkout(env):
    head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=ROOT, text=True)
    require(head == env["EXPECTED_COMMIT"] and not status, "Release checkout differs from the exact reviewed commit.")
    reject_private_inputs(ROOT, env)

def run_redacted(command, *, env, cwd, timeout=1800):
    # Do not tail Xcode, codesign, provisioning or Apple output into public logs.
    # The temporary file is removed on both success and failure.
    with tempfile.TemporaryFile(dir=env.get("RUNNER_TEMP") or None) as output:
        try:
            result = subprocess.run(command, env=env, cwd=cwd, stdout=output,
                                    stderr=subprocess.STDOUT, timeout=timeout, check=False)
        except (OSError, subprocess.SubprocessError):
            raise RuntimeError("Release command stopped; private arguments and output were suppressed. Check Apple before retrying an uncertain upload.") from None
        if result.returncode:
            raise RuntimeError("Release command failed; private arguments and output were suppressed. Check Apple before a new dispatch.")

def load_script(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def perform_release(env, version):
    try:
        run_redacted([sys.executable, "-B", str(ROOT / "scripts/private-delivery.py"),
                      "--public-release", "--upload"], env=env, cwd=ROOT)
    finally:
        # Fixed generated paths inside a fresh disposable checkout, never user media.
        shutil.rmtree(ROOT / "artifacts/release", ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "sign-upload"))
    args = parser.parse_args()
    env = dict(os.environ)
    version = validate_context(env, signing=args.command == "sign-upload")
    verify_checkout(env)
    if args.command == "check":
        print("Exact owner-reviewed public source and release request verified; no signing credentials were used.")
        return
    require(sys.platform == "darwin", "Signing requires the standard hosted macOS runner.")
    perform_release(env, version)
    message = "Confirmed upload of internal TestFlight build " + version + " from " + env["EXPECTED_COMMIT"] + ". Apple processing, existing private tester availability and installed-device acceptance remain."
    print(message)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as output:
            output.write(message + "\n")

if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError):
        # Even parser/backend errors must not reveal transformed secrets or paths.
        print("Public release stopped. Check exact source, protected acceptance, signing configuration and Apple status before retrying.", file=sys.stderr)
        sys.exit(1)
