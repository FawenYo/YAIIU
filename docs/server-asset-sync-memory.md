# Server Asset Sync Memory

## Purpose

The first server sync after install pulls every asset the user owns from Immich
(`POST /api/sync/stream`, types `AssetMetadataV1` and `AssetsV2`). On a large
library the app peaked around 700 MB during that sync while steady-state hashing
stays at 50–100 MB. This document records where that memory went and how the
sync path now keeps it close to the size of the compact parsed result.

## Root cause

All in the initial sync path, before this change:

| Location | Problem |
|---|---|
| `ImmichAPIService.fetchAssetStream` / `fetchAssetMetadataStream` | `URLSession.shared.data(for:)` buffered the whole NDJSON response body in one `Data`. |
| `ImmichAPIService.streamObjects(from:description:)` | Split that body and decoded **every** line with `JSONSerialization` into one `[[String: Any]]` before any filtering. Each dictionary keeps all AssetV2 fields (thumbhash, dates, dimensions, ...) as Foundation objects, and the loop had no `autoreleasepool`. |
| `ServerAssetSyncService.convertBase64ToHex` | `String(format: "%02x")` per checksum byte: 20 autoreleased `NSString`s per asset, never drained inside the loop. |
| `ServerAssetSyncService.performSync` | Copied the asset list three times (`filter` active, `filter` deleted, `compactMap` records). |
| `ServerAssetRepository` write loops | `(value as NSString).utf8String` per bound column inside one `dbQueue.sync` loop; buffers that must be allocated are autoreleased and pile up until the loop returns. |

Simulator measurement with 100,000 realistic AssetV2 lines (62 MB body): the old
asset-stream parse alone added 64 MB (body) + 146 MB (decoded dictionaries).
The new streaming parse adds 36 MB in total, which is the parsed `StreamAsset`
array itself.

## Design

- **Streaming response.** Both stream fetches use `URLSession.shared.bytes(for:)`.
  Our code never accumulates the body; only URLSession's internal buffer and the
  current line are held.
  Error bodies (non-200) are still collected in full for the error message,
  as before.
- **Incremental parsers.** `AssetStreamParser` and `AssetMetadataStreamParser`
  (private, in `ImmichAPIService.swift`) hold the parse state and take one decoded
  line at a time through `consume(_:)`. Both entry points share them:
  - `parseAssetStream(_ data: Data)` / `parseAssetMetadataStream(_ data: Data)`:
    buffered input, kept for tests.
  - `parseAssetStream(_ bytes:)` / `parseAssetMetadataStream(_ bytes:)`:
    generic over any `AsyncSequence` of `UInt8`; production passes
    `URLSession.AsyncBytes`.
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
- **Single pass.** `performSync` builds `serverAssetRecords` and `deletedIds` in
  one loop, in the original order, and reads `streamResult.acks` early so the
  parsed asset list is no longer used after that loop.
- **Repository writes.** Each row's bind + step in `saveServerAssets`,
  `updateICloudIds`, `clearICloudIds`, `updateSourceChecksums`, and
  `deleteServerAssets` (both statements) runs inside an `autoreleasepool`. The
  bound pointers use `SQLITE_STATIC`, so the pool has to wrap `sqlite3_step`;
  `sqlite3_reset` and `sqlite3_clear_bindings` do not read the bound values.

### Rejected alternatives

- **Writing each batch to SQLite while the stream is still downloading.** This
  would make memory depend only on batch size. It was rejected for now because
  `performSync` must see the whole response before it mutates anything: it
  checks for `SyncResetV1` (clear and retry), runs delta checksum invalidation
  before any cache write, and does the full-sync `clearCache()` before the first
  insert. Interleaving those steps with a live network stream changes failure
  behaviour, so it should be its own change.
- **`JSONDecoder` with a narrow `Decodable` type.** It would allocate less per
  line, but a field with an unexpected JSON type would throw for the whole line,
  where `as? String` only drops that field. That changes which events are
  accepted and acked.
- **`AsyncBytes.lines`.** It also splits on `\r` and Unicode line separators,
  which differs from the old `\n` split.

## Limits

- Memory still grows with library size through the compact `[StreamAsset]`,
  `[ServerAssetRecord]`, and metadata dictionaries: about 0.35 KB per asset
  (roughly 36 MB per 100k assets), down from more than 2 KB per asset.
- In Debug builds, reading `AsyncBytes` one byte at a time is slower than
  splitting a buffered `Data`. Release builds are expected to specialize the
  generic loop for `URLSession.AsyncBytes` (not measured).

## Extending safely

- Add new event types inside the parser's `consume(_:)`. Never collect raw
  `[String: Any]` objects outside the per-line `autoreleasepool`.
- New fetches of `/api/sync/stream` should use `bytes(for:)` and the generic
  parser entry points, not `data(for:)`.
- New SQLite bulk-write loops that bind with `(value as NSString).utf8String`
  need a per-row `autoreleasepool` that wraps `sqlite3_step`.
- Tests: `SyncStreamParserTests` (streaming/buffered equivalence, final
  line with no newline, reset) and
  `ServerAssetSyncPersistenceTests.testBase64ChecksumConvertsToLowercaseHex`.

## Re-verifying on device

1. Delete YAIIU from the iPhone, then build and run it from Xcode.
2. Log in, and choose skip at the Immich database import prompt.
3. Open Xcode Debug Navigator > Memory and watch the graph during the initial
   server sync (the "Fetching / Processing / Saving" phases).
4. Compare the peak with the earlier ~700 MB on the same server and library.
