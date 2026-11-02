"""Inert receipt, parser and credential-boundary tests; no network or Apple access."""
from copy import deepcopy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch
import urllib.error
import uuid

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("native_revalidation", ROOT / "scripts/revalidate-native-video.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
PROFILE = runpy.run_path(str(ROOT / "scripts/verify-video-profile.py"))


class NativeRevalidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.sim = str(uuid.uuid4())
        _, groups = PROFILE["phase_cases"](ROOT)
        cls.texts = {}
        for index, (role, cases) in enumerate(groups.items()):
            text = ""
            for case in sorted(cases):
                host, method = case.split("/")
                text += f"Test Case '-[{host} {method}]' started.\nTest Case '-[{host} {method}]' passed (0.100 seconds).\n"
            text += "** TEST EXECUTE SUCCEEDED **\n"
            if index < 3:
                methods = PROFILE["MAIN_HOST_METHODS"] if index == 0 else {next(iter(cases)).split("/")[1]}
                host = "VideoPresentationContinuityTests" if role == "native-lead" else "PlaybackSelectionVideoRegressionTests"
                for method in sorted(methods):
                    text += "NativeRuntimeHost " + json.dumps({"schema": 1, "bundleIdentifier": "dev.galaxybigbird.OfflineTikTokPlayer",
                        "pid": 100 + index, "moduleNonce": str(uuid.UUID(int=index + 1)), "simulatorUDID": cls.sim,
                        "testName": f"-[{host} {method}]"}, separators=(",", ":")) + "\n"
            else:
                text += f"PRODUCTION_HD_HOST schema=1 processID={100 + index} moduleNonce={uuid.UUID(int=index + 1)} explicitActivation={'true' if index == 4 else 'false'}\n"
            cls.texts[role] = text

    def metadata(self):
        run = {"id": CHECK.NATIVE_RUN, "head_sha": CHECK.COMPILED_SOURCE,
            "path": ".github/workflows/native-video-final.yml", "head_branch": "codex/native-video-final",
            "event": "push", "run_attempt": 1, "status": "completed", "conclusion": "failure",
            "repository": {"full_name": CHECK.REPOSITORY, "private": False}}
        job = {"id": CHECK.NATIVE_JOB, "run_id": CHECK.NATIVE_RUN, "head_sha": CHECK.COMPILED_SOURCE,
            "status": "completed", "conclusion": "failure", "steps": [
                {"name": name, "status": "completed", "conclusion": "success"} for name in CHECK.RUNTIME_STEPS] + [
                {"name": CHECK.REPORTER_STEP, "status": "completed", "conclusion": "failure"}]}
        return run, job

    def sdk(self, texts=None):
        header = "Command line invocation:\n/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild "
        dest = f'-destination "platform=iOS Simulator,id={self.sim}" '
        raw = CHECK.COMPILED_SOURCE + "\n" + header + "build-for-testing -project ios/OfflineTikTokPlayer.xcodeproj " + dest + "-resultBundlePath artifacts/native-format/Build.xcresult\n"
        for role, name in zip(self.texts, ("Native", "Lead", "Benchmark", "Fresh-1", "Fresh-2")):
            raw += header + "test-without-building -xctestrun /Users/runner/work/repo/repo/artifacts/NativeFormatDerived/Build/Products/app.xctestrun " + dest + f"-resultBundlePath artifacts/native-format/{name}.xcresult\n" + (texts or self.texts)[role]
        return "".join("2026-11-02T11:00:00.0000000Z " + line + "\n" for line in raw.splitlines())

    def verify_fixture(self, raw):
        digest = hashlib.sha256(CHECK.canonical_log(raw).encode()).hexdigest()
        with patch.object(CHECK, "LOG_SHA256", digest):
            return CHECK.verify_sdk(ROOT, raw)

    def test_only_the_exact_reporter_failure_is_eligible(self):
        run, job = self.metadata()
        CHECK.validate_metadata(run, job)
        for key, value in (("id", 1), ("head_sha", "a" * 40), ("path", "wrong.yml"),
                           ("head_branch", "main"), ("event", "workflow_dispatch"), ("run_attempt", 2),
                           ("status", "in_progress"), ("conclusion", "success")):
            with self.subTest(key=key), self.assertRaises(AssertionError):
                CHECK.validate_metadata(dict(run, **{key: value}), job)
        bad = deepcopy(run); bad["repository"]["private"] = True
        with self.assertRaises(AssertionError): CHECK.validate_metadata(bad, job)
        for change in ("runtime", "missing", "duplicate", "extra_failure", "incomplete"):
            bad = deepcopy(job)
            if change == "runtime": bad["steps"][0]["conclusion"] = "failure"
            if change == "missing": bad["steps"].pop(0)
            if change == "duplicate": bad["steps"].append(deepcopy(bad["steps"][0]))
            if change == "extra_failure": bad["steps"].append({"name": "other", "status": "completed", "conclusion": "failure"})
            if change == "incomplete": bad["steps"][0]["status"] = "in_progress"
            with self.subTest(change=change), self.assertRaises((AssertionError, KeyError)):
                CHECK.validate_metadata(run, bad)

    def test_source_must_preserve_the_compiled_tree_and_exact_reporting_diff(self):
        replies = {("rev-parse", "HEAD^"): CHECK.COMPILED_SOURCE,
            ("rev-parse", "HEAD:ios/OfflineTikTokPlayer"): CHECK.APP_TREE,
            ("rev-parse", "HEAD:ios/PlayerCore"): CHECK.CORE_TREE,
            ("diff", "--name-only", CHECK.COMPILED_SOURCE, "HEAD"): "\n".join(CHECK.ALLOWED_CHANGES),
            ("status", "--porcelain", "--untracked-files=all"): "", ("rev-parse", "HEAD"): "e" * 40}
        for path in ("ios", "tests/native-video-format-cases.json", ".github/workflows/native-video-final.yml", "scripts/verify-native-test-log.py"):
            for source in ("HEAD", CHECK.COMPILED_SOURCE): replies[("rev-parse", source + ":" + path)] = "f" * 40
        def output(args, **kwargs): return replies[tuple(args[3:])]
        with patch.object(CHECK.subprocess, "check_output", side_effect=output):
            self.assertEqual(CHECK.validate_source(ROOT), "e" * 40)
            for key in tuple(replies):
                old = replies[key]; replies[key] = "changed"
                if key != ("rev-parse", "HEAD"):
                    with self.subTest(key=key), self.assertRaises(AssertionError): CHECK.validate_source(ROOT)
                replies[key] = old

    def test_all_32_cases_and_five_hosts_are_required_with_owned_sdk_paths(self):
        self.assertTrue(self.verify_fixture(self.sdk())["allPassed"])
        for change in ("failed", "skipped", "duplicate", "restarted", "reused_host", "relative_plan", "extra_sdk", "zero_simulator"):
            texts = deepcopy(self.texts)
            if change in ("failed", "skipped"): texts["benchmark"] = texts["benchmark"].replace(" passed ", f" {change} ")
            if change == "duplicate": texts["benchmark"] += texts["benchmark"]
            if change == "restarted": texts["benchmark"] += "Restarting after unexpected exit, crash, or test timeout\n"
            if change == "reused_host": texts["benchmark"] = texts["benchmark"].replace('"pid":102', '"pid":100')
            raw = self.sdk(texts)
            if change == "relative_plan": raw = raw.replace("/Users/runner/work/repo/repo/artifacts/", "artifacts/")
            if change == "extra_sdk": raw += "Command line invocation:\n/xcodebuild test\n"
            if change == "zero_simulator": raw = raw.replace(self.sim, str(uuid.UUID(int=0)))
            with self.subTest(change=change), self.assertRaises((AssertionError, KeyError, ValueError)):
                self.verify_fixture(raw)

    def test_frozen_log_digest_cannot_be_substituted(self):
        with self.assertRaises(AssertionError): CHECK.verify_sdk(ROOT, self.sdk())
        self.assertEqual(CHECK.canonical_log("a\r\nb\n"), "a\nb\n")

    def test_only_the_observed_pid_interleave_can_recover_host_metadata(self):
        original = next(line for line in self.texts["main28"].splitlines() if line.startswith("NativeRuntimeHost "))
        joined = "2026-11-02 11:11:08.778868+0000 OfflineTikTokPlayer[1" + original + "00:44676] [AQ]        LoudnessManager.mm:1215  IsHardwareSupported: no plist loaded, returning false"
        changed = deepcopy(self.texts); changed["main28"] = changed["main28"].replace(original, joined)
        self.assertTrue(PROFILE["inspect_profile"](ROOT, changed, self.sim)["allPassed"])
        for invalid in (joined.replace("00:44676", "99:44676"), joined + " extra", "prefix " + joined,
                        joined.replace("LoudnessManager.mm:1215", "Other.mm:1215")):
            changed["main28"] = self.texts["main28"].replace(original, invalid)
            with self.subTest(invalid=invalid[-60:]), self.assertRaises((AssertionError, ValueError)):
                PROFILE["inspect_profile"](ROOT, changed, self.sim)

    def test_log_redirect_never_receives_github_authorization(self):
        class Response(io.BytesIO): status = 200
        opener = unittest.mock.Mock()
        opener.open.side_effect = urllib.error.HTTPError("https://api.github.com", 302, "redirect", {"Location": "https://logs.blob.core.windows.net/result"}, None)
        with patch.dict(os.environ, {"GITHUB_TOKEN": "inert-test-token"}), \
             patch.object(CHECK.urllib.request, "build_opener", return_value=opener), \
             patch.object(CHECK.urllib.request, "urlopen", return_value=Response(b"log")) as storage:
            self.assertEqual(CHECK.github_read(f"/repos/{CHECK.REPOSITORY}/actions/jobs/1/logs", log=True), "log")
            api_request = opener.open.call_args.args[0]
            self.assertEqual(api_request.get_header("Authorization"), "Bearer inert-test-token")
            self.assertIsNone(storage.call_args.args[0].get_header("Authorization"))
            for url in ("http://logs.blob.core.windows.net/result", "https://example.org/result", "https://user@logs.blob.core.windows.net/result"):
                opener.open.side_effect = urllib.error.HTTPError("api", 302, "redirect", {"Location": url}, None)
                with self.subTest(url=url), self.assertRaises(AssertionError):
                    CHECK.github_read(f"/repos/{CHECK.REPOSITORY}/actions/jobs/1/logs", log=True)


if __name__ == "__main__":
    unittest.main()
