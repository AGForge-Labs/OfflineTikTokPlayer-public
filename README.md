# OfflineTikTokPlayer

Production iPhone player and Windows helper source for a private video library.

Catalogs and media load at runtime from an authenticated OneDrive app folder or user-selected local files. User libraries, collections, playlists, media, browser sessions and authentication caches do not belong in source or build artifacts.

The existing production bundle identity, Microsoft public-client configuration, registered redirect and keychain entitlements are preserved. The registration identifier is application configuration; access tokens and signing keys are not source inputs.

Use the existing Python helper tests, Swift core tests, project generator check and local preflight. Core/source checks do not prove iOS SDK, phone authentication, update persistence or TestFlight acceptance.

Automation is an inactive unsigned manual draft under .github/workflow-drafts. Initial publication starts no jobs. Native execution, signing and release require separate review and authorization.

No new source-code license is asserted by this preparation. Existing source/dependency notices and rights remain in effect. Do not copy private data or third-party media into source or build artifacts.
