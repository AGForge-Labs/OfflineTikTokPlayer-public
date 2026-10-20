#!/usr/bin/env python3
"""Recreate public synthetic A/B media with one FFmpeg worker; no user media inputs."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "ios/OfflineTikTokPlayerTests/Fixtures"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", default=shutil.which("ffmpeg"))
    arguments = parser.parse_args()
    if not arguments.ffmpeg:
        parser.error("An existing FFmpeg executable is required; this script installs nothing")
    reports = []
    for identity, color, frequency in [("a", "0xF01818", 440), ("b", "0x18F018", 880)]:
        output = FIXTURES / f"test-selection-{identity}.mp4"
        command = [arguments.ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
            "-filter_threads", "1", "-filter_complex_threads", "1",
            "-f", "lavfi", "-i", f"color=c={color}:s=160x96:r=24:d=30",
            "-f", "lavfi", "-i", "color=c=0x1818F0:s=16x96:r=24:d=30",
            "-f", "lavfi", "-i", f"sine=frequency={frequency}:sample_rate=48000:duration=30",
            "-filter_complex",
            r"[0:v][1:v]overlay=x=mod(floor(t*8)*10\,144):y=0:shortest=1[v];[2:a]volume=1.6,pan=stereo|c0=c0|c1=c0[a]",
            "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-threads:v", "1",
            "-preset", "fast", "-crf", "23", "-g", "24", "-keyint_min", "24", "-sc_threshold", "0", "-bf", "0",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-threads:a", "1", "-b:a", "96k", "-ar", "48000",
            "-movflags", "+faststart", "-t", "30", str(output)]
        subprocess.run(command, check=True, timeout=60)
        content = output.read_bytes()
        reports.append({"file": output.name, "bytes": len(content), "sha256": hashlib.sha256(content).hexdigest(),
            "durationSeconds": 30, "width": 160, "height": 96, "framesPerSecond": 24, "toneHz": frequency})
    print(json.dumps(reports, indent=2))


if __name__ == "__main__":
    main()
