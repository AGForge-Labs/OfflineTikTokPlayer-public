"""Strict policy regressions for the reviewed synthetic compositor evidence steps."""
import copy
import importlib.util
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]


def workflow():
    return yaml.load((ROOT / ".github/workflows/first-frame-seek-grace.yml").read_text(encoding="utf-8"),
                     Loader=yaml.BaseLoader)


def reviewed_retention_steps():
    return [
        {"name": "Export bounded synthetic compositor evidence", "id": "compositor_evidence", "if": "always()",
         "run": "python3 scripts/export-compositor-evidence.py"},
        {"name": "Retain bounded synthetic compositor evidence for one day",
         "if": "${{ always() && steps.compositor_evidence.outcome == 'success' }}",
         "uses": "actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02",
         "with": {
             "name": "compositor-evidence-${{ github.run_id }}-${{ github.run_attempt }}",
             "path": "artifacts/compositor-evidence", "if-no-files-found": "error",
             "retention-days": "1", "compression-level": "0",
         }},
    ]


class CompositorWorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("compositor_local_preflight", ROOT / "scripts/local-preflight.py")
        cls.preflight = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.preflight)

    def assert_mutations_rejected(self, changes):
        baseline = workflow()
        self.assertEqual(len(baseline["jobs"]["natural"]["steps"]), 6)
        for label, mutate in changes:
            with self.subTest(change=label):
                config = copy.deepcopy(baseline)
                mutate(config)
                self.assertNotEqual(config, baseline, "A mutation must change the reviewed configuration")
                with self.assertRaises(ValueError):
                    self.preflight.validate_first_frame_seek_grace_workflow(config)

    def test_only_the_exact_reviewed_compositor_export_and_retention_are_allowed(self):
        config = workflow()
        self.assertEqual(len(config["jobs"]["natural"]["steps"]), 6)
        self.assertEqual(config["jobs"]["natural"]["steps"][4:], reviewed_retention_steps())
        self.preflight.validate_first_frame_seek_grace_workflow(config)

    def test_export_and_artifact_scope_extensions_are_rejected(self):
        def steps(config):
            return config["jobs"]["natural"]["steps"]

        self.assert_mutations_rejected([
            ("missing_export", lambda c: steps(c).pop(4)),
            ("missing_upload", lambda c: steps(c).pop(5)),
            ("retention_before_export", lambda c: steps(c).__setitem__(slice(4, 6), list(reversed(steps(c)[4:])))),
            ("export_missing_id", lambda c: steps(c)[4].pop("id")),
            ("export_wrong_id", lambda c: steps(c)[4].update({"id": "unreviewed_export"})),
            ("export_missing_always", lambda c: steps(c)[4].pop("if")),
            ("export_success_only", lambda c: steps(c)[4].update({"if": "success()"})),
            ("export_other_command", lambda c: steps(c)[4].update({"run": "python3 scripts/public-release.py sign-upload"})),
            ("export_extra_command", lambda c: steps(c)[4].update({"run": steps(c)[4]["run"] + "\nprintf unreviewed\n"})),
            ("export_extra_environment", lambda c: steps(c)[4].update({"env": {"OUTPUT": "artifacts"}})),
            ("export_secret", lambda c: steps(c)[4].update({"env": {"KEY": "${{ secrets.APPLE_CERTIFICATE_BASE64 }}"}})),
            ("export_shell_override", lambda c: steps(c)[4].update({"shell": "python"})),
            ("export_ignored_failure", lambda c: steps(c)[4].update({"continue-on-error": "true"})),
            ("upload_missing_export_success_guard", lambda c: steps(c)[5].pop("if")),
            ("upload_always_despite_export_failure", lambda c: steps(c)[5].update({"if": "always()"})),
            ("upload_success_only", lambda c: steps(c)[5].update({"if": "success()"})),
            ("upload_ignored_failure", lambda c: steps(c)[5].update({"continue-on-error": "true"})),
            ("upload_unpinned_action", lambda c: steps(c)[5].update({"uses": "actions/upload-artifact@main"})),
            ("upload_other_pin", lambda c: steps(c)[5].update({"uses": "actions/upload-artifact@" + "a" * 40})),
            ("upload_release_environment", lambda c: steps(c)[5].update({"environment": "release"})),
            ("upload_extra_environment", lambda c: steps(c)[5].update({"env": {"KEY": "${{ github.token }}"}})),
            ("upload_broad_path", lambda c: steps(c)[5]["with"].update({"path": "artifacts"})),
            ("upload_recursive_path", lambda c: steps(c)[5]["with"].update({"path": "artifacts/**"})),
            ("upload_original_capture_path", lambda c: steps(c)[5]["with"].update({"path": "artifacts/native"})),
            ("upload_multiple_paths", lambda c: steps(c)[5]["with"].update({"path": "artifacts/compositor-evidence\nartifacts/native"})),
            ("upload_absolute_path", lambda c: steps(c)[5]["with"].update({"path": "/Users/runner"})),
            ("upload_private_name", lambda c: steps(c)[5]["with"].update({"name": "${{ secrets.DELIVERY }}"})),
            ("upload_missing_attempt_identity", lambda c: steps(c)[5]["with"].update({"name": "compositor-evidence-${{ github.run_id }}"})),
            ("upload_extra_identity", lambda c: steps(c)[5]["with"].update({"name": "compositor-evidence-${{ github.run_id }}-${{ github.run_attempt }}-${{ github.sha }}"})),
            ("upload_missing_files_ignored", lambda c: steps(c)[5]["with"].update({"if-no-files-found": "ignore"})),
            ("upload_missing_files_warned", lambda c: steps(c)[5]["with"].update({"if-no-files-found": "warn"})),
            ("upload_missing_files_policy_removed", lambda c: steps(c)[5]["with"].pop("if-no-files-found")),
            ("upload_retention_extended", lambda c: steps(c)[5]["with"].update({"retention-days": "2"})),
            ("upload_retention_zero", lambda c: steps(c)[5]["with"].update({"retention-days": "0"})),
            ("upload_missing_retention", lambda c: steps(c)[5]["with"].pop("retention-days")),
            ("upload_compression_changed", lambda c: steps(c)[5]["with"].update({"compression-level": "9"})),
            ("upload_missing_compression", lambda c: steps(c)[5]["with"].pop("compression-level")),
            ("upload_hidden_files", lambda c: steps(c)[5]["with"].update({"include-hidden-files": "true"})),
            ("upload_overwrite", lambda c: steps(c)[5]["with"].update({"overwrite": "true"})),
            ("extra_upload", lambda c: steps(c).append(copy.deepcopy(steps(c)[5]))),
        ])

    def test_retention_cannot_replace_the_native_or_calibration_gates(self):
        def steps(config):
            return config["jobs"]["natural"]["steps"]

        self.assert_mutations_rejected([
            ("missing_native_run", lambda c: steps(c).pop(1)),
            ("broad_native_run", lambda c: steps(c)[1].update({"run": "bash scripts/check-ios.sh"})),
            ("missing_identity_gate", lambda c: steps(c).pop(2)),
            ("ignored_identity_failure", lambda c: steps(c)[2].update({"continue-on-error": "true"})),
            ("success_only_identity_gate", lambda c: steps(c)[2].update({"if": "success()"})),
            ("missing_manifest_exit", lambda c: steps(c)[2].update({"run": steps(c)[2]["run"].replace("raise SystemExit(", "print(")})),
            ("missing_evidence_verification", lambda c: steps(c)[2].update({"run": steps(c)[2]["run"].replace("verifier.verify_log(", "print(")})),
            ("full_application_acceptance", lambda c: steps(c)[2].update({"run": steps(c)[2]["run"].replace("not full-suite acceptance", "full-suite acceptance")})),
            ("missing_calibration", lambda c: steps(c).pop(3)),
            ("success_only_calibration", lambda c: steps(c)[3].update({"if": "success()"})),
            ("ignored_calibration_failure", lambda c: steps(c)[3].update({"continue-on-error": "true"})),
            ("unchecked_calibration", lambda c: steps(c)[3].update({"run": "true"})),
            ("upload_before_identity_gate", lambda c: steps(c).__setitem__(slice(2, 6), [steps(c)[4], steps(c)[5], steps(c)[2], steps(c)[3]])),
        ])

    def test_retention_cannot_expand_public_source_runner_or_permissions(self):
        def job(config):
            return config["jobs"]["natural"]

        self.assert_mutations_rejected([
            ("private_repository", lambda c: job(c).update({"if": "true"})),
            ("wrong_repository", lambda c: job(c).update({"if": job(c)["if"].replace("OfflineTikTokPlayer-public", "OfflineTikTokPlayer")})),
            ("extra_branch", lambda c: c["on"]["push"]["branches"].append("main")),
            ("extra_source_path", lambda c: c["on"]["push"]["paths"].append("ios/**")),
            ("manual_release_trigger", lambda c: c["on"].update({"workflow_dispatch": {}})),
            ("write_permissions", lambda c: c.update({"permissions": {"contents": "write"}})),
            ("identity_permissions", lambda c: job(c).update({"permissions": {"id-token": "write"}})),
            ("larger_runner", lambda c: job(c).update({"runs-on": "macos-26-xlarge"})),
            ("longer_timeout", lambda c: job(c).update({"timeout-minutes": "21"})),
            ("runner_matrix", lambda c: job(c).update({"strategy": {"matrix": {"value": ["1", "2"]}}})),
            ("extra_job", lambda c: c["jobs"].update({"release": copy.deepcopy(job(c))})),
            ("workflow_environment", lambda c: c.update({"env": {"KEY": "${{ secrets.DELIVERY }}"}})),
            ("job_environment", lambda c: job(c).update({"environment": {"name": "release"}})),
            ("unreviewed_checkout", lambda c: job(c)["steps"][0].update({"uses": "actions/checkout@main"})),
            ("persistent_credentials", lambda c: job(c)["steps"][0]["with"].update({"persist-credentials": "true"})),
        ])


if __name__ == "__main__":
    unittest.main()
