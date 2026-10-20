import base64
import copy
import datetime as dt
import importlib.util
from pathlib import Path
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
TEAM = "YU2A5J5978"
BUNDLE = "dev.galaxybigbird.OfflineTikTokPlayer"
NOW = dt.datetime(2026, 10, 18, tzinfo=dt.timezone.utc)


@pytest.fixture
def delivery():
    spec = importlib.util.spec_from_file_location("private_delivery", ROOT / "scripts/private-delivery.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def profile():
    return dict(UUID="11111111-2222-4333-8444-555555555555", Name="Offline Player Private TestFlight",
                TeamIdentifier=[TEAM], ApplicationIdentifierPrefix=[TEAM],
                ExpirationDate=NOW + dt.timedelta(days=300), DeveloperCertificates=[b"fixture-certificate"],
                Entitlements={"application-identifier": TEAM + "." + BUNDLE,
                              "com.apple.developer.team-identifier": TEAM,
                              "get-task-allow": False, "beta-reports-active": True,
                              "keychain-access-groups": [TEAM + ".*"]})


def test_distribution_profile_matches_only_this_team_app_and_certificate(delivery):
    assert delivery.validate_profile(profile(), b"fixture-certificate", now=NOW) == "11111111-2222-4333-8444-555555555555"


@pytest.mark.parametrize("change", ["team", "bundle", "expired", "debug", "devices", "enterprise", "certificate", "keychain"])
def test_wrong_or_non_testflight_signing_material_is_rejected_before_building(delivery, change):
    p = copy.deepcopy(profile())
    if change == "team": p["TeamIdentifier"] = ["OTHERTEAM1"]
    elif change == "bundle": p["Entitlements"]["application-identifier"] = TEAM + ".other.app"
    elif change == "expired": p["ExpirationDate"] = NOW - dt.timedelta(seconds=1)
    elif change == "debug": p["Entitlements"]["get-task-allow"] = True
    elif change == "devices": p["ProvisionedDevices"] = ["fixture-device"]
    elif change == "enterprise": p["ProvisionsAllDevices"] = True
    elif change == "certificate": p["DeveloperCertificates"] = [b"different-cert"]
    elif change == "keychain": p["Entitlements"]["keychain-access-groups"] = [TEAM + ".unrelated"]
    with pytest.raises(ValueError):
        delivery.validate_profile(p, b"fixture-certificate", now=NOW)


def test_export_is_internal_only_and_cannot_create_or_update_provisioning(delivery):
    options = delivery.export_options("fixture-profile-uuid", "A" * 40)
    assert options["testFlightInternalTestingOnly"] is True
    assert options["destination"] == "upload"
    assert options["method"] == "app-store-connect"
    assert options["signingStyle"] == "manual"
    assert options["teamID"] == TEAM
    assert options["provisioningProfiles"] == {BUNDLE: "fixture-profile-uuid"}
    assert options["manageAppVersionAndBuildNumber"] is False


@pytest.mark.parametrize("value", ["", "0", "202610180630", "1;echo secret", "1.100", "1.2.3.4"])
def test_invalid_build_numbers_fail_locally(delivery, value):
    with pytest.raises(ValueError): delivery.validate_build_number(value)


def test_increasing_workflow_attempts_produce_apple_compatible_build_numbers(delivery):
    assert delivery.validate_build_number("4.1") == "4.1"
    assert delivery.validate_build_number("4.2") == "4.2"


def test_secret_validation_never_echoes_its_contents(delivery):
    bad = {"certificateP12": "VERY-PRIVATE-TEST-VALUE"}
    with pytest.raises(ValueError) as exc:
        delivery.validate_configuration(bad)
    assert "VERY-PRIVATE" not in str(exc.value)


def test_child_tools_do_not_inherit_the_master_delivery_secret(delivery, monkeypatch):
    monkeypatch.setenv("APPLE_PRIVATE_DELIVERY", "fixture-private-material")
    result = delivery.run_tool([sys.executable, "-c", "import os; print('present' if 'APPLE_PRIVATE_DELIVERY' in os.environ else 'absent')"])
    assert result.strip() == b"absent"


def test_split_public_credentials_are_not_inherited_by_child_tools(delivery, monkeypatch):
    names = ("APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_PROVISIONING_PROFILE_BASE64", "APP_STORE_CONNECT_KEY_BASE64")
    for name in names:
        monkeypatch.setenv(name, "private-fixture")
    command = "import os; print(any(os.environ.get(n) for n in " + repr(names) + "))"
    assert delivery.run_tool([sys.executable, "-c", command]).strip() == b"False"


def test_split_public_configuration_preserves_the_approved_existing_identity(delivery):
    env = dict(APPLE_CERTIFICATE_BASE64=base64.b64encode(b"fixture-p12").decode(),
               APPLE_PROVISIONING_PROFILE_BASE64=base64.b64encode(b"fixture-cms").decode(),
               APPLE_CERTIFICATE_PASSWORD="fixture-password", APPLE_CERTIFICATE_SHA256="a" * 64,
               APP_STORE_CONNECT_KEY_BASE64=base64.b64encode(b"-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----").decode(),
               APP_STORE_CONNECT_KEY_ID="ABC1234567", APP_STORE_CONNECT_ISSUER_ID="11111111-2222-4333-8444-555555555555")
    config = delivery.public_configuration(env)
    assert config["teamID"] == TEAM
    assert config["certificateSHA256"] == "a" * 64
    assert config["apiKeyRole"] == "Developer"
    with pytest.raises(ValueError):
        delivery.public_configuration({**env, "APPLE_CERTIFICATE_SHA256": ""})


def test_archive_overrides_inherited_parallelism_and_keeps_internal_export(delivery, monkeypatch, tmp_path):
    monkeypatch.setenv("SWIFTC_MAXIMUM_DETERMINISM", "0")
    monkeypatch.setattr(delivery, "ROOT", tmp_path)
    monkeypatch.setattr(delivery.Path, "home", lambda: tmp_path / "home")
    commands = []
    real_tool = delivery.run_tool

    def tool(args, **kwargs):
        commands.append((args, kwargs))
        if args[:2] == ["xcrun", "swiftc"]:
            # Swift emits this remark on stderr; stdout contains its job plan.
            return real_tool([sys.executable, "-c", "import sys; print('driver job plan'); print('SWIFTC_MAXIMUM_DETERMINISM overriding -j', file=sys.stderr)"], **kwargs)
        return b""

    monkeypatch.setattr(delivery, "run_tool", tool)
    directory = tmp_path / "signing"
    directory.mkdir()
    profile_file = directory / "fixture-profile"
    profile_file.write_bytes(b"fixture-profile")
    config = dict(certificatePassword="fixture", apiKeyID="ABC1234567", issuerID="fixture-issuer")
    delivery.upload(config, directory, (directory / "cert", profile_file, directory / "key", "fixture-uuid", "A" * 40), "14.1")
    archive, arguments = next((args, kwargs) for args, kwargs in commands if args[0] == "xcodebuild" and "archive" in args)
    assert archive[archive.index("-jobs") + 1] == "1"
    assert archive[archive.index("-parallel-testing-enabled") + 1] == "NO"
    assert "SWIFTC_MAXIMUM_DETERMINISM=1" in archive
    assert "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO" in archive
    assert arguments["env"]["SWIFTC_MAXIMUM_DETERMINISM"] == "1"
    assert "CURRENT_PROJECT_VERSION=14.1" in archive
    probe, probe_arguments = commands[0]
    assert probe == ["xcrun", "swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"]
    assert probe_arguments["env"]["SWIFTC_MAXIMUM_DETERMINISM"] == "1"
    assert probe_arguments["input"] == b""
    assert probe_arguments["combined_output"] is True
    assert delivery.plistlib.loads((directory / "ExportOptions.plist").read_bytes())["testFlightInternalTestingOnly"] is True


@pytest.mark.parametrize("driver_failure", ["missing_override", "nonzero_exit"])
def test_archive_stops_before_keychain_or_build_without_driver_override(delivery, monkeypatch, tmp_path, driver_failure):
    commands = []
    monkeypatch.setattr(delivery.Path, "home", lambda: tmp_path / "home")
    def tool(args, **kwargs):
        commands.append(args)
        assert args[:2] == ["xcrun", "swiftc"]
        if driver_failure == "nonzero_exit":
            raise RuntimeError("one-job override probe failed")
        return b"unconfirmed driver plan"
    monkeypatch.setattr(delivery, "run_tool", tool)
    with pytest.raises((ValueError, RuntimeError), match="one-job override"):
        delivery.upload({}, tmp_path, (None, None, None, "fixture-uuid", "A" * 40), "14.1")
    assert len(commands) == 1
    assert commands[0][:2] == ["xcrun", "swiftc"]


def test_delivery_credentials_are_accepted_only_for_the_approved_team_and_role(delivery):
    config = dict(teamID=TEAM, apiKeyRole="Developer", apiKeyID="ABC1234567",
                  issuerID="11111111-2222-4333-8444-555555555555", certificatePassword="fixture-only",
                  certificateP12=base64.b64encode(b"fixture-p12").decode(),
                  provisioningProfile=base64.b64encode(b"fixture-cms").decode(),
                  apiPrivateKey="-----BEGIN PRIVATE KEY-----\nfixture\n-----END PRIVATE KEY-----")
    delivery.validate_configuration(config)
    for field, value in [("teamID", "OTHERTEAM1"), ("apiKeyRole", "Admin")]:
        bad = {**config, field: value}
        with pytest.raises(ValueError): delivery.validate_configuration(bad)
