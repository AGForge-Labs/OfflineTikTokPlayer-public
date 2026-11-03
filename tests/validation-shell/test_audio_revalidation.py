import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import runpy
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("audio_evidence", ROOT / "scripts/revalidate-audio-output.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)
CASES = set(json.loads((ROOT / "tests/audio-output-continuity.json").read_text())["cases"])
native = runpy.run_path(str(ROOT / "scripts/verify-native-test-log.py"))
VERIFIER = {"verify_log": native["verify_log"], "source_manifest": lambda root: CASES}
DEST = "platform=iOS Simulator,id=11111111-1111-4111-8111-111111111111"
PLAN = "/runner/artifacts/AudioOutputDerived/Build/Products/Test.xctestrun"
ALLOWED = (".github/workflows/audio-output-evidence.yml",
    "docs/superpowers/plans/2026-11-03-audio-output-continuity.md", "scripts/revalidate-audio-output.py",
    "scripts/verify-native-test-log.py", "tests/validation-shell/test_audio_revalidation.py",
    "tests/validation-shell/test_native_test_evidence.py")


def metadata():
    run = dict(id=evidence.NATIVE_RUN, head_sha=evidence.COMPILED_SOURCE,
        path=".github/workflows/audio-output-continuity.yml", head_branch="codex/audio-continuity-final",
        event="push", run_attempt=1, actor={"id": 105477711}, status="completed", conclusion="failure",
        repository={"full_name": evidence.REPOSITORY, "private": False})
    names = ["Set up job", "Compile the focused audio tests once", *evidence.REPORTER_STEPS, "Complete job"]
    job = dict(id=evidence.NATIVE_JOB, run_id=evidence.NATIVE_RUN, head_sha=evidence.COMPILED_SOURCE,
        status="completed", conclusion="failure", labels=["macos-26"], steps=[dict(name=name,
        status="completed", conclusion="failure" if name in evidence.REPORTER_STEPS else "success") for name in names])
    return run, job


def fixture_log():
    def case(identity, status):
        owner, method = identity.split("/")
        return f"Test Case '-[{owner} {method}]' {status} (0.001 seconds)."
    rows = ["2026-11-03T23:13:00.0000000Z " + evidence.COMPILED_SOURCE,
        "Command line invocation:", "/Applications/Xcode.app/xcodebuild -project ios/OfflineTikTokPlayer.xcodeproj -destination " + repr(DEST) +
        " -resultBundlePath artifacts/audio-output/Build.xcresult CODE_SIGNING_ALLOWED=NO build-for-testing"]
    for bundle, cases in (("Native", CASES - {evidence.HD_CASE}), ("HD", {evidence.HD_CASE})):
        selectors = " ".join("-only-testing:" + c.replace(".", "/", 1) for c in sorted(cases))
        rows += ["##[group]Run native", "Command line invocation:",
            "/Applications/Xcode.app/xcodebuild test-without-building -xctestrun " + PLAN + " -destination " + repr(DEST) +
            " -parallel-testing-enabled NO -resultBundlePath artifacts/audio-output/" + bundle + ".xcresult " + selectors]
        for identity in sorted(cases): rows += [case(identity, "started"), case(identity, "passed")]
        rows += (["AUDIO_LOOP_SOAK loops=1000 mediaSeconds=100 minimumRMS=0.101525833 underruns=0"] if bundle == "Native" else
            ["PRODUCTION_HD deliveredFPS=54.4376 maximumGapMs=72.36225 maximumEnqueueMs=1.712625 audioAdvanced=58880 underrunsAdded=0 actualPictureChanged=true"])
        rows += ["** TEST EXECUTE SUCCEEDED **"]
    return "\n".join(rows) + "\n"


class AudioRevalidationTests(unittest.TestCase):
    def inspect(self, raw):
        digest = hashlib.sha256(evidence.canonical_log(raw).encode()).hexdigest()
        with patch.object(evidence, "LOG_SHA256", digest):
            return evidence.verify_sdk(ROOT, raw, verifier=VERIFIER)

    def test_accepts_only_the_exact_completed_native_metadata(self):
        evidence.validate_metadata(*metadata())
        for field, value in (("run_attempt", 2), ("head_sha", "0" * 40), ("status", "in_progress"),
                             ("conclusion", "success"), ("head_branch", "main")):
            run, job = metadata(); run[field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError): evidence.validate_metadata(run, job)
        for mutate in (lambda r, j: r["repository"].update(private=True), lambda r, j: r["actor"].update(id=1),
                       lambda r, j: j.update(labels=["macos-26-large"]), lambda r, j: j.update(id=1),
                       lambda r, j: j["steps"][1].update(conclusion="failure"),
                       lambda r, j: j["steps"][2].update(conclusion="skipped"),
                       lambda r, j: j["steps"].append(copy.deepcopy(j["steps"][0]))):
            run, job = metadata(); mutate(run, job)
            with self.subTest(mutate=mutate), self.assertRaises(AssertionError): evidence.validate_metadata(run, job)

    def test_accepts_all_eighteen_exact_cases_and_retains_hd_and_loop_measurements(self):
        result = self.inspect(fixture_log())
        self.assertEqual(result["requiredUniqueCases"], 18)
        self.assertEqual(result["executions"], 18)
        self.assertTrue(result["allPassed"])
        self.assertEqual(result["loopCount"], 1000)

    def test_raw_checksum_is_required_before_any_case_acceptance(self):
        with self.assertRaises(AssertionError): evidence.verify_sdk(ROOT, fixture_log(), verifier=VERIFIER)

    def test_failure_skip_missing_duplicate_and_summary_only_evidence_stay_rejected(self):
        raw = fixture_log(); passed = next(line for line in raw.splitlines() if "' passed " in line)
        variants = [raw.replace(passed, passed.replace(" passed ", " failed "), 1),
            raw.replace(passed, passed.replace(" passed ", " skipped "), 1), raw.replace(passed, "", 1),
            raw.replace(passed, passed + "\n" + passed, 1), raw.replace(passed, "Executed18 tests,0 failures", 1),
            raw.replace("** TEST EXECUTE SUCCEEDED **", "** TEST EXECUTE FAILED **", 1)]
        for changed in variants:
            with self.subTest(changed=changed[-100:]), self.assertRaises((AssertionError, ValueError)): self.inspect(changed)

    def test_wrong_commands_selection_source_and_measurements_stay_rejected(self):
        raw = fixture_log()
        variants = [raw.replace(evidence.COMPILED_SOURCE, "f" * 40, 1),
            raw.replace("-only-testing:", "-skip-testing:", 1), raw.replace(DEST, DEST.replace("11111111-", "22222222-", 1), 1),
            raw.replace(PLAN, PLAN.replace("/Build/", "/../Build/")), raw.replace("deliveredFPS=54.4376", "deliveredFPS=49"),
            raw.replace("maximumGapMs=72.36225", "maximumGapMs=101"), raw.replace("underrunsAdded=0", "underrunsAdded=1"),
            raw.replace("actualPictureChanged=true", "actualPictureChanged=false")]
        for changed in variants:
            with self.subTest(changed=changed[-100:]), self.assertRaises((AssertionError, ValueError)): self.inspect(changed)

    def test_source_guard_requires_unchanged_ios_profile_workflow_and_only_the_reviewed_paths(self):
        self.assertEqual(evidence.ALLOWED_CHANGES, ALLOWED)
        def fake_git(command, **kwargs):
            args = tuple(command[3:])
            if args == ("rev-parse", "HEAD^"): return evidence.COMPILED_SOURCE
            if args == ("rev-parse", "HEAD:ios/OfflineTikTokPlayer"): return evidence.APP_TREE
            if args == ("rev-parse", "HEAD:ios/PlayerCore"): return evidence.CORE_TREE
            if args[:1] == ("rev-parse",): return "c" * 40
            if args[:1] == ("diff",): return "\n".join(ALLOWED)
            if args[:1] == ("status",): return ""
            raise AssertionError(command)
        with patch.object(evidence.subprocess, "check_output", side_effect=fake_git): evidence.validate_source(ROOT)
        for target in ("HEAD^", "HEAD:ios", "HEAD:ios/OfflineTikTokPlayer", "HEAD:ios/PlayerCore",
                       "HEAD:tests/audio-output-continuity.json", "HEAD:.github/workflows/audio-output-continuity.yml", "diff", "status"):
            def altered(command, **kwargs):
                if target in command:
                    return " M private.json" if target == "status" else ("\n".join(ALLOWED) + "\nprivate.json" if target == "diff" else "0" * 40)
                return fake_git(command, **kwargs)
            with self.subTest(target=target), patch.object(evidence.subprocess, "check_output", side_effect=altered), self.assertRaises(AssertionError): evidence.validate_source(ROOT)


if __name__ == "__main__": unittest.main()
