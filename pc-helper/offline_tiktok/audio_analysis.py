"""Content-bound loudness analysis; source samples and files are never changed."""
import hashlib
import json
import math
from pathlib import Path
import subprocess

from .catalog import AudioLoudness, Catalog


def analyze_loudness(path, *, ffmpeg="ffmpeg"):
    path = Path(path)
    if not path.is_file():
        raise ValueError("Loudness analysis requires a complete local file")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    result = subprocess.run([ffmpeg, "-nostdin", "-hide_banner", "-nostats", "-i", str(path),
        "-map", "0:a:0", "-vn", "-af", "loudnorm=I=-14:TP=-1:LRA=11:print_format=json",
        "-f", "null", "-"], capture_output=True, timeout=600,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    if result.returncode:
        raise ValueError("Could not analyze the archived audio")
    stderr = result.stderr.decode("utf-8", "replace")
    # FFmpeg may append final muxer statistics after this JSON object.
    try:
        raw, _ = json.JSONDecoder().raw_decode(stderr[stderr.rfind("{"):])
        integrated, peak = float(raw["input_i"]), float(raw["input_tp"])
    except (KeyError, ValueError, TypeError):
        raise ValueError("Invalid audio analysis response") from None
    with path.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != digest:
            raise ValueError("Playback file changed during loudness analysis")
    # Silence and extremely quiet background noise are not music to amplify.
    if not math.isfinite(integrated) or not math.isfinite(peak) or integrated <= -60:
        return None
    measurement = AudioLoudness(digest, integrated, peak)
    measurement.validate()
    return measurement


def merge_loudness(catalog, reports):
    """Apply audit metadata to a fresh catalog; never replace media or membership."""
    if (not isinstance(reports, dict) or type(reports.get("version")) is not int
            or reports["version"] != 1 or not isinstance(reports.get("items"), dict)):
        raise ValueError("Unsupported loudness audit checkpoint")
    updated = Catalog.from_json(catalog.to_json())
    changed = []
    for item in updated.media:
        record = reports["items"].get(item.id)
        if not isinstance(record, dict) or record.get("status") != "measured":
            continue
        if record.get("id") != item.id:
            raise ValueError("Loudness report identity mismatch")
        if item.status != "ready" or not item.asset or record.get("sha256") != item.asset.sha256:
            continue
        try:
            measurement = AudioLoudness(record["sha256"], record["integratedLUFS"], record["truePeakDBTP"])
        except KeyError:
            raise ValueError("Incomplete archived loudness report") from None
        measurement.validate()
        if measurement.integrated_lufs <= -60 or item.audio_loudness == measurement:
            continue
        item.audio_loudness = measurement
        changed.append(item.id)
    updated.validate()
    return updated, changed
