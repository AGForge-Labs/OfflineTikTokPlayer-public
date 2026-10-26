# Experimental phone repair23.1

Recover the same selected video after an interrupted initial OneDrive-link lookup.
The initial resolver gets one failure-only fresh-link attempt for classified transient
URL-loading errors. Permanent failures and cancellation do not retry. Pause and newer
selections remain authoritative. The existing independently bounded AVPlayer-item
recovery is unchanged. Error diagnostics store only numeric family/code and stage.

Frozen source: `e9feab6815a7b5d90cfd3851c3a61d0608267cc7`.
App tree: `79093f6ddf43272aff597bcc5a5749b6e8d001c4`.
PlayerCore tree unchanged: `64d337f129d7ee93a8b8f7361294e6b50cedfdd6`.
Required focused native run: `40416241013`, on `fix/source-preparation23`.
The signing guard requires that exact source/run to complete successfully.

Baseline run `40412922247` compiled the unchanged22.1 app. Its new cold-resolution
regression reproduced the preparation alert with zero fresh lookups and no playback;
the UI smoke case passed. The final profile retains all16existing controls, adds
four cold-recovery cases and checks numeric diagnostic privacy:21cases total.

Reuse the existing protected release environment, unchanged signing/owner helpers,
standard public macos-26 runner and owner-only internal TestFlight distribution.
No normal acceptance-gate, key, permission, tester or public-link change.
Focused native evidence does not establish the old full gapless acceptance gate
or physical-phone acceptance. Keep archived media private.

Candidate run `40414570409` passed19of20cases, including recovery and UI smoke, but
failed the combined Pause/selection case on a missing temporary resume-file error
in fixture cleanup. The next source separates both controls into independently
owned XCTest cases without changing app/core runtime bytes or their assertions.
The failed run remains in evidence and is not admitted to signing.
