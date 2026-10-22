#!/usr/bin/env python3
"""Bound a new owned xcodebuild session; never discover or signal Simulator/app PIDs."""
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import time

PHASES = {"build": (0, 720), "case-01": (1, 300), "case-02": (2, 300), "driver": (3, 60),
          "full-test": (4, 1800)}
MAX_SESSION_SECONDS = max(seconds for _, seconds in PHASES.values())
DRIVER_COMMAND = ("xcrun", "swiftc", "-driver-print-jobs", "-j1", "-j3", "-typecheck", "-")


def emit(event, report):
    print("OwnedXcodebuildCommand " + json.dumps(dict(schema=1, event=event, **report), sort_keys=True), flush=True)


def session(control, result, seconds, argv):
    # Caught handlers reset to defaults when the real child execs. Guardian stays
    # alive until supervisor cleanup, reserving the session leader PID/PGID even
    # if xcodebuild exits while descendants still hold the stdout/tee pipe open.
    if os.getpgid(0) != os.getpid() or os.getsid(0) != os.getpid() or not 0 < seconds <= MAX_SESSION_SECONDS: return 125
    for signum in (signal.SIGINT, signal.SIGTERM): signal.signal(signum, lambda *_: None)
    if not select.select([control], [], [], seconds + 3)[0] or os.read(control, 1) != b"G": return 125
    # Parent holds its write end until cleanup. EOF detects SIGKILL/crash; a
    # second independent deadline also bounds a parent that remains alive/hung.
    deadline = time.monotonic() + seconds + 3
    def abandon():
        own = os.getpid()
        if os.getpgid(0) == own and os.getsid(0) == own:
            os.killpg(own, signal.SIGTERM)
            time.sleep(1)
            os.killpg(own, signal.SIGKILL)
        raise SystemExit(125)
    def send(value):
        try: os.write(result, json.dumps(value).encode("ascii") + b"\n")
        except BrokenPipeError: abandon()
        os.close(result)
    sent = False
    try:
        child = subprocess.Popen(argv, close_fds=True)
    except OSError as error:
        child = None; sent = True
        send(dict(childReturnCode=None, xcodebuildPID=0, launchErrno=error.errno or -1))
    while True:
        if time.monotonic() >= deadline: abandon()
        if select.select([control], [], [], 0.1)[0]:
            # The only authorized parent payload was the initial G.
            os.read(control, 1); abandon()
        if not sent:
            code = child.poll()
            if code is not None:
                sent = True
                send(dict(childReturnCode=code, xcodebuildPID=child.pid, launchErrno=0))


def run_owned(argv, seconds, phase, cancellation=lambda: 0, grace_seconds=1, stdin=None):
    """Short budgets are internal real-child unit controls; CLI budgets are fixed."""
    report = dict(phase=phase, deadlineSeconds=seconds, pid=0, groupVerified=False,
                  launchErrno=0, timedOut=False, cancellationSignal=0, termSent=False,
                  killSent=False, leaderReaped=False, childReturnCode=None,
                  xcodebuildPID=0, outputBroken=False, controlErrno=0, cleanupErrno=0, wrapperExit=125)
    started, guardian, fds = time.monotonic(), None, []
    reply, output_broken = None, False
    try:
        if cancellation(): return dict(report, cancellationSignal=cancellation(), wrapperExit=128 + cancellation())
        control_read, control_write = os.pipe(); fds += [control_read, control_write]
        result_read, result_write = os.pipe(); fds += [result_read, result_write]
        guardian = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "--owned-session",
            str(control_read), str(result_write), str(seconds), "--"] + argv, start_new_session=True,
            close_fds=True, pass_fds=(control_read, result_write), stdin=stdin)
        report["pid"] = guardian.pid
        os.close(control_read); fds.remove(control_read)
        os.close(result_write); fds.remove(result_write)
        report["groupVerified"] = os.getpgid(guardian.pid) == guardian.pid and os.getsid(guardian.pid) == guardian.pid
        if not report["groupVerified"]: raise ValueError("New session ownership unavailable")
        if cancellation():
            report["cancellationSignal"] = cancellation()
            raise ValueError("Cancellation before owned child authorization")
        if time.monotonic() - started >= seconds:
            report["timedOut"] = True
            raise ValueError("Deadline before owned child authorization")
        os.write(control_write, b"G")
        # No wrapper stdout write occurs while the owned group is live. Native
        # stdout is inherited; final metadata is emitted only after cleanup.
        received = b""
        while reply is None:
            requested = cancellation()
            remaining = seconds - (time.monotonic() - started)
            if requested or remaining <= 0:
                report.update(cancellationSignal=requested, timedOut=not bool(requested)); break
            if not select.select([result_read], [], [], min(0.1, remaining))[0]: continue
            chunk = os.read(result_read, 512)
            if not chunk:
                requested = cancellation()
                expired = time.monotonic() - started >= seconds
                if requested or expired:
                    report.update(cancellationSignal=requested, timedOut=not bool(requested) and expired)
                    break
                raise ValueError("Owned session ended without a child result")
            received += chunk
            if len(received) > 256: raise ValueError("Owned child result exceeds bound")
            if received.endswith(b"\n"):
                reply = json.loads(received)
                if not isinstance(reply, dict) or set(reply) != {"childReturnCode", "xcodebuildPID", "launchErrno"}:
                    raise ValueError("Unexpected owned child result")
                if type(reply["launchErrno"]) is not int or type(reply["xcodebuildPID"]) is not int or (reply["childReturnCode"] is not None and type(reply["childReturnCode"]) is not int):
                    raise ValueError("Invalid owned child result")
                report.update(reply)
    except OSError as error:
        report["launchErrno" if guardian is None else "controlErrno"] = error.errno or -1
    except (ValueError, json.JSONDecodeError):
        pass
    finally:
        # Cleanup precedes any final stdout operation. Never wait/poll/reap the
        # guardian before the group signals: its reserved PID prevents PGID reuse.
        if guardian is not None:
            if report["groupVerified"]:
                for sig, key in ((signal.SIGTERM, "termSent"), (signal.SIGKILL, "killSent")):
                    try: os.killpg(guardian.pid, sig); report[key] = True
                    except ProcessLookupError: pass
                    except OSError as error: report["cleanupErrno"] = error.errno or -1
                    if sig == signal.SIGTERM: time.sleep(grace_seconds)
            else:
                try: guardian.kill(); report["killSent"] = True
                except OSError as error: report["cleanupErrno"] = error.errno or -1
            try: guardian.wait(timeout=1); report["leaderReaped"] = True
            except subprocess.TimeoutExpired: pass
        for fd in fds:
            try: os.close(fd)
            except OSError: pass
    report["cancellationSignal"] = report["cancellationSignal"] or cancellation()
    if report["cancellationSignal"]: report["wrapperExit"] = 128 + report["cancellationSignal"]
    elif report["timedOut"]: report["wrapperExit"] = 124
    elif report["launchErrno"] or report["controlErrno"]: report["wrapperExit"] = 127
    elif reply is not None and report["groupVerified"] and report["leaderReaped"] and not report["cleanupErrno"] and not output_broken:
        code = report["childReturnCode"]
        if code is not None: report["wrapperExit"] = code if code >= 0 else 128 - code
    report["elapsedMilliseconds"] = round((time.monotonic() - started) * 1000)
    try:
        if not output_broken: emit("complete", report)
    except BrokenPipeError:
        output_broken = True
        report["outputBroken"] = True
        if not report["cancellationSignal"]: report["wrapperExit"] = 125
    if output_broken:
        # Suppress interpreter shutdown flushing only after owned cleanup.
        with open(os.devnull, "w") as sink: os.dup2(sink.fileno(), sys.stdout.fileno())
    return report


def main():
    if sys.argv[1:2] == ["--owned-session"]:
        return session(int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), sys.argv[6:])
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phase", choices=PHASES, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    phase, seconds = PHASES[args.phase]
    mode = "build-for-testing" if phase == 0 else "test" if phase == 4 else "test-without-building"
    if os.name != "posix": parser.error("Only fixed POSIX SDK phases are supported")
    if phase == 3:
        if tuple(command) != DRIVER_COMMAND: parser.error("Only the exact read-only Swift driver probe is supported")
    else:
        if not command or command[0] != "xcodebuild" or command.count(mode) != 1:
            parser.error("Only the fixed POSIX xcodebuild phase is supported")
        if any(value in command for value in ({"build-for-testing", "test-without-building", "test", "archive", "build", "clean", "analyze",
                                                "install", "installhdrs", "installsrc", "docbuild"} - {mode})):
            parser.error("Mixed or unsupported xcodebuild action")
    executable = shutil.which(command[0])
    if executable is None:
        emit("complete", dict(phase=phase, launchErrno=2, wrapperExit=127)); return 127
    cancelled = [0]
    def receive(signum, frame):
        if not cancelled[0]: cancelled[0] = signum
    for signum in (signal.SIGINT, signal.SIGTERM): signal.signal(signum, receive)
    return run_owned([executable] + command[1:], seconds, phase, lambda: cancelled[0],
                     stdin=subprocess.DEVNULL if phase == 3 else None)["wrapperExit"]


if __name__ == "__main__":
    sys.exit(main())
