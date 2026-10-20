# Playback continuity implementation plan

**Goal:** Preserve audio where iOS permits, resume safely after interruptions, and prepare complete clips before loop/queue boundaries with bounded resources.

**Spec:** The October 19 playback continuity and speaker volume request. No trimming, private-media publication, new credentials, paid runners, or release changes. Execute here using one worker.

**Diagnosis:** Existing playback uses `.pause` at item ends, an end-notification zero seek for repeats, and only one forward prepared item. Session activation errors do not prevent play, and system interruptions call the explicit user-pause path. Public main `112b1cc` is the baseline. Work only from this clean public companion.

## Tasks

- [x] Pin playback intent with core tests: duplicate interruption begins, user pause, missing shouldResume, failed activation, missing end, normal foreground and explicit recovery. Integrate an activation gate and `.playback` / `.mixWithOthers` without attempting to take an exclusive camera session.
- [x] Pin native buffer behavior: automatic prepared advancement, complete repeat-one items, explicit skip, previous reuse, rapid reversals, queue exhaustion and bounded retained items. Use one persistent queue player, normally two queued items (three for repeat-one), and at most one retained predecessor; observe actual current-item changes instead of waiting to restart at the boundary.
- [x] Prepare natural successors (including full-duration duplicates) and previous items, retain revision/cancellation gates, remove preparation on memory pressure, and keep feed interaction/end-of-queue behavior deterministic. Automatic handoffs honor Saved/offline eligibility.
- [x] Recover speaker processing after optional cold-metadata timeouts. Measure quiet music gain, mid-bass response, native-tap PCM, sample headroom and bass distortion. Preserve Original sound and headphones/Bluetooth bypass without changing system volume.
- [x] Record cold/next/previous clock timing and natural-boundary scheduling separately from physical audible/visible output. Decode synthetic source audio to distinguish encoded silence from scheduling gaps. Preserve all source samples and source duration.
- [x] Run one-job Swift core/adapter/syntax checks, Python/project checks, and free unsigned public native CI. Review the diff and record physical iPhone/camera acceptance requirements before release coordination.

Independent read-only review is complete. Its startup-seek, retained-mix and coalesced-boundary findings are fixed, including the two-item replenishment window and longer-playlist continuation. Production source `2dc6625` passes 69 core, 40 native and one UI test in public run 39326804950. The final diagnostic comparison uses identical service/route/source/50 ms conditions with Speaker sound and Original sound, three serial trials per mode.

Physical iPhone acceptance and immediate next/previous playback remain open. Callback/clock timing does not establish first audible output or audible seamlessness. The validation report contains phase instrumentation and the concrete device/recording plan; no signing or release is performed here.

Review focus: stale end callbacks after swipes; interruption during asynchronous item readiness; pause during recovery; repeat-one explicit skip; memory pressure while preparing. These require regression coverage, with real iPhone audio-route/background/camera behavior explicitly pending.
