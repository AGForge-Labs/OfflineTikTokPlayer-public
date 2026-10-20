import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("public_release", ROOT / "scripts/public-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
SHA = "a" * 40

def request():
    return {
        "GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
        "RUNNER_ENVIRONMENT": "github-hosted", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "GITHUB_REPOSITORY": release.REPOSITORY, "GITHUB_REF": "refs/heads/main",
        "GITHUB_WORKFLOW_REF": release.REPOSITORY + "/.github/workflows/public-testflight.yml@refs/heads/main",
        "GITHUB_WORKFLOW_SHA": SHA, "GITHUB_SHA": SHA, "EXPECTED_COMMIT": SHA,
        "GITHUB_ACTOR_ID": "105477711", "GITHUB_TRIGGERING_ACTOR": "Galaxybigbird",
        "GITHUB_RUN_ATTEMPT": "1", "RELEASE_AUTHORIZED": "true",
        "RELEASE_BUILD_NUMBER": "100.1", "RELEASE_ENVIRONMENT": "release",
        "RELEASE_ACCEPTED_COMMIT": SHA,
    }

class PublicReleaseTests(unittest.TestCase):
    def test_only_exact_owner_dispatched_reviewed_default_branch_is_allowed(self):
        self.assertEqual(release.validate_context(request(), signing=True), "100.1")

    def test_wrong_repo_fork_event_owner_ref_workflow_sha_and_rerun_are_rejected(self):
        changes = {
            "GITHUB_ACTIONS": "false", "RUNNER_OS": "Linux",
            "RUNNER_ENVIRONMENT": "self-hosted", "GITHUB_EVENT_NAME": "pull_request_target",
            "GITHUB_REPOSITORY": "attacker/fork", "GITHUB_REF": "refs/heads/feature",
            "GITHUB_WORKFLOW_REF": release.REPOSITORY + "/.github/workflows/other.yml@refs/heads/main",
            "GITHUB_WORKFLOW_SHA": "b" * 40, "GITHUB_SHA": "b" * 40,
            "EXPECTED_COMMIT": "main", "GITHUB_ACTOR_ID": "1",
            "GITHUB_TRIGGERING_ACTOR": "another-user", "GITHUB_RUN_ATTEMPT": "2",
            "RELEASE_AUTHORIZED": "false",
        }
        for key, value in changes.items():
            with self.subTest(field=key), self.assertRaises(ValueError):
                release.validate_context({**request(), key: value}, signing=True)

    def test_signing_requires_accepted_commit_in_release_environment(self):
        for field in ("RELEASE_ACCEPTED_COMMIT", "RELEASE_ENVIRONMENT"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                release.validate_context({**request(), field: ""}, signing=True)
        env = request()
        env.pop("RELEASE_ACCEPTED_COMMIT")
        env.pop("RELEASE_ENVIRONMENT")
        self.assertEqual(release.validate_context(env), "100.1")

    def test_build_numbers_cannot_inject_commands_or_restart_at_public_run_one(self):
        for value in ("", "0", "1; echo private", "../1", "1.100", "1.2.3.4"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.validate_context({**request(), "RELEASE_BUILD_NUMBER": value})
        if "OfflineTikTokPlayer" in release.REPOSITORY:
            with self.assertRaises(ValueError):
                release.validate_context({**request(), "RELEASE_BUILD_NUMBER": "13.1"})

    def test_private_inputs_and_pack_overrides_are_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            release.reject_private_inputs(path, {})
            (path / "private-data").mkdir()
            with self.assertRaises(ValueError):
                release.reject_private_inputs(path, {})
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaises(ValueError):
                release.reject_private_inputs(Path(folder), {"APARTMENTFINDER_PRIVATE_PACK_DIRECTORY": "private"})

    def test_child_output_and_errors_never_publish_raw_signing_material(self):
        output = io.StringIO()
        command = [sys.executable, "-c", "print('PRIVATE-OUTPUT-MARKER'); raise SystemExit(9)"]
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(RuntimeError) as error:
                release.run_redacted(command, env=dict(os.environ), cwd=ROOT)
        self.assertNotIn("PRIVATE-OUTPUT-MARKER", output.getvalue() + str(error.exception))

    def test_successful_child_output_is_also_suppressed(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            release.run_redacted([sys.executable, "-c", "print('PRIVATE-OUTPUT-MARKER')"],
                                 env=dict(os.environ), cwd=ROOT)
        self.assertNotIn("PRIVATE-OUTPUT-MARKER", output.getvalue())

if __name__ == "__main__":
    unittest.main()
