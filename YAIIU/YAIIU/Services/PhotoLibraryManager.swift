import Foundation
import Photos
import UIKit

/// An Apple Photos album that can be chosen as a local gallery filter.
struct PhotoAlbumOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct PhotoAssetResourceSnapshot: Sendable, Equatable {
    let typeDescription: String
    let uniformTypeIdentifier: String
    let originalFilename: String
    let fileSize: Int64?

    static func makeFingerprint(
        resources: [PhotoAssetResourceSnapshot],
        hasAdjustments: Bool,
        adjustmentFormatIdentifier: String?,
        mediaType: Int,
        mediaSubtypes: UInt64
    ) -> String? {
        guard !resources.isEmpty else { return nil }
        let resourceValues = resources
            .sorted {
                ($0.typeDescription, $0.uniformTypeIdentifier, $0.originalFilename, $0.fileSize ?? -1)
                    < ($1.typeDescription, $1.uniformTypeIdentifier, $1.originalFilename, $1.fileSize ?? -1)
            }
            .map { resource in
                let size = resource.fileSize.map(String.init) ?? "nil"
                return "\(resource.typeDescription)/\(resource.uniformTypeIdentifier)/\(resource.originalFilename)/\(size)"
            }
            .joined(separator: ";")
        return "v1|adjustments=\(hasAdjustments)|format=\(adjustmentFormatIdentifier ?? "nil")|mediaType=\(mediaType)|mediaSubtypes=\(mediaSubtypes)|resources=\(resourceValues)"
    }
}

// PhotoKit exposes resource metadata but no public byte-version identifier.
// This signature intentionally suppresses metadata/iCloud-only update storms;
// a same-metadata byte replacement cannot be distinguished without reading and
// hashing resource bytes, which would recreate the startup cost this policy avoids.

struct PhotoAssetSnapshot: Sendable {
    let localIdentifier: String
    let modificationDate: Date?
    let isHidden: Bool
    let creationDate: Date?
    let isFavorite: Bool
    let hasAdjustments: Bool
    let adjustmentFormatIdentifier: String?
    let mediaType: Int
    let mediaSubtypes: UInt64
    let resourceFingerprint: String?
    let resources: [PhotoAssetResourceSnapshot]

    init(
        localIdentifier: String,
        modificationDate: Date?,
        isHidden: Bool = false,
        creationDate: Date? = nil,
        isFavorite: Bool = false,
        hasAdjustments: Bool = false,
        adjustmentFormatIdentifier: String? = nil,
        mediaType: Int = 0,
        mediaSubtypes: UInt64 = 0,
        resourceFingerprint: String? = nil,
        resources: [PhotoAssetResourceSnapshot] = []
    ) {
        self.localIdentifier = localIdentifier
        self.modificationDate = modificationDate
        self.isHidden = isHidden
        self.creationDate = creationDate
        self.isFavorite = isFavorite
        self.hasAdjustments = hasAdjustments
        self.adjustmentFormatIdentifier = adjustmentFormatIdentifier
        self.mediaType = mediaType
        self.mediaSubtypes = mediaSubtypes
        self.resourceFingerprint = resourceFingerprint
        self.resources = resources
    }

    init(
        asset: PHAsset,
        includeResourceFingerprint: Bool = false,
        includeResourceDiagnostics: Bool = true
    ) {
        let resourceSnapshots = includeResourceFingerprint
            ? PHAssetResource.assetResources(for: asset).map { resource in
                PhotoAssetResourceSnapshot(
                    typeDescription: String(describing: resource.type),
                    uniformTypeIdentifier: resource.uniformTypeIdentifier,
                    originalFilename: resource.originalFilename,
                    fileSize: (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
                )
            }
            : []
        self.init(
            localIdentifier: asset.localIdentifier,
            modificationDate: asset.modificationDate,
            isHidden: asset.isHidden,
            creationDate: asset.creationDate,
            isFavorite: asset.isFavorite,
            hasAdjustments: asset.hasAdjustments,
            adjustmentFormatIdentifier: asset.adjustmentFormatIdentifier,
            mediaType: asset.mediaType.rawValue,
            mediaSubtypes: UInt64(asset.mediaSubtypes.rawValue),
            resourceFingerprint: PhotoAssetResourceSnapshot.makeFingerprint(
                resources: resourceSnapshots,
                hasAdjustments: asset.hasAdjustments,
                adjustmentFormatIdentifier: asset.adjustmentFormatIdentifier,
                mediaType: asset.mediaType.rawValue,
                mediaSubtypes: UInt64(asset.mediaSubtypes.rawValue)
            ),
            resources: includeResourceDiagnostics ? resourceSnapshots : []
        )
    }

    static func resourceFingerprint(for asset: PHAsset) -> String? {
        resourceFingerprint(for: asset, resources: PHAssetResource.assetResources(for: asset))
    }

    static func resourceFingerprint(for asset: PHAsset, resources: [PHAssetResource]) -> String? {
        let resourceSnapshots = resources.map { resource in
            PhotoAssetResourceSnapshot(
                typeDescription: String(describing: resource.type),
                uniformTypeIdentifier: resource.uniformTypeIdentifier,
                originalFilename: resource.originalFilename,
                fileSize: (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
            )
        }
        return PhotoAssetResourceSnapshot.makeFingerprint(
            resources: resourceSnapshots,
            hasAdjustments: asset.hasAdjustments,
            adjustmentFormatIdentifier: asset.adjustmentFormatIdentifier,
            mediaType: asset.mediaType.rawValue,
            mediaSubtypes: UInt64(asset.mediaSubtypes.rawValue)
        )
    }

    func diagnosticSummary(storedModificationDate: Date?) -> String {
        func timestamp(_ date: Date?) -> String {
            guard let date else { return "nil" }
            return String(format: "%.1f", date.timeIntervalSince1970)
        }

        let resourceSummary = resources.map { resource in
            let size = resource.fileSize.map(String.init) ?? "nil"
            return "\(resource.typeDescription)/\(resource.uniformTypeIdentifier)/\(resource.originalFilename)/\(size)"
        }.joined(separator: ",")
        return "Foreground PhotoKit asset metadata: asset=\(localIdentifier), storedModificationDate=\(timestamp(storedModificationDate)), currentModificationDate=\(timestamp(modificationDate)), creationDate=\(timestamp(creationDate)), favorite=\(isFavorite), hidden=\(isHidden), hasAdjustments=\(hasAdjustments), adjustmentFormatIdentifier=\(adjustmentFormatIdentifier ?? "nil"), mediaType=\(mediaType), mediaSubtypes=\(mediaSubtypes), resources=[\(resourceSummary)]"
    }

    /// Do not start hashing hidden photos merely because orphan cleanup includes
    /// them in its authoritative PhotoKit snapshot.
    static func visibleIdentifiers(in snapshots: [PhotoAssetSnapshot]) -> [String] {
        snapshots.filter { !$0.isHidden }.map(\.localIdentifier)
    }
}

struct PhotoKitBaselineProgress: Equatable, Sendable {
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(completed) / Double(total)))
    }

    var isComplete: Bool {
        completed >= total && total > 0
    }
}



/// Bounded PhotoKit journal window. Coalesce historical updates before
/// requesting expensive PHAssetResource metadata: on devices with large
/// libraries, repeated iCloud/metadata updates can span thousands of journal
/// events. Each flush persists its cursor atomically with the work it represents.
/// The distinct-ID cap also bounds native PhotoKit snapshots and memory use.
struct ForegroundPhotoChangeBatch {
    static let maxChangeBatches = 4096
    static let maxChangedIdentifiers = 4096

    private(set) var affectedIdentifiers = Set<String>()
    private(set) var deletedIdentifiers = Set<String>()
    private(set) var tokenData: Data?
    private(set) var changeCount = 0

    var hasPending: Bool { tokenData != nil }

    /// Deletion is an ordering barrier only when an identifier crosses from
    /// update to delete or from delete to insert/update. Unrelated deletions
    /// can be coalesced into this window without an extra PhotoKit fetch.
    func requiresFlushBefore(
        adding affected: Set<String>,
        deleting deleted: Set<String>
    ) -> Bool {
        hasPending && (
            !affected.isDisjoint(with: deletedIdentifiers) ||
            !deleted.isDisjoint(with: affectedIdentifiers)
        )
    }

    var shouldFlush: Bool {
        changeCount >= Self.maxChangeBatches ||
            affectedIdentifiers.count + deletedIdentifiers.count >= Self.maxChangedIdentifiers
    }

    mutating func append(
        affected: Set<String>,
        deleted: Set<String>,
        tokenData: Data
    ) {
        affectedIdentifiers.formUnion(affected)
        deletedIdentifiers.formUnion(deleted)
        self.tokenData = tokenData
        changeCount += 1
    }

    mutating func reset() {
        self = Self()
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
    @Published private(set) var foregroundBaselineProgress: PhotoKitBaselineProgress?
    /// Invalidates PhotoKit-based grid filters when favorites or album membership changes.
    @Published private(set) var libraryRevision: Int = 0
    /// A live PhotoKit event makes the persisted inventory potentially stale
    /// until the foreground journal has been replayed through that event.
    @Published private(set) var inventoryChangeRevision: Int = 0
    @Published private(set) var reconciledInventoryRevision: Int = 0

    var isInventoryReconciled: Bool {
        inventoryChangeRevision == reconciledInventoryRevision
    }

    @MainActor
    func acknowledgeInventoryReconciliation(through revision: Int) {
        guard revision <= inventoryChangeRevision else { return }
        if revision > reconciledInventoryRevision {
            reconciledInventoryRevision = revision
        }
    }
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

    /// Local identifiers in fetch order, built on demand for indexed filters
    /// and identity reconciliation. The default grid counts with bounded queries.
    @Published private(set) var orderedLocalIdentifiers: [String] = []
    
    private var identifierScanTask: Task<[String]?, Never>?
    @MainActor private var identifierScanGeneration: Int?
    @MainActor private var wantsIdentifierSnapshot = false
    private var isFetchScheduled = false
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
            // Publish invalidation before changing the grid fetch generation.
            // Consumers must not display SQLite badge data from the old cursor.
            self.inventoryChangeRevision &+= 1
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

            if self.wantsIdentifierSnapshot {
                self.requestIdentifierSnapshot()
            }
            self.libraryRevision &+= 1
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
    
    /// Settings may change Photos permission while this singleton is alive.
    /// Invalidate the inventory badge before reloading the visible fetch.
    @MainActor
    func refreshAuthorizationStatus() {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current != authorizationStatus else { return }
        authorizationStatus = current
        inventoryChangeRevision &+= 1
        if current == .authorized || current == .limited {
            // A Settings grant can occur after initialization while Photos
            // access was denied. Mirror requestAuthorization's setup: the
            // initial fetch alone does not subscribe to future PHChange events.
            fetchResultLock.lock()
            albumFetchResult = Self.fetchUserAlbums()
            fetchResultLock.unlock()
            startObservingLibrary()
            fetchAssets()
        }
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
        fetchResultLock.lock()
        guard !isFetchScheduled else {
            fetchResultLock.unlock()
            return
        }
        isFetchScheduled = true
        fetchResultLock.unlock()
        Task {
            defer { finishScheduledFetch() }
            await fetchAssetsAsync()
        }
    }

    private func finishScheduledFetch() {
        fetchResultLock.lock()
        isFetchScheduled = false
        fetchResultLock.unlock()
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
        orderedIdentifiersGeneration = nil
        orderedLocalIdentifiers = []
        fetchResultLock.lock()
        _fetchResult = result
        fetchResultLock.unlock()

        assetCount = result.count
        isLoading = false

        // The default grid needs only the lazy fetch. Build full positions only
        // after an indexed filter or detail reconciliation requests them.
        if wantsIdentifierSnapshot {
            requestIdentifierSnapshot()
        }
        libraryRevision &+= 1

        await triggerFavoriteSync()
        await AlbumSyncService.shared.syncIfEnabled()
    }
    
    /// Detail can use its original valid positions immediately. Later library
    /// changes must build an identity snapshot before reconciling moved assets.
    @MainActor
    func requireIdentifierSnapshotsForChanges() {
        wantsIdentifierSnapshot = true
    }

    @MainActor
    func requestIdentifierSnapshot() {
        wantsIdentifierSnapshot = true
        guard !isLoading, let result = fetchResult,
              orderedIdentifiersGeneration != assetFetchGeneration,
              identifierScanGeneration != assetFetchGeneration else { return }
        let generation = assetFetchGeneration
        identifierScanGeneration = generation
        let scanTask = startIdentifierScan(for: result)
        Task { [weak self] in
            let identifiers = await scanTask.value
            guard let self, self.assetFetchGeneration == generation,
                  self.fetchResult === result else { return }
            self.identifierScanGeneration = nil
            guard let identifiers else { return }
            self.orderedLocalIdentifiers = identifiers
            self.orderedIdentifiersGeneration = generation
            self.libraryRevision &+= 1
        }
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
                asset: asset,
                includeResourceFingerprint: true,
                includeResourceDiagnostics: false
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
        // Imports can add unversioned hashes while a different task is
        // performing cloud verification. Reconcile/invalidate those hashes
        // under the same gate before a server check can trust them.
        // Keep this work off the importer's/UI's completion path.
        Task.detached(priority: .utility) { [weak self] in
            await ServerAssetVerificationGate.shared.acquire()
            guard let self else {
                await ServerAssetVerificationGate.shared.release()
                return
            }
            _ = self.prepareForegroundPhotoWork(forceVersionBaseline: true)
            await ServerAssetVerificationGate.shared.release()
        }
    }

    private func backfillUnknownHashVersionsLocked(
        force: Bool,
        excludingIdentifiers: Set<String> = []
    ) {
        guard force || !hasBackfilledUnknownHashVersions else { return }
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized else { return }
        hasBackfilledUnknownHashVersions = true

        let db = DatabaseManager.shared
        let rows = db.hashCacheRowsNeedingPhotoKitBaseline()
        guard !rows.isEmpty else { return }
        publishForegroundBaselineProgress(
            PhotoKitBaselineProgress(completed: 0, total: rows.count)
        )
        defer {
            publishForegroundBaselineProgress(nil)
            // Background baseline may invalidate old-date hashes after the
            // first hash run has started. Trigger another durable pending pass
            // so those assets are not stranded until the next app launch.
            DispatchQueue.main.async { [weak self] in
                self?.inventoryChangeRevision &+= 1
            }
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var matched = 0
        var filled = 0
        // Fetch only identifiers missing PhotoKit metadata, never resource bytes.
        // Chunking caps temporary allocations for large Immich imports.
        for start in stride(from: 0, to: rows.count, by: 300) {
            let end = min(start + 300, rows.count)
            let batch = rows[start..<end]
                .filter { !excludingIdentifiers.contains($0.localIdentifier) }
            if batch.isEmpty {
                publishForegroundBaselineProgress(
                    PhotoKitBaselineProgress(completed: end, total: rows.count)
                )
                continue
            }
            let checksums = Dictionary(uniqueKeysWithValues: batch.map {
                ($0.localIdentifier, $0.sha1Hash)
            })
            let assets = PHAsset.fetchAssets(
                withLocalIdentifiers: batch.map(\.localIdentifier),
                options: options
            )
            var updates: [(
                localIdentifier: String,
                sha1Hash: String,
                modificationDate: Date?,
                resourceFingerprint: String
            )] = []
            PhotoLibraryEnumeration.forEach(in: assets) { asset, _ in
                // Never erase a hidden photo's legacy upload receipt: hidden
                // resources are not eligible for foreground re-hashing.
                guard !asset.isHidden,
                      let checksum = checksums[asset.localIdentifier],
                      let resourceFingerprint = PhotoAssetResourceFingerprint.make(for: asset) else { return }
                updates.append((
                    localIdentifier: asset.localIdentifier,
                    sha1Hash: checksum,
                    modificationDate: asset.modificationDate,
                    resourceFingerprint: resourceFingerprint
                ))
            }
            matched += updates.count
            filled += db.backfillPhotoKitVersionMetadata(updates)
            publishForegroundBaselineProgress(
                PhotoKitBaselineProgress(
                    completed: end,
                    total: rows.count
                )
            )
        }
        logInfo(
            "PhotoKit hash-version baseline: needingMetadata=\(rows.count), foundFingerprint=\(matched), filled=\(filled), unresolved=\(rows.count - filled)",
            category: .hash
        )
    }

    private func publishForegroundBaselineProgress(_ progress: PhotoKitBaselineProgress?) {
        DispatchQueue.main.async { [weak self] in
            self?.foregroundBaselineProgress = progress
        }
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
            let result = prepareForegroundPhotoWorkLocked()
            // Caller holds ServerAssetVerificationGate across this method.
            // Backfill may invalidate old checksums; never let server
            // verification bind an iCloud ID using one of those stale hashes.
            // This still executes on PhotoGrid's detached utility task, not
            // on the UI thread. Each SQLite window commits independently.
            if case .incremental = result {
                backfillUnknownHashVersionsLocked(force: forceVersionBaseline)
            }
            return result
        }
    }

    private func prepareForegroundPhotoWorkLocked() -> ForegroundPhotoWork {
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
            guard let tokenData = db.loadForegroundPhotoToken() else {
                // Only a genuinely absent checkpoint is a first-time upgrade.
                // Keep old evidence and build the cheap ID-only inventory.
                let work = bootstrapForegroundPhotoWork()
                if case .incremental = work {
                    return prepareForegroundPhotoWorkLocked()
                }
                return work
            }
            guard let token = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: PHPersistentChangeToken.self, from: tokenData
            ) else {
                // A corrupt existing cursor may hide offline content edits:
                // rebuild resource evidence rather than silently trusting it.
                logWarning("Foreground PhotoKit checkpoint unreadable; validating all versions", category: .hash)
                return rebuildExpiredForegroundPhotoHistory()
            }

            // Existing installations have a cursor but no complete local ID
            // inventory. Seed the lightweight membership once, then replay
            // the OLD cursor: changes during the scan cannot be missed.
            let needsInventoryBootstrap = !db.isLocalPhotoInventoryReady()
            if needsInventoryBootstrap {
                guard bootstrapLocalPhotoInventory() else {
                    logWarning("Local PhotoKit inventory bootstrap incomplete; retry on next run", category: .hash)
                    return .unavailable
                }
            }

            do {
                let changes = try PHPhotoLibrary.shared().fetchPersistentChanges(since: token)
                var processedBatches = 0
                var touchedAssets = 0
                var insertedCount = 0
                var updatedCount = 0
                var deletedCount = 0
                var emptyAssetBatches = 0
                var uniqueUpdatedIdentifiers = Set<String>()
                var sampleIdentifiersLogged = 0
                var window = ForegroundPhotoChangeBatch()
                var committedWindows = 0
                var fetchedSnapshotCount = 0
                var totalPhotoKitElapsed: TimeInterval = 0
                var totalSQLiteElapsed: TimeInterval = 0
                var unresolvedLookups = 0
                let replayStartedAt = Date()

                // Apply a bounded window using PhotoKit's latest PHAsset state.
                // Keeping the cursor in the same SQLite transaction as pending
                // identifiers prevents crashes from skipping unprocessed assets.
                func flushWindow() -> Bool {
                    guard let tokenData = window.tokenData else { return true }
                    let startedAt = Date()
                    let options = PHFetchOptions()
                    options.includeHiddenAssets = true
                    let identifiers = Array(window.affectedIdentifiers)
                    var snapshots: [PhotoAssetSnapshot] = []
                    snapshots.reserveCapacity(identifiers.count)
                    // A single persistent-change batch can contain thousands of
                    // IDs even when the logical journal window is capped at 512.
                    // Bound native PHFetchResult allocations without splitting
                    // the atomic SQLite cursor+work transaction.
                    for start in stride(from: 0, to: identifiers.count, by: 300) {
                        let end = min(start + 300, identifiers.count)
                        // Larger coalescing windows still keep native PhotoKit
                        // objects short-lived. Only value snapshots survive.
                        autoreleasepool {
                            let fetched = PHAsset.fetchAssets(
                                withLocalIdentifiers: Array(identifiers[start..<end]),
                                options: options
                            )
                            PhotoLibraryEnumeration.forEach(in: fetched) { asset, _ in
                                snapshots.append(PhotoAssetSnapshot(
                                    asset: asset,
                                    includeResourceFingerprint: true,
                                    includeResourceDiagnostics: snapshots.count < 10
                                ))
                            }
                        }
                    }
                    let photoKitElapsed = Date().timeIntervalSince(startedAt)
                    totalPhotoKitElapsed += photoKitElapsed
                    fetchedSnapshotCount += snapshots.count
                    unresolvedLookups += max(0, identifiers.count - snapshots.count)
                    guard db.applyForegroundPhotoChanges(
                        snapshots: snapshots,
                        pendingIdentifiers: window.affectedIdentifiers,
                        deletedIdentifiers: window.deletedIdentifiers,
                        tokenData: tokenData,
                        bootstrap: false
                    ) else {
                        logError("Failed to atomically persist foreground PhotoKit delta", category: .database)
                        return false
                    }
                    committedWindows += 1
                    let totalElapsed = Date().timeIntervalSince(startedAt)
                    totalSQLiteElapsed += max(0, totalElapsed - photoKitElapsed)
                    if totalElapsed >= 1 || identifiers.count >= 300 {
                        logInfo(
                            "Foreground PhotoKit window: events=\(window.changeCount), " +
                            "changedIDs=\(identifiers.count), fetched=\(snapshots.count), " +
                            "photoKit=\(String(format: "%.1f", photoKitElapsed))s, " +
                            "sqlite=\(String(format: "%.1f", totalElapsed - photoKitElapsed))s",
                            category: .hash
                        )
                    }
                    window.reset()
                    return true
                }

                for change in changes {
                    let details = try change.changeDetails(for: .asset)
                    let deleted = details.deletedLocalIdentifiers
                    let affected = details.insertedLocalIdentifiers
                        .union(details.updatedLocalIdentifiers)
                        .subtracting(deleted)

                    // A deletion is a barrier: never merge an earlier update
                    // with a later deletion/reinsertion of the same identifier.
                    if window.requiresFlushBefore(adding: affected, deleting: deleted)
                        && !flushWindow() {
                        _ = db.invalidateLocalPhotoInventory()
                        return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
                    }

                    let nextTokenData = try NSKeyedArchiver.archivedData(
                        withRootObject: change.changeToken, requiringSecureCoding: true
                    )
                    window.append(affected: affected, deleted: deleted, tokenData: nextTokenData)
                    uniqueUpdatedIdentifiers.formUnion(details.updatedLocalIdentifiers)

                    processedBatches += 1
                    touchedAssets += affected.count + deleted.count
                    insertedCount += details.insertedLocalIdentifiers.count
                    updatedCount += details.updatedLocalIdentifiers.count
                    deletedCount += deleted.count
                    if affected.isEmpty && deleted.isEmpty {
                        emptyAssetBatches += 1
                    }

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

                    // Empty-asset batches still advance the checkpoint, but no
                    // longer trigger a separate SQLite transaction each time.
                    if !deleted.isEmpty || window.shouldFlush {
                        guard flushWindow() else {
                            _ = db.invalidateLocalPhotoInventory()
                            return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
                        }
                    }
                }
                guard flushWindow() else {
                    _ = db.invalidateLocalPhotoInventory()
                    return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
                }
                if processedBatches > 0 {
                    logInfo(
                        "Foreground PhotoKit delta: \(processedBatches) batch(es), \(touchedAssets) changed assets (inserted=\(insertedCount), updated=\(updatedCount), deleted=\(deletedCount)); emptyAssetBatches=\(emptyAssetBatches), uniqueUpdated=\(uniqueUpdatedIdentifiers.count), repeatedUpdateEvents=\(updatedCount - uniqueUpdatedIdentifiers.count), resourceSnapshots=\(fetchedSnapshotCount), unresolvedLookups=\(unresolvedLookups), sqliteWindows=\(committedWindows), photoKit=\(String(format: "%.1f", totalPhotoKitElapsed))s, sqlite=\(String(format: "%.1f", totalSQLiteElapsed))s, elapsed=\(String(format: "%.1f", Date().timeIntervalSince(replayStartedAt)))s",
                        category: .hash
                    )
                }
                // Version backfill runs on the serialized queue after this replay.
                let pendingStartedAt = Date()
                let pendingIdentifiers = visibleForegroundPendingIdentifiers()
                logInfo(
                    "Foreground PhotoKit post-replay: baseline=deferred, " +
                    "pendingReconciliation=\(String(format: "%.1f", Date().timeIntervalSince(pendingStartedAt)))s, " +
                    "queued=\(pendingIdentifiers.count)",
                    category: .hash
                )
                // Existing installations seed IDs BEFORE replaying the old
                // PhotoKit token. Do not advertise readiness until replay wins.
                if needsInventoryBootstrap && !db.finishLocalPhotoInventoryBootstrap() {
                    logError("Failed to finalize local PhotoKit inventory", category: .database)
                    return .unavailable
                }
                return .incremental(pendingIdentifiers)
            } catch let error as NSError
                where error.domain == PHPhotosErrorDomain &&
                    (error.code == PHPhotosError.persistentChangeTokenExpired.rawValue ||
                     error.code == PHPhotosError.persistentChangeDetailsUnavailable.rawValue) {
                logWarning("Foreground PhotoKit history expired; rebuilding version evidence", category: .hash)
                return rebuildExpiredForegroundPhotoHistory()
            } catch {
                logWarning("Foreground PhotoKit delta unavailable: \(error.localizedDescription)", category: .hash)
                _ = db.invalidateLocalPhotoInventory()
                return .fallbackSnapshot(allAssetSnapshots(includingHidden: true))
            }
    }

    /// A delayed extension event may re-enqueue previously hidden assets.
    /// Check only pending IDs, never the whole library, and retain
    /// temporarily unavailable IDs for a subsequent pass.
    private func visibleForegroundPendingIdentifiers() -> [String] {
        let startedAt = Date()
        let db = DatabaseManager.shared
        // The journal has already reconciled changed assets and updated the
        // inventory. A visible pending ID without a hash or receipt has no
        // existing resource evidence to invalidate, so it can go straight to
        // the hash pipeline without another PhotoKit resource enumeration.
        // On an incomplete inventory or SQL error, retain the old full check.
        let classified = db.isLocalPhotoInventoryReady()
            ? db.classifyForegroundPendingIdentifiers()
            : nil
        let knownVisible = classified?.visibleWithoutEvidence ?? []
        let knownHidden = classified?.hidden ?? []
        let needsPhotoKit = classified?.needsPhotoKit
            ?? db.getPendingForegroundPhotoIdentifiers()
        guard !knownVisible.isEmpty || !knownHidden.isEmpty || !needsPhotoKit.isEmpty else {
            return []
        }

        if !knownHidden.isEmpty && !db.discardForegroundPendingIdentifiers(knownHidden) {
            // Do not hand off stale hidden work if its durable cleanup failed.
            logWarning("Failed to discard known-hidden foreground pending work", category: .hash)
            return []
        }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        var output = knownVisible
        var fetchedVisible = 0
        var missingFromPhotoKit = 0
        var fetchSetupElapsed: TimeInterval = 0
        var snapshotEnumerationElapsed: TimeInterval = 0
        var sqliteReconciliationElapsed: TimeInterval = 0
        // Verify only IDs with an existing hash/receipt or unknown inventory
        // membership. Chunk both native PhotoKit objects AND SQLite writes;
        // do not retain a library-sized array of PHAsset snapshots.
        for start in stride(from: 0, to: needsPhotoKit.count, by: 300) {
            let end = min(start + 300, needsPhotoKit.count)
            let identifiers = Array(needsPhotoKit[start..<end])
            let fetchStartedAt = Date()
            let result = PHAsset.fetchAssets(
                withLocalIdentifiers: identifiers, options: options
            )
            fetchSetupElapsed += Date().timeIntervalSince(fetchStartedAt)
            let enumerationStartedAt = Date()
            var visible = Set<String>()
            var hidden = Set<String>()
            var snapshots = [PhotoAssetSnapshot]()
            snapshots.reserveCapacity(result.count)
            PhotoLibraryEnumeration.forEach(in: result) { asset, _ in
                if asset.isHidden {
                    hidden.insert(asset.localIdentifier)
                } else {
                    visible.insert(asset.localIdentifier)
                    snapshots.append(PhotoAssetSnapshot(
                        asset: asset,
                        includeResourceFingerprint: true,
                        includeResourceDiagnostics: false
                    ))
                }
            }
            snapshotEnumerationElapsed += Date().timeIntervalSince(enumerationStartedAt)
            missingFromPhotoKit += max(0, identifiers.count - result.count)
            let reconcileStartedAt = Date()
            if !hidden.isEmpty && !db.discardForegroundPendingIdentifiers(hidden) {
                logWarning("Failed to discard hidden foreground pending work", category: .hash)
                return []
            }
            let retained = db.reconcileForegroundPendingAssets(snapshots: snapshots)
            sqliteReconciliationElapsed += Date().timeIntervalSince(reconcileStartedAt)
            fetchedVisible += visible.count
            output.append(contentsOf: identifiers.filter {
                visible.contains($0) && retained.contains($0)
            })
        }
        logInfo(
            "Foreground pending reconciliation: knownVisible=\(knownVisible.count), " +
            "knownHidden=\(knownHidden.count), verifiedWithPhotoKit=\(needsPhotoKit.count), " +
            "fetchedVisible=\(fetchedVisible), temporarilyMissing=\(missingFromPhotoKit), " +
            "returned=\(output.count), elapsed=\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))s, " +
            "fetchSetup=\(String(format: "%.1f", fetchSetupElapsed))s, " +
            "snapshotEnumeration=\(String(format: "%.1f", snapshotEnumerationElapsed))s, " +
            "sqliteReconciliation=\(String(format: "%.1f", sqliteReconciliationElapsed))s",
            category: .hash
        )
        return output
    }

    /// One-time upgrade: only stream PhotoKit IDs + hidden flags in 300-item
    /// windows. Never enumerate full PHAssetSnapshot contents or advance the
    /// existing foreground change token here.
    private func bootstrapLocalPhotoInventory() -> Bool {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        let assets = PHAsset.fetchAssets(with: options)
        let db = DatabaseManager.shared
        guard db.beginLocalPhotoInventoryBootstrap() else { return false }
        publishForegroundBaselineProgress(PhotoKitBaselineProgress(completed: 0, total: assets.count))
        defer { publishForegroundBaselineProgress(nil) }
        var processed = 0
        var batch: [(identifier: String, isHidden: Bool)] = []
        batch.reserveCapacity(300)
        var succeeded = true
        let completed = PhotoLibraryEnumeration.forEach(
            in: assets, shouldStop: { !succeeded }
        ) { asset, _ in
            batch.append((asset.localIdentifier, asset.isHidden))
            processed += 1
            if batch.count == 300 {
                if !db.appendLocalPhotoInventoryBatch(batch) { succeeded = false }
                batch.removeAll(keepingCapacity: true)
                publishForegroundBaselineProgress(PhotoKitBaselineProgress(completed: processed, total: assets.count))
            }
        }
        guard completed, succeeded,
              PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              db.appendLocalPhotoInventoryBatch(batch) else { return false }
        publishForegroundBaselineProgress(PhotoKitBaselineProgress(completed: assets.count, total: assets.count))

        // The caller must first replay the old token (including events that
        // arrived during this enumeration) before committing readiness.
        logInfo("Local PhotoKit inventory baseline staged: assets=\(assets.count)", category: .hash)
        return true
    }

    /// An expired token is different from a first-time upgrade: the unseen
    /// edits must be checked against all stored resource fingerprints before
    /// establishing a new checkpoint.
    private func rebuildExpiredForegroundPhotoHistory() -> ForegroundPhotoWork {
        do {
            let tokenData = try NSKeyedArchiver.archivedData(
                withRootObject: PHPhotoLibrary.shared().currentChangeToken,
                requiringSecureCoding: true
            )
            let snapshots = allAssetSnapshots(includingHidden: true)
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                  DatabaseManager.shared.applyForegroundPhotoChanges(
                    snapshots: snapshots,
                    pendingIdentifiers: Set(PhotoAssetSnapshot.visibleIdentifiers(in: snapshots)),
                    deletedIdentifiers: [],
                    tokenData: tokenData,
                    bootstrap: true
                  ) else {
                _ = DatabaseManager.shared.invalidateLocalPhotoInventory()
                return .unavailable
            }
            return .incremental(visibleForegroundPendingIdentifiers())
        } catch {
            logWarning("Could not re-establish expired PhotoKit history: \(error.localizedDescription)", category: .hash)
            _ = DatabaseManager.shared.invalidateLocalPhotoInventory()
            return .unavailable
        }
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
            guard bootstrapLocalPhotoInventory(),
                  PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
                  DatabaseManager.shared.commitInitialForegroundPhotoBootstrap(tokenData: tokenData) else {
                logError("Lightweight PhotoKit inventory bootstrap failed; retrying later", category: .database)
                _ = DatabaseManager.shared.invalidateLocalPhotoInventory()
                return .unavailable
            }
            logInfo("Initial PhotoKit inventory checkpoint committed without invalidating old hashes", category: .hash)
            return .incremental([])
        } catch {
            logWarning("Could not capture foreground PhotoKit change token: \(error.localizedDescription)", category: .hash)
            _ = DatabaseManager.shared.invalidateLocalPhotoInventory()
            return .unavailable
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
