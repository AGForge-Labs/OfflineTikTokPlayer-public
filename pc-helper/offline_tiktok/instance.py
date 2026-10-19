"""One local helper owns the browser; launchers send only fixed UI commands."""
import json
import os
from pathlib import Path
import time
import uuid


class HelperInstance:
    commands = frozenset(("show", "hide", "pause", "check", "quit"))

    def __init__(self, directory):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.requests = self.directory / "helper-commands"
        self.requests.mkdir(exist_ok=True)
        self.record = self.directory / "helper-instance.json"
        self.stream = None
        self.identity = None
        self.details = {}

    def acquire(self):
        stream = (self.directory / "helper.instance.lock").open("a+b")
        stream.seek(0, 2)
        if stream.tell() == 0:
            stream.write(b"0"); stream.flush()
        stream.seek(0)
        try:
            if os.name == "nt":
                import msvcrt
                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            stream.close()
            return False
        self.stream, self.identity = stream, uuid.uuid4().hex
        self.report()
        return True

    def report(self, **details):
        if not self.stream:
            return
        self.details.update(details)
        temporary = self.record.with_suffix(".tmp")
        temporary.write_text(json.dumps(dict(instance=self.identity, pid=os.getpid(), heartbeat=time.time(), **self.details)), encoding="utf-8")
        temporary.replace(self.record)

    def send(self, command):
        if command not in self.commands:
            raise ValueError("Unsupported helper command")
        try:
            owner = json.loads(self.record.read_text(encoding="utf-8"))
            identity = owner["instance"]
        except (OSError, ValueError, KeyError, TypeError):
            return False
        destination = self.requests / f"{time.time_ns()}-{uuid.uuid4().hex}.json"
        temporary = destination.with_suffix(".tmp")
        temporary.write_text(json.dumps(dict(instance=identity, command=command)), encoding="utf-8")
        temporary.replace(destination)
        return True

    def receive(self):
        if not self.stream:
            return []
        result = []
        for path in sorted(self.requests.glob("*.json"))[:128]:
            try:
                if path.stat().st_size > 4096:
                    continue
                value = json.loads(path.read_text(encoding="utf-8"))
                if isinstance(value, dict) and value.get("instance") == self.identity and value.get("command") in self.commands:
                    result.append(value["command"])
            except (OSError, ValueError, TypeError):
                pass
            finally:
                try:
                    path.unlink()
                except OSError:
                    pass
        return result

    def close(self):
        if self.stream:
            self.stream.close()  # The OS releases the lock even after an abnormal exit.
            self.stream = None
