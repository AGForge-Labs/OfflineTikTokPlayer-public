import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import uuid

import pytest


def test_xcode_project_identities_match_across_windows_and_posix(monkeypatch):
    path = Path(__file__).resolve().parents[2] / "scripts" / "generate-ios-project.py"
    spec = importlib.util.spec_from_file_location("native_project", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = module.generate()
    identity = module.identity
    monkeypatch.setattr(module, "identity", lambda text: identity(text.replace("\\", "/")))
    assert module.generate() == original, "The checked-in project must be identical when generated on Windows or macOS"


def test_debug_app_and_test_targets_match_the_active_swift_package_architecture(monkeypatch):
    path = Path(__file__).resolve().parents[2] / "scripts" / "generate-ios-project.py"
    spec = importlib.util.spec_from_file_location("native_architecture_project", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    captured = {}
    encode = module.encode
    def capture(value, depth=0):
        if isinstance(value, dict) and "objects" in value:
            captured.update(value["objects"])
        return encode(value, depth)
    monkeypatch.setattr(module, "encode", capture)
    module.generate()
    for name in ("project", module.APP, module.APP + "Tests", module.APP + "UITests"):
        debug = captured[module.identity("config:" + name + "Debug")]["buildSettings"]
        release = captured[module.identity("config:" + name + "Release")]["buildSettings"]
        assert debug.get("ONLY_ACTIVE_ARCH") == "YES", "Debug must match the package's single active simulator architecture"
        assert release.get("ONLY_ACTIVE_ARCH") == "NO", "Release archives must retain their normal supported architectures"


def _capture_helper():
    path = Path(__file__).resolve().parents[2] / "scripts" / "capture-simulator-test-frames.py"
    spec = importlib.util.spec_from_file_location("native_worker_capture", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _worker_fixture(tmp_path, monkeypatch):
    module = _capture_helper()
    udid = "11111111-1111-4111-8111-111111111111"
    device = tmp_path / "Devices" / udid
    temporary = device / "data" / "Containers" / "Data" / "Application" / str(uuid.uuid4()) / "tmp"
    temporary.mkdir(parents=True)
    executable = (device / "data" / "Containers" / "Bundle" / "Application" / str(uuid.uuid4())
                  / "OfflineTikTokPlayer.app" / "OfflineTikTokPlayer")
    executable.parent.mkdir(parents=True)
    executable.write_text("synthetic executable identity only", encoding="utf-8")
    monkeypatch.setattr(module, "DEADLINE", module.time.monotonic() + 60)
    watcher = module.WorkerTraceWatcher(udid, temporary.resolve(), threading.Event())
    return module, watcher, temporary.resolve(), executable.resolve()


WORKER_ID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
OTHER_WORKER_ID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"


def _worker_request(module, temporary, purpose=0, changes=None):
    identifier = str(uuid.uuid4())
    payload = {"schemaVersion": 2, "requestID": identifier, "processID": 4321,
               "purposeCode": purpose, "workerID": WORKER_ID}
    payload.update(changes or {})
    request = temporary / f"{module.WORKER_PREFIX}{identifier}.request.json"
    request.write_text(json.dumps(payload), encoding="utf-8")
    return request, identifier


WORKER_SAMPLE = f"""Sampling process 4321; PRIVATE_REPORT_HEADER
Call graph:
    100 Thread_123 DispatchQueue_1: com.apple.main-thread (serial)
    + 100 PRIVATE_OTHER_THREAD
    100 Thread_455 DispatchQueue_6: OfflineTikTokPlayer.PCMDecode.{OTHER_WORKER_ID} (serial)
    + 100 PRIVATE_WRONG_DECODER
    100 Thread_456 DispatchQueue_7: OfflineTikTokPlayer.PCMDecode.{WORKER_ID} (serial)
    + 100 synthetic_worker_frame (in SyntheticFramework)
    + ! 100 synthetic_reader_wait (in SyntheticFramework)
    100 Thread_789 DispatchQueue_8: PRIVATE_ANOTHER_QUEUE (serial)
    + 100 PRIVATE_OTHER_FRAME
Binary Images:
PRIVATE_BINARY_PATH
"""


def _mock_worker_commands(monkeypatch, watcher, executable, report=WORKER_SAMPLE, failure=None, application=None):
    calls = []

    def command(arguments, timeout):
        calls.append((arguments, timeout))
        if arguments[0] == "/bin/ps":
            assert arguments == ["/bin/ps", "-ww", "-p", "4321", "-o", "comm="]
            return subprocess.CompletedProcess(arguments, 0, str(executable) + "\n", "PRIVATE_STDERR")
        if arguments[0] == "/usr/bin/xcrun":
            assert arguments == ["/usr/bin/xcrun", "simctl", "get_app_container", watcher.udid,
                                 "dev.galaxybigbird.OfflineTikTokPlayer", "app"]
            assert timeout == 1
            return subprocess.CompletedProcess(arguments, 0, str(application or executable.parent) + "\n", "PRIVATE_STDERR")
        assert arguments[:4] == ["/usr/bin/sample", "4321", "1", "-file"]
        assert timeout <= 4
        if failure is not None:
            raise failure
        Path(arguments[4]).write_text(report, encoding="utf-8")
        return subprocess.CompletedProcess(arguments, 0, "PRIVATE_STDOUT", "PRIVATE_STDERR")

    monkeypatch.setattr(watcher, "_command", command)
    return calls


def test_worker_trace_profiles_only_owned_pid_and_emits_only_worker_stack(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    calls = _mock_worker_commands(monkeypatch, watcher, executable)
    request, identifier = _worker_request(module, temporary)
    watcher.poll_once()
    output = capsys.readouterr().out
    assert len(calls) == 3
    assert f"requestID={identifier} purposeCode=0 workerID={WORKER_ID} statusCode=0" in output
    assert "decoderQueueCount=2" in output
    assert "OfflineTikTokPlayer.PCMDecode" in output and "synthetic_reader_wait" in output
    assert "PRIVATE_" not in output
    assert "startUptime=" in output and "elapsedSeconds=" in output
    assert not request.exists()
    assert not list(temporary.glob(module.WORKER_PREFIX + "*.sample.txt"))


@pytest.mark.parametrize("changes", [
    {"extra": 1}, {"schemaVersion": True}, {"schemaVersion": 1},
    {"requestID": "22222222-2222-4222-8222-222222222222"},
    {"processID": True}, {"processID": 0}, {"processID": -1}, {"processID": "4321"},
    {"purposeCode": True}, {"purposeCode": 2}, {"purposeCode": None},
    {"workerID": True}, {"workerID": None}, {"workerID": "invalid"},
    {"workerID": WORKER_ID.upper()}, {"workerID": WORKER_ID.replace("-", "")},
])
def test_worker_trace_rejects_invalid_schema_without_native_commands(tmp_path, monkeypatch, capsys, changes):
    module, watcher, temporary, _ = _worker_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(watcher, "_command", lambda *args, **kwargs: pytest.fail("Invalid requests cannot inspect a PID"))
    request, identifier = _worker_request(module, temporary, changes=changes)
    watcher.process_request(request, identifier)
    assert "statusCode=1" in capsys.readouterr().out
    assert watcher.profile_count == 0 and not request.exists()


@pytest.mark.parametrize("kind", ["missing", "duplicate", "oversized", "symlink"])
def test_worker_trace_rejects_bad_request_files(tmp_path, monkeypatch, capsys, kind):
    module, watcher, temporary, _ = _worker_fixture(tmp_path, monkeypatch)
    request, identifier = _worker_request(module, temporary)
    if kind == "missing":
        payload = json.loads(request.read_text(encoding="utf-8"))
        del payload["processID"]
        request.write_text(json.dumps(payload), encoding="utf-8")
    elif kind == "duplicate":
        request.write_text('{"schemaVersion":2,"schemaVersion":2,"requestID":"' + identifier
                           + '","processID":4321,"purposeCode":0,"workerID":"' + WORKER_ID + '"}', encoding="utf-8")
    elif kind == "oversized":
        request.write_text(" " * 4097, encoding="utf-8")
    else:
        original = Path.is_symlink
        monkeypatch.setattr(Path, "is_symlink", lambda path: path == request or original(path))
    monkeypatch.setattr(watcher, "_command", lambda *args, **kwargs: pytest.fail("Invalid files cannot invoke native tools"))
    watcher.process_request(request, identifier)
    assert "statusCode=1" in capsys.readouterr().out
    assert watcher.profile_count == 0
    if kind == "symlink":
        assert request.exists(), "Rejected symlinks are never removed as owned files"
    else:
        assert not request.exists()


@pytest.mark.parametrize("kind", ["relative", "other_device", "other_app", "symlink", "ancestor_symlink"])
def test_worker_trace_rejects_pid_with_wrong_executable_identity(tmp_path, monkeypatch, capsys, kind):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    reported = executable
    if kind == "relative":
        reported = Path("OfflineTikTokPlayer.app") / "OfflineTikTokPlayer"
    elif kind == "other_device":
        reported = Path(str(executable).replace(watcher.udid, "22222222-2222-4222-8222-222222222222"))
    elif kind == "other_app":
        reported = executable.parent.parent / "Another.app" / "OfflineTikTokPlayer"
    elif kind == "symlink":
        original = Path.is_symlink
        monkeypatch.setattr(Path, "is_symlink", lambda path: path == executable or original(path))
    else:
        original = Path.resolve
        monkeypatch.setattr(Path, "resolve", lambda path, *args, **kwargs:
                            path.parent / "redirected" if path == executable else original(path, *args, **kwargs))
    calls = _mock_worker_commands(monkeypatch, watcher, reported)
    request, identifier = _worker_request(module, temporary)
    watcher.process_request(request, identifier)
    assert len(calls) == 1 and watcher.profile_count == 0
    assert "statusCode=2" in capsys.readouterr().out


def test_worker_trace_profiles_at_most_once_per_purpose_and_twice_total(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    calls = _mock_worker_commands(monkeypatch, watcher, executable)
    for purpose in [0, 0, 1, 1]:
        request, identifier = _worker_request(module, temporary, purpose=purpose)
        watcher.process_request(request, identifier)
    assert len([call for call in calls if call[0][0] == "/usr/bin/sample"]) == 2
    assert len([call for call in calls if call[0][0] == "/usr/bin/xcrun"]) == 1
    assert watcher.profile_count == 2 and watcher.purposes == {0, 1}
    assert capsys.readouterr().out.count("statusCode=3") == 2


def test_worker_trace_rejects_same_app_name_in_another_bundle_container(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    imposter = (executable.parents[2] / str(uuid.uuid4())
                / "OfflineTikTokPlayer.app" / "OfflineTikTokPlayer")
    imposter.parent.mkdir(parents=True)
    imposter.write_text("same name, different installed bundle identity", encoding="utf-8")
    calls = _mock_worker_commands(monkeypatch, watcher, imposter, application=executable.parent)
    request, identifier = _worker_request(module, temporary)
    watcher.process_request(request, identifier)
    assert [call[0][0] for call in calls] == ["/bin/ps", "/usr/bin/xcrun"]
    assert watcher.application == executable.parent
    assert watcher.profile_count == 0 and not request.exists()
    assert "statusCode=2" in capsys.readouterr().out


def test_worker_trace_limits_request_processing_and_seen_ids_to_32(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, _ = _worker_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(watcher, "_command", lambda *args, **kwargs: pytest.fail("Invalid payloads must not invoke native tools"))
    for _ in range(40):
        request, identifier = _worker_request(module, temporary, changes={"extra": 1})
        watcher.process_request(request, identifier)
        watcher.process_request(request, identifier)
    assert watcher.processed == len(watcher.seen) == 32
    assert capsys.readouterr().out.count("NativeWorkerTraceResult") == 32


@pytest.mark.parametrize("failure,status", [(FileNotFoundError(), 6), (PermissionError(), 7),
                                           (subprocess.TimeoutExpired("sample", 4), 11)])
def test_worker_trace_reports_unavailable_protected_and_timed_out_sampling(tmp_path, monkeypatch, capsys, failure, status):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    _mock_worker_commands(monkeypatch, watcher, executable, failure=failure)
    request, identifier = _worker_request(module, temporary)
    watcher.process_request(request, identifier)
    assert f"statusCode={status}" in capsys.readouterr().out
    assert watcher.profile_count == 1 and watcher.purposes == {0}
    assert not request.exists() and not list(temporary.glob("*.sample.txt"))


def test_worker_trace_rejects_oversized_report_and_keeps_existing_files(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(module, "WORKER_REPORT_LIMIT", 32)
    _mock_worker_commands(monkeypatch, watcher, executable, report="x" * 33)
    request, identifier = _worker_request(module, temporary)
    watcher.process_request(request, identifier)
    assert "statusCode=9" in capsys.readouterr().out
    assert not list(temporary.glob("*.sample.txt"))
    request, identifier = _worker_request(module, temporary, purpose=1)
    existing = temporary / f"{module.WORKER_PREFIX}{identifier}.sample.txt"
    existing.write_text("preserve existing file", encoding="utf-8")
    watcher.process_request(request, identifier)
    assert "statusCode=9" in capsys.readouterr().out
    assert existing.read_text(encoding="utf-8") == "preserve existing file"


def test_worker_trace_filter_is_bounded_and_does_not_emit_other_sections():
    module = _capture_helper()
    section, truncated, queue_count = module.worker_section(WORKER_SAMPLE, WORKER_ID)
    assert "synthetic_worker_frame" in section and "PRIVATE_" not in section
    assert not truncated and queue_count == 2
    report = f"Call graph:\n    1 Thread_1 DispatchQueue_1: OfflineTikTokPlayer.PCMDecode.{WORKER_ID} (serial)\n" + "    + 1 " + "x" * 70_000
    section, truncated, _ = module.worker_section(report, WORKER_ID)
    assert truncated and len(section.encode("utf-8")) <= 64 * 1024
    section, _, queue_count = module.worker_section("PRIVATE_REPORT_HEADER\nCall graph:\n    1 Thread_1 DispatchQueue_1: other\n    + 1 PRIVATE_OTHER\n", WORKER_ID)
    assert queue_count == 0
    assert not section


def test_worker_trace_rejects_missing_requested_decoder_without_emitting_another(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, executable = _worker_fixture(tmp_path, monkeypatch)
    report = (f"Call graph:\n    1 Thread_1 DispatchQueue_1: OfflineTikTokPlayer.PCMDecode.{OTHER_WORKER_ID} (serial)\n"
              "    + 1 PRIVATE_WRONG_DECODER\nBinary Images:\nPRIVATE_IMAGE\n")
    _mock_worker_commands(monkeypatch, watcher, executable, report=report)
    request, identifier = _worker_request(module, temporary)
    watcher.process_request(request, identifier)
    output = capsys.readouterr().out
    assert "statusCode=10" in output and "decoderQueueCount=1" in output
    assert "PRIVATE_" not in output and OTHER_WORKER_ID not in output
    assert f"workerID={WORKER_ID}" in output


@pytest.mark.parametrize("worker_id", ["", WORKER_ID.upper(), "OfflineTikTokPlayer.PCMDecode", True])
def test_worker_trace_filter_requires_canonical_worker_uuid(worker_id):
    module = _capture_helper()
    with pytest.raises(ValueError):
        module.worker_section(WORKER_SAMPLE, worker_id)


def test_worker_trace_expired_deadline_never_invokes_native_tools(tmp_path, monkeypatch, capsys):
    module, watcher, temporary, _ = _worker_fixture(tmp_path, monkeypatch)
    request, identifier = _worker_request(module, temporary)
    monkeypatch.setattr(module, "DEADLINE", module.time.monotonic() - 1)
    monkeypatch.setattr(watcher, "_command", lambda *args, **kwargs: pytest.fail("Expired work must not invoke native tools"))
    watcher.process_request(request, identifier)
    assert "statusCode=4" in capsys.readouterr().out and watcher.profile_count == 0


def test_worker_trace_native_wait_clamps_to_remaining_deadline(tmp_path, monkeypatch):
    module, watcher, _, _ = _worker_fixture(tmp_path, monkeypatch)
    monkeypatch.setattr(module.time, "monotonic", lambda: 100.0)
    monkeypatch.setattr(module, "DEADLINE", 100.025)
    waits = []

    class Completed:
        returncode = 0
        def communicate(self, timeout):
            waits.append(timeout)
            return "synthetic output", None
        def poll(self):
            return self.returncode

    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: Completed())
    result = watcher._command(["/bin/ps", "-ww", "-p", "4321", "-o", "comm="], timeout=4)
    assert result.returncode == 0 and waits and max(waits) <= 0.025_001


def test_worker_trace_stop_interrupts_and_kills_pending_command(tmp_path, monkeypatch):
    module, watcher, _, _ = _worker_fixture(tmp_path, monkeypatch)
    killed = []

    class Pending:
        returncode = None
        def communicate(self, timeout):
            if self.returncode is not None:
                return "", None
            watcher.stop.set()
            raise subprocess.TimeoutExpired("synthetic command", timeout)
        def poll(self):
            return self.returncode
        def kill(self):
            killed.append(True)
            self.returncode = -9

    monkeypatch.setattr(module.subprocess, "Popen", lambda *args, **kwargs: Pending())
    with pytest.raises(module.WorkerTraceStopped):
        watcher._command(["/usr/bin/sample", "4321", "1", "-file", "synthetic"], timeout=4)
    assert killed == [True]


def test_worker_trace_sigterm_requests_stop_and_unwinds_main_cleanup():
    module = _capture_helper()
    stop = threading.Event()
    with pytest.raises(SystemExit) as error:
        module.trace_termination_handler(stop)(module.signal.SIGTERM, None)
    assert error.value.code == 0 and stop.is_set()
