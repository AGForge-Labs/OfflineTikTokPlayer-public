# Focused playback diagnosis

The manual source-only workflow runs all portable core tests and 13 exact native/UI cases. It uses one standard Mac, has a 15-minute limit and references no signing secrets. The existing full native mode remains available. A passing focused profile does not establish full release or physical-phone acceptance.

The profile retains compressed sample-exact loops/Next/Previous, retained streaming heads, the default real-output benchmark, stereo-silence calibration, actual selected-video pixels, paused/foreground restoration and UI navigation. An exact PCM-frame anchor regression covers the observed paused clock mismatch. No silence, timing, pixel or ownership assertion is loosened.

Runtime libraries, media, catalogs, browser profiles and account credentials are excluded. This branch matches none of the automatic Mac workflow branch filters.
