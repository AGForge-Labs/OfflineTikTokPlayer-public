from dataclasses import dataclass
import json
import math
from fractions import Fraction
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import zipfile


class MediaTools:
    def __init__(self, ffmpeg="ffmpeg", ffprobe="ffprobe"):
        self.ffmpeg, self.ffprobe = ffmpeg, ffprobe

    def _run(self, args):
        args = list(args)
        remote = any(str(value).startswith(("https://", "http://127.0.0.1:")) for value in args)
        if remote:
            args[1:1] = ["-rw_timeout", "10000000"]
        result = subprocess.run(args, capture_output=True, timeout=45 if remote else None,
                                creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        if result.returncode:
            raise RuntimeError(result.stderr.decode("utf-8", "replace")[-1800:])
        return result.stdout

    def probe(self, path):
        info = json.loads(self._run([self.ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)]))
        video = next((s for s in info["streams"] if s["codec_type"] == "video"), {})
        audio = next((s for s in info["streams"] if s["codec_type"] == "audio"), {})
        duration = float(info.get("format", {}).get("duration", 0))
        if not math.isfinite(duration) or duration <= 0:
            raise ValueError("Media has no valid duration")
        return dict(duration=duration, width=video.get("width", 0), height=video.get("height", 0),
                    video_codec=video.get("codec_name"), audio_codec=audio.get("codec_name"),
                    pixel_format=video.get("pix_fmt"), codec_tag=video.get("codec_tag_string"),
                    color_space=video.get("color_space"), color_transfer=video.get("color_transfer"),
                    color_primaries=video.get("color_primaries"),
                    fps=float(Fraction(video.get("avg_frame_rate") or "0/1")) if video.get("avg_frame_rate") not in (None, "0/0") else 0,
                    video_bitrate=int(video.get("bit_rate") or 0), audio_bitrate=int(audio.get("bit_rate") or 0),
                    audio_sample_rate=int(audio.get("sample_rate") or 0), audio_channels=int(audio.get("channels") or 0),
                    audio_start=float(audio.get("start_time") or 0))

    def compatible(self, original):
        original = Path(original)
        info = self.probe(original)
        native_video = info["video_codec"] in ("h264", "hevc") and info["pixel_format"] in ("yuv420p", "yuv420p10le")
        # iOS ignores FFmpeg's MP3-in-MP4 audio track (the native decoder test
        # reproduces this even though FFprobe and desktop players see audio).
        native_audio = info["audio_codec"] in (None, "aac", "alac")
        needs_hevc_tag = info["video_codec"] == "hevc" and info["codec_tag"] != "hvc1"
        if native_video and native_audio and original.suffix.lower() in (".mp4", ".mov", ".m4v") and not needs_hevc_tag:
            return original
        output = original.with_name(original.stem + ".iphone.mp4")
        args = [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(original), "-map", "0:v:0", "-map", "0:a:0?"]
        if native_video:
            args += ["-c:v", "copy"]
        else:
            args += ["-c:v", "libx264", "-crf", "16", "-preset", "medium", "-pix_fmt", "yuv420p"]
        args += ["-c:a", "copy" if native_audio else "alac"]
        if info["video_codec"] == "hevc" and native_video:
            args += ["-tag:v", "hvc1"]
        args += ["-movflags", "+faststart", str(output)]
        self._run(args)
        self.probe(output)
        return output

    def slideshow(self, images, audio, output):
        from PIL import Image, ImageOps
        images = [Path(image) for image in images]
        if not images:
            raise ValueError("Photo post contains no images")
        output = Path(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        frames = output.parent / "render-frames"
        frames.mkdir(exist_ok=True)
        dimensions = []
        for source in images:
            with Image.open(source) as image:
                dimensions.append(ImageOps.exif_transpose(image).size)
        width = max(w for w, h in dimensions)
        height = max(h for w, h in dimensions)
        width += width % 2
        height += height % 2
        duration = self.probe(audio)["duration"] if audio else 5.0 * len(images)
        interval = duration / len(images)
        entries = ["ffconcat version 1.0"]
        for index, source in enumerate(images):
            frame = frames / f"{index:06}.png"
            with Image.open(source) as image:
                image = ImageOps.exif_transpose(image).convert("RGB")
                ImageOps.pad(image, (width, height), color="black", method=Image.Resampling.LANCZOS).save(frame)
            # Relative filenames avoid quoting arbitrary user paths inside concat syntax.
            entries += [f"file 'render-frames/{frame.name}'", f"duration {interval:.9f}"]
        entries.append(f"file 'render-frames/{len(images)-1:06}.png'")
        listing = output.parent / "frames.ffconcat"
        listing.write_text("\n".join(entries) + "\n", encoding="utf-8")
        args = [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "1", "-i", str(listing)]
        if audio:
            args += ["-i", str(audio), "-map", "0:v:0", "-map", "1:a:0", "-c:a",
                     "copy" if self.probe(audio)["audio_codec"] in ("aac", "alac") else "alac"]
        args += ["-t", f"{duration:.9f}", "-vf", "fps=30", "-c:v", "libx264", "-crf", "16", "-preset", "medium",
                 "-pix_fmt", "yuv420p", "-movflags", "+faststart", str(output)]
        self._run(args)
        self.probe(output)
        return output

    def thumbnail(self, video, output):
        output = Path(output)
        args = [self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(video), "-frames:v", "1",
                "-vf", "scale=320:-2", str(output)]
        try:
            self._run(args)
        except RuntimeError as error:
            if "Invalid color space" not in str(error):
                raise
            info = self.probe(video)
            codec = info["video_codec"]
            if codec not in ("h264", "hevc"):
                raise
            # FFmpeg rejects reserved VUI tags before filters can repair them.
            # Remux one frame for artwork only; retain the original bitstream.
            repair = []
            for name, field in (("matrix_coefficients", "color_space"), ("colour_primaries", "color_primaries"),
                                ("transfer_characteristics", "color_transfer")):
                if info.get(field) in (None, "unknown", "reserved"):
                    repair.append(name + "=1")  # BT.709 fallback for invalid tags.
            if not repair:
                raise
            with tempfile.TemporaryDirectory(prefix="offline-tiktok-artwork-") as directory:
                frame = Path(directory) / "frame.mkv"
                self._run([self.ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(video),
                           "-map", "0:v:0", "-c:v", "copy", "-frames:v", "1", "-bsf:v",
                           codec + "_metadata=" + ":".join(repair), str(frame)])
                args[args.index("-i") + 1] = str(frame)
                self._run(args)
        return output


@dataclass
class Acquisition:
    original: Path
    playback: Path
    artwork: Path
    duration: float


class _QuietLogger:
    def debug(self, message):
        pass

    def warning(self, message):
        pass

    def error(self, message):
        pass


class MediaDownloader:
    def __init__(self, root, progress=lambda message: None, cancelled=lambda: False, tools=None):
        self.root = Path(root)
        self.progress, self.cancelled = progress, cancelled
        self.tools = tools or MediaTools()
        self._last_space_check = 0

    def _check(self):
        if self.cancelled():
            raise InterruptedError("Paused; completed files are retained.")
        if time.monotonic() - self._last_space_check > 1:
            self._last_space_check = time.monotonic()
            existing = next(path for path in (self.root, *self.root.parents) if path.exists())
            if shutil.disk_usage(existing).free < 2 * 1073741824:
                raise InterruptedError("Paused for local storage: less than 2 GiB remains. Completed media and playlist membership are retained.")

    def acquire(self, item, cookies=()):
        if not re.fullmatch(r"\d+", item.id):
            raise ValueError("Invalid TikTok post identity")
        self._check()
        directory = self.root / item.id
        directory.mkdir(parents=True, exist_ok=True)
        if item.kind == "slideshow":
            original, playback = self._photo(item, directory, cookies)
        else:
            original = self._video(item, directory, cookies)
            playback = self.tools.compatible(original)
        artwork = self.tools.thumbnail(playback, directory / "artwork.jpg")
        details = self.tools.probe(playback)
        return Acquisition(original, playback, artwork, details["duration"])

    def _video(self, item, directory, cookies):
        from .quality_download import QualityDownloader
        return QualityDownloader(self.tools, self.progress, self.cancelled, guard=self._check).acquire(
            item, Path(directory) / "source-quality-v1", cookies)

    def _photo(self, item, directory, cookies):
        import gallery_dl.config
        from gallery_dl.job import DataJob
        import httpx
        gallery_dl.config.set(("extractor", "tiktok"), "cookies", {c["name"]: c["value"] for c in cookies if c["domain"].lstrip(".") in ("tiktok.com", "www.tiktok.com")})
        job = DataJob(item.source_url, file=None)
        job.run()
        if job.exception:
            raise RuntimeError("TikTok could not expose the photo post; check sign-in and retry") from job.exception
        images, audio = [], None
        source_dir = directory / "source"
        source_dir.mkdir(exist_ok=True)
        with httpx.Client(follow_redirects=True, timeout=60) as client:
            for url, metadata in zip(job.data_urls, job.data_meta):
                self._check()
                kind = metadata.get("type")
                if kind not in ("image", "audio"):
                    continue
                extension = metadata.get("extension", "jpg" if kind == "image" else "mp3")
                if not re.fullmatch(r"[a-zA-Z0-9]{1,8}", extension):
                    raise ValueError("Unsupported photo asset extension")
                target = source_dir / (f"image-{len(images):06}.{extension}" if kind == "image" else f"audio.{extension}")
                partial = target.with_suffix(target.suffix + ".part")
                with client.stream("GET", url, headers={"Referer": "https://www.tiktok.com/"}) as response:
                    response.raise_for_status()
                    with partial.open("wb") as output:
                        for chunk in response.iter_bytes():
                            self._check()
                            output.write(chunk)
                partial.replace(target)
                if kind == "image":
                    images.append(target)
                else:
                    audio = target
        playback = self.tools.slideshow(images, audio, directory / "slideshow.mp4")
        original = directory / "original-photo.zip"
        with zipfile.ZipFile(original, "w", compression=zipfile.ZIP_STORED) as archive:
            for path in images + ([audio] if audio else []):
                archive.write(path, arcname=path.name)
        return original, playback
