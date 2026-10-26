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
    print("Use Xcode-managed startup for the exact iPhone 17 Pro Max test destination", flush=True)
    spec = importlib.util.spec_from_file_location("owned_xcode", ROOT / "scripts/run-owned-xcodebuild.py")
    owned = importlib.util.module_from_spec(spec); spec.loader.exec_module(owned)
    command = ["xcodebuild", "-project", "ios/OfflineTikTokPlayer.xcodeproj", "-scheme", "OfflineTikTokPlayer",
        "-destination", "platform=iOS Simulator,name=iPhone 17 Pro Max", "-derivedDataPath", "artifacts/PhoneDerivedData",
        "-resultBundlePath", "artifacts/phone-native.xcresult", "-jobs", "1", "-parallel-testing-enabled", "NO",
        "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "60",
        "-maximum-test-execution-time-allowance", "60", *selectors,
        "SWIFT_OPTIMIZATION_LEVEL=-O", "PLAYBACK_TEST_SWIFT_FLAGS=-Onone",
        "SWIFT_USE_PARALLEL_WHOLE_MODULE_OPTIMIZATION=NO",
        "SWIFTC_MAXIMUM_DETERMINISM=1", "CODE_SIGNING_ALLOWED=NO", "test"]
    return owned.run_owned(command, 840, phase=4)["wrapperExit"]
if __name__ == "__main__": sys.exit(main())
