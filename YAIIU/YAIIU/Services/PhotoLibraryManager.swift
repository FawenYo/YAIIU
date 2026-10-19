import Foundation
import Photos
import UIKit

/// An Apple Photos album that can be chosen as a local gallery filter.
struct PhotoAlbumOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct PhotoAssetSnapshot: Sendable {
    let localIdentifier: String
    let modificationDate: Date?
    let isHidden: Bool

    init(localIdentifier: String, modificationDate: Date?, isHidden: Bool = false) {
        self.localIdentifier = localIdentifier
        self.modificationDate = modificationDate
        self.isHidden = isHidden
    }

    /// Do not start hashing hidden photos merely because orphan cleanup includes
    /// them in its authoritative PhotoKit snapshot.
    static func visibleIdentifiers(in snapshots: [PhotoAssetSnapshot]) -> [String] {
        snapshots.filter { !$0.isHidden }.map(\.localIdentifier)
    }
}



/// Foreground startup may avoid library-wide enumeration after the initial
/// checkpoint, but Limited Photos and transient PhotoKit failures fall back to
/// the legacy snapshot (without authoritative orphan deletion).
enum ForegroundPhotoWork {
    case incremental([String])
    case fallbackSnapshot([PhotoAssetSnapshot])
    case unavailable
}

extension PhotoLibraryEnumeration {
    @discardableResult
    static func forEach<Object>(
        in result: PHFetchResult<Object>,
        shouldStop: () -> Bool = { false },
        _ body: (Object, Int) -> Void
    ) -> Bool {
        forEach(
            count: result.count, objectAt: { result.object(at: $0) },
            shouldStop: shouldStop, body
        )
    }
}

/// Manages photo library access with lazy loading for optimal memory performance.
/// Uses PHFetchResult directly instead of materializing all PHAsset objects into arrays.
final class PhotoLibraryManager: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    /// Single shared instance so authorization grants from any entry point (grid,
    /// settings toggle) propagate to every consumer.
    static let shared = PhotoLibraryManager()

    @Published var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var assetCount: Int = 0
    /// Invalidates PhotoKit-based grid filters when favorites or album membership changes.
    @Published private(set) var libraryRevision: Int = 0
    /// The grid may only interpret index-based filters against this fetch generation.
    /// Both the fetch and the identifier snapshot get the same generation.
    @Published private(set) var assetFetchGeneration: Int = 0
    /// Content-only fetch replacements preserve numeric positions. Structural
    /// changes and explicit reloads invalidate every open filtered index.
    private var indexGeneration = PhotoLibraryIndexGeneration()
    var assetIndexGeneration: Int { indexGeneration.value }
    @Published private(set) var orderedIdentifiersGeneration: Int? = nil
    /// The generation at which PhotoKit last required a nonincremental reload.
    /// A pending full reload also carries through superseding notifications.
    private(set) var fullReloadGeneration: Int = 0

    /// Local identifiers in fetch order, materialized once per library load so
    /// callers can derive counts/filters without re-enumerating the lazy
    /// PHFetchResult (which loads each PHAsset on demand and is very slow for
    /// large libraries).
    @Published private(set) var orderedLocalIdentifiers: [String] = []
    
    private var identifierScanTask: Task<[String]?, Never>?
    private var _fetchResult: PHFetchResult<PHAsset>?
    private let fetchResultLock = NSLock()
    private var albumFetchResult: PHFetchResult<PHAssetCollection>?

    /// Whether this instance is currently registered as a library change observer.
    /// Registration is deferred until access is granted so that constructing this
    /// manager (e.g. at app launch, before login) does not trigger the system photo
    /// permission prompt.
    private var isObservingLibrary = false
    
    /// Thread-safe access to fetch result
    var fetchResult: PHFetchResult<PHAsset>? {
        fetchResultLock.lock()
        defer { fetchResultLock.unlock() }
        return _fetchResult
    }
    
    private override init() {
        super.init()
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            fetchResultLock.lock()
            albumFetchResult = Self.fetchUserAlbums()
            fetchResultLock.unlock()
            fetchAssets()
            startObservingLibrary()
        }
    }

    deinit {
        identifierScanTask?.cancel()
        if isObservingLibrary {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    /// Registers as a library change observer. Accessing PHPhotoLibrary.shared() while
    /// authorization is undetermined prompts the user, so this is only called once
    /// access has been granted.
    private func startObservingLibrary() {
        guard !isObservingLibrary else { return }
        PHPhotoLibrary.shared().register(self)
        isObservingLibrary = true
    }

    /// Incrementally applies library changes so photos captured while the app was
    /// backgrounded appear on foreground without a full re-fetch.
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Album membership and favorite changes can leave the all-assets count unchanged.
        // Notify filters even if PhotoKit supplies no changes for the all-assets fetch.
        DispatchQueue.main.async { [weak self] in
            self?.libraryRevision &+= 1
        }
        fetchResultLock.lock()
        let albums = albumFetchResult
        fetchResultLock.unlock()

        if let albums,
           let albumChanges = changeInstance.changeDetails(for: albums) {
            fetchResultLock.lock()
            albumFetchResult = albumChanges.fetchResultAfterChanges
            fetchResultLock.unlock()
            Task { await AlbumSyncService.shared.syncIfEnabled() }
        }

        guard let currentResult = fetchResult,
              let changes = changeInstance.changeDetails(for: currentResult) else {
            return
        }

        let hasIncrementalChanges = changes.hasIncrementalChanges
        let insertedCount = changes.insertedIndexes?.count ?? 0
        let removedCount = changes.removedIndexes?.count ?? 0
        let hasMoves = changes.hasMoves

        // Most edits provide changedIndexes; avoid eagerly materializing
        // changedObjects on that path. Some in-place edits provide only
        // changedObjects, however, and must still invalidate their thumbnails.
        let changedIndexes = changes.changedIndexes
        var fallbackChangedIdentifiers: Set<String> = []
        if hasIncrementalChanges && (changedIndexes?.isEmpty ?? true) {
            autoreleasepool {
                for asset in changes.changedObjects {
                    fallbackChangedIdentifiers.insert(asset.localIdentifier)
                }
            }
        }

        // Skip only truly empty incremental notifications. A changedObjects-only
        // update must be published even when changedIndexes is empty.
        if hasIncrementalChanges {
            let insertedEmpty = changes.insertedIndexes?.isEmpty ?? true
            let removedEmpty = changes.removedIndexes?.isEmpty ?? true
            let changedEmpty = changedIndexes?.isEmpty ?? true
            if insertedEmpty && removedEmpty && changedEmpty &&
               !hasMoves && fallbackChangedIdentifiers.isEmpty {
                return
            }
        }

        let updatedResult = changes.fetchResultAfterChanges
        let count = updatedResult.count

        // changedIndexes uses after-state positions, including in-place edits.
        // Prefer a pooled indexed lookup; fallback identifiers were gathered
        // above only when PhotoKit did not provide any changed positions.
        var changedIdentifiers = fallbackChangedIdentifiers
        if hasIncrementalChanges, let changedIndexes, !changedIndexes.isEmpty {
            PhotoLibraryEnumeration.forEach(
                indices: changedIndexes, objectAt: { updatedResult.object(at: $0) }
            ) { asset, _ in
                changedIdentifiers.insert(asset.localIdentifier)
            }
        }
        let identifiersToInvalidate = changedIdentifiers

        // Content-only replacements retain the identifier order. Reuse a ready
        // snapshot; structural changes and unfinished snapshots need a scan.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // For nonincremental changes PhotoKit cannot identify which assets
            // changed, so all cached previews and RAW metadata must be refreshed.
            // Incremental edits keep their lightweight per-asset invalidation.
            if !hasIncrementalChanges {
                ThumbnailCache.shared.invalidateAllThumbnails()
                RAWFormatChecker.shared.clearCache()
            } else {
                for identifier in identifiersToInvalidate {
                    ThumbnailCache.shared.invalidateThumbnail(for: identifier)
                    RAWFormatChecker.shared.invalidateCachedStatus(for: identifier)
                }
            }
            // If a second PhotoKit notification supersedes an unfinished
            // nonincremental scan, the surviving generation still needs the
            // full thumbnail/metadata refresh.
            let awaitingFullReload = self.fullReloadGeneration > 0 &&
                self.fullReloadGeneration == self.assetFetchGeneration &&
                self.orderedIdentifiersGeneration != self.assetFetchGeneration
            let previousIndexGeneration = self.assetIndexGeneration
            let snapshotIsReady = self.orderedIdentifiersGeneration == self.assetFetchGeneration
            self.indexGeneration.recordChange(
                isIncremental: hasIncrementalChanges,
                insertedCount: insertedCount, removedCount: removedCount, hasMoves: hasMoves
            )
            let canReuseIdentifiers = self.indexGeneration.canReuseIdentifiers(
                from: previousIndexGeneration, snapshotIsReady: snapshotIsReady,
                snapshotCount: self.orderedLocalIdentifiers.count, assetCount: count
            )
            self.assetFetchGeneration &+= 1
            let generation = self.assetFetchGeneration
            if !hasIncrementalChanges || awaitingFullReload {
                self.fullReloadGeneration = generation
            }
            if !canReuseIdentifiers {
                self.orderedIdentifiersGeneration = nil
                self.orderedLocalIdentifiers = []
            }
            self.fetchResultLock.lock()
            self._fetchResult = updatedResult
            self.fetchResultLock.unlock()
            self.assetCount = count

            if canReuseIdentifiers {
                self.orderedIdentifiersGeneration = generation
                self.libraryRevision &+= 1
                return
            }

            let scanTask = self.startIdentifierScan(for: updatedResult)
            Task { [weak self] in
                guard let identifiers = await scanTask.value else { return }
                await MainActor.run { [weak self] in
                    guard let self,
                          self.assetFetchGeneration == generation,
                          self.fetchResult === updatedResult else { return }
                    self.orderedLocalIdentifiers = identifiers
                    self.orderedIdentifiersGeneration = generation
                    self.libraryRevision &+= 1
                }
            }
        }
    }

    /// Enumerate user-accessible albums without retaining PhotoKit collection objects in SwiftUI.
    static func availableAlbums() -> [PhotoAlbumOption] {
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .any, options: nil
        )
        var albums: [PhotoAlbumOption] = []
        albums.reserveCapacity(collections.count)
        PhotoLibraryEnumeration.forEach(in: collections) { collection, _ in
            albums.append(PhotoAlbumOption(
                id: collection.localIdentifier,
                title: collection.localizedTitle ?? ""
            ))
        }
        return albums.sorted {
            let comparison = $0.title.localizedStandardCompare($1.title)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }

    /// Use PhotoKit's native Favorites smart album, then map identifiers to the
    /// already-ordered main-library index. No PHAsset array is retained.
    static func favoriteIndices(in orderedIdentifiers: [String]) -> [Int] {
        let favorites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum, subtype: .smartAlbumFavorites, options: nil
        )
        guard let collection = favorites.firstObject else { return [] }
        return indices(in: orderedIdentifiers, collection: collection)
    }

    static func albumIndices(in orderedIdentifiers: [String], albumID: String) -> [Int] {
        let collections = PHAssetCollection.fetchAssetCollections(
            withLocalIdentifiers: [albumID], options: nil
        )
        guard let collection = collections.firstObject,
              collection.assetCollectionType == .album else { return [] }
        return indices(in: orderedIdentifiers, collection: collection)
    }

    private static func indices(in orderedIdentifiers: [String], collection: PHAssetCollection) -> [Int] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        var members = Set<String>(minimumCapacity: assets.count)
        PhotoLibraryEnumeration.forEach(in: assets, shouldStop: { Task.isCancelled }) { asset, _ in
            members.insert(asset.localIdentifier)
        }
        guard !Task.isCancelled else { return [] }
        return matchingIndices(in: orderedIdentifiers, members: members)
    }

    /// Pure indexing helper: preserves the main grid's newest-first order and
    /// excludes limited-library-inaccessible/hidden assets.
    static func matchingIndices(in orderedIdentifiers: [String], members: Set<String>) -> [Int] {
        var indices: [Int] = []
        indices.reserveCapacity(min(orderedIdentifiers.count, members.count))
        for (index, id) in orderedIdentifiers.enumerated() where members.contains(id) {
            indices.append(index)
        }
        return indices
    }

    private static func fetchUserAlbums() -> PHFetchResult<PHAssetCollection> {
        PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
    }
    
    func requestAuthorization(completion: ((PHAuthorizationStatus) -> Void)? = nil) {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if currentStatus == .authorized || currentStatus == .limited {
            DispatchQueue.main.async {
                self.authorizationStatus = currentStatus
                self.fetchResultLock.lock()
                let shouldFetchAssets = self._fetchResult == nil
                self.albumFetchResult = Self.fetchUserAlbums()
                self.fetchResultLock.unlock()
                if shouldFetchAssets {
                    self.fetchAssets()
                }
                self.startObservingLibrary()
                completion?(currentStatus)
            }
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationStatus = status
                if status == .authorized || status == .limited {
                    self.fetchResultLock.lock()
                    self.albumFetchResult = Self.fetchUserAlbums()
                    self.fetchResultLock.unlock()
                    self.fetchAssets()
                    self.startObservingLibrary()
                }
                completion?(status)
            }
        }
    }
    
    /// Fetches assets lazily - only creates PHFetchResult without materializing PHAsset objects.
    /// PHFetchResult is a lazy collection that loads assets on-demand.
    func fetchAssets() {
        Task {
            await fetchAssetsAsync()
        }
    }
    
    /// Async version of fetchAssets for proper await support in pull-to-refresh.
    @MainActor
    func fetchAssetsAsync() async {
        isLoading = true

        // Fetch the lazy PHFetchResult first. `count` is O(1), so the grid can paint
        // immediately via lazy `asset(at:)` access. Enumerating every identifier for a
        // large library takes several seconds and must not block the first paint.
        let result = await Task.detached(priority: .userInitiated) {
            let fetchOptions = PHFetchOptions()
            fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            fetchOptions.includeHiddenAssets = false
            return PHAsset.fetchAssets(with: fetchOptions)
        }.value

        indexGeneration.recordReload()
        assetFetchGeneration &+= 1
        let generation = assetFetchGeneration
        orderedIdentifiersGeneration = nil
        orderedLocalIdentifiers = []
        fetchResultLock.lock()
        _fetchResult = result
        fetchResultLock.unlock()

        assetCount = result.count
        isLoading = false

        // Build the full identifier list off the critical path. It is only needed for
        // the "not uploaded" filter/count, not for the default grid, so publishing it
        // after first paint keeps launch responsive.
        let scanTask = startIdentifierScan(for: result)
        let identifiers = await withTaskCancellationHandler {
            await scanTask.value
        } onCancel: {
            scanTask.cancel()
        }
        // A PhotoKit change may have replaced the fetch during enumeration.
        // Never let a delayed snapshot overwrite a newer fetch generation.
        guard !Task.isCancelled, let identifiers,
              assetFetchGeneration == generation, fetchResult === result else { return }
        orderedLocalIdentifiers = identifiers
        orderedIdentifiersGeneration = generation
        libraryRevision &+= 1

        await triggerFavoriteSync()
        await AlbumSyncService.shared.syncIfEnabled()
    }
    
    @MainActor
    private func startIdentifierScan(for result: PHFetchResult<PHAsset>) -> Task<[String]?, Never> {
        identifierScanTask?.cancel()
        let task = Task.detached(priority: .utility) { () -> [String]? in
            var identifiers: [String] = []
            identifiers.reserveCapacity(result.count)
            let completed = PhotoLibraryEnumeration.forEach(
                in: result, shouldStop: { Task.isCancelled }
            ) { asset, _ in
                identifiers.append(asset.localIdentifier)
            }
            return completed ? identifiers : nil
        }
        identifierScanTask = task
        return task
    }

    /// Returns the formatted date for a given asset index.
    func creationDate(at index: Int) -> Date? {
        guard let asset = asset(at: index) else { return nil }
        return asset.creationDate
    }
    
    /// Returns asset at specific index. This is the preferred way to access assets
    /// as it only materializes one PHAsset object at a time.
    func asset(at index: Int) -> PHAsset? {
        guard let result = fetchResult, index >= 0, index < result.count else {
            return nil
        }
        return result.object(at: index)
    }
    
    /// Bound temporary PhotoKit allocations when only the identifier is needed.
    func localIdentifier(at index: Int) -> String? {
        return autoreleasepool { asset(at: index)?.localIdentifier }
    }
    
    /// Returns assets within index range for batch operations.
    /// Use sparingly - prefer index-based access for UI rendering.
    func assets(in range: Range<Int>) -> [PHAsset] {
        guard let result = fetchResult else { return [] }
        let clampedRange = max(0, range.lowerBound)..<min(result.count, range.upperBound)
        guard clampedRange.lowerBound < clampedRange.upperBound else { return [] }
        
        let indexSet = IndexSet(clampedRange)
        return result.objects(at: indexSet)
    }
    
    /// Returns all identifiers with bounded temporary PhotoKit allocations.
    func allLocalIdentifiers() -> [String] {
        guard let result = fetchResult else { return [] }
        var identifiers: [String] = []
        identifiers.reserveCapacity(result.count)

        PhotoLibraryEnumeration.forEach(in: result) { asset, _ in
            identifiers.append(asset.localIdentifier)
        }
        return identifiers
    }

    /// The grid intentionally excludes hidden Photos, but orphan cleanup must
    /// compare with a hidden-inclusive snapshot or it could delete valid hashes.
    func allAssetSnapshots(includingHidden: Bool = false) -> [PhotoAssetSnapshot] {
        let result: PHFetchResult<PHAsset>
        if includingHidden {
            let options = PHFetchOptions()
            options.includeHiddenAssets = true
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            result = PHAsset.fetchAssets(with: options)
        } else {
            guard let visibleResult = fetchResult else { return [] }
            result = visibleResult
        }

        var snapshots: [PhotoAssetSnapshot] = []
        snapshots.reserveCapacity(result.count)
        PhotoLibraryEnumeration.forEach(in: result) { asset, _ in
            snapshots.append(PhotoAssetSnapshot(
                localIdentifier: asset.localIdentifier,
                modificationDate: asset.modificationDate,
                isHidden: asset.isHidden
            ))
        }
        return snapshots
    }
    
    // MARK: - Foreground PhotoKit Delta Reconciliation

    /// Independent of the background upload extension's own change cursor.
    /// Serialized because launch, foregrounding, and initial asset loading may
    /// all request a scan at nearly the same time.
    private static let foregroundChangeQueue =
        DispatchQueue(label: "com.fawenyo.yaiiu.foreground-photo-changes")

    /// Serialized with foreground PhotoKit reconciliation so an import or
    /// startup baseline cannot race a second baseline pass.
    private var hasBackfilledUnknownHashVersions = false

    /// An import can re-introduce NULL versions while the app is running.
    /// Replay any outstanding PhotoKit changes before binding imported hashes
    /// to dates; calling the baseline directly would hide an offline edit.
    func backfillUnknownHashVersionsAfterImport() {
        _ = prepareForegroundPhotoWork(forceVersionBaseline: true)
    }

    private func backfillUnknownHashVersionsLocked(
        force: Bool,
        excludingIdentifiers: Set<String> = []
    ) {
        guard force || !hasBackfilledUnknownHashVersions else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        hasBackfilledUnknownHashVersions = true

        let db = DatabaseManager.shared
        let rows = db.unversionedHashCacheRows()
        guard !rows.isEmpty else { return }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var matched = 0
        var filled = 0
        // Fetch only identifiers with NULL cached dates, never resource bytes.
        // Chunking caps temporary allocations for large Immich imports.
        for start in stride(from: 0, to: rows.count, by: 300) {
            let batch = rows[start..<min(start + 300, rows.count)]
                .filter { !excludingIdentifiers.contains($0.localIdentifier) }
            guard !batch.isEmpty else { continue }
            let checksums = Dictionary(uniqueKeysWithValues: batch.map {
                ($0.localIdentifier, $0.sha1Hash)
            })
            let assets = PHAsset.fetchAssets(
                withLocalIdentifiers: batch.map(\.localIdentifier),
                options: options
            )
            var updates: [(localIdentifier: String, sha1Hash: String, modificationDate: Date)] = []
            PhotoLibraryEnumeration.forEach(in: assets) { asset, _ in
                guard let date = asset.modificationDate,
                      let checksum = checksums[asset.localIdentifier] else { return }
                updates.append((
                    localIdentifier: asset.localIdentifier,
                    sha1Hash: checksum,
                    modificationDate: date
                ))
            }
            matched += updates.count
            filled += db.backfillUnversionedHashDates(updates)
        }
        logInfo(
            "PhotoKit hash-version baseline: unversioned=\(rows.count), foundDate=\(matched), filled=\(filled), unresolved=\(rows.count - filled)",
            category: .hash
        )
    }

    /// Call on a background queue, never on the first-paint UI path.
    /// On normal launches this reads PhotoKit persistent history plus durable
    /// unresolved IDs; it does NOT walk the entire asset library.
    func prepareForegroundPhotoWork() -> ForegroundPhotoWork {
        prepareForegroundPhotoWork(forceVersionBaseline: false)
    }

    /// Both startup and post-import reconciliation use the same serialized
    /// PhotoKit journal replay before any unknown hash receives a baseline.
    private func prepareForegroundPhotoWork(forceVersionBaseline: Bool) -> ForegroundPhotoWork {
        Self.foregroundChangeQueue.sync {
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else {
                return .unavailable
            }

            // PhotoKit Limited Photos can change its visible selection without
            // a trustworthy full-library deletion set. Never advance the full
            // cursor while the app has partial access.
            if authorization == .limited {
                return .fallbackSnapshot(allAssetSnapshots())
            }

            let db = DatabaseManager.shared
            guard let tokenData = db.loadForegroundPhotoToken(),
                  let token = try? NSKeyedUnarchiver.unarchivedObject(
                      ofClass: PHPersistentChangeToken.self, from: tokenData
                  ) else {
                return bootstrapForegroundPhotoWork()
            }

            do {
                let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
                var processedBatches = 0
                var touchedAssets = 0
                var insertedCount = 0
                var updatedCount = 0
                var deletedCount = 0
                var sampleIdentifiersLogged = 0
                var replayedIdentifiers = Set<String>()
                for change in changes {
                    let details = try change.changeDetails(for: .asset)
                    let deleted = details.deletedLocalIdentifiers
                    let affected = details.insertedLocalIdentifiers
                        .union(details.updatedLocalIdentifiers)
                        .subtracting(deleted)
                    replayedIdentifiers.formUnion(affected)
                    replayedIdentifiers.formUnion(deleted)

                    // Fetch only changed identifiers, including hidden assets to
                    // distinguish legitimate hidden updates from removals.
                    let options = PHFetchOptions()
                    options.includeHiddenAssets = true
                    let fetched = PHAsset.fetchAssets(
                        withLocalIdentifiers: Array(affected), options: options
                    )
                    var snapshots: [PhotoAssetSnapshot] = []
                    snapshots.reserveCapacity(fetched.count)
                    PhotoLibraryEnumeration.forEach(in: fetched) { asset, _ in
                        snapshots.append(PhotoAssetSnapshot(
                            localIdentifier: asset.localIdentifier,
                            modificationDate: asset.modificationDate,
                            isHidden: asset.isHidden
                        ))
                    }

                    let nextTokenData = try NSKeyedArchiver.archivedData(
                        withRootObject: change.changeToken, requiringSecureCoding: true
                    )
                    guard db.applyForegroundPhotoChanges(
                        snapshots: snapshots,
                        pendingIdentifiers: affected,
                        deletedIdentifiers: deleted,
                        tokenData: nextTokenData,
                        bootstrap: false
                    ) else {
                        logError("Failed to atomically persist foreground PhotoKit delta", category: .database)
                        return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
                    }
                    processedBatches += 1
                    touchedAssets += affected.count + deleted.count
                    insertedCount += details.insertedLocalIdentifiers.count
                    updatedCount += details.updatedLocalIdentifiers.count
                    deletedCount += deleted.count
                    // Keep aggregate counts exact but bound disk log volume
                    // when PhotoKit delivers a very large persistent change set.
                    for identifier in details.insertedLocalIdentifiers {
                        guard sampleIdentifiersLogged < 10 else { break }
                        logDebug("Foreground PhotoKit inserted: asset=\(identifier)", category: .hash)
                        sampleIdentifiersLogged += 1
                    }
                    for identifier in details.updatedLocalIdentifiers {
                        guard sampleIdentifiersLogged < 10 else { break }
                        logDebug("Foreground PhotoKit updated: asset=\(identifier)", category: .hash)
                        sampleIdentifiersLogged += 1
                    }
                }
                if processedBatches > 0 {
                    logInfo(
                        "Foreground PhotoKit delta: \(processedBatches) batch(es), \(touchedAssets) changed assets (inserted=\(insertedCount), updated=\(updatedCount), deleted=\(deletedCount))",
                        category: .hash
                    )
                }
                // Baseline only after successful, durable journal replay.
                // Updated unknown-version hashes were already invalidated.
                backfillUnknownHashVersionsLocked(
                    force: forceVersionBaseline,
                    excludingIdentifiers: replayedIdentifiers
                )
                return .incremental(visibleForegroundPendingIdentifiers())
            } catch let error as NSError
                where error.domain == PHPhotosErrorDomain &&
                    (error.code == PHPhotosError.persistentChangeTokenExpired.rawValue ||
                     error.code == PHPhotosError.persistentChangeDetailsUnavailable.rawValue) {
                logWarning("Foreground PhotoKit history expired; rebuilding checkpoint", category: .hash)
                return bootstrapForegroundPhotoWork()
            } catch {
                logWarning("Foreground PhotoKit delta unavailable: \(error.localizedDescription)", category: .hash)
                return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
            }
        }
    }

    /// A delayed extension event may re-enqueue previously hidden assets.
    /// Check only pending IDs, never the whole library, and retain
    /// temporarily unavailable IDs for a subsequent pass.
    private func visibleForegroundPendingIdentifiers() -> [String] {
        let pending = DatabaseManager.shared.getPendingForegroundPhotoIdentifiers()
        guard !pending.isEmpty else { return [] }
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let result = PHAsset.fetchAssets(withLocalIdentifiers: pending, options: options)
        var visible = Set<String>()
        var hidden = Set<String>()
        PhotoLibraryEnumeration.forEach(in: result) { asset, _ in
            if asset.isHidden {
                hidden.insert(asset.localIdentifier)
            } else {
                visible.insert(asset.localIdentifier)
            }
        }
        if !hidden.isEmpty {
            DatabaseManager.shared.discardForegroundPendingIdentifiers(hidden)
        }
        return pending.filter { visible.contains($0) }
    }

    private func bootstrapForegroundPhotoWork() -> ForegroundPhotoWork {
        logInfo("Foreground PhotoKit bootstrap started", category: .hash)
        // Capture BEFORE the full scan: edits during enumeration must replay
        // on the next delta, not disappear behind the checkpoint.
        do {
            let tokenData = try NSKeyedArchiver.archivedData(
                withRootObject: PHPhotoLibrary.shared().currentChangeToken,
                requiringSecureCoding: true
            )
            let snapshots = allAssetSnapshots(includingHidden: true)
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else {
                return .fallbackSnapshot(snapshots)
            }
            guard DatabaseManager.shared.applyForegroundPhotoChanges(
                snapshots: snapshots,
                pendingIdentifiers: Set(PhotoAssetSnapshot.visibleIdentifiers(in: snapshots)),
                deletedIdentifiers: [],
                tokenData: tokenData,
                bootstrap: true
            ) else {
                logError("Foreground PhotoKit bootstrap checkpoint persistence failed", category: .database)
                return .fallbackSnapshot(snapshots)
            }
            logInfo("Foreground PhotoKit initial checkpoint built; assets=\(snapshots.count)", category: .hash)
            return .incremental(visibleForegroundPendingIdentifiers())
        } catch {
            logWarning("Could not capture foreground PhotoKit change token: \(error.localizedDescription)", category: .hash)
            return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
        }
    }

    private func triggerFavoriteSync() async {
        await FavoriteSyncService.shared.syncFavoriteChanges()
    }
    
    func getAssetResources(for asset: PHAsset) -> [PHAssetResource] {
        return PHAssetResource.assetResources(for: asset)
    }
    
    func hasRAWResource(_ asset: PHAsset) -> Bool {
        let resources = getAssetResources(for: asset)
        return resources.contains { resource in
            let uti = resource.uniformTypeIdentifier.lowercased()
            return uti.contains("raw") || 
                   uti.contains("dng") || 
                   uti.contains("arw") || 
                   uti.contains("cr2") || 
                   uti.contains("cr3") ||
                   uti.contains("nef") ||
                   uti.contains("raf") ||
                   uti.contains("orf") ||
                   uti.contains("rw2")
        }
    }
    
    func getUploadableResources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = getAssetResources(for: asset)
        
        var jpegResource: PHAssetResource?
        var rawResource: PHAssetResource?
        var videoResource: PHAssetResource?
        
        for resource in resources {
            let uti = resource.uniformTypeIdentifier.lowercased()
            
            let isRAW = uti.contains("raw-image") ||
                        uti.contains("dng") ||
                        uti.contains("arw") ||
                        uti.contains("cr2") ||
                        uti.contains("cr3") ||
                        uti.contains("nef") ||
                        uti.contains("raf") ||
                        uti.contains("orf") ||
                        uti.contains("rw2") ||
                        resource.type == .alternatePhoto
            
            let isVideo = resource.type == .video ||
                          resource.type == .fullSizeVideo ||
                          uti.contains("video") ||
                          uti.contains("movie")
            
            let isMainPhoto = (resource.type == .photo || resource.type == .fullSizePhoto) && !isRAW
            
            if isRAW {
                if rawResource == nil || resource.type == .fullSizePhoto {
                    rawResource = resource
                }
            } else if isVideo {
                if videoResource == nil || resource.type == .fullSizeVideo {
                    videoResource = resource
                }
            } else if isMainPhoto {
                if jpegResource == nil || resource.type == .fullSizePhoto {
                    jpegResource = resource
                }
            }
        }
        
        var uploadableResources: [PHAssetResource] = []
        
        if let jpeg = jpegResource {
            uploadableResources.append(jpeg)
        }
        
        if let raw = rawResource {
            uploadableResources.append(raw)
        }
        
        if let video = videoResource {
            uploadableResources.append(video)
        }
        
        if uploadableResources.isEmpty, let firstResource = resources.first {
            uploadableResources.append(firstResource)
        }
        
        return uploadableResources
    }
    
    func isRAWResource(_ resource: PHAssetResource) -> Bool {
        let uti = resource.uniformTypeIdentifier.lowercased()
        return uti.contains("raw-image") ||
               uti.contains("dng") ||
               uti.contains("arw") ||
               uti.contains("cr2") ||
               uti.contains("cr3") ||
               uti.contains("nef") ||
               uti.contains("raf") ||
               uti.contains("orf") ||
               uti.contains("rw2") ||
               resource.type == .alternatePhoto
    }
    
    func getThumbnail(for asset: PHAsset, targetSize: CGSize = CGSize(width: 200, height: 200), completion: @escaping (UIImage?) -> Void) {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }
    
    func getMimeType(for resource: PHAssetResource) -> String {
        let uti = resource.uniformTypeIdentifier.lowercased()
        
        if uti.contains("jpeg") || uti.contains("jpg") {
            return "image/jpeg"
        } else if uti.contains("png") {
            return "image/png"
        } else if uti.contains("heic") || uti.contains("heif") {
            return "image/heic"
        } else if uti.contains("gif") {
            return "image/gif"
        } else if uti.contains("webp") {
            return "image/webp"
        } else if uti.contains("tiff") {
            return "image/tiff"
        }
        
        if uti.contains("dng") {
            return "image/x-adobe-dng"
        } else if uti.contains("arw") {
            return "image/x-sony-arw"
        } else if uti.contains("cr2") {
            return "image/x-canon-cr2"
        } else if uti.contains("cr3") {
            return "image/x-canon-cr3"
        } else if uti.contains("nef") {
            return "image/x-nikon-nef"
        } else if uti.contains("raf") {
            return "image/x-fuji-raf"
        } else if uti.contains("orf") {
            return "image/x-olympus-orf"
        } else if uti.contains("rw2") {
            return "image/x-panasonic-rw2"
        } else if uti.contains("raw") {
            return "image/x-raw"
        }
        
        if uti.contains("mpeg4") || uti.contains("mp4") {
            return "video/mp4"
        } else if uti.contains("quicktime") || uti.contains("mov") {
            return "video/quicktime"
        } else if uti.contains("avi") {
            return "video/x-msvideo"
        }
        
        return "application/octet-stream"
    }
    
    func getFilename(for resource: PHAssetResource) -> String {
        return resource.resolvedFilename()
    }
}
