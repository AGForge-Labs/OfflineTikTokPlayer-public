import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("experimental_phone", ROOT / "scripts/experimental-phone.py")
phone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(phone)


class ExperimentalPhoneTests(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.env = dict(GITHUB_ACTIONS="true", RUNNER_OS="macOS", RUNNER_ENVIRONMENT="github-hosted",
                        GITHUB_REPOSITORY=phone.REPOSITORY, GITHUB_REF="refs/heads/main",
                        GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR_ID="105477711",
                        GITHUB_TRIGGERING_ACTOR="Galaxybigbird", GITHUB_RUN_ATTEMPT="1",
                        GITHUB_WORKFLOW_REF=phone.REPOSITORY + "/.github/workflows/public-experimental-phone.yml@refs/heads/main",
                        GITHUB_SHA=self.sha, GITHUB_WORKFLOW_SHA=self.sha, EXPECTED_CONTROL_COMMIT=self.sha,
                        EXPERIMENTAL_PHONE_AUTHORIZED="true", EXPERIMENTAL_BUILD_NUMBER="20.1")
        self.event = {"repository": {"full_name": phone.REPOSITORY, "private": False}}

    def test_exact_public_owner_main_workflow_and_first_attempt_are_required(self):
        self.assertEqual(phone.validate_context(self.env, self.event), "20.1")
        for key in self.env:
            env = dict(self.env, **{key: "wrong"})
            with self.subTest(key=key), self.assertRaises(ValueError):
                phone.validate_context(env, self.event)
        for key, value in (("private", True), ("private", "false"), ("full_name", "other/repo")):
            event = copy.deepcopy(self.event)
            event["repository"][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                phone.validate_context(self.env, event)

    def test_signing_requires_existing_release_environment_and_valid_new_build(self):
        with self.assertRaises(ValueError):
            phone.validate_context(self.env, self.event, signing=True)
        signing = dict(self.env, RELEASE_ENVIRONMENT="release")
        self.assertEqual(phone.validate_context(signing, self.event, signing=True), "20.1")
        for value in ("", "19.1", "20.01", "$(command)", "10000.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                phone.validate_context(dict(signing, EXPERIMENTAL_BUILD_NUMBER=value), self.event, signing=True)
        with self.assertRaises(ValueError):
            phone.validate_context(dict(signing, APPLE_PRIVATE_DELIVERY="unexpected"), self.event, signing=True)

    def test_wrong_source_tree_signer_dirty_or_private_inputs_are_refused(self):
        test_root = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory(dir=test_root, prefix="owned-public-phone-") as temporary:
            base = Path(temporary).resolve()
            self.assertEqual(base.parent, test_root)
            control, candidate = base / "control", base / "candidate"
            control.mkdir(); candidate.mkdir()
            (candidate / "scripts").mkdir()
            signer = candidate / "scripts/private-delivery.py"
            signer.write_bytes(b"reviewed test fixture")
            digest = hashlib.sha256(signer.read_bytes()).hexdigest()
            data = {(control, "rev-parse", "HEAD"): self.sha,
                    (candidate, "rev-parse", "HEAD"): phone.SOURCE,
                    (candidate, "rev-parse", "HEAD:ios/OfflineTikTokPlayer"): phone.APP_TREE,
                    (candidate, "rev-parse", "HEAD:ios/PlayerCore"): phone.CORE_TREE,
                    (control, "status", "--porcelain", "--untracked-files=all"): "",
                    (candidate, "status", "--porcelain", "--untracked-files=all"): ""}
            def git(root, *arguments): return data[(root, *arguments)]
            phone.verify_checkouts(control, candidate, self.sha, git=git, signer_sha=digest)
            for key in data:
                original = data[key]; data[key] = "wrong"
                with self.subTest(key=key), self.assertRaises(ValueError):
                    phone.verify_checkouts(control, candidate, self.sha, git=git, signer_sha=digest)
                data[key] = original
            signer.write_bytes(b"changed test fixture")
            with self.assertRaises(ValueError):
                phone.verify_checkouts(control, candidate, self.sha, git=git, signer_sha=digest)
            signer.write_bytes(b"reviewed test fixture")
            (candidate / ".env").write_text("private fixture")
            with self.assertRaises(ValueError):
                phone.verify_checkouts(control, candidate, self.sha, git=git, signer_sha=digest)


if __name__ == "__main__":
    unittest.main()
