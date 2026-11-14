"""Synthetic lookup tests: never use real Apple keys or network."""
import base64
import importlib.util
import io
from pathlib import Path
from urllib.error import HTTPError
import uuid

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module


@pytest.fixture
def lookup():
    return load("prepared_apple_lookup", ROOT / "scripts/apple-build-info.py")


@pytest.fixture
def owner():
    return load("existing_apple_owner", ROOT / "scripts/apple-owner-runner.py")


def context():
    sha = "a" * 40
    return dict(GITHUB_ACTIONS="true", RUNNER_OS="Linux", RUNNER_ENVIRONMENT="github-hosted",
                GITHUB_REPOSITORY="AGForge-Labs/OfflineTikTokPlayer-public", GITHUB_REF="refs/heads/main",
                GITHUB_EVENT_NAME="workflow_dispatch", GITHUB_ACTOR_ID="105477711",
                GITHUB_TRIGGERING_ACTOR="Galaxybigbird", GITHUB_RUN_ATTEMPT="1",
                GITHUB_WORKFLOW_REF="AGForge-Labs/OfflineTikTokPlayer-public/.github/workflows/apple-build-info.yml@refs/heads/main",
                GITHUB_SHA=sha, GITHUB_WORKFLOW_SHA=sha, EXPECTED_CONTROL_COMMIT=sha, LOOKUP_AUTHORIZED="true")


EVENT = dict(repository=dict(full_name="AGForge-Labs/OfflineTikTokPlayer-public", private=False))


@pytest.mark.parametrize("key,value", [("GITHUB_ACTOR_ID", "1"), ("GITHUB_REF", "refs/heads/other"),
    ("GITHUB_RUN_ATTEMPT", "2"), ("GITHUB_SHA", "b" * 40), ("LOOKUP_AUTHORIZED", "false")])
def test_wrong_lookup_context_rejected_before_key_use(lookup, key, value):
    with pytest.raises(ValueError):
        lookup.validate_context(context() | {key: value}, EVENT)


def test_lookup_requires_public_repo_and_protected_environment(lookup):
    assert lookup.validate_context(context(), EVENT)
    with pytest.raises(ValueError):
        lookup.validate_context(context(), dict(repository=dict(full_name=lookup.REPOSITORY, private=True)))
    with pytest.raises(ValueError):
        lookup.validate_context(context(), EVENT, credentials=True)
    assert lookup.validate_context(context() | {"RELEASE_ENVIRONMENT": "release"}, EVENT, credentials=True)


def test_lookup_preflight_refuses_key_and_certificate_inputs(lookup):
    for key in ["APP_STORE_CONNECT_KEY_BASE64", "APPLE_CERTIFICATE_BASE64", "APPLE_PRIVATE_DELIVERY"]:
        with pytest.raises(ValueError):
            lookup.validate_context(context() | {key: "SYNTHETIC-PRIVATE-MARKER"}, EVENT)
    with pytest.raises(ValueError):
        lookup.validate_context(context() | {"RELEASE_ENVIRONMENT": "release", "APPLE_CERTIFICATE_PASSWORD": "synthetic"}, EVENT, credentials=True)


def test_configuration_is_key_only_and_invalid_data_is_redacted(lookup):
    pem = "-----BEGIN PRIVATE KEY-----\nSYNTHETIC-ONLY\n-----END PRIVATE KEY-----\n"
    env = dict(APP_STORE_CONNECT_KEY_ID="SYNTHETIC1", APP_STORE_CONNECT_ISSUER_ID=str(uuid.UUID(int=1)),
               APP_STORE_CONNECT_KEY_BASE64=base64.b64encode(pem.encode()).decode())
    result = lookup.key_configuration(env)
    assert set(result) == {"apiKeyID", "issuerID", "apiPrivateKey"}
    assert result["apiPrivateKey"] == pem
    for changed in [env | {"APP_STORE_CONNECT_KEY_BASE64": "SYNTHETIC-PRIVATE-MARKER"},
                    env | {"APP_STORE_CONNECT_KEY_ID": "bad"}, env | {"APP_STORE_CONNECT_ISSUER_ID": "bad"}]:
        with pytest.raises(ValueError) as error:
            lookup.key_configuration(changed)
        assert "SYNTHETIC-PRIVATE-MARKER" not in str(error.value)


def records():
    return [dict(id=str(uuid.UUID(int=n)), attributes=dict(version=version, processingState="VALID",
        buildAudienceType="INTERNAL_ONLY", expired=False, uploadedDate="2026-10-26T00:00:00Z",
        expirationDate="2027-01-24T00:00:00Z", privateUnexpectedField="SYNTHETIC-PRIVATE-MARKER"))
        for n, version in [(1, "9.1"), (2, "23.1"), (3, "20.1")]]


def test_build_report_selects_numeric_latest_and_only_safe_fields(lookup, owner):
    report = lookup.summarize_builds(records(), owner.number)
    assert report["appID"] == lookup.APP
    assert report["latestVersion"] == "23.1" and report["suggestedNextBuild"] == "24.1"
    assert [b["version"] for b in report["builds"]] == ["23.1", "20.1", "9.1"]
    assert "SYNTHETIC-PRIVATE-MARKER" not in str(report)


@pytest.mark.parametrize("status,body,expected", [
    (403, b'{"errors":[{"code":"FORBIDDEN.REQUIRED_AGREEMENTS_MISSING_OR_EXPIRED","detail":"SYNTHETIC-PRIVATE-MARKER"}]}', "required-agreement"),
    (401, b'{"errors":[{"code":"SYNTHETIC-PRIVATE-MARKER"}]}', "other"),
    (502, b"SYNTHETIC-PRIVATE-MARKER", "other"),
])
def test_read_only_lookup_reports_status_without_apple_response_details(lookup, status, body, expected):
    error = HTTPError("https://example.invalid/SYNTHETIC-PRIVATE-MARKER", status, "private", {}, io.BytesIO(body))
    assert lookup.apple_lookup_failure(error) == f"Apple build lookup returned HTTP {status} ({expected})."


@pytest.mark.parametrize("bad", [[], [dict(id=str(uuid.UUID(int=1)), attributes=dict(version="$(bad)"))],
    [dict(id=str(uuid.UUID(int=1)), attributes=dict(version="9999.1", processingState="VALID"))]])
def test_missing_or_invalid_build_state_cannot_guess_a_number(lookup, owner, bad):
    with pytest.raises(ValueError):
        lookup.summarize_builds(bad, owner.number)
