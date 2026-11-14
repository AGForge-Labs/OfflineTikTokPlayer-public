"""Owner-only read-only lookup for one app. Never print credential material."""
import argparse
import base64
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.error
import uuid

APP = "6824156409"
REPOSITORY = "AGForge-Labs/OfflineTikTokPlayer-public"
ROOT = Path(__file__).resolve().parents[1]
CERTIFICATE_INPUTS = ("APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD",
                      "APPLE_PROVISIONING_PROFILE_BASE64", "APPLE_PRIVATE_DELIVERY")


def require(value):
    if not value:
        raise ValueError("Read-only Apple lookup validation failed; private details are suppressed.")


def validate_context(environment, event, *, credentials=False):
    expected = environment.get("EXPECTED_CONTROL_COMMIT", "")
    checks = dict(GITHUB_ACTIONS="true", RUNNER_OS="Linux", RUNNER_ENVIRONMENT="github-hosted",
        GITHUB_REPOSITORY=REPOSITORY, GITHUB_REF="refs/heads/main", GITHUB_EVENT_NAME="workflow_dispatch",
        GITHUB_ACTOR_ID="105477711", GITHUB_TRIGGERING_ACTOR="Galaxybigbird", GITHUB_RUN_ATTEMPT="1",
        GITHUB_WORKFLOW_REF=REPOSITORY + "/.github/workflows/apple-build-info.yml@refs/heads/main",
        GITHUB_SHA=expected, GITHUB_WORKFLOW_SHA=expected, LOOKUP_AUTHORIZED="true")
    require(re.fullmatch(r"[0-9a-f]{40}", expected) is not None
        and all(environment.get(name) == value for name, value in checks.items()))
    repository = event.get("repository") if isinstance(event, dict) else None
    require(isinstance(repository, dict) and repository.get("full_name") == REPOSITORY
        and repository.get("private") is False)
    require(not any(environment.get(name) for name in CERTIFICATE_INPUTS))
    if credentials:
        require(environment.get("RELEASE_ENVIRONMENT") == "release")
    else:
        require(not environment.get("APP_STORE_CONNECT_KEY_BASE64"))
    return True


def key_configuration(environment):
    try:
        key_id = environment["APP_STORE_CONNECT_KEY_ID"]
        issuer = environment["APP_STORE_CONNECT_ISSUER_ID"]
        encoded = environment["APP_STORE_CONNECT_KEY_BASE64"]
        require(isinstance(key_id, str) and re.fullmatch(r"[A-Z0-9]{10}", key_id))
        uuid.UUID(issuer)
        require(isinstance(encoded, str) and 1 <= len(encoded) <= 24 * 1024)
        pem = base64.b64decode(encoded, validate=True).decode("utf-8")
        require(pem.startswith("-----BEGIN PRIVATE KEY-----\n")
            and pem.strip().endswith("-----END PRIVATE KEY-----"))
        return dict(apiKeyID=key_id, issuerID=issuer, apiPrivateKey=pem)
    except Exception:
        raise ValueError("Protected Apple API key inputs are invalid; values are suppressed.") from None


def apple_lookup_failure(error):
    reason = "other"
    try:
        payload = json.loads(error.read(32 * 1024))
        if error.code == 403 and any(value.get("code") == "FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED"
                                     for value in payload.get("errors", []) if isinstance(value, dict)):
            reason = "required-agreement"
    except (ValueError, AttributeError, TypeError, OSError):
        pass
    return f"Apple build lookup returned HTTP {error.code} ({reason})."


def summarize_builds(records, number):
    require(isinstance(records, list) and 1 <= len(records) <= 200)
    safe = []
    for record in records:
        require(isinstance(record, dict) and isinstance(record.get("attributes"), dict))
        attrs = record["attributes"]
        version = attrs.get("version"); number(version)
        require(attrs.get("processingState") in {"PROCESSING", "VALID", "FAILED", "INVALID"})
        require(attrs.get("buildAudienceType") in {None, "INTERNAL_ONLY", "APP_STORE_ELIGIBLE"})
        require(attrs.get("expired") is None or type(attrs["expired"]) is bool)
        item = dict(id=str(uuid.UUID(record["id"])), version=version,
            processingState=attrs["processingState"], buildAudienceType=attrs.get("buildAudienceType"),
            expired=attrs.get("expired"))
        for name in ("uploadedDate", "expirationDate"):
            value = attrs.get(name)
            require(value is None or isinstance(value, str) and len(value) <= 64)
            item[name] = dt.datetime.fromisoformat(value).isoformat() if value else None
        safe.append(item)
    safe.sort(key=lambda item: number(item["version"]), reverse=True)
    latest = safe[0]["version"]
    first = number(latest)[0]
    require(first < 9999)
    return dict(appID=APP, latestVersion=latest, suggestedNextBuild=str(first + 1) + ".1", builds=safe)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "lookup"))
    args = parser.parse_args()
    environment = dict(os.environ)
    event_path = Path(environment["GITHUB_EVENT_PATH"])
    require(event_path.stat().st_size <= 1024 * 1024)
    event = json.loads(event_path.read_text(encoding="utf-8"))
    validate_context(environment, event, credentials=args.command == "lookup")
    workspace = Path(environment["GITHUB_WORKSPACE"]).resolve(strict=True)
    require(ROOT == workspace / "control" and not (workspace / "control").is_symlink())
    def git(*arguments):
        return subprocess.check_output(["git", "--no-optional-locks", "-C", str(ROOT), *arguments],
            stdin=subprocess.DEVNULL, timeout=10).decode().strip()
    require(git("rev-parse", "HEAD") == environment["EXPECTED_CONTROL_COMMIT"]
        and not git("status", "--porcelain", "--untracked-files=all"))
    if args.command == "check":
        print("Exact owner/main lookup request verified without Apple inputs.")
        return
    spec = importlib.util.spec_from_file_location("existing_apple_owner", ROOT / "scripts/apple-owner-runner.py")
    owner = importlib.util.module_from_spec(spec); spec.loader.exec_module(owner)
    require(owner.APP == APP)
    try:
        configuration = key_configuration(environment)
    except ValueError:
        print("Protected Apple API key inputs did not pass validation.", file=sys.stderr)
        raise SystemExit(1) from None
    with tempfile.TemporaryDirectory(prefix="apple-build-read-", dir=environment["RUNNER_TEMP"]) as temporary:
        directory = Path(temporary); directory.chmod(0o700)
        try:
            apple = owner.Apple(configuration, directory)
        except (ValueError, OSError, subprocess.SubprocessError):
            print("Apple build lookup could not create its signed API token.", file=sys.stderr)
            raise SystemExit(1) from None
        # Existing client permits exactly this app's GET build-list route here.
        try:
            builds = owner.builds(apple)
        except ValueError as error:
            # The existing client suppresses Apple HTTP bodies at the public boundary.
            if isinstance(error.__context__, urllib.error.HTTPError):
                print(apple_lookup_failure(error.__context__), file=sys.stderr)
                raise SystemExit(1) from None
            print("Apple build lookup received an invalid build list.", file=sys.stderr)
            raise SystemExit(1) from None
        report = summarize_builds(builds, owner.number)
    report["checkedAtUTC"] = dt.datetime.now(dt.timezone.utc).isoformat()
    print("APPLE_BUILD_INFO " + json.dumps(report, sort_keys=True))
    if environment.get("GITHUB_STEP_SUMMARY"):
        with Path(environment["GITHUB_STEP_SUMMARY"]).open("a", encoding="utf-8") as summary:
            summary.write("Latest existing build: " + report["latestVersion"]
                + "; next increasing candidate: " + report["suggestedNextBuild"] + ". Read-only lookup; no upload.\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Read-only Apple build lookup stopped; private details are suppressed.", file=sys.stderr)
        sys.exit(1)
