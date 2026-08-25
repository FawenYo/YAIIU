# Design: Preserve iCloud ID mappings during incremental sync

**Date:** 2026-08-25
**Branch:** fix/icloud-id-first-sync

## Problem

The app fetches `AssetMetadataV1` and `AssetsV2` through separate Immich sync streams. The metadata stream returns an `assetId -> iCloudId` map, but `ServerAssetSyncService` only applies that map while constructing records for assets present in the current `AssetsV2` delta. Metadata-only changes for assets absent from that delta are discarded.

`ServerAssetRepository.saveServerAssets` also uses `INSERT OR REPLACE`. When an asset delta has no matching metadata event, the replacement row writes `NULL` to `icloud_id`, destroying a previously cached mapping. Those gaps force `HashManager` to calculate hashes even though Immich already has both the checksum and iCloud ID.

The stream parsers retain only one final acknowledgment. Immich checkpoints are stored per sync entity type, so a response containing multiple entity types must preserve the latest acknowledgment for each type.

## Decision

Keep the existing two stream requests, but make metadata persistence independent from asset persistence and acknowledge all entity checkpoints only after the corresponding database changes succeed.

This change repairs future incremental synchronization only. It does not reset Immich sync checkpoints or force a full rebuild of the existing server cache. Existing rows whose `icloud_id` is already `NULL` may continue to require local hashing until Immich emits a new metadata event for them.

## API stream result

Replace the metadata stream's dictionary-only result with a result containing:

- iCloud ID upserts keyed by Immich asset ID;
- mobile-app metadata deletions keyed by Immich asset ID;
- the latest acknowledgment for each emitted entity type.

Replace the asset stream's single `lastAck` with the same per-entity acknowledgment collection. `SyncCompleteV1` is not acknowledged because it is a stream boundary rather than a persisted cache mutation. `SyncAckV1` entries must use their `ackType` when determining the checkpoint key.

The stream functions no longer call `sendSyncAck` internally. They return parsed events and acknowledgments to `ServerAssetSyncService`.

## Database writes

### Asset upsert

Replace `INSERT OR REPLACE` with `INSERT ... ON CONFLICT(immich_id) DO UPDATE`.

All asset fields continue to update from `AssetsV2`. The `icloud_id` assignment uses `COALESCE(excluded.icloud_id, server_assets_cache.icloud_id)`, so the absence of a metadata event cannot erase an existing mapping.

### Metadata delta

Add repository operations that update `server_assets_cache` by `immich_id`:

- upsert event: set `icloud_id` to the new value when the asset row exists;
- delete event for metadata key `mobile-app`: set `icloud_id` to `NULL` when the asset row exists.

A metadata event cannot create a complete `server_assets_cache` row because it lacks the required checksum. If its asset row is not present, the update affects zero rows and is intentionally ignored. A later `AssetsV2` event can still carry an iCloud ID from the metadata map fetched in that same sync cycle.

Metadata deletions for keys other than `mobile-app` are ignored.

## Sync transaction and acknowledgment order

`ServerAssetSyncService.performSync` performs these steps:

1. Fetch and parse metadata events without acknowledging them.
2. Fetch and parse asset events without acknowledging them.
3. Build active asset records, using metadata upserts from this cycle where available.
4. Persist asset upserts and asset deletions.
5. Apply metadata upserts and metadata deletions independently by Immich asset ID.
6. Persist local sync metadata.
7. Send the union of metadata and asset acknowledgments in one `/api/sync/ack` request.

If parsing, conversion, or database persistence fails, no newly returned checkpoint is acknowledged. If the acknowledgment request fails after persistence, the sync reports failure; Immich may replay the events on the next run, and all database operations remain idempotent.

## Testing

The repository currently has no XCTest target. Add a `YAIIUTests` unit-test target and cover observable regression cases:

- asset upsert without an iCloud ID preserves an existing mapping;
- asset upsert with a new iCloud ID updates the mapping;
- metadata-only upsert updates an existing cache row;
- mobile-app metadata deletion clears the mapping;
- unrelated metadata deletion leaves the mapping unchanged;
- mixed stream entities retain the latest acknowledgment for every entity type;
- stream parsing does not send acknowledgment itself;
- service acknowledgment occurs only after successful persistence.

Tests use temporary SQLite databases or isolated repository dependencies. They must not access the user's app-group database or make live Immich requests.

## Logging

Keep the current uncommitted hash timing logs. Add only aggregate sync diagnostics needed to verify the fix: metadata upsert/delete counts and acknowledgment count. Do not log complete iCloud IDs, checksums, or authentication data.

## Documentation

Update the existing sync documentation or project README section describing server cache behavior. Document that iCloud IDs are synchronized independently from asset deltas, missing metadata does not erase cached IDs, and the change does not retroactively rebuild existing null mappings.

## Out of scope

- Forced full cache rebuild or sync checkpoint reset.
- A user-facing cache rebuild control.
- Changes to upload metadata format.
- Changes to PhotoKit iCloud ID lookup.
- Repairing existing null mappings without a new Immich metadata event.
