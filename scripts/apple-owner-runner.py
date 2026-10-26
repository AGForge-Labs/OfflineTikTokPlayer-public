"""Use the existing delivery key for this app's build checks and existing Owner group only."""
import base64
import json
import hashlib
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.request

APP = "6824156409"
GROUP = "14c0a090-358a-4ed6-a03f-f65f3c40e6fd"
OWNER_SHA256 = "f2ce965d0d3a6ce3a9e2ff253e192828e11878867421763cfa2e21e44e6c7215"
BASE = "https://api.appstoreconnect.apple.com/v1/"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        raise ValueError("Apple API redirects are refused.")


def require(value):
    if not value:
        raise ValueError("Apple owner/build validation failed; no broader access is permitted.")


def number(value):
    import re
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{1,4}(?:\.[0-9]{1,2}){0,2}", value))
    parts = tuple(map(int, value.split(".")))
    return parts + (0,) * (3 - len(parts))


def raw_signature(der):
    # OpenSSL ES256 produces ASN.1 DER, whereas JWT requires two 32-byte integers.
    require(8 <= len(der) <= 72 and der[0] == 0x30 and der[1] == len(der) - 2)
    result, offset = b"", 2
    for _ in range(2):
        require(offset + 2 <= len(der) and der[offset] == 2)
        size = der[offset + 1]; offset += 2
        require(1 <= size <= 33 and offset + size <= len(der))
        value = der[offset:offset + size]; offset += size
        require(value[0] < 128 and (size <= 32 or value[0] == 0))
        integer = int.from_bytes(value, "big")
        require(0 < integer < 2**256)
        result += integer.to_bytes(32, "big")
    require(offset == len(der))
    return result


def token(configuration, directory):
    encode = lambda value: base64.urlsafe_b64encode(value).rstrip(b"=")
    now = int(time.time())
    header = encode(json.dumps(dict(alg="ES256", kid=configuration["apiKeyID"], typ="JWT"), separators=(",", ":")).encode())
    payload = encode(json.dumps(dict(iss=configuration["issuerID"], iat=now, exp=now + 600, aud="appstoreconnect-v1"), separators=(",", ":")).encode())
    unsigned = header + b"." + payload
    key = Path(directory) / "owner-status-key.p8"
    key.write_text(configuration["apiPrivateKey"], encoding="utf-8"); key.chmod(0o600)
    signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(key)], input=unsigned,
                            capture_output=True, timeout=15,
                            env={name: os.environ[name] for name in ("PATH", "SYSTEMROOT", "TMPDIR") if name in os.environ})
    require(signed.returncode == 0)
    return (unsigned + b"." + encode(raw_signature(signed.stdout))).decode("ascii")


class Apple:
    def __init__(self, configuration, directory):
        self.authorization = "Bearer " + token(configuration, directory)

    def request(self, path, body=None):
        allowed = {f"apps/{APP}/builds?limit=200", f"betaGroups/{GROUP}?include=app,betaTesters",
                   f"betaGroups/{GROUP}/betaTesters?limit=200",
                   f"betaGroups/{GROUP}/relationships/builds", f"betaGroups/{GROUP}/relationships/builds?limit=200"}
        require(path in allowed)
        if body is not None:
            require(path == f"betaGroups/{GROUP}/relationships/builds")
        request = urllib.request.Request(BASE + path, data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": self.authorization, "Content-Type": "application/json"})
        try:
            with urllib.request.build_opener(NoRedirect()).open(request, timeout=20) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
                require(len(raw) <= 2 * 1024 * 1024 and response.status in (200, 204))
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError:
            raise ValueError("Apple request failed; private response is suppressed.") from None


def check_owner(apple):
    result = apple.request(f"betaGroups/{GROUP}?include=app,betaTesters")
    data = result["data"]; attributes = data["attributes"]
    included = [item for item in result.get("included", []) if item["type"] == "betaTesters"]
    require(data["id"] == GROUP and data["relationships"]["app"]["data"]["id"] == APP)
    require(attributes["name"] == "Owner" and attributes["isInternalGroup"] is True
            and not attributes.get("publicLinkEnabled", False))
    membership = apple.request(f"betaGroups/{GROUP}/betaTesters?limit=200")
    require(not membership.get("links", {}).get("next"))
    testers = membership["data"]
    total = membership.get("meta", {}).get("paging", {}).get("total")
    require(total is None or (type(total) is int and total == len(testers)))
    require(len(testers) == 1 and testers[0]["type"] == "betaTesters"
            and hashlib.sha256(testers[0]["attributes"]["email"].lower().encode()).hexdigest() == OWNER_SHA256)
    ids = {testers[0]["id"]}
    require(len(included) == 1 and included[0]["id"] in ids
            and hashlib.sha256(included[0]["attributes"]["email"].lower().encode()).hexdigest() == OWNER_SHA256)
    relationship = data["relationships"].get("betaTesters", {}).get("data")
    require(relationship is None or (len(relationship) == 1 and {item["id"] for item in relationship} == ids))
    return True


def builds(apple):
    result = apple.request(f"apps/{APP}/builds?limit=200")
    require(not result.get("links", {}).get("next"))
    require(isinstance(result["data"], list))
    for item in result["data"]:
        number(item["attributes"]["version"])
    return result["data"]


def before_upload(apple, version):
    check_owner(apple)
    proposed = number(version)
    require(all(number(item["attributes"]["version"]) < proposed for item in builds(apple)))


def finish(apple, version, *, seconds=180, monotonic=time.monotonic, sleep=time.sleep):
    deadline = monotonic() + seconds
    while True:
        candidate = next((item for item in builds(apple) if item["attributes"]["version"] == version), None)
        if candidate:
            attrs = candidate["attributes"]
            require(attrs.get("buildAudienceType") == "INTERNAL_ONLY" and attrs.get("expired") is False)
            require(attrs["processingState"] in ("PROCESSING", "VALID"))
            if attrs["processingState"] == "VALID":
                check_owner(apple)
                path = f"betaGroups/{GROUP}/relationships/builds"
                linked = apple.request(path + "?limit=200")
                require(not linked.get("links", {}).get("next"))
                if candidate["id"] not in {item["id"] for item in linked["data"]}:
                    apple.request(path, {"data": [{"type": "builds", "id": candidate["id"]}]})
                assigned = apple.request(path + "?limit=200")
                require(not assigned.get("links", {}).get("next") and candidate["id"] in {item["id"] for item in assigned["data"]})
                return dict(version=version, state="VALID", audience="INTERNAL_ONLY", assigned=True, onlyApprovedOwner=True)
        if monotonic() >= deadline:
            return dict(version=version, state="PROCESSING" if candidate else "NOT_RECEIVED", assigned=False)
        sleep(min(15, max(0, deadline - monotonic())))
