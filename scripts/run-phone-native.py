"""One focused unsigned simulator check; it never signs or grants native acceptance."""
from pathlib import Path
import importlib.util
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
def main():
    subprocess.run([sys.executable, "-B", "scripts/generate-ios-project.py", "--check"], cwd=ROOT, check=True, timeout=30)
    profile = "tests/phone-playback-reliability.json"
    selectors = subprocess.check_output([sys.executable, "-B", "scripts/verify-native-test-log.py",
        "--profile", profile, "--print-xcode-tests"], cwd=ROOT, timeout=30).decode().splitlines()
    # Start the installed Simulator service before its first cold simctl query.
    subprocess.run(["open", "-g", "-a", "Simulator"], cwd=ROOT, check=True, timeout=20)
    identifier = subprocess.check_output([sys.executable, "-B", "scripts/capture-simulator-test-frames.py",
        "--resolve-destination", "platform=iOS Simulator,name=iPhone 17 Pro Max"], cwd=ROOT, timeout=65).decode().strip()
    subprocess.run([sys.executable, "-B", "scripts/ensure-simulator-booted.py", "--udid", identifier], cwd=ROOT, check=True, timeout=245)
    spec = importlib.util.spec_from_file_location("owned_xcode", ROOT / "scripts/run-owned-xcodebuild.py")
    owned = importlib.util.module_from_spec(spec); spec.loader.exec_module(owned)
    command = ["xcodebuild", "-project", "ios/OfflineTikTokPlayer.xcodeproj", "-scheme", "OfflineTikTokPlayer",
        "-destination", "platform=iOS Simulator,id=" + identifier, "-derivedDataPath", "artifacts/PhoneDerivedData",
        "-resultBundlePath", "artifacts/phone-native.xcresult", "-jobs", "1", "-parallel-testing-enabled", "NO",
        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "60",
        "-maximum-test-execution-time-allowance", "60", *selectors,
        "SWIFTC_MAXIMUM_DETERMINISM=1", "CODE_SIGNING_ALLOWED=NO", "test"]
    return owned.run_owned(command, 360, phase=4)["wrapperExit"]
if __name__ == "__main__": sys.exit(main())
