"""Separate owner-only experimental phone build; never marks native acceptance passed."""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
SOURCE = "e9feab6815a7b5d90cfd3851c3a61d0608267cc7"
APP_TREE = "79093f6ddf43272aff597bcc5a5749b6e8d001c4"
CORE_TREE = "64d337f129d7ee93a8b8f7361294e6b50cedfdd6"
SIGNER_SHA = "ead74c3e3ca0938bdff58d4f09448ece01ac790388fda946bdc2e986f33d2e14"
REPOSITORY = "AGForge-Labs/OfflineTikTokPlayer-public"
SECRETS = ("APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD",
           "APPLE_PROVISIONING_PROFILE_BASE64", "APP_STORE_CONNECT_KEY_BASE64")
ROOT = Path(__file__).resolve().parents[1]
PHASES = {"credential-inputs", "credential-validation", "project-validation", "archive", "export-upload", "apple-processing", "complete"}
REASONS = {"profile-not-found", "profile-entitlement-mismatch", "certificate-not-found", "keychain-signing-failed",
           "swift-compilation", "xcodebuild-error", "tool-validation-failed"}
DIAGNOSTIC_CERTIFICATE = b"""-----BEGIN CERTIFICATE-----
MIIECDCCAnCgAwIBAgIUZpv+W/YXo99JxSwDLtPIy9k2jWwwDQYJKoZIhvcNAQEL
BQAwNDEyMDAGA1UEAwwpT2ZmbGluZSBQbGF5ZXIgZGlhZ25vc3RpYyBlbmNyeXB0
aW9uIG9ubHkwHhcNMjYxMDI1MTk0MDA0WhcNMjYxMTAxMTk0NTA0WjA0MTIwMAYD
VQQDDClPZmZsaW5lIFBsYXllciBkaWFnbm9zdGljIGVuY3J5cHRpb24gb25seTCC
AaIwDQYJKoZIhvcNAQEBBQADggGPADCCAYoCggGBAKa26+Qt3NZ+W5Dv8mLN2t0Y
G/tsO0kkrkCGAsD8COM+NbAKwpC8a/AcRBlK/6cE/mUJPrVbFIsdalXULE8FmzAW
307jtdUC/AhAqcXrhG/9QQZ4lVzYK5RCz/stKDvGkJASPMPhtT4qsn8fiVoLPnjA
EhvARN0LZ+EsLRj+uDQpJQBCm49dffQaqRJI3vWZnnxPuGPNHNSRIsmUSXsckEWE
5C2oIDdjSzj+BJt0pDjvakpmocBM9mEqlTzSxhv9olkFOf50NpY/jN+HglZlFM5h
ZRJxsCF8x9EpT3M908wKxMYXvd4YYy7M1DeracDe83/2Z1HyquTg6NZU5UC++Ou9
WXRnfqp1CORKTLSVElW0OT8YQOUU2DOfUW9HpLjX6WDxF6LRERxUF5ItEuM0h8Q4
aflRDwTE5KbF85JGrryATkEkMEeeKEhKXU3Gz9QV6P7eUIGftIHq1Kh696qCyU+4
BcyCH8zYFfm+t5UpL40cYG6zCDkAk0HJ6sEmht7n6wIDAQABoxIwEDAOBgNVHQ8B
Af8EBAMCBSAwDQYJKoZIhvcNAQELBQADggGBAIvzbiS1FX1LHYWOOovZA+uCgQKa
Mep0IOZZ7zDu3WHy4Z1Uv2aZDYor0Hekf6syXVSqD+DFTqiGMChEtxwYiUaxBcai
lE5pvcAbIMDLzpm7uE2lARmm4dKJHPtqHECd620Sd9k9Cj0yRiqny9/dQQa0EX40
rxi61QwnGQ4xpEbfGp290MPFeEI1xwn1cAs6jDY/6IJx2MrymlHFnX/TEgtDv27p
AfxAorHCiFF7SQmufMf+wtgf7/8W6hSC74VguFmsavu7nRfvMyt6c/4HB6iVfRve
9dVwEx58mAiA16KycXLMAXxyZmSAJ/qWT4ADqk25QdCa34h9MIEju2f5g7YitD4d
WE3+YQ/wF/mJcCYXEfllG9jpEcIJpMzqInQXG39srR5OW8nPr32NrtY6lixwVd9O
C3Lr3MFLPp5nW+XyviyVOy/tHNgLo532m9SpUReen67BB72vz6UxmhqWRrCRK2MB
IgtjJ/GZxotnmPYGh6qOJMm7orcTiSYsg2Rhyg==
-----END CERTIFICATE-----
"""


def seal_diagnostic(raw, phase, exit_code, directory, *, openssl="openssl"):
    """Only a public encryption certificate is present on the runner; no plaintext fallback."""
    certificate = directory / "diagnostic-encryption.pem"
    certificate.write_bytes(DIAGNOSTIC_CERTIFICATE)
    payload = json.dumps(dict(source=SOURCE, control=os.environ.get("EXPECTED_CONTROL_COMMIT", ""),
        build=os.environ.get("EXPERIMENTAL_BUILD_NUMBER", ""), phase=phase, exitCode=exit_code,
        tail=base64.b64encode(raw[-48 * 1024:]).decode("ascii"))).encode()
    environment = {name: os.environ[name] for name in ("PATH", "SYSTEMROOT", "TMPDIR") if name in os.environ}
    result = subprocess.run([openssl, "cms", "-encrypt", "-aes-256-cbc", "-binary", "-outform", "DER",
                             "-recip", str(certificate)], input=payload, capture_output=True,
                            env=environment, timeout=10)
    if result.returncode or not 128 <= len(result.stdout) <= 96 * 1024 or result.stdout[:1] != b"\x30":
        raise RuntimeError("Diagnostic encryption failed; plaintext remains suppressed.")
    return base64.b64encode(result.stdout).decode("ascii")


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
    require(numbers > (22, 1, 0), "The experimental build must follow existing build22.1.")
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


def compatible_archive_arguments(arguments):
    # Native37 emitted the per-file WMO objects Xcode expects using its default
    # backend thread count. The old NO override instead leaves those files absent.
    if Path(arguments[0]).name == "xcodebuild" and "archive" in arguments and "-exportArchive" not in arguments:
        return [value for value in arguments if value != "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO"]
    return list(arguments)


def upload_with_receipt(helper, configuration, directory, build, receipt):
    original = helper.run_tool
    failed = False
    def record(phase, reason=None, location=None, sealed=None, exit_code=None):
        nonlocal failed
        if failed:
            return
        failed = reason is not None
        status = {"phase": phase, "reason": reason}
        if location is not None:
            status.update(sourceFile=location[0], line=location[1])
        if sealed is not None:
            status.update(sealedDiagnostic=sealed, exitCode=exit_code)
        receipt.write_text(json.dumps(status), encoding="utf-8")
    def observed_tool(arguments, **kwargs):
        arguments = compatible_archive_arguments(arguments)
        tool = Path(arguments[0]).name
        phase = ("export-upload" if "-exportArchive" in arguments else "archive") if tool == "xcodebuild" else (
            "project-validation" if any("generate-ios-project.py" in str(value) for value in arguments) else "credential-validation")
        record(phase)
        try:
            if tool != "xcodebuild":
                return original(arguments, **kwargs)
            environment = dict(kwargs.pop("env", os.environ))
            for name in (*SECRETS, "APPLE_PRIVATE_DELIVERY"):
                environment.pop(name, None)
            kwargs.pop("visible", None)
            kwargs.pop("combined_output", None)
            with tempfile.TemporaryFile(dir=directory) as output:
                result = subprocess.run(arguments, env=environment, stdout=output, stderr=subprocess.STDOUT, **kwargs)
                if result.returncode:
                    output.seek(0, os.SEEK_END)
                    size = output.tell()
                    output.seek(max(0, size - 8 * 1024 * 1024))
                    raw = output.read(8 * 1024 * 1024)
                    errors = [line for line in raw.splitlines() if b"error:" in line.lower()]
                    text = b"\n".join(errors).lower()
                    patterns = ((b"no profiles for", "profile-not-found"), (b"requires a provisioning profile", "profile-not-found"),
                                (b"doesn't include", "profile-entitlement-mismatch"),
                                (b"no signing certificate", "certificate-not-found"),
                                (b"errsecinternalcomponent", "keychain-signing-failed"))
                    reason = next((value for pattern, value in patterns if pattern in text), "xcodebuild-error")
                    location = None
                    known = {path.name for path in Path(getattr(helper, "ROOT", directory)).glob("ios/**/*.swift")}
                    for line in errors:
                        match = re.search(rb"(?:^|/)([A-Za-z0-9_]+\.swift):([0-9]+):(?:[0-9]+:)?\s*error:", line)
                        if match and match[1].decode("ascii") in known:
                            location = (match[1].decode("ascii"), int(match[2]))
                            reason = "swift-compilation"
                            break
                    sealed = None
                    try:
                        sealed = seal_diagnostic(raw, phase, result.returncode, directory)
                    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                        pass
                    record(phase, reason, location, sealed, result.returncode)
                    raise RuntimeError("Xcode failed; raw signing output is suppressed.")
            return b""
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            record(phase, "tool-validation-failed")
            raise
    helper.run_tool = observed_tool
    try:
        record("credential-validation")
        material = helper.materialize(configuration, directory)
        helper.upload(configuration, directory, material, build)
        record("complete")
    finally:
        helper.run_tool = original


NATIVE_RUN = 40416241013

def require_native_result(read=None):
    if read is None:
        import urllib.request
        def read():
            request = urllib.request.Request("https://api.github.com/repos/" + REPOSITORY + "/actions/runs/" + str(NATIVE_RUN),
                headers={"Accept": "application/vnd.github+json", "User-Agent": "OfflinePlayer-owner-delivery"})
            with urllib.request.urlopen(request, timeout=20) as response:
                data = response.read(128 * 1024 + 1)
                require(len(data) <= 128 * 1024, "Native receipt exceeded its bound.")
                return json.loads(data)
    result = read()
    require(isinstance(result, dict) and isinstance(result.get("repository"), dict), "Invalid native run receipt.")
    require(result.get("id") == NATIVE_RUN and result.get("head_sha") == SOURCE
        and result.get("status") == "completed" and result.get("conclusion") == "success"
        and result.get("path") == ".github/workflows/phone-native.yml" and result.get("event") == "push"
        and result.get("head_branch") == "fix/source-preparation23"
        and result.get("repository", {}).get("full_name") == REPOSITORY
        and result.get("repository", {}).get("private") is False,
        "The exact focused public native run must pass before signing; full gapless acceptance remains unresolved.")


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
        with tempfile.TemporaryDirectory(prefix="phone-diagnostic-", dir=environment["RUNNER_TEMP"]) as temporary:
            receipt = Path(temporary) / "phase.json"
            receipt.write_text(json.dumps({"phase": "credential-inputs", "reason": None}))
            environment["EXPERIMENTAL_RECEIPT_PATH"] = str(receipt)
            try:
                public.run_redacted([sys.executable, "-B", str(Path(__file__).resolve()), "child"],
                                    env=environment, cwd=ROOT, timeout=600)
            except RuntimeError:
                status = json.loads(receipt.read_text()) if receipt.stat().st_size <= 128 * 1024 else {}
                phase, reason = status.get("phase"), status.get("reason")
                if isinstance(phase, str) and phase in PHASES:
                    category = reason if isinstance(reason, str) and reason in REASONS else "unclassified"
                    print("Experimental failure category: " + phase + "/" + category, flush=True)
                    file, line = status.get("sourceFile"), status.get("line")
                    if isinstance(file, str) and re.fullmatch(r"[A-Za-z0-9_]+\.swift", file) and type(line) is int and 0 < line < 1_000_000:
                        print("Public compiler location: " + file + ":" + str(line), flush=True)
                    sealed = status.get("sealedDiagnostic")
                    if isinstance(sealed, str) and 128 <= len(sealed) <= 128 * 1024 and re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", sealed):
                        for offset in range(0, len(sealed), 4096):
                            print("Encrypted diagnostic " + str(offset // 4096 + 1) + ": " + sealed[offset:offset + 4096], flush=True)
                raise
            completed_status = json.loads(receipt.read_text())
        delivery = completed_status.get("delivery", {})
        print("Apple owner delivery: " + json.dumps(delivery, sort_keys=True))
        message = "Uploaded experimental internal-only phone build " + build + " from " + SOURCE + ". Native and phone acceptance remain unresolved."
        print(message)
        if environment.get("GITHUB_STEP_SUMMARY"):
            with Path(environment["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as stream:
                stream.write(message + "\n")
        return
    require_native_result()
    helper = load_module("existing_private_delivery", candidate / "scripts/private-delivery.py")
    configuration = helper.public_configuration(environment)
    helper.validate_configuration(configuration)
    runner_temp = Path(environment["RUNNER_TEMP"]).resolve(strict=True)
    receipt = Path(environment["EXPERIMENTAL_RECEIPT_PATH"]).resolve(strict=True)
    require(receipt.name == "phase.json" and receipt.parent.name.startswith("phone-diagnostic-")
            and receipt.parent.parent == runner_temp, "Only the owned diagnostic receipt is admitted.")
    with tempfile.TemporaryDirectory(prefix="experimental-player-signing-", dir=runner_temp) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        apple_owner = load_module("apple_owner", ROOT / "scripts/apple-owner-runner.py")
        apple = apple_owner.Apple(configuration, directory)
        apple_owner.before_upload(apple, build)
        upload_with_receipt(helper, configuration, directory, build, receipt)
        receipt.write_text(json.dumps({"phase": "apple-processing", "reason": None}))
        delivery = apple_owner.finish(apple, build)
        receipt.write_text(json.dumps({"phase": "complete", "reason": None, "delivery": delivery}))


if __name__ == "__main__":
    try:
        main()
    except (KeyError, ValueError, RuntimeError, OSError, subprocess.SubprocessError):
        print("Experimental phone build stopped. Check Apple before any new dispatch; private output is suppressed.", file=sys.stderr)
        sys.exit(1)
