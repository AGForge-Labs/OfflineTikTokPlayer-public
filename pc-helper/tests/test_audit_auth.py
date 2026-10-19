import json
from datetime import datetime, timedelta, timezone
import pytest
from offline_tiktok import audit_auth


class Persistence:
    value = None

    def save(self, value):
        self.value = value

    def load(self):
        return self.value


def test_session_is_scoped_to_tiktok_and_sent_to_the_encrypted_storage_boundary(tmp_path, monkeypatch):
    persistence = Persistence()
    monkeypatch.setattr(audit_auth, "_persistence", lambda path: persistence)
    cookies = [{"name": "sessionid", "value": "dummy-test-value", "domain": ".tiktok.com"},
               {"name": "unrelated", "value": "dummy", "domain": ".example.com"}]
    audit_auth.save_session(tmp_path / "protected.bin", cookies)
    saved = json.loads(persistence.value)
    assert saved["cookies"] == cookies[:1]
    assert datetime.fromisoformat(saved["expiresAt"]) > datetime.now(timezone.utc)


def test_unsigned_profile_cannot_authorize_private_video_checks(tmp_path, monkeypatch):
    persistence = Persistence()
    monkeypatch.setattr(audit_auth, "_persistence", lambda path: persistence)
    with pytest.raises(ValueError, match="Sign in"):
        audit_auth.save_session(tmp_path / "protected.bin", [{"name": "public", "domain": ".tiktok.com"}])
    assert persistence.value is None


def test_expired_audit_authorization_does_not_get_reused(tmp_path, monkeypatch):
    path = tmp_path / "protected.bin"
    path.write_bytes(b"dummy encrypted fixture")
    persistence = Persistence()
    persistence.value = json.dumps({"expiresAt": (datetime.now(timezone.utc)-timedelta(seconds=1)).isoformat(),
                                   "cookies": [{"name": "sessionid", "value": "dummy-test-value", "domain": ".tiktok.com"}]})
    monkeypatch.setattr(audit_auth, "_persistence", lambda path: persistence)
    assert audit_auth.load_session(path) == []
