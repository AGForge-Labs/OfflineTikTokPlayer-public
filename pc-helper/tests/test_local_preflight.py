import copy
import importlib.util
from pathlib import Path
import subprocess

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def preflight():
    spec = importlib.util.spec_from_file_location("local_preflight", ROOT / "scripts/local-preflight.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def workflow():
    # BaseLoader preserves GitHub's YAML `on` key instead of interpreting it as YAML 1.1 True.
    return yaml.load((ROOT / ".github/workflow-drafts/native-check.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)


def test_public_playback_validation_is_standard_unsigned_and_private_guarded(preflight):
    config = yaml.load((ROOT / ".github/workflows/playback-validation.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    preflight.validate_public_workflow(config)
    for change in ["extra_branch", "private_guard", "runner", "secret", "write", "command", "extra_step", "evidence_guard", "launcher_regressions", "worker_regressions"]:
        altered = copy.deepcopy(config)
        job = altered["jobs"]["ios"]
        if change == "extra_branch": altered["on"]["push"]["branches"].append("unreviewed/additional-branch")
        elif change == "private_guard": job["if"] = "true"
        elif change == "runner": job["runs-on"] = "macos-26-xlarge"
        elif change == "secret": job["steps"][1]["env"] = {"KEY": "${{ secrets.KEY }}"}
        elif change == "write": altered["permissions"]["contents"] = "write"
        elif change == "command": job["steps"][1]["run"] += " --upload"
        elif change == "extra_step": job["steps"].append({"run": "unexpected command"})
        elif change == "evidence_guard": job["steps"].pop()
        elif change == "launcher_regressions": job["steps"][1]["run"] = "bash scripts/check-ios.sh"
        elif change == "worker_regressions": job["steps"][1]["run"] = job["steps"][1]["run"].replace("python3 tests/validation-shell/test_native_worker_trace.py\n", "")
        with pytest.raises(ValueError): preflight.validate_public_workflow(altered)


def test_protected_public_release_is_validated_without_weakening_unsigned_checks(preflight):
    config = yaml.load((ROOT / ".github/workflows/public-testflight.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
    preflight.validate_public_release_workflow(config)
    for change in ("trigger", "owner", "environment", "acceptance", "secret_before_gate", "artifact", "action", "permissions", "evidence_guard", "launcher_regressions"):
        altered = copy.deepcopy(config)
        if change == "trigger": altered["on"]["pull_request_target"] = {}
        elif change == "owner": altered["jobs"]["validate"]["if"] = "true"
        elif change == "environment": altered["jobs"]["release"].pop("environment")
        elif change == "acceptance": altered["jobs"]["release"]["env"].pop("RELEASE_ACCEPTED_COMMIT")
        elif change == "secret_before_gate": altered["jobs"]["validate"]["steps"][1]["env"] = {"KEY": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"}
        elif change == "artifact": altered["jobs"]["release"]["steps"].append({"uses": "actions/upload-artifact@" + "a" * 40})
        elif change == "action": altered["jobs"]["release"]["steps"][0]["uses"] = "actions/checkout@main"
        elif change == "permissions": altered["permissions"]["contents"] = "write"
        elif change == "evidence_guard": altered["jobs"]["validate"]["steps"].pop()
        elif change == "launcher_regressions": altered["jobs"]["validate"]["steps"].pop(3)
        with pytest.raises(ValueError):
            preflight.validate_public_release_workflow(altered)


def test_inactive_unsigned_draft_requires_a_deliberate_capped_run(preflight):
    preflight.validate_workflow(workflow())


@pytest.mark.parametrize("change", [
    "push", "pull_request", "schedule", "release", "default_approval", "unguarded_job",
    "extra_job", "long_timeout", "missing_timeout", "expensive_runner", "long_retention",
    "workflow_run", "pull_request_target", "public",
])
def test_preflight_rejects_changes_that_can_spend_minutes_unexpectedly(preflight, change):
    config = copy.deepcopy(workflow())
    job = config["jobs"]["ios"]
    if change in {"push", "pull_request", "schedule", "release", "workflow_run", "pull_request_target", "public"}:
        config["on"][change] = {}
    elif change == "default_approval":
        config["on"]["workflow_dispatch"]["inputs"]["approve_runner"]["default"] = "true"
    elif change == "unguarded_job":
        job.pop("if")
    elif change == "extra_job":
        config["jobs"]["another-mac"] = copy.deepcopy(job)
    elif change == "long_timeout":
        job["timeout-minutes"] = "21"
    elif change == "missing_timeout":
        job.pop("timeout-minutes")
    elif change == "expensive_runner":
        job["runs-on"] = "macos-latest-xlarge"
    elif change == "long_retention":
        job["steps"][-1]["with"]["retention-days"] = "90"
    with pytest.raises(ValueError):
        preflight.validate_workflow(config)


def test_local_checks_stop_at_the_first_failure_without_starting_remote_work(preflight):
    commands = []
    def command(args, **kwargs):
        commands.append(args)
        if "pytest" in args:
            raise subprocess.CalledProcessError(1, args)
        return subprocess.CompletedProcess(args, 0)
    with pytest.raises(subprocess.CalledProcessError):
        preflight.run_checks(ROOT, runner=command, platform="win32")
    assert len(commands) == 2
    assert not any("wsl" in args or "gh" in args or "xcodebuild" in args for args in commands)


@pytest.mark.parametrize("change", [
    "extra_input", "write_permissions", "job_permissions", "secret_env", "nested_secret",
    "secret_brackets", "signing_command", "signed_archive", "uncontrolled_archive",
    "credential_persistence", "unpinned_action", "workflow_env",
])
def test_unsigned_draft_cannot_gain_credentials_or_signing(preflight, change):
    config = copy.deepcopy(workflow())
    job = config["jobs"]["ios"]
    archive = next(step for step in job["steps"] if "xcodebuild" in step.get("run", ""))
    if change == "extra_input":
        config["on"]["workflow_dispatch"]["inputs"]["upload_testflight"] = {"type": "boolean", "default": "false"}
    elif change == "write_permissions":
        config["permissions"]["contents"] = "write"
    elif change == "job_permissions":
        job["permissions"] = {"id-token": "write"}
    elif change == "secret_env":
        archive["env"] = {"APPLE_PRIVATE_DELIVERY": "${{ secrets.APPLE_PRIVATE_DELIVERY }}"}
    elif change == "nested_secret":
        job["steps"][-1]["with"]["name"] = "${{ secrets.DELIVERY }}"
    elif change == "secret_brackets":
        job["steps"][-1]["with"]["name"] = "${{ secrets['DELIVERY'] }}"
    elif change == "signing_command":
        archive["run"] += "\ncodesign --sign example unsigned.app\n"
    elif change == "signed_archive":
        archive["run"] = archive["run"].replace("CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_ALLOWED=YES")
    elif change == "uncontrolled_archive":
        archive["run"] = archive["run"].replace("CODE_SIGNING_ALLOWED=NO", "")
    elif change == "credential_persistence":
        job["steps"][0]["with"]["persist-credentials"] = "true"
    elif change == "unpinned_action":
        job["steps"][0]["uses"] = "actions/checkout@main"
    elif change == "workflow_env":
        config["env"] = {"APPLE_PRIVATE_DELIVERY": "opaque"}
    with pytest.raises(ValueError):
        preflight.validate_workflow(config)


@pytest.mark.parametrize("name", ["native-check.yml", "surprise.yaml", "manual.YML"])
def test_any_active_workflow_blocks_initial_publication_checks(preflight, tmp_path, name):
    directory = tmp_path / ".github/workflows"
    directory.mkdir(parents=True)
    text = (ROOT / ".github/workflow-drafts/native-check.yml").read_text(encoding="utf-8")
    draft = tmp_path / ".github/workflow-drafts/native-check.yml"
    draft.parent.mkdir(parents=True)
    draft.write_text(text, encoding="utf-8")
    (directory / name).write_text(text, encoding="utf-8")
    commands = []
    with pytest.raises(ValueError):
        preflight.run_checks(tmp_path, runner=lambda args, **kwargs: commands.append(args))
    assert commands == []


def test_an_inactive_draft_allows_existing_local_checks(preflight, tmp_path):
    draft = tmp_path / ".github/workflow-drafts/native-check.yml"
    draft.parent.mkdir(parents=True)
    draft.write_text((ROOT / ".github/workflow-drafts/native-check.yml").read_text(encoding="utf-8"), encoding="utf-8")
    commands = []
    complete = preflight.run_checks(tmp_path, runner=lambda args, **kwargs: commands.append(args), platform="linux")
    assert len(commands) == 5
    assert len(complete) == 6
    assert any("scripts/test-core.sh" in args for args in commands)
    assert not any("gh" in args or "xcodebuild" in args for args in commands)
