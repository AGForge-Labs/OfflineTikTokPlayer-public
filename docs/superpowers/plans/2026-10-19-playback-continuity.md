# Playback continuity implementation plan

**Goal:** Preserve audio where iOS permits, resume safely after interruptions, and prepare complete clips before loop/queue boundaries with bounded resources.

**Spec:** The October 19 playback continuity and speaker volume request. No trimming, private-media publication, new credentials, paid runners, or release changes. Execute here using one worker.

**Diagnosis:** Existing playback uses `.pause` at item ends, an end-notification zero seek for repeats, and only one forward prepared item. Session activation errors do not prevent play, and system interruptions call the explicit user-pause path. Public main `112b1cc` is the baseline. Work only from this clean public companion.

## Tasks

- [ ] Pin playback intent with core tests: duplicate interruption begins, user pause, missing shouldResume, failed activation, missing end, normal foreground and explicit recovery. Integrate an activation gate and `.playback` / `.mixWithOthers` without attempting to take an exclusive camera session.
- [ ] Pin native buffer behavior: automatic prepared advancement, complete repeat-one items, explicit skip, previous reuse, rapid reversals, queue exhaustion and bounded retained items. Use a persistent queue player, two queued items and at most one retained predecessor; observe actual current-item changes instead of waiting to restart at the boundary.
- [ ] Prepare natural successors (including full-duration duplicates) and previous items, retain revision/cancellation gates, remove preparation on memory pressure, and keep feed interaction/end-of-queue behavior deterministic.
- [ ] Recover speaker processing after optional cold-metadata timeouts. Measure quiet music gain, mid-bass response, native-tap PCM, sample headroom and bass distortion. Preserve Original sound and headphones/Bluetooth bypass without changing system volume.
- [ ] Record cold/next/previous clock timing and natural-boundary scheduling separately from physical audible/visible output. Decode synthetic source audio to distinguish encoded silence from scheduling gaps. Preserve all source samples and source duration.
- [ ] Run one-job Swift core/adapter/syntax checks, Python/project checks, and free unsigned public native CI. Review the diff and record physical iPhone/OnTrac acceptance requirements before release coordination.

Review focus: stale end callbacks after swipes; interruption during asynchronous item readiness; pause during recovery; repeat-one explicit skip; memory pressure while preparing. These require regression coverage, with real iPhone audio-route/background/camera behavior explicitly pending.
