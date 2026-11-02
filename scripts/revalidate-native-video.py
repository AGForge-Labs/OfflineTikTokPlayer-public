"""Revalidate one completed, passing native execution whose reporter failed."""
from pathlib import Path, PurePosixPath
import hashlib
import json
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
COMPILED_SOURCE = "30c1a5d36da393743cd3155ac991a2221eb7a7bc"
NATIVE_RUN = 41433680171
NATIVE_JOB = 125238206931
APP_TREE = "3a7a7c5563bf51ff8c62e9b9db8dbaae3f8a7b66"
CORE_TREE = "f9b20964220eb867c397e9fa8334c673263d92a5"
LOG_SHA256 = "bf1f24e3313d7e71f282acbe5d70584a30b11474bd413a105d5daa2ba287b547"
RUNTIME_STEPS = ("Compile the focused test bundle once",
    "Real images rapid reversals and ownership checks",
    "Measure the offset native clock in a fresh process",
    "Measure the production startup policy in a fresh process",
    "Observe two fresh full-resolution service starts without recompiling")
REPORTER_STEP = "Require the complete isolated thirty one case profile"
ALLOWED_CHANGES = (".github/workflows/native-video-evidence.yml", "scripts/revalidate-native-video.py",
                   "scripts/verify-video-profile.py", "tests/validation-shell/test_video_revalidation.py")


def canonical_log(raw):
    return "\n".join(raw.splitlines()) + "\n"


def validate_metadata(run, job):
    assert run["id"] == NATIVE_RUN and run["head_sha"] == COMPILED_SOURCE
    assert run["path"] == ".github/workflows/native-video-final.yml" and run["head_branch"] == "codex/native-video-final"
    assert run["event"] == "push" and run["run_attempt"] == 1
    assert run["status"] == "completed" and run["conclusion"] == "failure"
    assert run["repository"]["full_name"] == REPOSITORY and run["repository"]["private"] is False
    assert job["id"] == NATIVE_JOB and job["run_id"] == NATIVE_RUN and job["head_sha"] == COMPILED_SOURCE
    assert job["status"] == "completed" and job["conclusion"] == "failure"
    steps = job["steps"]
    assert steps and all(step["status"] == "completed" for step in steps)
    assert len({step["name"] for step in steps}) == len(steps)
    by_name = {step["name"]: step for step in steps}
    assert all(by_name[name]["conclusion"] == "success" for name in RUNTIME_STEPS)
    assert [step["name"] for step in steps if step["conclusion"] != "success"] == [REPORTER_STEP]
    assert by_name[REPORTER_STEP]["conclusion"] == "failure"


def validate_source(root):
    def git(*args):
        return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
    assert git("rev-parse", "HEAD^") == COMPILED_SOURCE
    for path in ("ios", "tests/native-video-format-cases.json", ".github/workflows/native-video-final.yml",
                 "scripts/verify-native-test-log.py"):
        assert git("rev-parse", "HEAD:" + path) == git("rev-parse", COMPILED_SOURCE + ":" + path)
    assert git("rev-parse", "HEAD:ios/OfflineTikTokPlayer") == APP_TREE
    assert git("rev-parse", "HEAD:ios/PlayerCore") == CORE_TREE
    assert tuple(git("diff", "--name-only", COMPILED_SOURCE, "HEAD").splitlines()) == ALLOWED_CHANGES
    assert not git("status", "--porcelain", "--untracked-files=all")
    return git("rev-parse", "HEAD")


def verify_sdk(root, raw):
    raw = canonical_log(raw)
    assert hashlib.sha256(raw.encode()).hexdigest() == LOG_SHA256
    assert re.search(r"(?m)^\d{4}-\d\d-\d\dT\S+Z " + COMPILED_SOURCE + r"\s*$", raw)
    lines = raw.splitlines(keepends=True)
    def clean(line): return re.sub(r"^\d{4}-\d\d-\d\dT\S+Z ", "", line).strip()
    headers = [i for i, line in enumerate(lines) if clean(line) == "Command line invocation:"]
    assert len(headers) == 6
    expected = {"artifacts/native-format/Native.xcresult": "main28",
                "artifacts/native-format/Lead.xcresult": "native-lead",
                "artifacts/native-format/Benchmark.xcresult": "benchmark",
                "artifacts/native-format/Fresh-1.xcresult": "hd-fresh-1",
                "artifacts/native-format/Fresh-2.xcresult": "hd-fresh-2"}
    destinations, plans, phases = set(), set(), {}
    for ordinal, index in enumerate(headers):
        args = shlex.split(clean(lines[index + 1]))
        assert args[0].endswith("/xcodebuild")
        destinations.add(args[args.index("-destination") + 1])
        if ordinal == 0:
            assert "build-for-testing" in args and "test" not in args and "test-without-building" not in args
            assert args[args.index("-resultBundlePath") + 1] == "artifacts/native-format/Build.xcresult"
            assert args[args.index("-project") + 1] == "ios/OfflineTikTokPlayer.xcodeproj"
            continue
        assert "test-without-building" in args and "test" not in args and "build-for-testing" not in args
        role = expected[args[args.index("-resultBundlePath") + 1]]
        assert role == tuple(expected.values())[ordinal - 1] and role not in phases
        plans.add(args[args.index("-xctestrun") + 1])
        end = headers[ordinal + 1] if ordinal + 1 < len(headers) else len(lines)
        end = next((i for i in range(index + 2, end) if clean(lines[i]).startswith("##[group]Run ")), end)
        phases[role] = "".join(lines[index:end])
    assert len(destinations) == len(plans) == 1 and set(phases) == set(expected.values())
    plan_text = next(iter(plans)); plan = PurePosixPath(plan_text)
    assert plan.is_absolute() and ".." not in plan.parts and "." not in plan_text.split("/")
    assert plan.parent.parts[-4:] == ("artifacts", "NativeFormatDerived", "Build", "Products")
    assert plan.suffix == ".xctestrun" and 0 < len(plan.name) <= 256
    dest = re.fullmatch(r"platform=iOS Simulator,id=([0-9a-fA-F-]{36})", next(iter(destinations)))
    assert dest and uuid.UUID(dest[1]).int and str(uuid.UUID(dest[1])).lower() == dest[1].lower()
    verifier = runpy.run_path(str(root / "scripts/verify-video-profile.py"))
    profile = verifier["inspect_profile"](root, phases, dest[1])
    assert profile["allPassed"] and profile["requiredUniqueCases"] == 31 and profile["executions"] == 32
    assert profile["distinctHosts"] == 5
    return profile


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
              "GITHUB_REF": "refs/heads/codex/native-video-evidence", "GITHUB_RUN_ATTEMPT": "1",
              "GITHUB_ACTOR_ID": "105477711", "GITHUB_TRIGGERING_ACTOR": "Galaxybigbird", "RUNNER_OS": "Linux"}
    assert all(os.environ.get(k) == v for k, v in checks.items())
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    assert event["repository"]["full_name"] == REPOSITORY and event["repository"]["private"] is False
    root = Path(__file__).resolve().parents[1]
    proof = validate_source(root)
    run = github_read(f"/repos/{REPOSITORY}/actions/runs/{NATIVE_RUN}")
    job = github_read(f"/repos/{REPOSITORY}/actions/jobs/{NATIVE_JOB}")
    validate_metadata(run, job)
    raw = github_read(f"/repos/{REPOSITORY}/actions/jobs/{NATIVE_JOB}/logs", log=True)
    profile = verify_sdk(root, raw)
    report = {"compiledSource": COMPILED_SOURCE, "nativeRun": NATIVE_RUN, "nativeJob": NATIVE_JOB,
              "proofSource": proof, "appTree": APP_TREE, "coreTree": CORE_TREE, "logSHA256": LOG_SHA256,
              "originalJobConclusion": "failure", "originalFailure": "evidence-log-reporter",
              "runtimeAndSwiftTestsChanged": False, **profile}
    output = root / "artifacts/native-video-revalidation"; output.mkdir(parents=True, exist_ok=True)
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("NATIVE_VIDEO_REVALIDATED " + json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
