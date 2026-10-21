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


def sampler_workflow():
    return yaml.load((ROOT / ".github/workflows/native-sampler-capability.yml").read_text(encoding="utf-8"),
                     Loader=yaml.BaseLoader)


def seek_grace_workflow():
    return yaml.load((ROOT / ".github/workflows/first-frame-seek-grace.yml").read_text(encoding="utf-8"),
                     Loader=yaml.BaseLoader)


def test_first_frame_seek_grace_accepts_only_the_reviewed_scoped_diagnostic(preflight):
    preflight.validate_first_frame_seek_grace_workflow(seek_grace_workflow())


@pytest.mark.parametrize("change", [
    "wrong_branch", "extra_branch", "wrong_path", "extra_path", "manual_trigger", "schedule", "pull_request_target",
    "private_guard", "repository_guard", "missing_guard", "runner", "timeout", "shorter_timeout", "missing_timeout",
    "extra_job", "matrix", "workflow_permissions", "write_permissions", "extra_permissions", "job_permissions",
    "workflow_env", "job_env", "environment", "concurrency", "extra_step", "missing_step", "step_env", "step_shell",
    "continue_on_error", "unpinned_checkout", "different_checkout", "credential_persistence", "missing_credential_policy",
    "checkout_ref", "checkout_submodules", "broad_command", "extra_command", "secret", "secret_brackets", "signing",
    "upload", "missing_always", "conditional_gate", "missing_identity", "extra_identity", "wrong_identity",
    "missing_manifest_exit", "missing_evidence_verification", "wrong_evidence_log", "full_acceptance_claim",
    "missing_calibration_gate", "wrong_calibration_command", "name_expression",
])
def test_first_frame_seek_grace_rejects_scope_execution_or_evidence_extensions(preflight, change):
    config = copy.deepcopy(seek_grace_workflow())
    job = config["jobs"]["natural"]
    checkout, run, gate, calibration = job["steps"]
    identity = "OfflineTikTokPlayerTests.PlaybackSelectionVideoRegressionTests/testDebugPausedVideoReanchorRejectsUserActionsBeforeFirstFrame"
    if change == "wrong_branch": config["on"]["push"]["branches"] = ["fix/playback-start-latency"]
    elif change == "extra_branch": config["on"]["push"]["branches"].append("main")
    elif change == "wrong_path": config["on"]["push"]["paths"] = ["ios/**"]
    elif change == "extra_path": config["on"]["push"]["paths"].append("ios/**")
    elif change == "manual_trigger": config["on"]["workflow_dispatch"] = {}
    elif change == "schedule": config["on"]["schedule"] = [{"cron": "0 * * * *"}]
    elif change == "pull_request_target": config["on"]["pull_request_target"] = {}
    elif change == "private_guard": job["if"] = "true"
    elif change == "repository_guard": job["if"] = job["if"].replace("OfflineTikTokPlayer-public", "OfflineTikTokPlayer")
    elif change == "missing_guard": job.pop("if")
    elif change == "runner": job["runs-on"] = "macos-26-xlarge"
    elif change == "timeout": job["timeout-minutes"] = "21"
    elif change == "shorter_timeout": job["timeout-minutes"] = "19"
    elif change == "missing_timeout": job.pop("timeout-minutes")
    elif change == "extra_job": config["jobs"]["release"] = copy.deepcopy(job)
    elif change == "matrix": job["strategy"] = {"matrix": {"value": ["1", "2"]}}
    elif change == "workflow_permissions": config["permissions"] = {}
    elif change == "write_permissions": config["permissions"] = {"contents": "write"}
    elif change == "extra_permissions": config["permissions"]["id-token"] = "write"
    elif change == "job_permissions": job["permissions"] = {"contents": "write"}
    elif change == "workflow_env": config["env"] = {"PLAYER_TESTS": "all"}
    elif change == "job_env": job["env"] = {"PLAYER_TESTS": "all"}
    elif change == "environment": job["environment"] = {"name": "release"}
    elif change == "concurrency": config["concurrency"] = {"group": "unreviewed"}
    elif change == "extra_step": job["steps"].append({"run": "true"})
    elif change == "missing_step": job["steps"].pop(1)
    elif change == "step_env": run["env"] = {"PLAYER_TESTS": "all"}
    elif change == "step_shell": run["shell"] = "python"
    elif change == "continue_on_error": run["continue-on-error"] = "true"
    elif change == "unpinned_checkout": checkout["uses"] = "actions/checkout@main"
    elif change == "different_checkout": checkout["uses"] = "actions/checkout@" + "a" * 40
    elif change == "credential_persistence": checkout["with"]["persist-credentials"] = "true"
    elif change == "missing_credential_policy": checkout["with"].pop("persist-credentials")
    elif change == "checkout_ref": checkout["with"]["ref"] = "main"
    elif change == "checkout_submodules": checkout["with"]["submodules"] = "recursive"
    elif change == "broad_command": run["run"] = "bash scripts/check-ios.sh"
    elif change == "extra_command": run["run"] += "\nprintf unreviewed\n"
    elif change == "secret": run["run"] += "\n${{ secrets.APPLE_PRIVATE_DELIVERY }}\n"
    elif change == "secret_brackets": run["env"] = {"KEY": "${{ secrets['DELIVERY'] }}"}
    elif change == "signing": run["run"] += "\ncodesign --sign example unsigned.app\n"
    elif change == "upload": job["steps"].append({"uses": "actions/upload-artifact@" + "a" * 40})
    elif change == "missing_always": gate.pop("if")
    elif change == "conditional_gate": gate["if"] = "success()"
    elif change == "missing_identity": gate["run"] = gate["run"].replace("    '" + identity + "',\n", "")
    elif change == "extra_identity": gate["run"] = gate["run"].replace("expected = {\n", "expected = {\n    'OfflineTikTokPlayerTests.OtherTests/testUnreviewed',\n")
    elif change == "wrong_identity": gate["run"] = gate["run"].replace(identity, "OfflineTikTokPlayerTests.OtherTests/testUnreviewed")
    elif change == "missing_manifest_exit": gate["run"] = gate["run"].replace("raise SystemExit('Scoped identities are missing from this immutable checkout')", "print('Scoped identities are missing from this immutable checkout')")
    elif change == "missing_evidence_verification": gate["run"] = gate["run"].replace("verifier.verify_log(Path('artifacts/native/xcodebuild-test.log').read_text(), expected)", "print('unchecked')")
    elif change == "wrong_evidence_log": gate["run"] = gate["run"].replace("artifacts/native/xcodebuild-test.log", "artifacts/other.log")
    elif change == "full_acceptance_claim": gate["run"] = gate["run"].replace("not full-suite acceptance", "full-suite acceptance")
    elif change == "missing_calibration_gate": calibration.pop("if")
    elif change == "wrong_calibration_command": calibration["run"] = "true"
    elif change == "name_expression": config["name"] = "${{ github.token }}"
    assert config != seek_grace_workflow(), "Each mutation must alter the reviewed workflow"
    with pytest.raises(ValueError):
        preflight.validate_first_frame_seek_grace_workflow(config)


@pytest.mark.parametrize("name,allowed", [
    ("first-frame-seek-grace.yml", True), ("first-frame-seek-grace.yaml", False),
    ("first-frame-seek-grace.YML", False), ("First-frame-seek-grace.yml", False),
    ("renamed-first-frame-seek-grace.yml", False), ("playback-validation.yml", False),
    ("public-testflight.yml", False), ("native-sampler-capability.yml", False),
])
def test_first_frame_seek_grace_is_routed_only_by_its_exact_filename(preflight, tmp_path, name, allowed):
    directory = tmp_path / ".github/workflows"
    directory.mkdir(parents=True)
    (directory / name).write_text((ROOT / ".github/workflows/first-frame-seek-grace.yml").read_text(encoding="utf-8"),
                                 encoding="utf-8")
    draft = tmp_path / ".github/workflow-drafts/native-check.yml"
    draft.parent.mkdir(parents=True)
    draft.write_text((ROOT / ".github/workflow-drafts/native-check.yml").read_text(encoding="utf-8"), encoding="utf-8")
    commands = []
    runner = lambda args, **kwargs: commands.append(args)
    if allowed:
        complete = preflight.run_checks(tmp_path, runner=runner, platform="linux")
        assert len(commands) == 5
        assert len(complete) == 6
        assert any("scripts/test-core.sh" in args for args in commands)
        assert any("scripts/test-native-cloud.sh" in args for args in commands)
        assert not any("gh" in args or "xcodebuild" in args for args in commands)
    else:
        with pytest.raises(ValueError):
            preflight.run_checks(tmp_path, runner=runner, platform="linux")
        assert commands == []


def test_sampler_capability_is_only_the_exact_public_documentation_job(preflight):
    config = sampler_workflow()
    assert config["on"] == {"push": {"branches": ["diagnostic/native-sampler-capability"],
                                     "paths": [".github/workflows/native-sampler-capability.yml"]}}
    assert config["permissions"] == {}
    preflight.validate_native_sampler_capability_workflow(config)


@pytest.mark.parametrize("change", [
    "playback_branch", "extra_branch", "wrong_path", "extra_path", "manual_trigger", "schedule",
    "private_guard", "repository_guard", "runner", "timeout", "missing_timeout", "extra_job", "matrix",
    "extra_step", "read_permissions", "write_permissions", "null_permissions", "list_permissions", "job_permissions", "workflow_env", "job_env",
    "environment", "step_env", "step_shell", "continue_on_error", "checkout", "artifact", "secret",
    "profile_target", "network", "signing", "arbitrary_command", "name_expression",
])
def test_sampler_capability_rejects_any_execution_or_scope_extension(preflight, change):
    config = copy.deepcopy(sampler_workflow())
    job = config["jobs"]["documentation"]
    step = job["steps"][0]
    if change == "playback_branch": config["on"]["push"]["branches"] = ["fix/playback-start-latency"]
    elif change == "extra_branch": config["on"]["push"]["branches"].append("fix/playback-start-latency")
    elif change == "wrong_path": config["on"]["push"]["paths"] = ["scripts/**"]
    elif change == "extra_path": config["on"]["push"]["paths"].append("ios/**")
    elif change == "manual_trigger": config["on"]["workflow_dispatch"] = {}
    elif change == "schedule": config["on"]["schedule"] = [{"cron": "0 * * * *"}]
    elif change == "private_guard": job["if"] = "true"
    elif change == "repository_guard": job["if"] = job["if"].replace("OfflineTikTokPlayer-public", "OfflineTikTokPlayer-private")
    elif change == "runner": job["runs-on"] = "macos-26-xlarge"
    elif change == "timeout": job["timeout-minutes"] = "4"
    elif change == "missing_timeout": job.pop("timeout-minutes")
    elif change == "extra_job": config["jobs"]["another"] = copy.deepcopy(job)
    elif change == "matrix": job["strategy"] = {"matrix": {"value": ["1", "2"]}}
    elif change == "extra_step": job["steps"].append({"run": "true"})
    elif change == "read_permissions": config["permissions"] = {"contents": "read"}
    elif change == "write_permissions": config["permissions"] = {"contents": "write"}
    elif change == "null_permissions": config["permissions"] = None
    elif change == "list_permissions": config["permissions"] = []
    elif change == "job_permissions": job["permissions"] = {"id-token": "write"}
    elif change == "workflow_env": config["env"] = {"PYTHONPATH": "unreviewed"}
    elif change == "job_env": job["env"] = {"PAGER": "unreviewed"}
    elif change == "environment": job["environment"] = {"name": "release"}
    elif change == "step_env": step["env"] = {"KEY": "${{ github.token }}"}
    elif change == "step_shell": step["shell"] = "python"
    elif change == "continue_on_error": step["continue-on-error"] = "true"
    elif change == "checkout": job["steps"].insert(0, {"uses": "actions/checkout@" + "a" * 40})
    elif change == "artifact": job["steps"].append({"uses": "actions/upload-artifact@" + "a" * 40})
    elif change == "secret": step["run"] += "\n${{ secrets.APPLE_PRIVATE_DELIVERY }}\n"
    elif change == "profile_target": step["run"] = step["run"].replace("['/usr/bin/sample', '-h']", "['/usr/bin/sample', '123', '1']")
    elif change == "network": step["run"] += "\n/usr/bin/curl https://example.invalid\n"
    elif change == "signing": step["run"] += "\ncodesign --sign example unsigned.app\n"
    elif change == "arbitrary_command": step["run"] += "\nprintf extra\n"
    elif change == "name_expression": step["name"] = "${{ github.token }}"
    with pytest.raises(ValueError):
        preflight.validate_native_sampler_capability_workflow(config)


@pytest.mark.parametrize("name,allowed", [
    ("native-sampler-capability.yml", True), ("native-sampler-capability.yaml", False),
    ("native-sampler-capability.YML", False), ("renamed-sampler.yml", False),
    ("playback-validation.yml", False), ("public-testflight.yml", False),
])
def test_sampler_capability_exception_is_routed_only_by_its_exact_filename(preflight, tmp_path, name, allowed):
    directory = tmp_path / ".github/workflows"
    directory.mkdir(parents=True)
    (directory / name).write_text((ROOT / ".github/workflows/native-sampler-capability.yml").read_text(encoding="utf-8"),
                                 encoding="utf-8")
    draft = tmp_path / ".github/workflow-drafts/native-check.yml"
    draft.parent.mkdir(parents=True)
    draft.write_text((ROOT / ".github/workflow-drafts/native-check.yml").read_text(encoding="utf-8"), encoding="utf-8")
    commands = []
    runner = lambda args, **kwargs: commands.append(args)
    if allowed:
        complete = preflight.run_checks(tmp_path, runner=runner, platform="linux")
        assert len(commands) == 5
        assert len(complete) == 6
    else:
        with pytest.raises(ValueError):
            preflight.run_checks(tmp_path, runner=runner, platform="linux")
        assert commands == []


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
