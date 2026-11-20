"""Render TikTok Photo Mode's automatic carousel from its ordered original stills."""
from pathlib import Path
import json
import re
import shutil
from tempfile import TemporaryDirectory
import zipfile


# TikTok's public post player (webapp-desktop/static/js/async/2356.da90e581.js)
# sets Swiper delay=2500, speed=800, loop=true. Its autoplay waits for the
# transition to finish before starting the next delay. Music loops independently.
PHOTO_RENDER = "slideshow.tiktok-v1.mp4"
NATIVE_MEMBER = "native-video.mp4"
FPS = 30
HOLD_FRAMES = 75
SWIPE_FRAMES = 24
STEP_FRAMES = HOLD_FRAMES + SWIPE_FRAMES


def archive_images(archive):
    """Read only the flat, numbered media layout written by the photo importer."""
    images, audio, native = {}, None, None
    for member in archive.infolist():
        name = member.filename
        match = re.fullmatch(r"image-(\d{6})\.[a-zA-Z0-9]{1,8}", name)
        if match and int(match[1]) not in images:
            images[int(match[1])] = member
        elif re.fullmatch(r"audio\.[a-zA-Z0-9]{1,8}", name) and audio is None:
            audio = member
        elif name == NATIVE_MEMBER and native is None:
            native = member
        else:
            raise ValueError("Photo archive has unexpected or duplicate media")
        if not member.file_size:
            raise ValueError("Photo archive contains an empty original")
    if not images or sorted(images) != list(range(len(images))):
        raise ValueError("Photo archive has incomplete image order")
    return [images[i] for i in range(len(images))], audio


def render_archive(tools, original, output, *, scratch_dir=None):
    output = Path(output)
    with zipfile.ZipFile(original) as archive:
        images, audio = archive_images(archive)
        native = NATIVE_MEMBER in archive.namelist()
        output.parent.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=scratch_dir or output.parent, prefix="photo-") as directory:
            def unpack(member):
                path = Path(directory) / member.filename
                with archive.open(member) as source, path.open("wb") as destination:
                    shutil.copyfileobj(source, destination)
                return path
            if native:
                result = tools.compatible(unpack(archive.getinfo(NATIVE_MEMBER)))
                info = tools.probe(result)
                if not info["video_codec"]:
                    raise ValueError("Archived native photo rendition contains no picture")
                if audio and not info["audio_codec"]:
                    track = unpack(audio)
                    muxed = Path(directory) / "play.mp4"
                    tools._run([tools.ffmpeg, "-v", "error", "-y", "-i", str(result),
                                *_soundtrack_options(track, tools.probe(track), info["duration"]),
                                "-c:v", "copy", "-t", str(info["duration"]), "-movflags", "+faststart", str(muxed)])
                    checked = tools.probe(muxed)
                    if not checked["audio_codec"] or abs(checked["duration"] - info["duration"]) > .12:
                        raise ValueError("Could not retain the native photo rendition and soundtrack")
                    result = muxed
            else:
                result = tools.slideshow([unpack(m) for m in images], unpack(audio) if audio else None,
                                         Path(directory) / "play.mp4")
            result.replace(output)
            return output


def cached_photo(tools, original):
    from .cost_audit import atomic_json
    from .store import checksum
    output = Path(original).with_name(PHOTO_RENDER)
    receipt = output.with_suffix(".json")
    original_digest = checksum(original)
    if output.is_file() and receipt.is_file():
        try:
            proof = json.loads(receipt.read_text(encoding="utf8"))
            if proof == {"originalSHA256": original_digest, "playbackSHA256": checksum(output)}:
                return output
        except (ValueError, OSError):
            pass
    render_archive(tools, original, output)
    atomic_json(receipt, {"originalSHA256": original_digest, "playbackSHA256": checksum(output)})
    return output


def _swipe_offset(width):
    """FFmpeg crop offsets for CSS 'ease' (cubic-bezier(.25,.1,.25,1))."""
    positions = []
    for frame in range(1, SWIPE_FRAMES):
        elapsed = frame / SWIPE_FRAMES
        low, high = 0., 1.
        for _ in range(16):
            t = (low + high) / 2
            if t * (.75 + t * (-.75 + t)) < elapsed:
                low = t
            else:
                high = t
        progress = t * (.3 + t * (2.4 - 1.7 * t))
        positions.append(f"{round(progress * width)}*eq(mod(n,{STEP_FRAMES}),{HOLD_FRAMES + frame})")
    return "+".join(positions)


def _soundtrack_options(audio, details, duration):
    args = ["-i", str(audio), "-map", "0:v:0", "-map", "1:a:0"]
    if details["duration"] < duration:
        # Loop decoded samples including the original codec's gapless trim,
        # then encode losslessly for iPhone playback.
        return args + ["-af", "aloop=loop=-1:size=2147483647", "-c:a", "alac"]
    return args + ["-c:a", "copy" if details["audio_codec"] in ("aac", "alac") else "alac"]


def render_carousel(tools, images, audio, output):
    from PIL import Image, ImageOps
    if not images:
        raise ValueError("Photo post contains no images")
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    soundtrack = tools.probe(audio) if audio else {}
    music_length = soundtrack.get("duration", 0)
    count = len(images)
    cycle_frames = count * STEP_FRAMES
    duration = max(music_length, cycle_frames / FPS) if count > 1 else (music_length or 5.)
    with TemporaryDirectory(dir=output.parent, prefix="photo-render-") as directory:
        scratch = Path(directory)
        sizes = []
        for source in images:
            with Image.open(source) as image:
                sizes.append(ImageOps.exif_transpose(image).size)
        width, height = (max(axis) for axis in zip(*sizes))
        size = (width + width % 2, height + height % 2)
        for index, source in enumerate(images):
            with Image.open(source) as image:
                still = ImageOps.exif_transpose(image).convert("RGB")
                ImageOps.pad(still, size, method=Image.Resampling.LANCZOS, color="black").save(scratch / f"{index:06}.png")
        command = [tools.ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
        encode = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "16", "-preset", "veryfast",
                  "-threads", "3", "-bf", "0", "-movflags", "+faststart"]
        result = scratch / "result.mp4"
        if count > 1:
            # Two offset views of the same image sequence supply the outgoing
            # and incoming stills. Render one cycle even for a long soundtrack.
            shutil.copyfile(scratch / "000000.png", scratch / f"{count:06}.png")
            sequence = str(scratch / "%06d.png")
            rate = f"{FPS}/{STEP_FRAMES}"
            crop = f"hstack,crop=w=iw/2:h=ih:x='{_swipe_offset(size[0])}':y=0"
            cycle = scratch / "cycle.mp4" if audio else result
            tools._run(command + ["-framerate", rate, "-start_number", "0", "-i", sequence,
                                  "-framerate", rate, "-start_number", "1", "-i", sequence,
                                  "-filter_complex_threads", "2", "-filter_complex",
                                  f"[0:v]fps={FPS},format=yuv420p[a];[1:v]fps={FPS},format=yuv420p[b];[a][b]{crop}",
                                  "-frames:v", str(cycle_frames), *encode, str(cycle)])
            picture = ["-stream_loop", "-1", "-i", str(cycle)]
            video_options = ["-c:v", "copy", "-movflags", "+faststart"]
        else:
            picture = ["-loop", "1", "-framerate", str(FPS), "-i", str(scratch / "000000.png")]
            video_options = encode
        if audio or count == 1:
            audio_options = _soundtrack_options(audio, soundtrack, duration) if audio else []
            tools._run(command + picture + audio_options + ["-t", f"{duration:.9f}", *video_options, str(result)])
        details = tools.probe(result)
        if (not details["video_codec"] or bool(details["audio_codec"]) != bool(audio)
                or abs(details["duration"] - duration) > .12):
            raise ValueError("Photo rendition has incomplete picture or sound")
        result.replace(output)
    return output
