"""Separate owner-only experimental phone build; never marks native acceptance passed."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
SOURCE = "9489d3b3ae85cb41b5ef4f56633dcf41b36505af"
APP_TREE = "afe3a687be3ed2d905c5841950ee7877f218e647"
CORE_TREE = "859923fd7ca5fd3ea2689bf7b077e7f8af65fcb3"
SIGNER_SHA = "ead74c3e3ca0938bdff58d4f09448ece01ac790388fda946bdc2e986f33d2e14"
REPOSITORY = "AGForge-Labs/OfflineTikTokPlayer-public"
SECRETS = ("APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD",
           "APPLE_PROVISIONING_PROFILE_BASE64", "APP_STORE_CONNECT_KEY_BASE64")
ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)

def validate_context(environment, event, *, signing=False):
    expected = environment.get("EXPECTED_CONTROL_COMMIT", "")
    checks = dict(GITHUB_ACTIONS="true", RUNNER_OS="macOS", RUNNER_ENVIRONMENT="github-hosted",
                  GITHUB_REPOSITORY=REPOSITORY, GITHUB_REF="refs/heads/main",
                  GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR_ID="105477711",
                  GITHUB_TRIGGERING_ACTOR="Galaxybigbird", GITHUB_RUN_ATTEMPT="1",
                  GITHUB_WORKFLOW_REF=REPOSITORY + "/.github/workflows/public-experimental-phone.yml@refs/heads/main",
                  GITHUB_SHA=expected, GITHUB_WORKFLOW_SHA=expected,
                  EXPERIMENTAL_PHONE_AUTHORIZED="true")
    require(re.fullmatch(r"[0-9a-f]{40}", expected) is not None
            and all(environment.get(key) == value for key, value in checks.items()),
            "An exact owner/main/first manual experimental request is required.")
    repository = event.get("repository", {})
    require(repository.get("full_name") == REPOSITORY and repository.get("private") is False,
            "Only the existing public source repository is admitted.")
    build = environment.get("EXPERIMENTAL_BUILD_NUMBER", "")
    require(re.fullmatch(r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}", build) is not None,
            "An Apple-checked increasing build number is required.")
    numbers = tuple(map(int, build.split("."))) + (0,) * (3 - len(build.split(".")))
    require(numbers > (19, 1, 0), "The experimental build must follow existing build19.1.")
    require(not environment.get("APPLE_PRIVATE_DELIVERY"), "The private aggregate secret is not used here.")
    if signing:
        require(environment.get("RELEASE_ENVIRONMENT") == "release", "The existing protected release environment is required.")
    else:
        require(not any(environment.get(name) for name in SECRETS), "Preflight must run without signing inputs.")
    return build

def verify_checkouts(control, candidate, expected, *, git=None, signer_sha=SIGNER_SHA):
    control, candidate = Path(control).resolve(strict=True), Path(candidate).resolve(strict=True)
    if git is None:
        def git(root, *arguments):
            return subprocess.check_output(["git", "--no-optional-locks", "-C", str(root), *arguments],
                                           stdin=subprocess.DEVNULL, timeout=10).decode().strip()
    pins = {(control, "rev-parse", "HEAD"): expected,
            (candidate, "rev-parse", "HEAD"): SOURCE,
            (candidate, "rev-parse", "HEAD:ios/OfflineTikTokPlayer"): APP_TREE,
            (candidate, "rev-parse", "HEAD:ios/PlayerCore"): CORE_TREE,
            (control, "status", "--porcelain", "--untracked-files=all"): "",
            (candidate, "status", "--porcelain", "--untracked-files=all"): ""}
    require(all(git(*arguments) == value for arguments, value in pins.items()),
            "Experimental workflow/source must match every frozen pin and be clean.")
    forbidden = ("private-data", "private-baselines", "local-data", "data/catalog.json", ".env", "config.local.json")
    require(not any((root / name).exists() or (root / name).is_symlink()
                    for root in (control, candidate) for name in forbidden), "Private inputs are refused.")
    signer = candidate / "scripts/private-delivery.py"
    require(signer.stat().st_size <= 256 * 1024 and hashlib.sha256(signer.read_bytes()).hexdigest() == signer_sha,
            "The unchanged reviewed signing helper is required.")


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "sign-upload", "child"))
    args = parser.parse_args()
    environment = dict(os.environ)
    with Path(environment["GITHUB_EVENT_PATH"]).open(encoding="utf-8") as stream:
        event = json.load(stream)
    build = validate_context(environment, event, signing=args.command != "check")
    workspace = Path(environment["GITHUB_WORKSPACE"]).resolve(strict=True)
    candidate = workspace / "candidate"
    require(ROOT == workspace / "control" and not (workspace / "control").is_symlink()
            and not candidate.is_symlink() and candidate.resolve(strict=True).parent == workspace,
            "Only the two owned workspace checkouts are admitted.")
    verify_checkouts(ROOT, candidate, environment["EXPECTED_CONTROL_COMMIT"])
    if args.command == "check":
        print("Exact experimental source and owner request verified. Native acceptance remains failed.")
        return
    require(sys.platform == "darwin", "Signing requires the existing standard macOS runner.")
    if args.command == "sign-upload":
        public = load_module("existing_public_release", ROOT / "scripts/public-release.py")
        # Reuse the existing redacted subprocess boundary; no raw Apple/Xcode output or artifact is published.
        public.run_redacted([sys.executable, "-B", str(Path(__file__).resolve()), "child"],
                            env=environment, cwd=ROOT, timeout=360)
        message = "Uploaded experimental internal-only phone build " + build + " from " + SOURCE + ". Native and phone acceptance remain unresolved."
        print(message)
        if environment.get("GITHUB_STEP_SUMMARY"):
            with Path(environment["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as stream:
                stream.write(message + "\n")
        return
    helper = load_module("existing_private_delivery", candidate / "scripts/private-delivery.py")
    configuration = helper.public_configuration(environment)
    helper.validate_configuration(configuration)
    runner_temp = Path(environment["RUNNER_TEMP"]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="experimental-player-signing-", dir=runner_temp) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        material = helper.materialize(configuration, directory)
        helper.upload(configuration, directory, material, build)


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.SubprocessError):
        print("Experimental phone build stopped. Check Apple before any new dispatch; private output is suppressed.", file=sys.stderr)
        sys.exit(1)
