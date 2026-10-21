"""Run free local gates before deliberately starting a native Mac check. Never dispatches CI."""
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import yaml


def _values(value):
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key)
            yield from _values(child)
    elif isinstance(value, list):
        for child in value:
            yield from _values(child)
    else:
        yield str(value)


def validate_workflow(config):
    try:
        if set(config) - {"name", "on", "permissions", "jobs"}:
            raise ValueError("The unsigned draft contains an unreviewed workflow setting.")
        if config.get("permissions") != {"contents": "read"}:
            raise ValueError("The unsigned draft needs only read access to its source.")
        if any(re.search(r"\bsecrets\s*(?:\.|\[)", value, re.IGNORECASE) for value in _values(config)):
            raise ValueError("The unsigned draft cannot use repository or environment secrets.")
        triggers = config["on"]
        if set(triggers) != {"workflow_dispatch"}:
            raise ValueError("Mac checks must only run by manual dispatch, never on pushes or schedules.")
        inputs = triggers["workflow_dispatch"]["inputs"]
        if set(inputs) != {"approve_runner"}:
            raise ValueError("The unsigned draft may request only a runner review.")
        approval = inputs["approve_runner"]
        if approval["type"] != "boolean" or str(approval["default"]).lower() != "false" or str(approval["required"]).lower() != "true":
            raise ValueError("Mac runner approval must be an explicit boolean, defaulting to false.")
        if set(config["jobs"]) != {"ios"}:
            raise ValueError("Only one Mac job is allowed per approved run.")
        job = config["jobs"]["ios"]
        if set(job) - {"if", "runs-on", "timeout-minutes", "steps"}:
            raise ValueError("The unsigned draft contains an unreviewed job setting.")
        if job.get("if") != "${{ inputs.approve_runner }}":
            raise ValueError("The Mac job must require the approval input.")
        if job["runs-on"] != "macos-26" or "strategy" in job:
            raise ValueError("Use one standard macos-26 runner without a matrix.")
        if not 1 <= int(job["timeout-minutes"]) <= 20:
            raise ValueError("Mac checks need a timeout of at most 20 minutes.")
        for step in job["steps"]:
            if set(step) - {"name", "uses", "with", "run"}:
                raise ValueError("The unsigned draft contains an unreviewed step setting.")
            action = step.get("uses", "")
            if action and not re.fullmatch(r"actions/(?:checkout|upload-artifact)@[0-9a-f]{40}", action):
                raise ValueError("Use only reviewed checkout and artifact actions pinned to a commit.")
            if action.startswith("actions/checkout@") and str(step.get("with", {}).get("persist-credentials")).lower() != "false":
                raise ValueError("Checkout must not persist its access credential.")
            if action.startswith("actions/upload-artifact@"):
                if int(step["with"]["retention-days"]) != 1:
                    raise ValueError("Retain native evidence for one day to limit storage usage.")
            command = step.get("run", "")
            if re.search(r"\bcodesign\b|\bsecurity\s+(?:import|create-keychain)|-exportArchive|\btestflight\b", command, re.IGNORECASE):
                raise ValueError("Signing and delivery are outside the unsigned draft.")
            if "xcodebuild" in command and "CODE_SIGNING_ALLOWED=NO" not in command:
                raise ValueError("Every device archive must explicitly disable code signing.")
    except (KeyError, TypeError, AttributeError) as error:
        raise ValueError("The native workflow is missing a required cost control.") from error


def validate_public_workflow(config):
    """Allow only this task's standard, public, unsigned simulator validation."""
    expected_trigger = {"push": {"branches": ["fix/playback-continuity", "fix/continuous-pcm-playback", "fix/selected-video-regression", "fix/ui-shell-dismissal-sync", "fix/playback-start-latency"],
        "paths": ["ios/**", "scripts/**", "tests/apple-playback/**", "tests/validation-shell/**", ".github/workflows/playback-validation.yml"]}}
    public_guard = "${{ github.repository == 'AGForge-Labs/OfflineTikTokPlayer-public' && github.event.repository.private == false }}"
    job = config.get("jobs", {}).get("ios", {})
    if set(config) != {"name", "on", "permissions", "jobs"} or config.get("on") != expected_trigger:
        raise ValueError("Public playback validation must be scoped to its reviewed branch.")
    if config["permissions"] != {"contents": "read"} or set(config["jobs"]) != {"ios"}:
        raise ValueError("Public playback validation needs one read-only job.")
    if set(job) != {"if", "runs-on", "timeout-minutes", "steps"} or job["if"] != public_guard:
        raise ValueError("Public playback validation must never run against a private repository.")
    if job["runs-on"] != "macos-26" or not 1 <= int(job["timeout-minutes"]) <= 20:
        raise ValueError("Public playback validation requires one capped standard runner.")
    if any(re.search(r"\bsecrets\s*(?:\.|\[)", value, re.I) for value in _values(config)):
        raise ValueError("Public playback validation cannot use secrets.")
    steps = job["steps"]
    if len(steps) != 3:
        raise ValueError("Public playback validation has unreviewed steps.")
    if steps[0] != {"uses": "actions/checkout@11d5960a326750d5838078e36cf38b85af677262", "with": {"persist-credentials": "false"}}:
        raise ValueError("Public checkout must be pinned and discard credentials.")
    if set(steps[1]) != {"name", "run"} or steps[1]["run"] != (
            "python3 tests/validation-shell/test_check_ios_shell.py\n"
            "python3 tests/validation-shell/test_native_test_evidence.py\n"
            "python3 tests/validation-shell/test_native_worker_trace.py\n"
            "bash scripts/check-ios.sh\n"):
        raise ValueError("Only unsigned source and simulator checks are approved.")
    if set(steps[2]) != {"name", "run"} or steps[2]["run"] != (
            "python3 scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log"):
        raise ValueError("Only unsigned source and simulator checks are approved.")


def validate_public_release_workflow(config):
    """A separate strict policy for the explicitly approved release infrastructure.

    The existing unsigned validator still rejects all signing/secret access.
    This policy never dispatches a workflow or grants a credential.
    """
    def check(condition):
        if not condition:
            raise ValueError("Public release differs from its reviewed owner, source, environment or credential policy.")

    def step(value):
        check(not re.search(r"\$\{\{", value.get("name", "")))
        return {key: item for key, item in value.items() if key != "name"}

    try:
        check(set(config) == {"name", "on", "permissions", "concurrency", "env", "jobs"})
        check(not re.search(r"\$\{\{", config["name"]))
        check(config["permissions"] == {"contents": "read"})
        check(config["concurrency"] == {"group": "public-testflight-release", "cancel-in-progress": "false"})
        check(set(config["on"]) == {"workflow_dispatch"})
        inputs = config["on"]["workflow_dispatch"]["inputs"]
        check(set(inputs) == {"authorize_upload", "expected_commit", "build_number"})
        for name, kind in (("authorize_upload", "boolean"), ("expected_commit", "string"), ("build_number", "string")):
            allowed = {"description", "type", "required", "default"} if name == "authorize_upload" else {"description", "type", "required"}
            check(set(inputs[name]) == allowed and inputs[name]["type"] == kind and inputs[name]["required"] == "true")
        check(inputs["authorize_upload"]["default"] == "false")
        check(config["env"] == {"EXPECTED_COMMIT": "${{ inputs.expected_commit }}",
              "RELEASE_BUILD_NUMBER": "${{ inputs.build_number }}", "RELEASE_AUTHORIZED": "${{ inputs.authorize_upload }}",
              "PYTHONDONTWRITEBYTECODE": "1"})
        check(set(config["jobs"]) == {"validate", "release"})
        validation, release = config["jobs"]["validate"], config["jobs"]["release"]
        check(set(validation) == {"if", "runs-on", "timeout-minutes", "steps"})
        check(set(release) == {"needs", "if", "environment", "runs-on", "timeout-minutes", "env", "steps"})
        gate = ("github.event_name == 'workflow_dispatch' && inputs.authorize_upload && "
                "github.repository == 'AGForge-Labs/OfflineTikTokPlayer-public' && !github.event.repository.private && "
                "github.actor_id == '105477711' && github.triggering_actor == 'Galaxybigbird' && "
                "github.ref == 'refs/heads/main' && github.run_attempt == 1")
        check(" ".join(validation["if"].split()) == gate)
        check(release["needs"] == "validate" and release["if"] == "${{ needs.validate.result == 'success' }}")
        check(release["environment"] == {"name": "release"})
        check(release["env"] == {"RELEASE_ENVIRONMENT": "release", "RELEASE_ACCEPTED_COMMIT": "${{ vars.RELEASE_ACCEPTED_COMMIT }}"})
        check(validation["runs-on"] == release["runs-on"] == "macos-26")
        check(1 <= int(validation["timeout-minutes"]) <= 25 and 1 <= int(release["timeout-minutes"]) <= 35)
        checkout = {"uses": "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
                    "with": {"ref": "${{ github.sha }}", "persist-credentials": "false"}}
        check([step(value) for value in validation["steps"]] == [checkout,
              {"run": "python3 -B scripts/public-release.py check"},
              {"run": "python3 -B -m unittest discover -s tests/release -v"},
              {"run": "python3 -B tests/validation-shell/test_check_ios_shell.py\n"
                      "python3 -B tests/validation-shell/test_native_test_evidence.py\n"},
              {"shell": "bash", "run": "bash scripts/check-ios.sh"},
              {"run": "python3 -B scripts/verify-native-test-log.py --log artifacts/native/xcodebuild-test.log"}])
        credentials = {name: "${{ secrets." + name + " }}" for name in (
            "APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_PROVISIONING_PROFILE_BASE64", "APP_STORE_CONNECT_KEY_BASE64")}
        credentials.update({name: "${{ vars." + name + " }}" for name in (
            "APP_STORE_CONNECT_KEY_ID", "APP_STORE_CONNECT_ISSUER_ID", "APPLE_CERTIFICATE_SHA256")})
        check([step(value) for value in release["steps"]] == [checkout,
              {"env": credentials, "run": "python3 -B scripts/public-release.py sign-upload"}])
    except (KeyError, TypeError, AttributeError):
        raise ValueError("Public release is missing a required protection.") from None


def run_checks(root, *, runner=subprocess.run, platform=sys.platform):
    root = Path(root)
    directory = root / ".github/workflows"
    active = [path for path in directory.iterdir() if path.suffix.lower() in {".yaml", ".yml"}] if directory.exists() else []
    if active:
        validators = {"playback-validation.yml": validate_public_workflow,
                      "public-testflight.yml": validate_public_release_workflow}
        if any(path.name not in validators for path in active):
            raise ValueError("Only the reviewed public playback and protected release workflows may be present.")
        for path in active:
            validators[path.name](yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader))
    workflow = yaml.load((root / ".github/workflow-drafts/native-check.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    validate_workflow(workflow)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    shell = ["wsl", "--distribution", os.environ.get("PLAYER_WSL_DISTRO", "Ubuntu"), "--", "bash"] if platform == "win32" else ["bash"]
    commands = [
        ("Xcode project references", [sys.executable, "scripts/generate-ios-project.py", "--check"]),
        ("Python importer and workflow regressions", [sys.executable, "-m", "pytest", "-q", "--basetemp=artifacts/preflight-" + stamp,
                                                       "-o", "cache_dir=artifacts/pytest-cache", "--tb=short"]),
        ("Compiled Swift core tests", shell + ["scripts/test-core.sh"]),
        ("Native OneDrive adapter HTTP regressions", shell + ["scripts/test-native-cloud.sh"]),
        ("Native Swift syntax", shell + ["scripts/check-swift-syntax.sh"]),
    ]
    complete = ["Unsigned workflow controls (public playback CI allowed)"]
    for name, command in commands:
        print("Checking: " + name, flush=True)
        runner(command, cwd=root, check=True, timeout=300)
        complete.append(name)
    return complete


def main():
    root = Path(__file__).resolve().parents[1]
    report = dict(checkedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  nativeSDKChecked=False, remoteBuildStarted=False)
    try:
        report["checks"] = run_checks(root)
        report["passed"] = True
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        report.update(passed=False, error=str(error))
    destination = root / "artifacts/local-preflight.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report), flush=True)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
