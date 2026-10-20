# Public release migration implementation plan

**Goal:** Build, sign and upload the reviewed clean public source on standard hosted macOS while preserving installed identity, private data and existing private TestFlight access.
**Architecture:** Separate credential-free native validation from a manual owner-only signing job in the protected `release` environment. Source, workflow and accepted commit must match the exact 40-character dispatch SHA; reruns cannot upload.
**Constraints:** No original history, private packs, credentials, signed IPA, raw signing output, paid runners, automatic distribution, changed entitlements or app storage.
**Execution:** Implement directly in the isolated migration checkout. Credential access and environment activation require the owner's specific action-time approval; do not pause safe preparation.

- [x] Read release scripts, identities and existing synthetic validation.
- [x] Add failing tests for source/actor/ref/attempt gates, private-input refusal and output redaction.
- [x] Implement public workflow and signing adapter while retaining existing validation and release acceptance requirements.
- [x] Run portable tests, project checks, shell/workflow syntax and inspect the publication diff. Native signing remains unverified; broader helper host checks have dependency/platform failures.
- [ ] Open a draft PR, record tested source and report the exact activation blockers.

Review focus: a fork or wrong SHA never signs; public run numbering cannot reset an Apple build; failed tests block upload; private output never enters artifacts; upload uncertainty requires checking Apple before another dispatch.
