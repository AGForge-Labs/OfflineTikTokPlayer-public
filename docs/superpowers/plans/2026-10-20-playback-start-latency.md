# Playback start and transition latency investigation

**Goal:** Investigate the reported continuing silence/loading delay without assuming the owner's installed build; 14.1 has not uploaded.
**Baseline:** Public main `08fba4fd9bc49fa62d268ccbd37d10ccc8074886`; shipped rollback 12.1 tree `01664b0f0bb49a9eeead83586542fb2fc942d636` remains read-only.
**Approach:** Measure cold load, prepared selection/return, natural boundaries and presentation recovery separately. Use independently identifiable synthetic tones, actual engine-output samples and actual video pixels. Prior zero PCM-underrun evidence does not establish output or visual latency.
**Constraints:** One serial low-resource worker; public fixtures only; no merge, signing, upload, release dispatch or environment change. Preserve all source frames/silence and private user data.

- [x] Read current instructions, prior acceptance evidence and relevant current/shipped paths.
- [x] Run the portable baseline: 83 tests pass with one Swift job.
- [ ] Add native request-to-output/first-frame measurements and reproduce a failure before changing production behavior.
- [ ] Isolate a supported causal path and implement only the demonstrated correction.
- [ ] Verify regression identity, pixels, output continuity, intent, queue endings and resource bounds without relaxing thresholds.
- [ ] Obtain independent review and publish exact before/after evidence and remaining physical-device limits.

Initial supported paths: current cold selection does not attach the video item until precise PCM preparation finishes. Prepared video selection also performs composition/output setup on selection and a forced exact seek on its first audio-render visit; that seek removes the displayed frame and blocks pulls. These are hypotheses about measured latency, not a diagnosis of the unknown installed build.
