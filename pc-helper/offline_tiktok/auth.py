from pathlib import Path
import uuid
from .graph import AuthenticationRequired


class MicrosoftAuth:
    scopes = ["https://graph.microsoft.com/Files.ReadWrite.AppFolder"]

    def __init__(self, client_id, data_dir, *, progress=lambda message: None, cancelled=lambda: False):
        import msal
        from msal_extensions import PersistedTokenCache, build_encrypted_persistence
        try:
            uuid.UUID(client_id)
        except (ValueError, TypeError, AttributeError):
            raise ValueError("Enter the Microsoft application/client ID from the app registration") from None
        data_dir = Path(data_dir)
        data_dir.mkdir(parents=True, exist_ok=True)
        # No plaintext fallback. Standard local app data keeps tokens outside OneDrive.
        persistence = build_encrypted_persistence(str(data_dir / "microsoft.tokens"))
        self.app = msal.PublicClientApplication(client_id, authority="https://login.microsoftonline.com/common",
                                               token_cache=PersistedTokenCache(persistence))
        self.progress, self.cancelled = progress, cancelled

    def token(self):
        accounts = self.app.get_accounts()
        if len(accounts) != 1:
            raise AuthenticationRequired("Connect the intended OneDrive account in the helper")
        result = self.app.acquire_token_silent(self.scopes, account=accounts[0])
        if not result or "access_token" not in result:
            raise AuthenticationRequired("Reconnect OneDrive to refresh the app-folder grant")
        return result["access_token"]

    def connect(self):
        flow = self.app.initiate_device_flow(scopes=self.scopes)
        if "user_code" not in flow:
            raise AuthenticationRequired("Microsoft could not start sign-in. Check the client ID and enabled public-client flows.")
        self.progress(flow["message"])
        result = self.app.acquire_token_by_device_flow(flow, exit_condition=lambda data: self.cancelled())
        if "access_token" not in result:
            raise AuthenticationRequired("Microsoft sign-in was cancelled or declined; no library was uploaded")
        self.progress("OneDrive connected; access is limited to this app's folder")
        return result["access_token"]
