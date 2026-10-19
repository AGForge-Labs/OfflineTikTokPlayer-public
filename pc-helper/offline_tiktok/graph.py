from datetime import datetime, timezone
import hashlib
import mimetypes
from pathlib import Path
import time
from urllib.parse import quote, urlparse
import httpx
from .catalog import AssetRef
from .store import checksum


class AuthenticationRequired(RuntimeError):
    pass


class StorageFull(RuntimeError):
    pass


class GraphClient:
    base = "https://graph.microsoft.com/v1.0"
    chunk_size = 10 * 1024 * 1024

    def __init__(self, token_provider, store, *, http=None, cancelled=lambda: False, progress=lambda message: None, sleep=time.sleep):
        self.token_provider, self.store = token_provider, store
        self.http = http or httpx.Client(timeout=60)
        self.cancelled, self.progress, self.sleep = cancelled, progress, sleep

    def close(self):
        self.http.close()

    def _check(self):
        if self.cancelled():
            raise InterruptedError("Paused; completed files and transfer checkpoints are retained.")

    def _request(self, method, path, *, allowed=(), **kwargs):
        self._check()
        url = self.base + path if path.startswith("/") else path
        parsed = urlparse(url)
        if parsed.scheme != "https":
            raise ValueError("Cloud transfers require HTTPS")
        headers = dict(kwargs.pop("headers", {}))
        if parsed.hostname == "graph.microsoft.com":
            headers["Authorization"] = "Bearer " + self.token_provider()
        for attempt in range(4):
            self._check()
            try:
                response = self.http.request(method, url, headers=headers, **kwargs)
            except httpx.TransportError:
                if attempt == 3:
                    raise RuntimeError("OneDrive connection failed; completed progress is retained") from None
                self.sleep(2 ** attempt)
                continue
            if response.status_code == 401:
                raise AuthenticationRequired("Reconnect OneDrive to refresh access. Archived files are retained.")
            if response.status_code == 507:
                raise StorageFull("OneDrive is full. Free space or increase capacity, then resume.")
            if response.status_code in allowed:
                return response
            if response.status_code == 429 or response.status_code >= 500:
                if attempt < 3:
                    try:
                        delay = min(float(response.headers.get("Retry-After", 2 ** attempt)), 30)
                    except ValueError:
                        delay = 2 ** attempt
                    self.sleep(delay)
                    continue
            if response.is_error:
                raise RuntimeError(f"OneDrive request failed (HTTP {response.status_code}); retry or reconnect.")
            return response
        raise RuntimeError("OneDrive did not complete the request")

    def app_folder(self):
        data = self._request("GET", "/me/drive/special/approot").json()
        drive_id = data.get("parentReference", {}).get("driveId")
        if not drive_id:
            drive_id = self._request("GET", "/me/drive").json()["id"]
        return drive_id, data["id"]

    def quota(self):
        # App-folder access may not expose drive-level quota on every account.
        response = self._request("GET", "/me/drive?$select=id,quota", allowed=(403,))
        return response.json().get("quota") if response.status_code != 403 else None

    def folder(self, name, drive_id, root_id):
        path = f"/drives/{quote(drive_id, safe='')}/items/{quote(root_id, safe='')}:/{quote(name, safe='') }"
        response = self._request("GET", path, allowed=(404,))
        if response.status_code != 404:
            return response.json()["id"]
        created = self._request("POST", f"/drives/{quote(drive_id, safe='')}/items/{quote(root_id, safe='')}/children",
                                json={"name": name, "folder": {}, "@microsoft.graph.conflictBehavior": "fail"}, allowed=(409,))
        if created.status_code == 409:
            return self._request("GET", path).json()["id"]
        return created.json()["id"]

    def _ref(self, data, path, drive_id, digest):
        if data.get("size") != path.stat().st_size or not data.get("id"):
            raise ValueError("OneDrive returned an incomplete asset; catalog publication was stopped")
        return AssetRef(drive_id, data["id"], data.get("name", path.name), data["size"], digest,
                        mimetypes.guess_type(path.name)[0] or "application/octet-stream")

    def verify_file(self, asset, source):
        """Revalidate repair checkpoints against the live file, never a cached capability URL."""
        source = Path(source)
        if source.stat().st_size != asset.byte_size or checksum(source) != asset.sha256:
            return False
        response = self._request("GET", f"/drives/{quote(asset.drive_id, safe='')}/items/{quote(asset.item_id, safe='')}", allowed=(404,))
        if response.status_code == 404:
            return False
        data = response.json()
        if data.get("id") != asset.item_id or data.get("size") != asset.byte_size:
            return False
        server_sha1 = data.get("file", {}).get("hashes", {}).get("sha1Hash")
        if server_sha1:
            with source.open("rb") as stream:
                return hashlib.file_digest(stream, "sha1").hexdigest().lower() == server_sha1.lower()
        # Graph does not support sha256Hash. If SHA-1 is absent, hash a streamed
        # round trip rather than trusting locally recorded metadata as remote proof.
        url = data.get("@microsoft.graph.downloadUrl")
        if not url or urlparse(url).scheme != "https":
            raise ValueError("OneDrive could not expose the repaired file for verification")
        digest, size = hashlib.sha256(), 0
        try:
            with self.http.stream("GET", url, follow_redirects=True) as content:
                if content.status_code != 200:
                    return False
                for chunk in content.iter_bytes(1024 * 1024):
                    self._check()
                    size += len(chunk)
                    if size > asset.byte_size:
                        return False
                    digest.update(chunk)
        except httpx.HTTPError:
            raise RuntimeError("OneDrive repair verification was interrupted; resume to retry") from None
        return size == asset.byte_size and digest.hexdigest() == asset.sha256

    def upload_file(self, source, destination, drive_id, root_id, *, force_chunked=False):
        path = Path(source)
        size = path.stat().st_size
        if not size:
            raise ValueError("Cannot upload empty media")
        digest = checksum(path)
        target = f"/drives/{quote(drive_id, safe='')}/items/{quote(root_id, safe='')}:/{quote(destination, safe='/')}"
        if size <= 10 * 1024 * 1024 and not force_chunked:
            response = self._request("PUT", target + ":/content", content=path.read_bytes())
            return self._ref(response.json(), path, drive_id, digest)
        checkpoint = self.store.upload(digest)
        if checkpoint and checkpoint.get("target") != target:
            # A capability URL must remain bound to the account and destination
            # that created it, even when another file has exactly the same bytes.
            checkpoint = None
        if checkpoint:
            try:
                expired = datetime.fromisoformat(checkpoint["expires_at"].replace("Z", "+00:00")) <= datetime.now(timezone.utc)
            except ValueError:
                expired = True
            if expired:
                checkpoint = None
            else:
                response = self._request("GET", checkpoint["url"], allowed=(404, 410))
                if response.status_code in (404, 410):
                    checkpoint = None
                else:
                    checkpoint["offset"] = int(response.json()["nextExpectedRanges"][0].split("-")[0])
        if not checkpoint:
            response = self._request("POST", target + ":/createUploadSession", json={"item": {"@microsoft.graph.conflictBehavior": "replace", "name": destination.rsplit("/", 1)[-1]}})
            data = response.json()
            checkpoint = dict(url=data["uploadUrl"], offset=0, expires_at=data["expirationDateTime"])
        offset = checkpoint["offset"]
        if offset < 0 or offset >= size:
            raise ValueError("Upload session returned an invalid resume position")
        self.store.save_upload(digest, checkpoint["url"], offset, checkpoint["expires_at"], target=target)
        with path.open("rb") as stream:
            stream.seek(offset)
            while offset < size:
                self._check()
                chunk = stream.read(self.chunk_size)
                response = self._request("PUT", checkpoint["url"], content=chunk,
                                         headers={"Content-Length": str(len(chunk)), "Content-Range": f"bytes {offset}-{offset + len(chunk)-1}/{size}"})
                if response.status_code in (200, 201):
                    ref = self._ref(response.json(), path, drive_id, digest)
                    self.store.clear_upload(digest)
                    return ref
                data = response.json()
                next_offset = int(data["nextExpectedRanges"][0].split("-")[0])
                if next_offset <= offset or next_offset > size:
                    raise ValueError("OneDrive returned a non-progressing upload position")
                offset = next_offset
                stream.seek(offset)
                checkpoint["expires_at"] = data.get("expirationDateTime", checkpoint["expires_at"])
                self.store.save_upload(digest, checkpoint["url"], offset, checkpoint["expires_at"], target=target)
                self.progress(f"Uploaded {offset / 1048576:.1f} of {size / 1048576:.1f} MiB")
        raise RuntimeError("OneDrive did not confirm the final asset; catalog publication was stopped")

    def publish(self, catalog, drive_id, root_id):
        content = catalog.to_json().encode("utf-8")
        response = self._request("PUT", f"/drives/{quote(drive_id, safe='')}/items/{quote(root_id, safe='') }:/catalog.json:/content",
                                 headers={"Content-Type": "application/json"}, content=content)
        if response.json().get("size") != len(content):
            raise ValueError("OneDrive did not confirm the catalog bytes")
        return response.json()["id"]

    def resolve(self, asset):
        # Personal OneDrive can omit this annotation when a $select filter is used.
        data = self._request("GET", f"/drives/{quote(asset.drive_id, safe='')}/items/{quote(asset.item_id, safe='')}").json()
        url = data.get("@microsoft.graph.downloadUrl")
        if not url or urlparse(url).scheme != "https":
            raise ValueError("OneDrive did not supply a downloadable asset URL")
        return url

    def read_range(self, asset, start, end):
        if start < 0 or end < start:
            raise ValueError("Invalid media byte range")
        response = self._request("GET", self.resolve(asset), headers={"Range": f"bytes={start}-{end}"}, follow_redirects=True)
        if response.status_code != 206:
            raise ValueError("OneDrive did not honor the media byte range; seekability is unverified")
        return response.content
