# Public source to private TestFlight

Infrastructure preparation only. This branch is not an accepted release and has not uploaded a build. Player 13.1 failed physical-device acceptance; use the later reviewed rollback/repair source before enabling a release.

## Release contract

`.github/workflows/public-testflight.yml` has one manual owner trigger. Only Galaxybigbird (account ID 105477711) can run it from this repository's `main`; a rerun cannot sign. The supplied full SHA must match the source commit, workflow commit and checkout. Dispatch inputs are passed through environment variables, never shell interpolation.

A credential-free job runs the existing complete core, Apple buffer and simulator checks in `scripts/check-ios.sh`. A failure blocks signing. These checks do not establish working playback or correct selection on an installed phone. Full applicable release acceptance must be reviewed separately and recorded in the protected environment variable `RELEASE_ACCEPTED_COMMIT`, matching the final reviewed public main SHA. This is an explicit acceptance gate, not an automatic declaration that synthetic checks are sufficient. Do not set it for a known failed candidate.

A new isolated standard hosted macOS job then builds, verifies and uploads. The `release` environment is the credential boundary. The workflow requests only `contents: read`, uses checkout pinned to its immutable v7.0.1 commit, persists no checkout credential, publishes no cache or artifact, and captures signing/Apple output into temporary files that are deleted. Signed IPA, archives, provisioning, credentials, private data and raw signing logs are never uploaded to GitHub artifacts.

Use an explicit Apple-compatible build number greater than every existing App Store Connect build for this version. Public workflow numbering starts separately and must never determine the release number. The guard also rejects 13.1 and earlier. An uncertain or interrupted upload requires checking Apple before a fresh dispatch; do not use rerun to duplicate it.

Existing app identifiers, team, entitlements, App Group/keychain access and on-device stores stay unchanged. Export is internal TestFlight only. This workflow does not create testers, change groups, enable public links or submit a public beta. Existing private audience availability and a normal update over the installed app still require verification in Apple/TestFlight.

## Activation requires specific owner approval

Do not configure credential access on general migration approval. Before activation, present the exact environment, names/types below, access scope, protections and risks together for action-time approval.

Target: `AGForge-Labs/OfflineTikTokPlayer-public`, environment `release`. Required protections: only the `main` branch may deploy (no tags), required reviewer `Galaxybigbird`, administrator bypass disabled. The sole owner can review their own deliberate dispatch; add an independently authorized reviewer before enabling prevention of self-review. Repository/organization signing secrets must not bypass this environment.

| Environment secret | Existing material/type |
| --- | --- |
| `APPLE_CERTIFICATE_BASE64` | Existing distribution PKCS#12, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | Existing PKCS#12 password |
| `APPLE_PROVISIONING_PROFILE_BASE64` | Existing app distribution profile, base64 |
| `APP_STORE_CONNECT_KEY_BASE64` | Existing Developer upload private key, base64 |

Protected environment variables: `RELEASE_ACCEPTED_COMMIT`, `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and `APPLE_CERTIFICATE_SHA256` (SHA-256 of the original distribution certificate DER).

Scope: reuse the existing distribution identity, app-specific distribution profile and existing upload key with its current Apple permissions. No new key, certificate, Apple role, tester, paid runner, subscription or organization-wide access is required. The legacy aggregate `APPLE_PRIVATE_DELIVERY` is not read or exported by this workflow; supply the separate inputs from the original secure material. GitHub secret APIs do not return existing secret values. Use the supported GitHub environment secret entry flow from the owner's original secure material after approval, or approve narrowly scoped existing organizational-secret access only if it is actually available and compatible with the environment boundary. Never recover secrets through logs or a workflow.

Risk: reviewed code on a public hosted runner will temporarily possess signing and upload credentials. An authorized malicious workflow could disclose them; owner-trigger, exact-commit review, branch restriction, environment approval and least privilege are required. Public jobs cannot contain private packs, personal manifests, media, sessions or sensitive diagnostic artifacts. No security configuration or credential access was changed by this branch.

## Finish and verify

1. Review this infrastructure against the latest repaired/current candidate. Keep the active delivery independent.
2. Merge only reviewed source; confirm native and installed-upgrade acceptance, then obtain the specific activation approval.
3. Configure/verify the protected environment and supply existing secure material. Set accepted SHA only after acceptance review.
4. Owner manually dispatches from main with that exact SHA and a new Apple build number.
5. Verify successful Apple upload, processing, unchanged identifiers and existing private tester availability. Install as an update and confirm saved data persists.
6. Only after the public route is verified should the legacy private build route be retired. Keep original repositories private and retain private history.

The migration is incomplete until step 5 succeeds. This preparation does not authorize a new release of the current failed candidate.
