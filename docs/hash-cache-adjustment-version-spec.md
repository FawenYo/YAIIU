# Hash Cache Adjustment Version

## Purpose

`hash_cache` stores the SHA-1 of each asset's media, so an asset is not read and hashed again
on every launch. A cached hash can only be reused while the media is unchanged. PhotoKit makes
this hard: `fetchPersistentChanges(since:)` and `PHAsset.modificationDate` report many changes
that do not touch media bytes, such as opening a photo in Apple Photos, favorites, album
membership, iCloud state, and Photos analysis. If any of those invalidated the cache, a large
library would be rehashed (and iCloud originals downloaded) all the time.

The cache is therefore keyed on an **adjustment version**. This is the same signal the official
Immich iOS app uses (`local_asset_entity.adjustment_time`, compared in
`mobile/lib/infrastructure/repositories/local_album.repository.dart` `_upsertAssetsDarwin`).
Because both apps use the same signal, checksums imported from the Immich database keep a
version that can be compared directly.

## Value format

Built by `PhotoAssetAdjustmentVersion` in `YAIIU/Shared/BackgroundUploadDatabase.swift`.
Both the app and the extension use it.

| Value | Meaning |
|---|---|
| `adj:none` | PhotoKit `adjustmentTimestamp` is nil (asset never edited) |
| `adj:<Int64 seconds>` | `Int64(adjustmentTimestamp.timeIntervalSince1970)`, truncated toward zero exactly as in Immich `PHAssetExtensions.swift` |
| `mod:<Double>` / `mod:none` | Fallback when `PHAsset` stops responding to the private `adjustmentTimestamp` selector |
| SQL `NULL` | Unknown: a legacy (v0.1.9 and earlier) row, or an import from an Immich DB without `adjustment_time` |

API:
- `make(for: PHAsset) -> String` reads the private KVC key `adjustmentTimestamp`, but only after `responds(to:)` succeeds, so a missing key cannot raise `NSUnknownKeyException`.
- `make(adjustmentTimestamp: Date?) -> String`
- `make(modificationDateFallback: Date?) -> String`
- `make(immichAdjustmentTime: String?) -> String?` parses drift ISO-8601 text such as `2024-05-01T12:34:56.000Z` or `...+08:00`. It drops fractional seconds before parsing. `nil` input maps to `adj:none`. Unparseable text returns `nil` (unknown).

## Storage

- `hash_cache.asset_adjustment_version TEXT` (schema v10)
- `uploaded_assets.asset_adjustment_version TEXT` (schema v11). Upload receipts carry the version of the asset that was uploaded.
- The foreground reconciliation temp table `foreground_snapshot.adjustment_version`

v10 and v11 were rewritten in place before release. v0.1.9 shipped schema v8, so a released
database upgrades directly to the final columns. A development database already at
`user_version >= 10` with the old `asset_resource_fingerprint` columns must be reset
(reinstall the app).

## Where it is compared

All comparisons are plain string equality, and `NULL` always means unknown:
- Background extension: `BackgroundUploadDatabase.commitPersistentChange` (`updatedAssetAdjustmentVersions`).
- Foreground journal and snapshot: `HashCacheRepository.applyForegroundPhotoChanges`, `resetCacheForModifiedAssets`, `reconcileForegroundPendingAssets`.
- After hashing: `HashManager` discards the result when the version captured in `AssetResourcePlan.adjustmentVersion` no longer matches the current asset.
- Baseline: `HashCacheRepository.backfillPhotoKitVersionMetadata`. A row with a stored version that differs from the current one is invalidated. A row with no evidence at all is stamped with the current version.
- First checkpoint: `HashCacheRepository.commitInitialForegroundPhotoBootstrap` queues for per-asset PhotoKit verification only the rows that have both a version and a modification date. Rows without a date (fresh Immich imports, legacy rows) are left to the batched baseline above. Queuing a whole imported library for per-asset verification is far slower and is what made a large import hang on "Preparing".

The UI reports the two first-run passes separately through `PhotoKitBaselineProgress.stage`: `.inventory` while the PhotoKit identifiers are being read, and `.hashVersions` while the baseline runs.

## Immich SQLite import

`ImmichSQLiteImporter.readLocalHashes(db:remoteChecksums:)` reads `id`, `checksum` and, when
`PRAGMA table_info(local_asset_entity)` lists it, `adjustment_time`.
`HashCacheRepository.batchSaveHashCache` stores the imported version with a NULL
modification date and never overwrites an existing row. After the import,
`PhotoLibraryManager.backfillUnknownHashVersionsAfterImport()` runs the baseline:

- Imported version equals current: the hash is kept and the modification date is stamped. No rehash.
- Imported version differs (the asset was edited after Immich last synced): the hash is deleted, the asset is queued in `foreground_photo_pending_assets`, and it is rehashed.
- The Immich DB has no `adjustment_time` column, or the value cannot be parsed: the version is `NULL` and the legacy "stamp without evidence" baseline applies.

This works because Immich clears `checksum` whenever `adjustment_time` changes. A non-NULL
Immich checksum therefore always belongs to the `adjustment_time` on the same row.

## Known limits

- A media byte replacement without an adjustment is not detected. Immich accepts the same limit.
- Two edits within the same second share a version, because only whole seconds are stored.
- `adjustmentTimestamp` is private API. If it disappears, the `mod:` fallback avoids stalling, at the cost of the metadata-update rehash storms described above.

## Extending safely

- Changing the value format invalidates every stored version once. A one-time full rehash is the cost; it does not cause incorrect results.
- Keep `make(immichAdjustmentTime:)` consistent with `make(adjustmentTimestamp:)`. `BackgroundUploadPolicyTests.testImmichAdjustmentTimeMapsToPhotoKitAdjustmentVersion` guards this.
- Never treat `NULL` as equal to a known version. Unknown rows go through the baseline path only.
