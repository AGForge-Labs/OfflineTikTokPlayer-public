# OfflineTikTokPlayer

Production iPhone player and Windows helper source for a private video library.

Catalogs and media load at runtime from an authenticated OneDrive app folder or user-selected local files. User libraries, collections, playlists, media, browser sessions and authentication caches do not belong in source or build artifacts.

The existing production bundle identity, Microsoft public-client configuration, registered redirect and keychain entitlements are preserved. The registration identifier is application configuration; access tokens and signing keys are not source inputs.

Use the existing Python helper tests, Swift core tests, project generator check and local preflight. Core/source checks do not prove iOS SDK, phone authentication, update persistence or TestFlight acceptance.

The authorized public playback branch runs one standard macOS job for unsigned core and simulator validation. The workflow is guarded to this public repository, uses no signing secrets, and limits builds to one job. Metrics print to job logs; no build artifacts or caches are uploaded. The separate production archive draft remains inactive under .github/workflow-drafts. Signing and release remain separate actions.

No new source-code license is asserted by this preparation. Existing source/dependency notices and rights remain in effect. Do not copy private data or third-party media into source or build artifacts.

The proposed owner-only public build/sign/upload route and its required credential protection are documented in [public release preparation](docs/public-release.md). Player 13.1 failed installed-device acceptance; this infrastructure does not accept or release that candidate.
