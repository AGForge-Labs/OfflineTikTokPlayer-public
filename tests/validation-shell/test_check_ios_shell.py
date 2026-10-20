#!/usr/bin/env python3
"""Exercise the native-check launcher with isolated fake tools, including Bash 3."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]


class NativeLauncherTests(unittest.TestCase):
    def exercise(self, arguments=(), status=0):
        with tempfile.TemporaryDirectory(prefix="offline-ios-shell-") as directory:
            root = Path(directory)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            shutil.copyfile(ROOT / "scripts/check-ios.sh", root / "scripts/check-ios.sh")
            for script in ("test-core.sh", "test-apple-buffer.sh"):
                (root / "scripts" / script).write_text("#!/bin/bash\nexit 0\n")
            python = root / "bin/python3"
            python.write_text("""#!/bin/bash
case "$*" in
  *--resolve-destination*) printf '%s\\n' '00000000-0000-0000-0000-000000000001' ;;
  *--udid*) echo $$ > "$LAUNCHER_TEST_ROOT/helper.pid"; exec sleep 60 ;;
  *) exit 0 ;;
esac
""")
            xcode = root / "bin/xcodebuild"
            xcode.write_text("""#!/bin/bash
printf '%s\\n' "$@" > "$LAUNCHER_TEST_ROOT/xcode.args"
for ((attempt=0; attempt<100; attempt++)); do
  [ -f "$LAUNCHER_TEST_ROOT/helper.pid" ] && break
  sleep 0.01
done
exit "$LAUNCHER_TEST_STATUS"
""")
            python.chmod(0o755)
            xcode.chmod(0o755)
            environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                LAUNCHER_TEST_ROOT=str(root), LAUNCHER_TEST_STATUS=str(status))
            result = subprocess.run(["/bin/bash", str(root / "scripts/check-ios.sh"), *arguments],
                env=environment, text=True, capture_output=True, timeout=10)
            actual = (root / "xcode.args").read_text().splitlines() if (root / "xcode.args").exists() else []
            pid_file = root / "helper.pid"
            if pid_file.exists():
                pid = int(pid_file.read_text())
                for _ in range(50):
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.01)
                else:
                    os.kill(pid, signal.SIGTERM)
                    self.fail("The launcher left its screenshot helper running")
            self.assertTrue(pid_file.exists(), "The isolated screenshot helper must actually start")
            self.assertEqual(result.returncode, status, result.stdout + result.stderr)
            self.assertIn("CODE_SIGNING_ALLOWED=NO", actual)
            self.assertEqual(actual[actual.index("-jobs") + 1], "1")
            self.assertEqual(actual[actual.index("-parallel-testing-enabled") + 1], "NO")
            self.assertEqual(actual[actual.index("-destination") + 1],
                "platform=iOS Simulator,id=00000000-0000-0000-0000-000000000001")
            return actual

    def test_full_suite_reaches_xcodebuild_without_filters(self):
        self.assertFalse(any(arg.startswith("-only-testing:") for arg in self.exercise()))

    def test_focused_suite_keeps_all_four_native_classes(self):
        arguments = self.exercise(("--selection-only",))
        self.assertEqual({arg for arg in arguments if arg.startswith("-only-testing:")}, {
            "-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionFailureTests",
            "-only-testing:OfflineTikTokPlayerTests/PlaybackSelectionVideoRegressionTests",
            "-only-testing:OfflineTikTokPlayerTests/ContinuousAudioPlayerTests",
            "-only-testing:OfflineTikTokPlayerTests/ContinuousPCMDecoderTests",
        })

    def test_native_failure_survives_exit_cleanup(self):
        self.exercise(status=23)


if __name__ == "__main__":
    unittest.main()
