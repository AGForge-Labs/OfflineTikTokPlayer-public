# PCM player integration candidate

This candidate combines the continuous PCM experiment with the already-delivered
Library Audio only control and phone-requested TikTok refresh. It is not a delivered build.

The existing focused profile now requires 63 native results and one UI result, including
every original diagnostic case plus complete relevant service, presentation, library,
speaker and feed suites. All portable core tests still run. Missing, failed, skipped,
duplicate or unexpected case evidence remains a failure. The ordinary full-suite mode
is unchanged, including the long experimental A/B comparisons and their failed evidence.
This profile is partial evidence and does not claim complete release or phone acceptance.

OneDrive streaming and the bounded temporary cache remain the media path. Audio only
preserves the PCM owner, selected item and position, stops video/PiP presentation, persists
the preference and restores the saved queue paused. Player and the mini-player restore
video. iOS interruption permission still controls camera/call recovery.

Free local cloud tests first failed on missing import APIs, then all 16 passed after
the delivered adapter/repository implementation was restored. Swift parsing and project
references pass. The new native persistence and interruption tests require Apple SDK
execution; real OnTrac scanning/photos and real-phone gaplessness remain pending.

`gap-profile-snapshot.json` preserves the earlier isolated diagnostic import provenance;
it is not a checksum assertion for this subsequent integration. The Git commit and its
current native job receipt identify the integrated source.

Whole-branch source review is complete. The mandatory full-file cache dependency remains
a release blocker for valid cloud assets that exceed or cannot enter its 256MiB budget.
The owner-only delivered19.1 is unchanged; this branch is unsigned diagnostic source.

The prior public run40084532134 failed five selected native cases. Its exact frame-grid
regression and actual UI Downloads navigation passed. Audio underruns remain failed
evidence. The Audio only test exhausted its30-second clip during slow compositor capture;
the setup now explicitly settles an earlier position after preserving that motion proof.
Fixture owners now join their service tasks and decoder shutdown before deleting media,
and XCTest awaits completion before starting another case. These changes need native
execution and do not establish a production audio fix or phone acceptance.
