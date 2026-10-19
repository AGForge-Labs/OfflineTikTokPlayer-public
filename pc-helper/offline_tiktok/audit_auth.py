"""Protect the helper's own TikTok audit session with Windows user encryption."""
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path


def _persistence(path):
    from msal_extensions import build_encrypted_persistence
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    return build_encrypted_persistence(str(path))


def save_session(path, cookies):
    selected = [value for value in cookies if value["domain"].lstrip(".") in ("tiktok.com", "www.tiktok.com")]
    if not any(value["name"] in ("sessionid", "sessionid_ss", "sid_tt") for value in selected):
        raise ValueError("Sign in to TikTok in the helper's browser before authorizing video checks.")
    expiry = datetime.now(timezone.utc) + timedelta(hours=4)
    _persistence(path).save(json.dumps({"expiresAt": expiry.isoformat(), "cookies": selected}))


def load_session(path):
    if not Path(path).exists():
        return []
    try:
        data = json.loads(_persistence(path).load())
        if datetime.fromisoformat(data["expiresAt"]) <= datetime.now(timezone.utc):
            return []
        return data["cookies"]
    except (ValueError, KeyError):
        return []
