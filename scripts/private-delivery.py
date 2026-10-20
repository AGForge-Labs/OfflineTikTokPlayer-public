"""Validate approved signing material; optionally upload an internal-only TestFlight build.

APPLE_PRIVATE_DELIVERY is a repository secret, never a checked-in configuration file.
Only standard Python and Apple's existing command-line tools are required on the runner.
"""
import argparse
import base64
import binascii
import datetime as dt
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import uuid

TEAM = "YU2A5J5978"
BUNDLE = "dev.galaxybigbird.OfflineTikTokPlayer"
ROOT = Path(__file__).resolve().parents[1]


def public_configuration(env):
    """Use individually protected inputs; never extract the old repository secret."""
    try:
        config = dict(teamID=TEAM, apiKeyRole="Developer",
                      apiKeyID=env["APP_STORE_CONNECT_KEY_ID"], issuerID=env["APP_STORE_CONNECT_ISSUER_ID"],
                      certificatePassword=env["APPLE_CERTIFICATE_PASSWORD"],
                      certificateP12=env["APPLE_CERTIFICATE_BASE64"],
                      provisioningProfile=env["APPLE_PROVISIONING_PROFILE_BASE64"],
                      apiPrivateKey=base64.b64decode(env["APP_STORE_CONNECT_KEY_BASE64"], validate=True).decode("utf-8"),
                      certificateSHA256=env["APPLE_CERTIFICATE_SHA256"])
        if not re.fullmatch(r"[0-9a-f]{64}", config["certificateSHA256"]):
            raise ValueError
        validate_configuration(config)
        return config
    except (KeyError, ValueError, UnicodeError, binascii.Error):
        raise ValueError("Protected public signing inputs are incomplete or invalid.") from None


def validate_build_number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]{0,3}(?:\.(?:0|[1-9][0-9]?)){0,2}", value):
        raise ValueError("Use an increasing build number with up to three numeric components, such as 4.1.")
    return value


def validate_configuration(config):
    try:
        if config["teamID"] != TEAM or config["apiKeyRole"] != "Developer":
            raise ValueError
        if not re.fullmatch(r"[A-Z0-9]{10}", config["apiKeyID"]):
            raise ValueError
        uuid.UUID(config["issuerID"])
        if not config["certificatePassword"] or not isinstance(config["certificatePassword"], str):
            raise ValueError
        for field in ("certificateP12", "provisioningProfile"):
            if not base64.b64decode(config[field], validate=True):
                raise ValueError
        if not (config["apiPrivateKey"].startswith("-----BEGIN PRIVATE KEY-----\n")
                and config["apiPrivateKey"].strip().endswith("-----END PRIVATE KEY-----")):
            raise ValueError
    except (KeyError, TypeError, AttributeError, ValueError, binascii.Error):
        raise ValueError("The private delivery secret is incomplete or differs from the approved team/Developer role.") from None


def validate_profile(profile, certificate_der, *, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    try:
        entitlements = profile["Entitlements"]
        expiry = profile["ExpirationDate"]
        if expiry.tzinfo is None:
            expiry = expiry.replace(tzinfo=dt.timezone.utc)
        groups = entitlements.get("keychain-access-groups", [])
        checks = [
            profile["TeamIdentifier"] == [TEAM],
            profile["ApplicationIdentifierPrefix"] == [TEAM],
            entitlements["application-identifier"] == TEAM + "." + BUNDLE,
            entitlements["com.apple.developer.team-identifier"] == TEAM,
            entitlements.get("get-task-allow") is False,
            entitlements.get("beta-reports-active") is True,
            not profile.get("ProvisionedDevices"), not profile.get("ProvisionsAllDevices"),
            expiry > now + dt.timedelta(hours=1),
            certificate_der in profile["DeveloperCertificates"],
            TEAM + ".*" in groups or TEAM + ".com.microsoft.adalcache" in groups,
        ]
        if not all(checks):
            raise ValueError
        return str(uuid.UUID(profile["UUID"]))
    except (KeyError, TypeError, AttributeError, ValueError):
        raise ValueError("Signing profile must be current App Store distribution for this team, app, keychain group and certificate.") from None


def export_options(profile_uuid, certificate_sha1):
    return dict(method="app-store-connect", destination="upload", signingStyle="manual", teamID=TEAM,
                signingCertificate=certificate_sha1, provisioningProfiles={BUNDLE: profile_uuid},
                testFlightInternalTestingOnly=True, manageAppVersionAndBuildNumber=False, uploadSymbols=True)


def run_tool(args, *, visible=False, combined_output=False, **kwargs):
    # Several security commands take passwords as arguments. Never format their exceptions or command lines.
    environment = dict(kwargs.pop("env", os.environ))
    environment.pop("APPLE_PRIVATE_DELIVERY", None)
    for name in ("APPLE_CERTIFICATE_BASE64", "APPLE_CERTIFICATE_PASSWORD", "APPLE_PROVISIONING_PROFILE_BASE64",
                 "APP_STORE_CONNECT_KEY_BASE64"):
        environment.pop(name, None)
    result = subprocess.run(args, stdout=None if visible else subprocess.PIPE,
                            stderr=subprocess.STDOUT if combined_output else (None if visible else subprocess.PIPE),
                            env=environment, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{Path(args[0]).name} failed (exit {result.returncode}); private arguments were omitted.")
    return result.stdout


def materialize(config, directory):
    certificate = directory / "distribution.p12"
    certificate.write_bytes(base64.b64decode(config["certificateP12"], validate=True))
    password = directory / "certificate-password"
    password.write_text(config["certificatePassword"], encoding="utf-8")
    cms_profile = directory / "player.mobileprovision"
    cms_profile.write_bytes(base64.b64decode(config["provisioningProfile"], validate=True))
    api_key = directory / ("AuthKey_" + config["apiKeyID"] + ".p8")
    api_key.write_text(config["apiPrivateKey"], encoding="utf-8")
    for path in (certificate, password, cms_profile, api_key):
        path.chmod(0o600)
    decoded = run_tool(["security", "cms", "-D", "-i", str(cms_profile)])
    cert_pem = directory / "certificate.pem"
    run_tool(["openssl", "pkcs12", "-in", str(certificate), "-passin", "file:" + str(password),
              "-clcerts", "-nokeys", "-out", str(cert_pem)])
    cert_der = run_tool(["openssl", "x509", "-in", str(cert_pem), "-outform", "DER"])
    if config.get("certificateSHA256"):
        if hashlib.sha256(cert_der).hexdigest() != config["certificateSHA256"]:
            raise ValueError("Distribution certificate differs from the approved existing signing identity.")
    profile_uuid = validate_profile(plistlib.loads(decoded), cert_der)
    run_tool(["openssl", "x509", "-in", str(cert_pem), "-checkend", "3600", "-noout"])
    run_tool(["openssl", "pkey", "-in", str(api_key), "-check", "-noout"])
    return certificate, cms_profile, api_key, profile_uuid, hashlib.sha1(cert_der).hexdigest().upper()


def upload(config, directory, material, build_number):
    certificate, cms_profile, api_key, profile_uuid, certificate_sha1 = material
    # This archive runs on a different hosted job from native validation.
    # Force the Swift driver's cap as well as Xcode's build queue limit.
    archive_environment = dict(os.environ, SWIFTC_MAXIMUM_DETERMINISM="1")
    driver_plan = run_tool(["xcrun", "swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-"],
                           input=b"", env=archive_environment, combined_output=True)
    if b"SWIFTC_MAXIMUM_DETERMINISM overriding -j" not in driver_plan:
        raise ValueError("The selected archive Swift driver did not confirm its one-job override.")
    keychain = directory / "player-signing.keychain-db"
    keychain_password = secrets.token_urlsafe(32)
    old_search_list = shlex.split(run_tool(["security", "list-keychains", "-d", "user"]).decode())
    profile_dir = Path.home() / "Library/MobileDevice/Provisioning Profiles"
    profile_dir.mkdir(parents=True, exist_ok=True)
    installed_profile = profile_dir / (profile_uuid + ".mobileprovision")
    if installed_profile.exists():
        raise ValueError("This signing profile is already installed; refusing to overwrite it.")
    created_keychain = installed = False
    try:
        run_tool(["security", "create-keychain", "-p", keychain_password, str(keychain)])
        created_keychain = True
        run_tool(["security", "set-keychain-settings", "-lut", "3600", str(keychain)])
        run_tool(["security", "unlock-keychain", "-p", keychain_password, str(keychain)])
        run_tool(["security", "import", str(certificate), "-k", str(keychain), "-P", config["certificatePassword"],
                  "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"])
        run_tool(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychain_password, str(keychain)])
        run_tool(["security", "list-keychains", "-d", "user", "-s", str(keychain), *old_search_list])
        with installed_profile.open("xb") as target:
            target.write(cms_profile.read_bytes())
        installed = True
        installed_profile.chmod(0o600)
        archive = ROOT / "artifacts/release" / ("OfflineTikTokPlayer-" + build_number + ".xcarchive")
        archive.parent.mkdir(parents=True, exist_ok=True)
        run_tool(["python3", "scripts/generate-ios-project.py", "--check"], cwd=ROOT, visible=True)
        run_tool(["xcodebuild", "-project", "ios/OfflineTikTokPlayer.xcodeproj", "-scheme", "OfflineTikTokPlayer",
                  "-configuration", "Release", "-destination", "generic/platform=iOS", "-archivePath", str(archive),
                  "-derivedDataPath", "artifacts/DerivedData", "-jobs", "1", "-parallel-testing-enabled", "NO",
                  "SWIFTC_MAXIMUM_DETERMINISM=1", "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO",
                  "DEVELOPMENT_TEAM=" + TEAM,
                  "CURRENT_PROJECT_VERSION=" + build_number, "CODE_SIGN_STYLE=Manual",
                  "PROVISIONING_PROFILE_SPECIFIER=" + profile_uuid, "CODE_SIGN_IDENTITY=" + certificate_sha1, "archive"],
                 cwd=ROOT, visible=True, env=archive_environment)
        options_file = directory / "ExportOptions.plist"
        options_file.write_bytes(plistlib.dumps(export_options(profile_uuid, certificate_sha1)))
        run_tool(["xcodebuild", "-exportArchive", "-archivePath", str(archive), "-exportPath", str(directory / "export"),
                  "-exportOptionsPlist", str(options_file), "-authenticationKeyPath", str(api_key),
                  "-authenticationKeyID", config["apiKeyID"], "-authenticationKeyIssuerID", config["issuerID"]],
                 cwd=ROOT, visible=True)
        print("Uploaded internal-only TestFlight build " + build_number + "; Apple processing and owner phone acceptance remain.", flush=True)
    finally:
        # A hosted runner is disposable; still clean up normally on both success and error.
        if installed:
            installed_profile.unlink(missing_ok=True)
        if created_keychain:
            for command in (["security", "list-keychains", "-d", "user", "-s", *old_search_list],
                            ["security", "delete-keychain", str(keychain)]):
                try: run_tool(command)
                except (OSError, RuntimeError): print("Runner keychain cleanup needs attention.", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upload", action="store_true", help="Archive and upload; omission validates credentials only.")
    parser.add_argument("--public-release", action="store_true", help="Use the reviewed protected public release route.")
    args = parser.parse_args()
    if sys.platform != "darwin":
        raise ValueError("Private signing requires the approved macOS runner.")
    if args.public_release:
        spec = importlib.util.spec_from_file_location("public_release", ROOT / "scripts/public-release.py")
        public = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(public)
        build_number = public.validate_context(os.environ, signing=True)
        public.verify_checkout(os.environ)
        config = public_configuration(os.environ)
    else:
        if os.environ.get("GITHUB_REPOSITORY") != "AGForge-Labs/OfflineTikTokPlayer" or os.environ.get("GITHUB_REF") != "refs/heads/main":
            raise ValueError("Private delivery is restricted to the approved repository's main branch.")
        if os.environ.get("GITHUB_EVENT_NAME") != "workflow_dispatch":
            raise ValueError("Private delivery must be deliberately dispatched.")
        build_number = validate_build_number(os.environ.get("BUILD_NUMBER", ""))
        try:
            config = json.loads(os.environ.get("APPLE_PRIVATE_DELIVERY", ""))
        except (ValueError, TypeError):
            raise ValueError("The APPLE_PRIVATE_DELIVERY repository secret is missing or invalid.") from None
    validate_configuration(config)
    runner_temp = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="offline-player-signing-", dir=runner_temp) as temporary:
        directory = Path(temporary)
        directory.chmod(0o700)
        material = materialize(config, directory)
        print("Approved app/profile/certificate and API-key format validated.", flush=True)
        if args.upload:
            upload(config, directory, material, build_number)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError):
        # No traceback or raw secret/configuration is sent to Actions logs.
        print("Private delivery stopped. Check the signing secret, profile, runner scope and preceding Xcode result.", file=sys.stderr)
        raise SystemExit(1)
