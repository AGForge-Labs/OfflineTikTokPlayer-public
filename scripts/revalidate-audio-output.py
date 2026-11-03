"""Read-only revalidation of one frozen native run; never rerun media tests."""
from pathlib import Path, PurePosixPath
import hashlib
import json
import math
import os
import re
import runpy
import shlex
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import uuid

REPOSITORY = "AGForge-Labs/OfflineTikTokPlayer-public"
COMPILED_SOURCE = "da51788aef457e668580a44840b361d0a9f1d7c6"
NATIVE_RUN = 41737350404
NATIVE_JOB = 126269841756
APP_TREE = "a8eb0a2051c8cb2aa79c43432e4130ad289301ee"
CORE_TREE = "f9b20964220eb867c397e9fa8334c673263d92a5"
LOG_SHA256 = "10d3106467798883a1771fb041f6ba5c709f877952229d04ba622abb75cf78cd"
REPORTER_STEPS = ("Verify audio recovery and existing loop switching and video controls",
                  "Verify HD cadence in a fresh process without capture polling")
ALLOWED_CHANGES = (".github/workflows/audio-output-evidence.yml",
    "docs/superpowers/plans/2026-11-03-audio-output-continuity.md",
    "scripts/revalidate-audio-output.py", "scripts/verify-native-test-log.py",
    "tests/validation-shell/test_audio_revalidation.py", "tests/validation-shell/test_native_test_evidence.py")
HD_CASE = "OfflineTikTokPlayerTests.PictureRecoveryTests/testFullResolutionProductionPlaybackKeepsVideoAndAudioMoving"


def canonical_log(raw):
    return "\n".join(raw.splitlines()) + "\n"


def validate_metadata(run, job):
    assert run["id"] == NATIVE_RUN and run["head_sha"] == COMPILED_SOURCE
    assert run["path"] == ".github/workflows/audio-output-continuity.yml"
    assert run["head_branch"] == "codex/audio-continuity-final"
    assert run["event"] == "push" and run["run_attempt"] == 1 and run["actor"]["id"] == 105477711
    assert run["status"] == "completed" and run["conclusion"] == "failure"
    assert run["repository"]["full_name"] == REPOSITORY and run["repository"]["private"] is False
    assert job["id"] == NATIVE_JOB and job["run_id"] == NATIVE_RUN and job["head_sha"] == COMPILED_SOURCE
    assert job["status"] == "completed" and job["conclusion"] == "failure" and job["labels"] == ["macos-26"]
    steps = job["steps"]
    assert steps and all(s["status"] == "completed" for s in steps)
    assert len({s["name"] for s in steps}) == len(steps)
    assert [s["name"] for s in steps if s["conclusion"] != "success"] == list(REPORTER_STEPS)
    by_name = {s["name"]: s for s in steps}
    assert by_name["Compile the focused audio tests once"]["conclusion"] == "success"
    assert all(by_name[name]["conclusion"] == "failure" for name in REPORTER_STEPS)


def validate_source(root):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
    assert git("rev-parse", "HEAD^") == COMPILED_SOURCE
    for path in ("ios", "tests/audio-output-continuity.json", ".github/workflows/audio-output-continuity.yml"):
        assert git("rev-parse", "HEAD:" + path) == git("rev-parse", COMPILED_SOURCE + ":" + path)
    assert git("rev-parse", "HEAD:ios/OfflineTikTokPlayer") == APP_TREE
    assert git("rev-parse", "HEAD:ios/PlayerCore") == CORE_TREE
    assert tuple(git("diff", "--name-only", COMPILED_SOURCE, "HEAD").splitlines()) == ALLOWED_CHANGES
    assert not git("status", "--porcelain", "--untracked-files=all")
    return git("rev-parse", "HEAD")


def verify_sdk(root, raw, *, verifier=None):
    raw = canonical_log(raw)
    assert hashlib.sha256(raw.encode()).hexdigest() == LOG_SHA256
    assert re.search(r"(?m)^\d{4}-\d\d-\d\dT\S+Z " + COMPILED_SOURCE + r"\s*$", raw)
    profile = json.loads((root / "tests/audio-output-continuity.json").read_text(encoding="utf-8"))
    cases = set(profile["cases"])
    assert profile["version"] == 1 and len(cases) == len(profile["cases"]) == 18 and HD_CASE in cases
    if verifier is None:
        verifier = runpy.run_path(str(root / "scripts/verify-native-test-log.py"))
    assert cases <= verifier["source_manifest"](root)
    lines = raw.splitlines(keepends=True)
    def clean(line):
        return re.sub(r"^\d{4}-\d\d-\d\dT\S+Z ", "", line).strip()
    headers = [i for i, line in enumerate(lines) if clean(line) == "Command line invocation:"]
    assert len(headers) == 3
    expected = {"artifacts/audio-output/Native.xcresult": cases - {HD_CASE},
                "artifacts/audio-output/HD.xcresult": {HD_CASE}}
    phases, destinations, plans = {}, set(), set()
    for ordinal, index in enumerate(headers):
        args = shlex.split(clean(lines[index + 1]))
        assert args[0].endswith("/xcodebuild")
        destinations.add(args[args.index("-destination") + 1])
        if ordinal == 0:
            assert "build-for-testing" in args and "test-without-building" not in args and "test" not in args
            assert "CODE_SIGNING_ALLOWED=NO" in args
            assert args[args.index("-project") + 1] == "ios/OfflineTikTokPlayer.xcodeproj"
            assert args[args.index("-resultBundlePath") + 1] == "artifacts/audio-output/Build.xcresult"
            continue
        assert "test-without-building" in args and "build-for-testing" not in args and "test" not in args
        bundle = args[args.index("-resultBundlePath") + 1]
        assert bundle == tuple(expected)[ordinal - 1] and bundle not in phases
        selectors = [v for v in args if v.startswith("-only-testing:")]
        assert len(selectors) == len(expected[bundle])
        assert set(selectors) == {"-only-testing:" + case.replace(".", "/", 1) for case in expected[bundle]}
        assert not any(v.startswith("-skip-testing") for v in args)
        assert args[args.index("-parallel-testing-enabled") + 1] == "NO"
        plans.add(args[args.index("-xctestrun") + 1])
        end = headers[ordinal + 1] if ordinal + 1 < len(headers) else len(lines)
        end = next((i for i in range(index + 2, end) if clean(lines[i]).startswith("##[group]Run ")), end)
        phases[bundle] = "".join(lines[index:end])
        verifier["verify_log"](phases[bundle], expected[bundle], invocation="test-without-building")
    assert set(phases) == set(expected) and len(destinations) == len(plans) == 1
    plan_text = next(iter(plans)); plan = PurePosixPath(plan_text)
    assert plan.is_absolute() and ".." not in plan.parts and "." not in plan_text.split("/")
    assert plan.parent.parts[-4:] == ("artifacts", "AudioOutputDerived", "Build", "Products")
    assert plan.suffix == ".xctestrun" and 0 < len(plan.name) <= 256
    destination = re.fullmatch(r"platform=iOS Simulator,id=([0-9a-fA-F-]{36})", next(iter(destinations)))
    assert destination and uuid.UUID(destination[1]).int
    assert str(uuid.UUID(destination[1])).lower() == destination[1].lower()
    hd = re.findall(r"PRODUCTION_HD deliveredFPS=([0-9.]+) maximumGapMs=([0-9.]+) maximumEnqueueMs=([0-9.]+) audioAdvanced=([0-9]+) underrunsAdded=([0-9]+) actualPictureChanged=(true|false)", phases["artifacts/audio-output/HD.xcresult"])
    assert len(hd) == 1
    fps, gap, enqueue = map(float, hd[0][:3])
    assert all(math.isfinite(v) for v in (fps, gap, enqueue)) and fps > 50 and gap < 100
    assert int(hd[0][3]) > 0 and hd[0][4:] == ("0", "true")
    soak = re.findall(r"AUDIO_LOOP_SOAK loops=1000 mediaSeconds=100 minimumRMS=([0-9.]+) underruns=0", phases["artifacts/audio-output/Native.xcresult"])
    assert len(soak) == 1 and math.isfinite(float(soak[0])) and float(soak[0]) > 0
    return {"allPassed": True, "requiredUniqueCases": 18, "executions": 18,
            "hdDeliveredFPS": fps, "hdMaximumVideoGapMs": gap, "hdMaximumEnqueueMs": enqueue,
            "audioUnderrunsAdded": 0, "loopCount": 1000, "loopMinimumRMS": float(soak[0])}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def github_read(path, *, log=False):
    assert path.startswith("/repos/" + REPOSITORY + "/actions/")
    token = os.environ.get("GITHUB_TOKEN", "")
    assert token
    request = urllib.request.Request("https://api.github.com" + path,
        headers={"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
                 "User-Agent": "OfflinePlayer-read-only-native-revalidation", "X-GitHub-Api-Version": "2022-11-28"})
    opener = urllib.request.build_opener(NoRedirect)
    limit = 64 * 1024 * 1024 if log else 512 * 1024
    try:
        response = opener.open(request, timeout=30)
    except urllib.error.HTTPError as error:
        assert log and error.code in (301, 302, 303, 307, 308)
        location = error.headers["Location"]; url = urllib.parse.urlsplit(location)
        assert url.scheme == "https" and url.hostname and url.port in (None, 443)
        assert url.username is None and url.password is None
        assert url.hostname.endswith((".blob.core.windows.net", ".githubusercontent.com"))
        # A new request deliberately carries no GitHub authorization to storage.
        response = urllib.request.urlopen(urllib.request.Request(location), timeout=30)
    with response:
        assert response.status == 200
        data = response.read(limit + 1)
        assert 0 < len(data) <= limit
    return data.decode("utf-8") if log else json.loads(data)




def main():
    checks = {"GITHUB_REPOSITORY": REPOSITORY, "GITHUB_EVENT_NAME": "push",
        "GITHUB_REF": "refs/heads/codex/audio-continuity-evidence", "GITHUB_RUN_ATTEMPT": "1",
        "GITHUB_ACTOR_ID": "105477711", "GITHUB_TRIGGERING_ACTOR": "Galaxybigbird", "RUNNER_OS": "Linux"}
    assert all(os.environ.get(k) == v for k, v in checks.items())
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
    assert event["repository"]["full_name"] == REPOSITORY and event["repository"]["private"] is False
    root = Path(__file__).resolve().parents[1]
    proof = validate_source(root)
    assert proof == os.environ["GITHUB_SHA"]
    run = github_read(f"/repos/{REPOSITORY}/actions/runs/{NATIVE_RUN}")
    jobs = github_read(f"/repos/{REPOSITORY}/actions/runs/{NATIVE_RUN}/jobs")
    assert jobs["total_count"] == len(jobs["jobs"]) == 1
    job = jobs["jobs"][0]
    validate_metadata(run, job)
    raw = github_read(f"/repos/{REPOSITORY}/actions/jobs/{NATIVE_JOB}/logs", log=True)
    result = verify_sdk(root, raw)
    report = {"compiledSource": COMPILED_SOURCE, "nativeRun": NATIVE_RUN, "nativeJob": NATIVE_JOB,
        "proofSource": proof, "appTree": APP_TREE, "coreTree": CORE_TREE, "logSHA256": LOG_SHA256,
        "originalJobConclusion": "failure", "originalFailure": "evidence-log-reporter",
        "runtimeAndSwiftTestsChanged": False, **result}
    output = root / "artifacts/audio-output-revalidation"; output.mkdir(parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("AUDIO_OUTPUT_REVALIDATED " + json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
