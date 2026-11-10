# PhotoKit Change Cursor Lockstep

## Purpose

The app and the background upload extension both consume PhotoKit persistent
change history (`PHPhotoLibrary.fetchPersistentChanges(since:)`), each with its
own cursor in the shared App Group database:

| Cursor | Table | Owner |
|---|---|---|
| Extension | `change_tokens` | `BackgroundUploadExtension.ingestPersistentChanges` |
| Foreground | `foreground_photo_change_state` | `PhotoLibraryManager.prepareForegroundPhotoWorkLocked` |

Before this change the two cursors were fully independent. Overnight the
extension is woken many times and walks thousands of journal events. The next
app launch then walked the same events again before hashing could start.
Enumerating the journal and reading each event's `changeDetails(for:)` costs a
few milliseconds per event, and PhotoKit records many events that touch no
asset, so a launch after a long gap was dominated by replaying history the
extension had already processed.

With lockstep, whichever process commits a journal range first applies the
effects of both consumers and advances both cursors. The other process starts
from the new position and skips that range.

## Effect sets

Both effect sets live in `Shared/PhotoChangeJournal.swift` and run on a raw
`OpaquePointer` inside the caller's transaction, so the app
(`SQLiteConnection`) and the extension (`BackgroundUploadDatabase`) execute the
same SQL.

`PhotoChangeJournal.applyBackgroundEffects(db:range:)`:
- enqueue inserted and updated assets in `background_upload_queue`
- compare adjustment versions with `hash_cache`, invalidate `hash_cache`,
  `uploaded_assets` and completed `upload_jobs` rows on real changes, and backfill
  versions on matching legacy rows
- delete completed jobs that have no matching upload receipt
- add `foreground_photo_pending_assets` candidates: inserted, invalidated, and
  updated assets without a hash
- remove deleted assets from the pending list and the upload queue

`PhotoChangeJournal.applyForegroundEffects(db:states:pendingIdentifiers:deletedIdentifiers:visitVisibleState:)`:
- the same version comparison on visible assets, recording cache diagnostics
- remove hidden assets from the pending list and add visible affected ones;
  drop pending entries whose cached version still matches
- for deleted assets, clear hash, receipt, pending and queue rows and
  `pending`/`failed` jobs
- maintain `local_photo_assets` (membership and `is_hidden`)

When both run in one commit, the background effects go first so that the
foreground comparison sees their invalidations.

## Lockstep rule

`PhotoChangeJournal.Cursors.inLockstep(at:)` holds when:

1. `change_tokens.token_data` and `foreground_photo_change_state.token_data` are
   byte-identical and equal to the token the committing range started from, and
2. `local_photo_inventory_state.is_ready = 1`. The foreground effects assume a
   complete inventory.

When the app has not created `foreground_photo_change_state` or
`local_photo_inventory_state` yet, `readCursors` reports "not in lockstep"
instead of failing. The extension can run before the app.

Equality is checked on the stored bytes, never by archiving two tokens and
comparing the results. Cursors only become equal by copying bytes (realignment)
or by writing the same `tokenData` to both rows in one transaction, so byte
equality means "same position".

### Commits

Both commit paths open `BEGIN IMMEDIATE`, so reading the cursors and writing them
cannot interleave with the other process.

`BackgroundUploadDatabase.commitPersistentChange(insertedAssetIds:updatedAssetIds:deletedAssetIds:assetStates:expectedTokenData:tokenData:allowsForegroundLockstep:)`
handles one journal event:
- returns `.failed` without writing when any updated, non-deleted asset has no
  adjustment version (unchanged rule: replay it next run)
- returns `.cursorMoved` when `change_tokens` no longer equals
  `expectedTokenData`
- otherwise applies the background effects. In lockstep it also applies the
  foreground effects and writes `foreground_photo_change_state`
  (`summary.advancedForegroundCursor == true`)
- the extension passes `allowsForegroundLockstep: false` unless the
  authorization status is `.authorized`. Under Limited Photos access the app
  never advances its own cursor, so the extension must not advance it either.

`HashCacheRepository.commitForegroundPhotoJournalWindow(range:snapshots:expectedTokenData:tokenData:)`
handles one coalesced `ForegroundPhotoChangeBatch` window:
- returns `.cursorMoved` when `foreground_photo_change_state` no longer equals
  `expectedTokenData`
- applies the foreground effects. In lockstep, and only when every updated
  asset has a version, it also applies the background effects and writes
  `change_tokens` (`.committed(advancedBackgroundCursor: true)`). If an update
  could not be versioned, only the foreground cursor advances, which ends
  lockstep. The next launch realigns.
- the background effects run inside `SAVEPOINT background_effects`. If they
  fail, the savepoint is rolled back and the window commits foreground-only,
  instead of failing the whole window into the full-snapshot fallback.

`ForegroundPhotoChangeBatch` tracks `updatedIdentifiers` separately so
`journalRange(snapshots:)` can hand the background effects the inserted/updated
split they need. Coalescing many events into one range gives the same result
as per-event commits: both effect sets read the current PhotoKit state, not
per-event history, and the window already flushes at delete/reinsert barriers.

### Conflicts

- Extension sees `.cursorMoved`: the app replayed this range in lockstep. The
  extension stops the ingestion pass and resumes from the stored cursor next run.
- App sees `.cursorMoved`: the extension advanced both cursors. The app discards
  the uncommitted window and restarts the replay from the stored cursor, up to
  `PhotoLibraryManager.maxCursorMoveRestarts` (3) times. After that it returns the
  current pending list, since the extension is still applying the foreground
  effects itself.

## Realignment

The cursors drift apart on every install, after the extension resets its own
cursor (destination change, expired history, bootstrap promotion), after
`invalidateLocalPhotoInventory`, or after a foreground window could not advance
the extension cursor.

On launch, when `change_tokens` exists and differs from the foreground cursor,
`PhotoLibraryManager.realignForegroundCursor(to:)`:

1. Decodes the extension token and probes `fetchPersistentChanges(since:)`. If
   the token is unreadable or expired, it skips realignment; the extension
   rebuilds its own cursor.
2. Takes a full hidden-inclusive snapshot (`allAssetSnapshots(includingHidden: true)`).
3. Commits `HashCacheRepository.realignForegroundPhotoChanges(snapshots:pendingIdentifiers:backgroundTokenData:)`.
   This uses the same SQL as the expired-history rebuild, but stores the
   extension's token bytes verbatim, and returns `.cursorMoved` if
   `change_tokens` changed during the snapshot.
4. Replays from the shared cursor with realignment disabled, so it cannot loop.

This is safe because the extension token was written before the snapshot was
taken. Replaying from it repeats work, and both effect sets tolerate replay,
but it never skips a change.

Realignment is skipped on the launch that creates the first foreground
checkpoint (`bootstrapForegroundPhotoWork`). That launch keeps imported hashes
and lets the version backfill run first; realignment happens on a later launch.

## Cost and limits

- Realignment costs one library enumeration of identifier, hidden state,
  modification date and adjustment version. It runs once per drift, not once
  per launch.
- While in lockstep, each extension event also fetches the state of inserted
  assets (previously only updated ones) to record their hidden state.
- Limited Photos access never reaches the replay (`.fallbackSnapshot`), so it
  never realigns or advances the extension cursor.
- When the extension is disabled but `change_tokens` still exists, the app keeps
  advancing it and enqueues `background_upload_queue` rows the extension would
  have queued. That queue is keyed by asset ID and bounded by library size.

## Extending safely

- Any new per-change effect must go into the matching function in
  `PhotoChangeJournal`. A change added to only one process's commit path is
  silently skipped whenever the other process commits in lockstep.
- Any new writer of either cursor row must run in an IMMEDIATE transaction and
  either compare the row with the token it started from, or deliberately leave
  the cursors unequal (a reset). Never write re-archived token bytes into the
  other cursor.
- Tests: `YAIIUTests/PhotoChangeCursorLockstepTests.swift` opens the app
  repository and `BackgroundUploadDatabase` on one SQLite file to exercise both
  processes.
