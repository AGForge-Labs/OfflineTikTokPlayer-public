# Accepted player and public release integration

**Goal:** Prepare a reviewable public release integration without signing or uploading.
**Source:** Preserve every `ios/` blob from accepted `7da8c8f10bdb7f5b02bba7a1ca02498b74dd714b`; cherry-pick infrastructure `0d850de686b6d5dac3cf1b40a160e15a3ccb7a7e`.
**Architecture:** Retain the main-only Owner dispatch, exact workflow/source SHA, credential-free native validation and protected `release` environment. Carry the accepted compiler determinism and one-job limits into the separate archive process.
**Constraints:** No dispatch, signing, upload, new credential, audience expansion, private media/history or paid fallback. Keep the existing 12.1 Owner offer and 13.1 withdrawal.

- [x] Isolate the accepted source in a linked worktree and apply only the infrastructure commit patch.
- [x] Add regression coverage for archive resource limits, including a hostile inherited compiler setting, missing/failed driver override and stderr diagnostics.
- [x] Update the strict preflight policy for the accepted validation harness and retain its fail-closed checks in release validation.
- [x] Run serial infrastructure tests, project generation, syntax and workflow checks; verify exact accepted iOS tree equality.
- [x] Obtain independent static review; the integration is ready to publish for parent review.
- [x] Verify proposed version/build, fresh read-only protection/audience evidence, cost expectation and the remaining specific Owner action.

The existing unsigned run 39410213569 establishes software validation for the unchanged accepted app. An infrastructure-only integration does not establish iPhone/OnTrac acceptance. The release route must rerun full unsigned native validation before its protected signing job; this preparation does not dispatch it.

Validation: 61 targeted preflight/signing/project tests, seven release-gate tests, eight launcher regressions and 16 evidence regressions passed. Workflow actionlint 1.7.12, Python/shell syntax, generated project and diff checks passed. The iOS tree equals `41f6ebe7bb9cd9992c2e0a9bb51ae33737f0eba5` from the accepted source. The independent reviewer found and verified the fix for stderr-only Swift diagnostics; no code blocker remains.

Read-only readiness at 2026-10-20 11:10:51 UTC confirmed the existing protected main-only `release` environment, Galaxybigbird reviewer, no administrator bypass, four environment secrets, no repository secrets and unset accepted-commit attestation. Existing Owner audience remains one tester with no public link or automatic access to all builds. Version 1.0 build 14.1 is newer than all existing Apple builds; 12.1 remains offered and 13.1 withdrawn. Recheck at action time. Full numeric receipts remain local and are not published.

Pending: review/merge the exact integration, obtain specific Owner authorization for one public candidate run and existing Owner-only delivery, attest the final reviewed main SHA, then deliberately dispatch and approve the protected environment. No signing, upload, group assignment or installed-device acceptance occurred during this preparation. Public standard hosted runner compute is expected to cost $0 under [GitHub's documented billing policy](https://docs.github.com/en/billing/concepts/product-billing/github-actions); this workflow uploads no artifact or cache.
