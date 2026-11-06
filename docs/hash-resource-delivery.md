# Hash Resource Delivery

## Purpose

The foreground hash pipeline (`HashManager`) computes SHA-1 checksums of each
asset's original resources (primary JPEG/HEIC/video and optional RAW) so the
app can match them against Immich. This document describes how original bytes
are read from PhotoKit for hashing, and why.

## Design

Hashing streams bytes from `PHAssetResourceManager.requestData` straight into
SHA-1. No temp files are written.

- `HashManager.processHashItems` runs `HashManager.hashItem` for each pending
  identifier through `HashPipelinePolicy.processConcurrently`, at most
  `HashPipelinePolicy.photoKitRequestWindow` (3) assets at a time.
- `HashManager.hashItem` selects resources with `AssetResourceSelector.select(for:)`,
  takes one slot from `HashManager.photoKitRequestSlots`, passes the
  `HashMemoryPressureThrottle`, calls `HashService.streamHash(_:)`, releases the
  slot, then persists via `HashManager.persistHashResult`.
- `HashService.streamHash(_:)` hashes the primary resource and, unless the plan
  is RAW-only, the RAW resource with `ResourceStreamHasher.sha1Hex(of:)`, and
  returns a `MultiResourceHashResult`.
- `ResourceStreamHasher.sha1Hex(of:)` (`YAIIU/YAIIU/Services/ResourceFileAccess.swift`)
  wraps `requestData`. Each chunk is fed to `StreamingHashRequest` inside an
  `autoreleasepool`.
- `StreamingHashRequest` is the exactly-once continuation state machine. On
  cancellation it calls `cancelDataRequest` but resumes only when PhotoKit's
  completion handler fires, so the caller keeps its request slot until the
  request has drained. Chunks after cancellation are ignored; a completion
  error after cancellation is reported as `CancellationError`.
- `persistHashResult` re-reads the asset's PhotoKit adjustment version and
  discards the hash if the asset was edited while it was being hashed.

### Concurrency and memory bounds

- `photoKitRequestSlots` is process-wide. A cancelled request from a stopped
  run keeps its slot until PhotoKit completes, so a replacement run cannot push
  the total above `photoKitRequestWindow` concurrent requests.
- Memory is bounded by in-flight chunks of at most three requests, not by
  throughput, so there is no byte-rate limiter.
- `HashMemoryPressureThrottle` remains the safety net: after a memory warning,
  new requests pause for a cooldown and then run one at a time for the rest of
  the run.

### Logging

`HashRunStats` reports whole-run throughput, because per-asset timings mix
iCloud download latency with local work:

- `Hash run started: assets=N`
- `Hash run progress: hashed=..., failed=..., bytes=..., elapsed=..., throughput=...MiB/s`
  every `HashRunStats.progressInterval` (50) hashed assets.
- `Hash run finished: ... cancelled=...` when the run ends.

`hashed` counts delivered results, including ones discarded because the asset
was edited during hashing. `failed` counts missing assets, assets without
selectable resources, and delivery errors.

## Decisions and alternatives

- **`writeData` to a temp file, then hash the file (previous design, rejected).**
  It was adopted because an earlier iOS release retained about 10 MB per asset
  inside `PhotoLibraryServicesCore` when using `requestData`, leading to jetsam
  after a few hundred photos. It needed a disk budget that serialized assets,
  a 24 MiB/s PhotoKit rate limiter to avoid memory warnings near 58 MiB/s, a
  producer/consumer pipeline, and an extra disk write and read per resource.
- **Measurements on iOS 27.0.1 (iPhone 16 Pro)** that led to the switch:
  - `requestData` streaming, one asset at a time at 24 MiB/s: memory flat at
    about 55-90 MB over 300+ assets, including a 185 MB video in one request.
    The retention did not reproduce.
  - Three concurrent requests, same on-device assets: throughput matched the
    rate limit exactly (24.01 MiB/s, then 48.04 MiB/s when raised).
  - Without the rate limit: 192 assets (8.3 GB) in 6.5 s, 1221.64 MiB/s, with
    hashing memory flat at about 69 MB.
  - Memory spikes of 440-650 MB seen in these runs happened during the initial
    server asset sync and PhotoKit version comparison, not during hashing.
- **More than three concurrent requests (not adopted).** On-device assets are
  already CPU/IO bound at about 1.2 GB/s. iCloud-only assets are bounded by
  network bandwidth, where more parallel requests mostly share the same link.

## Limits

- Uploads (`ImmichAPIService`) still use `ResourceFileAccess.tempFile(for:)`
  and `FileHasher`, because URLSession streamed uploads need a re-readable body
  for retries.
- Hashing runs on PhotoKit's delivery callback queue. SHA-1 via CommonCrypto is
  fast enough that this does not delay delivery measurably.
- Assets stored only in iCloud are hashed at network speed; PhotoKit must
  download each original.

## Modifying safely

- Changing `photoKitRequestWindow` changes peak memory proportionally. Verify on
  a physical device: delete the app so every asset is re-hashed, skip the
  Immich database import, then watch Xcode's Debug Navigator memory gauge and
  the `Hash run progress` lines.
- Digests must stay byte-identical to `FileHasher` over the same bytes, since
  hash-cache entries are shared with uploads and imported Immich databases.
  `HashPipelinePolicyTests.testStreamingHashMatchesFileHasherForSameBytes`
  guards this.
- If `requestData` retention reappears on a future iOS release, the symptom is
  per-asset memory growth during hashing that does not return after the run.
