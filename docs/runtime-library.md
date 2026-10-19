# Runtime library boundary

The Windows helper keeps session-dependent import data local and publishes catalog/media to the user's authenticated OneDrive app folder. Existing MSAL token persistence is encrypted. The iPhone app obtains tokens through MSAL, resolves private media at runtime, and stores its catalog/downloads in app-private storage with existing file protection.

Local import and the editable Microsoft registration setting remain available. Preserve the intended production bundle ID, redirect, keychain entitlement and app registration/account for the existing library.

Source builds contain no user playlist, media, cookie store, bearer token or signing credential. Migration of signing access to a different repository/protected environment is separate and unconfigured.
