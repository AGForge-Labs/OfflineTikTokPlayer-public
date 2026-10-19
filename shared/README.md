# Shared catalog contract

`catalog.schema.json` defines the version-1 JSON exchanged through the app's private OneDrive folder. The Windows helper publishes `catalog.json` only after the referenced media uploads are complete. Download URLs and authentication data are never catalog fields.

Each media ID is a TikTok post ID. Each playlist ID is its stable TikTok collection ID; a rename changes its name without changing its identity. `itemIds` preserves collection order. Combined queues deduplicate by media ID in first-seen catalog/playlist order. All-items playback includes every archived ready item, including items no longer in an imported collection.

`ready` requires a complete playback asset. `pending` and `unavailable` remain visible in the library but cannot enter a cloud playback queue. Original media and artwork use independent optional asset references. Photo-post originals are a ZIP; their playback asset is the rendered MP4. Each asset records the OneDrive drive/item IDs, byte count and SHA-256 so the phone can refresh expired links and verify local copies.

Consumers must also validate unique media/playlist IDs and that every playlist member exists in `media`. JSON Schema alone cannot check these cross-record relationships. Unknown `schemaVersion` values must fail with an actionable update message while preserving the last valid catalog and offline files.
