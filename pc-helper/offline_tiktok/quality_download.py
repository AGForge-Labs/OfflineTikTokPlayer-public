"""Verified TikTok post components; no standalone-song substitutions."""
from http.cookiejar import Cookie
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from urllib.parse import urlparse
from .source_quality import QUALITY_VERSION, Rendition, choose_video, audio_candidates, combine_tracks
from .source_session import probe_source
from .cost_audit import atomic_json


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def source_options():
    return dict(format="best*", format_sort=["res", "fps", "br", "codec"],
                quiet=True, no_warnings=True, noplaylist=True, socket_timeout=20, retries=2, extractor_retries=1)


def source_identity(fmt):
    # Query parameters can identify the media, not just authorize it. Only the
    # digest is persisted; signed URLs and their credentials stay in memory.
    identity = (fmt["format_id"], fmt.get("filesize"), fmt.get("url", ""))
    return hashlib.sha256(json.dumps(identity).encode()).hexdigest()


class TikTokSource:
    def __init__(self, item, cookies, tools, progress, cancelled):
        self.item, self.tools, self.progress, self.cancelled = item, tools, progress, cancelled
        from yt_dlp import YoutubeDL
        from .media import _QuietLogger
        self.downloader = YoutubeDL(dict(**source_options(), logger=_QuietLogger()))
        self.probes = {}
        for value in cookies:
            if value["domain"].lstrip(".") not in ("tiktok.com", "www.tiktok.com"):
                continue
            self.downloader.cookiejar.set_cookie(Cookie(0, value["name"], value["value"], None, False,
                value["domain"], True, value["domain"].startswith("."), value["path"], True,
                value.get("secure", False), int(value["expires"]) if value.get("expires", -1) > 0 else None,
                True, None, None, {"HttpOnly": value.get("httpOnly", False)}, False))

    def __enter__(self):
        try:
            parsed = urlparse(self.item.source_url)
            if (parsed.scheme != "https" or parsed.hostname not in ("www.tiktok.com", "tiktok.com")
                    or not parsed.path.endswith("/video/" + self.item.id)):
                raise ValueError("Use this post's original TikTok video link")
            self.info = self.downloader.extract_info(self.item.source_url, download=False)
            if str(self.info.get("id")) != self.item.id:
                raise ValueError("TikTok supplied metadata for a different post")
            return self
        except Exception as error:
            self.downloader.close()
            raise ValueError("TikTok could not verify this post's source streams") from error

    def __exit__(self, *args):
        self.downloader.close()

    def probe(self, fmt):
        headers = dict(self.info.get("http_headers", {}))
        headers.update(fmt.get("http_headers", {}))
        with probe_source(self.downloader, fmt["url"], headers) as local:
            details = self.tools.probe(local)
            self.probes[source_identity(fmt)] = details
            return details

    def fetch(self, fmt, target):
        from yt_dlp import YoutubeDL
        from .media import _QuietLogger
        target = Path(target)
        receipt = target.with_suffix(".source.json")
        identity = source_identity(fmt)
        if target.is_file() and receipt.is_file():
            cached = json.loads(receipt.read_text(encoding="utf-8"))
            if (cached.get("source") == identity and cached.get("postID") == self.item.id
                    and target.stat().st_size == cached.get("byteSize") and digest(target) == cached.get("sha256")
                    and self._matches_probe(identity, self.tools.probe(target))):
                return target
        # Only working stream files use these format-specific paths. A completed
        # file without its verified receipt must not trigger yt-dlp's skip logic.
        if target.exists(): target.unlink()
        def hook(status):
            if self.cancelled(): raise InterruptedError("Source-quality download paused; completed files are retained")
            if status["status"] == "downloading":
                self.progress(f"Video {self.item.id}: {status.get('downloaded_bytes', 0) / 1048576:.1f} MiB downloaded")
        options = dict(**source_options(), outtmpl=str(target), logger=_QuietLogger(),
                       continuedl=True, progress_hooks=[hook], ffmpeg_location=shutil.which(self.tools.ffmpeg))
        with YoutubeDL(options) as writer:
            for cookie in self.downloader.cookiejar:
                writer.cookiejar.set_cookie(cookie)
            writer.process_ie_result(dict(id=self.item.id, title=self.item.title, extractor="tiktok", extractor_key="TikTok",
                webpage_url=self.item.source_url, http_headers=self.info.get("http_headers", {}), formats=[dict(fmt)]), download=True)
        if not target.is_file() or target.stat().st_size <= 0:
            raise ValueError("TikTok did not provide a completed source stream")
        if fmt.get("filesize") and target.stat().st_size != fmt["filesize"]:
            raise ValueError("The downloaded source length changed during verification")
        actual = self.tools.probe(target)
        if not self._matches_probe(identity, actual):
            raise ValueError("Downloaded stream differs from the verified rendition")
        atomic_json(receipt, dict(source=identity, postID=self.item.id, byteSize=target.stat().st_size, sha256=digest(target)))
        return target

    def _matches_probe(self, identity, actual):
        expected = self.probes.get(identity)
        return not expected or not (any(actual.get(key) != expected.get(key) for key in ("width", "height", "video_codec", "audio_codec"))
            or abs(actual["duration"] - expected["duration"]) > .12
            or expected.get("audio_bitrate", 0) and abs(actual.get("audio_bitrate", 0) / expected["audio_bitrate"] - 1) > .05)


class QualityDownloader:
    def __init__(self, tools, progress=lambda message: None, cancelled=lambda: False, *, provider=TikTokSource, guard=lambda: None):
        self.tools, self.progress, self.cancelled, self.provider = tools, progress, cancelled, provider
        self.guard = guard

    def _check(self):
        self.guard()
        if self.cancelled(): raise InterruptedError("Source-quality work paused; verified progress is retained")

    def _cancelled(self):
        self._check()
        return False

    def _assembly_check(self, *sources):
        self._check()
        required = sum(path.stat().st_size for path in set(sources))
        if shutil.disk_usage(sources[0].parent).free < 2 * 1073741824 + required:
            raise InterruptedError("Paused: insufficient storage for a verified quality copy plus a 2 GiB reserve")

    def acquire(self, item, directory, cookies=()):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        output, record = directory / "original.mp4", directory / "quality.json"
        self._check()
        if record.is_file():
            proof = json.loads(record.read_text(encoding="utf-8"))
            if (proof.get("version") == QUALITY_VERSION and proof.get("postID") == item.id
                    and output.is_file() and output.stat().st_size == proof.get("byteSize")
                    and digest(output) == proof.get("sha256")):
                return output
            raise ValueError("Source-quality checkpoint changed or failed verification")
        with self.provider(item, cookies, self.tools, self.progress, self._cancelled) as source:
            groups = {}
            for fmt in source.info.get("formats", []):
                if (fmt.get("vcodec") == "none" or fmt.get("preference", 0) is not None and fmt.get("preference", 0) <= -100
                        or "UNPLAYABLE" in (fmt.get("format_note") or "")):
                    continue
                key = re.sub(r"-\d+$", "", fmt["format_id"])
                groups.setdefault(key, []).append(fmt)
            renditions = []
            for group in groups.values():
                self._check()
                for fmt in reversed(group):
                    try:
                        details = source.probe(fmt)
                        renditions.append(Rendition(fmt, details))
                        break
                    except InterruptedError:
                        raise
                    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError):
                        continue
            picture = choose_video(renditions)
            video_path = source.fetch(picture.format, directory / ("picture-" + source_identity(picture.format)[:24] + ".mp4"))
            self._check()
            selected, assembly = None, None
            candidates = audio_candidates(renditions, picture)
            for audio in candidates:
                self._check()
                try:
                    audio_path = video_path if audio is picture else source.fetch(audio.format, directory / ("audio-" + source_identity(audio.format)[:24] + ".mp4"))
                    self._assembly_check(video_path, audio_path)
                    assembly = combine_tracks(video_path, audio_path, output, self.tools, check=self._check)
                    selected = audio
                    break
                except ValueError:
                    continue
            if assembly is None:
                if candidates:
                    raise ValueError("No post audio could be verified against the selected picture")
                self._assembly_check(video_path)
                assembly = combine_tracks(video_path, None, output, self.tools, check=self._check)
            self._check()
            def describe(rendition):
                if rendition is None: return None
                return dict(formatID=rendition.format["format_id"], **{key: rendition.details.get(key) for key in
                    ("width", "height", "fps", "duration", "video_codec", "video_bitrate", "audio_codec", "audio_bitrate",
                     "audio_sample_rate", "audio_channels")})
            proof = dict(version=QUALITY_VERSION, postID=item.id, video=describe(picture), audio=describe(selected),
                         sha256=digest(output), byteSize=output.stat().st_size, **assembly)
            atomic_json(record, proof, check=self._check)
            self.progress(f"Source quality {item.id}: {picture.details['width']}x{picture.details['height']}; " +
                (f"{selected.details.get('audio_bitrate', 0) / 1000:.0f} kbps post audio" if selected else "source has no embedded audio"))
            return output
