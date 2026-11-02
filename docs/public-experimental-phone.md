# Owner phone video timing repair

Candidate: `8357efed671323bfbeea10b10f9fa2500f9022df`; parent `4910ed6b69b0cdca3391810919b8e683851fae37`.
App: `ce76fdd2a2665b0e4ca131dcaca3a8f1906ff650`; unchanged Core: `f9b20964220eb867c397e9fa8334c673263d92a5`.

Preserve the muted native timing track, native video pixel format and media-owned
visibility during rapid reversals. PCM remains audible. The final exact31-case
native run41396159005 must succeed before any signing input is mapped. It includes
real-service1080p60, PCM progress/mute, supersession and pause/interruption checks.
Earlier reversal19 and baseline/image receipts remain required. Failed pacing
audits41390543020,41392840748 and41394165312 are retained as failure evidence;
none of them authorizes this candidate. Full-suite and phone acceptance remain open.

Use the existing protected release environment, unchanged signing helper and
owner-only internal TestFlight group. No credential, role, tester or billing change.

# Historical phone repair23.1

Recover the selected video after an interrupted initial OneDrive-link lookup.
One classified transient URL-loading failure receives one fresh-link attempt.
Permanent errors and cancellation do not retry. Pause and newer selections remain
authoritative. Diagnostics record only numeric error family/code and stage.
The existing separately bounded AVPlayer-item recovery remains in place.

Frozen source: `2e43c1fc8c8be33e8677c73866246a328db3a892`.
App tree: `79093f6ddf43272aff597bcc5a5749b6e8d001c4`.
PlayerCore tree: `64d337f129d7ee93a8b8f7361294e6b50cedfdd6`.
Required native run: `40420488203`, branch `fix/source-preparation23`.
This exact run completed SUCCESS with23native/UI-support cases plus1UI smoke case,
24total, all individually verified. The signing guard requires that exact successful
run and source. Physical-phone acceptance and the old full gapless gate remain open.

Baseline `40412922247` reproduced the cold failure on unchanged22.1 runtime.
Candidate workflows `40414570409`, `40416241013`, `40417588359`, and `40418821656`
are FAILED and are not admitted to signing. Guard-fixture setup was corrected to
supply a complete asset for a ready replacement clip. A narrowly validated adjacent
Apple AQ log reconstruction repaired reporting without reducing case requirements.
Original logs, failed histories and assertions are preserved.

Use only the existing protected release environment and unchanged signing/owner
helpers on the standard public macos-26 runner. Distribution stays owner-only,
internal TestFlight. No key, permission, tester, public-link, or normal gate change.
Archived media and account credentials remain private.
