"""Reuse exact native test results only when the application and its fixtures match."""
import json
from pathlib import Path
import re
import subprocess
import sys


SOURCE = "5ff22edfaa2de9bab12f63ffc7a1ddc7b2e76246"
RUN = 44714238152
SIMULATOR = 136214095858
WORKFLOW = ".github/workflows/loop-picture-recovery.yml"
PENDING = "OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests/testIssuedVideoSeekCompletionCannotActivateStaleABeforeNaturalBVisitAdoption"


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def git(*args):
    return subprocess.check_output(["git", *args], text=True, encoding="utf-8").strip()


def selectors(workflow):
    aliases = dict(re.findall(r"^\s*(\w+)=(OfflineTikTokPlayerTests/\w+)\s*$", workflow, re.M))
    names = set(re.findall(r"(\$(?:video|recovery|native|selection)/test\w+|OfflineTikTokPlayer(?:UI)?Tests/\w+/test\w+)", workflow))
    result = set()
    for name in names:
        if name.startswith("$"):
            alias, method = name[1:].split("/")
            name = f"{aliases[alias]}/{method}"
        result.add(name)
    return result


def main():
    run_path, jobs_path, log_path = map(Path, sys.argv[1:])
    run = json.loads(run_path.read_text(encoding="utf-8"))
    require(run["id"] == RUN and run["head_sha"] == SOURCE and run["run_attempt"] == 1
            and run["head_branch"] == "codex/current-player-frame-source" and run["path"] == WORKFLOW
            and run["event"] == "push" and run["conclusion"] == "failure"
            and run["repository"]["full_name"] == "Galaxybigbird/OfflineTikTokPlayer-public"
            and run["repository"]["id"] == 1424911966 and run["repository"]["private"] is False,
            "Prior run does not match the reviewed repository, branch or source.")
    jobs = json.loads(jobs_path.read_text(encoding="utf-8"))["jobs"]
    require(all(j["head_sha"] == SOURCE and j["run_id"] == RUN and j["status"] == "completed" for j in jobs)
            and {(j["id"], j["name"], j["conclusion"]) for j in jobs}
            == {(136213403093, "portable", "success"), (SIMULATOR, "simulator", "failure")},
            "Prior native jobs do not match.")
    changes = set(git("diff", "--name-only", SOURCE, "HEAD").splitlines())
    require(changes <= {WORKFLOW, "scripts/verify-held-picture-results.py",
                        "ios/OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests.swift"},
            "Production code, project, fixture or other test differs. Run full native verification.")
    expected = selectors(git("show", f"{SOURCE}:{WORKFLOW}"))
    require(len(expected) == 36 and PENDING in expected, "The original test matrix differs.")
    log = log_path.read_text(encoding="utf-8", errors="replace")
    results = re.findall(r"'-\[(OfflineTikTokPlayer(?:UI)?Tests)\.(\w+) (test\w+)\]' (passed|failed) \([\d.]+ seconds\)\.", log)
    by_case = {f"{module}/{suite}/{method}": outcome for module, suite, method, outcome in results}
    require(len(results) == len(by_case) and set(by_case) == expected, "Missing or duplicate XCTest results.")
    require({name for name in expected if by_case[name] != "passed"} == {PENDING}
            and "NaturalSeekCompletionStartup schema=1 stage=0 prepared=false" in log
            and "NaturalSeekCompletionSummary schema=1 stage=0 intercepted=false nativeCallbacks=0" in log,
            "The prior result is not the single confirmed setup failure.")
    print("Confirmed 35 native passes on identical runtime and fixtures. The one open test must pass on macOS.")


if __name__ == "__main__":
    main()
