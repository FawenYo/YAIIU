# Server Asset Sync Memory

## Purpose

The first server sync after install pulls every asset the user owns from Immich
(`POST /api/sync/stream`, types `AssetMetadataV1` and `AssetsV2`). On a large
library the app peaked around 700 MB during that sync while steady-state hashing
stays at 50–100 MB. This document records where that memory went and how the
sync path now keeps it bounded by a fixed batch size instead of library size.

## Root cause

All in the initial sync path, before this change:

| Location | Problem |
|---|---|
| `ImmichAPIService.fetchAssetStream` / `fetchAssetMetadataStream` | `URLSession.shared.data(for:)` buffered the whole NDJSON response body in one `Data`. |
| `ImmichAPIService.streamObjects(from:description:)` | Split that body and decoded **every** line with `JSONSerialization` into one `[[String: Any]]` before any filtering. Each dictionary keeps all AssetV2 fields (thumbhash, dates, dimensions, ...) as Foundation objects, and the loop had no `autoreleasepool`. |
| `ServerAssetSyncService.convertBase64ToHex` | `String(format: "%02x")` per checksum byte: 20 autoreleased `NSString`s per asset, never drained inside the loop. |
| `ServerAssetSyncService.performSync` | Collected every parsed asset (and every metadata change) before writing anything, then copied the asset list three times (`filter` active, `filter` deleted, `compactMap` records). |
| `ServerAssetRepository` write loops | `(value as NSString).utf8String` per bound column inside one `dbQueue.sync` loop; buffers that must be allocated are autoreleased and pile up until the loop returns. |

Simulator measurement with 100,000 realistic AssetV2 lines (62 MB body): the old
asset-stream parse alone added 64 MB (body) + 146 MB (decoded dictionaries).
Streaming the parse alone brought that to 36 MB, but on device the collected
`StreamAsset` array still grew for the whole download: the memory graph showed
about 790k `CFString`s (the bridged field strings of ~130k parsed assets). The
assets and metadata are now persisted in batches while the streams download, so
that list never exceeds `ImmichAPIService.syncBatchSize` (1,000) entries.

## Design

- **Batch persistence.** `ServerAssetSyncService.performSync` runs, in order:
  1. Full sync only: `invalidateHashChecksForServerChanges(fullReset: true)`
     then `clearCache()` (which also deletes `sync_metadata`).
  2. `ImmichAPIService.streamAssets` → `persistAssetBatch` per batch: build
     records and deleted IDs in stream order; on delta, invalidate the affected
     checksums of this batch; then `saveServerAssets` and `deleteServerAssets`.
  3. `streamAssetMetadata` → `persistMetadataBatch` per batch: on delta,
     invalidate checksums whose source checksum changes; then
     `updateICloudIds`, `clearICloudIds`, `updateSourceChecksums`.
  4. `saveSyncMetadata` with the new `lastAck`, then `sendSyncAck`, then backfill.
- **Assets first, metadata second.** Metadata events update rows by
  `immich_id`, so they run after the asset rows exist. Asset records are
  written with `iCloudId: nil` and, on delta, the cached `sourceChecksum`; the
  upsert's `COALESCE` keeps cached values, and the metadata batches then set
  the new ones.
- **Staged metadata (schema v13, `server_asset_metadata_pending`).** The two
  streams are separate requests read at different times. An asset uploaded
  after the asset stream was read but before the metadata stream is missing
  from the cache when its metadata arrives. Trashed assets are missing too:
  AssetV2 with `deletedAt` removes the row, and Immich sends no metadata event
  on trash or restore. `persistAssetBatch` therefore splits deletions:
  trashed assets go through `deleteServerAssets(_:retainingMetadata: true)`,
  which first copies the row's `icloud_id` and `source_checksum` into the table
  below, so the restore upsert gets them back. `AssetDeleteV1` (permanent
  delete) uses `retainingMetadata: false`, which also drops staged metadata. `updateICloudIds`,
  `updateSourceChecksums` and `clearICloudIds` therefore write any value whose
  `UPDATE` matched no row into that table (`immich_id` primary key, latest value
  wins). `ServerAssetRepository.saveServerAssets` merges staged values into rows
  that now exist, in the same transaction, then deletes them. Without this, the
  metadata ack would advance and the server would never resend those values.
  On delta, `persistAssetBatch` also invalidates staged source checksums
  (`pendingSourceChecksums(for:)`) before the save merges them, because a hash
  check may have marked them absent in the meantime.
  `clearServerAssetsCache` empties the table along with the cache.
- **Server reset.** A `SyncResetV1` from either stream calls
  `restartAfterServerReset`: full invalidation, `clearCache()` (discarding any
  batches already written), ack only the reset, and retry once as a full sync.
  A second reset throws `SyncError.repeatedServerReset`.
- **Failure and crash safety.** Acks are sent only after every batch and
  `saveSyncMetadata` succeed. If a batch write, the network, or the app fails
  mid-stream, `lastAck` is unchanged: a delta replays the same idempotent events
  next time, and an interrupted full sync has no `sync_metadata`, so it runs as a
  full sync again. Hash checks stay correct because every cache write is
  preceded by invalidation of the checksums it can change.
  `ServerAssetVerificationGate` still keeps hash verification from reading the
  cache while a sync is in progress.
- **Progress.** Each asset batch reports `.fetchingAssets` with the running
  count, which the setup screen shows as "Fetching assets (N)".
- **Streaming response.** Both stream fetches use `URLSession.shared.bytes(for:)`
  through `openSyncStream(types:serverURL:apiKey:)`. If a batch handler throws,
  the request task is cancelled.
  Our code never accumulates the body; only URLSession's internal buffer and the
  current line are held.
  Error bodies (non-200) are still collected in full for the error message,
  as before.
- **Incremental parsers.** `AssetStreamParser` and `AssetMetadataStreamParser`
  (private, in `ImmichAPIService.swift`) hold the parse state and take one decoded
  line at a time through `consume(_:)`. Both entry points share them:
  - `parseAssetStream(_ data: Data)` / `parseAssetMetadataStream(_ data: Data)`:
    buffered input, kept for tests.
  - `parseAssetStream(_:batchSize:onBatch:)` /
    `parseAssetMetadataStream(_:batchSize:onBatch:)`: generic over any
    `AsyncSequence` of `UInt8`; production passes `URLSession.AsyncBytes`.
    They call `onBatch` each time `batchSize` items are pending and once more
    at the end, and return a `SyncStreamSummary` (acks per type, reset state).
    A metadata batch is an `AssetMetadataChanges` value.
- **Line handling.** `forEachStreamObject(in:description:_:)` splits on `\n`,
  skips empty lines, and flushes a final line that has no trailing newline. Only
  the current line is buffered. Each line is decoded in `consumeStreamLine`
  inside an `autoreleasepool`, so the Foundation objects for a line are freed
  before the next one. A trailing `\r` is left for `JSONSerialization`, which
  treats it as whitespace, the same as the old split.
- **Parsing semantics are unchanged.** The same `as? String` checks, ack
  collection (`collectLatestAck`), reset detection (`validResetAck`), and
  malformed-line logging. Tests check that the streaming and buffered parsers
  give the same result, including empty lines, CRLF, and a final line with no
  trailing newline.
- **Hex conversion.** `ServerAssetSyncService.convertBase64ToHex` (now `static`
  so it can be tested) writes lowercase hex digits into a byte buffer. Output is
  the same as before.
- **Repository writes.** Each row's bind + step in `saveServerAssets`,
  `updateICloudIds`, `clearICloudIds`, `updateSourceChecksums`, and
  `deleteServerAssets` (both statements) runs inside an `autoreleasepool`. The
  bound pointers use `SQLITE_STATIC`, so the pool has to wrap `sqlite3_step`;
  `sqlite3_reset` and `sqlite3_clear_bindings` do not read the bound values.

### Rejected alternatives

- **Buffering the whole stream, then writing.** The first version of this fix
  did that to keep the old "see everything, then mutate" order, but memory still
  grew with library size on device.
- **One SQLite transaction across all batches.** It would make the sync atomic,
  but it holds the write lock for the whole download and blocks the hash pipeline
  and the background upload extension that share the app-group database. The
  invalidate-before-write ordering plus deferred ack already makes a partial
  sync safe to replay.
- **`JSONDecoder` with a narrow `Decodable` type.** It would allocate less per
  line, but a field with an unexpected JSON type would throw for the whole line,
  where `as? String` only drops that field. That changes which events are
  accepted and acked.
- **`AsyncBytes.lines`.** It also splits on `\r` and Unicode line separators,
  which differs from the old `\n` split.

## Limits

- Memory per batch is bounded, but small per-sync state still exists: the acks
  per entity type and progress counters.
- A full sync that fails mid-stream leaves a partially rebuilt cache until the
  next sync completes. Before, it left the cache untouched, but that was another
  session's cache (a full sync only runs on first login, a user or server
  change, or a server reset).
- Within one batch, upserts are written before deletions, as in the old code.
  Across batches, events apply in stream order. Immich sends an asset's delete
  only after the row is gone, so the two never conflict in practice.
- A metadata event is acked only if it, or an earlier event for the same asset
  in the current batch, produced a change. The old code looked at the whole
  stream, so the result now depends on batch boundaries when the server sends
  the same asset twice. Only the latest ack per type is kept, so this is
  harmless.
- Staged rows stay in `server_asset_metadata_pending` while an asset is in the
  trash, and for metadata whose AssetV2 event the parser rejected (for example a
  checksum that is not valid Base64). They are removed by a restore, by a
  permanent delete, or by the next cache clear (full sync or server reset).
  Every `saveServerAssets` call merges against the whole table, so its cost
  grows with the trash size. That is expected to stay small.
- In Debug builds, reading `AsyncBytes` one byte at a time is slower than
  splitting a buffered `Data`, and uses a lot of CPU. Release builds are
  expected to specialize the generic loop for `URLSession.AsyncBytes` (not
  measured).

## Extending safely

- Add new event types inside the parser's `consume(_:)`. Never collect raw
  `[String: Any]` objects outside the per-line `autoreleasepool`.
- New fetches of `/api/sync/stream` should use `bytes(for:)` and the generic
  parser entry points, not `data(for:)`.
- New SQLite bulk-write loops that bind with `(value as NSString).utf8String`
  need a per-row `autoreleasepool` that wraps `sqlite3_step`.
- Any new cache mutation in a batch must invalidate the checksums it can
  change before writing, and must not send acks; only the end of
  `performSync` acknowledges.
- A new metadata field that updates rows by `immich_id` needs a column in
  `server_asset_metadata_pending` (added through a new migration), staging in
  its update method, and a matching `COALESCE` in `mergePendingMetadata`.
- Change the batch size with `ImmichAPIService.syncBatchSize`.
- Tests: `SyncStreamParserTests` (streaming/buffered equivalence, batch
  boundaries, handler errors stopping the stream, final line with no newline,
  reset), `ServerAssetSyncPersistenceTests` (batches written while
  streaming, per-batch invalidation before each write, staged source checksum
  invalidated before merge, no checkpoint advance after a failed batch, reset
  from either stream, repeated reset; against a real SQLite file:
  `testBatchedFullSyncWritesExpectedRowsToDatabase` and
  `testMetadataForAssetMissedByAssetStreamIsAppliedOnLaterSync`), and
  `ServerAssetRepositoryTests` (staging, merge, clearing a staged iCloud ID,
  trash keeps metadata and permanent delete drops it, cache clear). The
  real-SQLite test `testTrashedThenRestoredAssetKeepsMetadataAcrossDeltas`
  covers trash and restore across delta syncs.

## Re-verifying on device

1. Delete YAIIU from the iPhone, then build and run it from Xcode.
2. Log in, and choose skip at the Immich database import prompt.
3. Open Xcode Debug Navigator > Memory and watch the graph during the initial
   server sync ("Fetching assets (N)" counting up, then "Saving").
4. The graph should stay flat while N increases. Compare the peak with the
   earlier ~700 MB on the same server and library. In a paused memory graph,
   `CFString` should be in the thousands, not hundreds of thousands.
