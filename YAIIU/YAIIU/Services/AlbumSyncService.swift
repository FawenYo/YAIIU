import Foundation
import Photos

/// Mirrors Apple Photos user albums to Immich. Synchronization is additive: it
/// creates missing albums and adds uploaded assets, but never removes server data.
actor AlbumSyncService {
    static let shared = AlbumSyncService()
    static let albumMappingsKey = "immich_apple_photos_album_mappings"
    static let sessionKey = "immich_album_sync_session"

    private let batchSize = 500
    private var isSyncing = false
    private var recentBatches: [String: Date] = [:]
    private var needsSync = false
    private struct Session {
        let serverURL: String
        let apiKey: String
        let generation: String?
    }

    private init() {}

    @MainActor
    func syncIfEnabled() async {
        let settings = SettingsManager()
        guard settings.syncApplePhotosAlbums, settings.isLoggedIn else { return }
        let authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizationStatus == .authorized || authorizationStatus == .limited else {
            logDebug("Album sync requires photo library access", category: .sync)
            return
        }

        do {
            try await sync()
        } catch {
            logError("Album sync failed: \(error.localizedDescription)", category: .sync)
        }
    }
    private func sync() async throws {
        needsSync = true
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsSync = false
            let current = await MainActor.run { () -> Session in
                let settings = SettingsManager()
                return Session(serverURL: settings.activeServerURL, apiKey: settings.apiKey,
                               generation: UserDefaults.standard.string(forKey: Self.sessionKey))
            }
            try await performSync(current)
        } while needsSync
    }

    private func performSync(_ snapshot: Session) async throws {
        let serverURL = snapshot.serverURL
        let apiKey = snapshot.apiKey
        guard !serverURL.isEmpty, !apiKey.isEmpty else { return }
        let session = snapshot.generation
        func checkSession() throws {
            try Task.checkCancellation()
            guard UserDefaults.standard.bool(forKey: "immich_sync_apple_photos_albums"),
                  UserDefaults.standard.bool(forKey: "immich_is_logged_in"),
                  UserDefaults.standard.string(forKey: Self.sessionKey) == session else {
                throw CancellationError()
            }
        }
        try checkSession()

        let localAlbums = fetchLocalAlbums()
        guard !localAlbums.isEmpty else { return }

        let remoteAlbums = try await ImmichAPIService.shared.fetchOwnedAlbums(
            serverURL: serverURL,
            apiKey: apiKey
        )
        try checkSession()
        var mappings = loadMappings()
        let remoteById = Dictionary(uniqueKeysWithValues: remoteAlbums.map { ($0.id, $0) })

        var createdCount = 0
        var addedCount = 0

        for localAlbum in localAlbums {
            try checkSession()

            let remoteAlbum: ImmichAlbum
            if let mappedId = mappings[localAlbum.localIdentifier],
               let mappedAlbum = remoteById[mappedId] {
                remoteAlbum = mappedAlbum
            } else {
                let title = localAlbum.localizedTitle ?? "Untitled Album"
                remoteAlbum = try await ImmichAPIService.shared.createAlbum(
                    name: title,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                try checkSession()
                mappings[localAlbum.localIdentifier] = remoteAlbum.id
                try await MainActor.run {
                    try checkSession()
                    UserDefaults.standard.set(mappings, forKey: Self.albumMappingsKey)
                }
                createdCount += 1
            }

            let assets = PHAsset.fetchAssets(in: localAlbum, options: nil)
            for start in stride(from: 0, to: assets.count, by: batchSize) {
                try checkSession()
                let batch = autoreleasepool {
                    var ids = Set<String>()
                    let repository = UploadRecordRepository()
                    for index in start..<min(start + batchSize, assets.count) {
                        ids.formUnion(repository.albumAssetIds(for: assets.object(at: index).localIdentifier))
                    }
                    return ids.sorted()
                }
                guard !batch.isEmpty else { continue }
                let cacheKey = (session ?? "") + remoteAlbum.id + batch.joined(separator: ",")
                if let date = recentBatches[cacheKey], Date().timeIntervalSince(date) < 60 { continue }
                try await ImmichAPIService.shared.addAssets(
                    batch,
                    toAlbum: remoteAlbum.id,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                addedCount += batch.count
                try checkSession()
                if recentBatches.count >= 128 { recentBatches.removeAll(keepingCapacity: true) }
                recentBatches[cacheKey] = Date()
            }
        }

        logInfo("Album sync completed: \(localAlbums.count) scanned, \(createdCount) created, \(addedCount) asset memberships submitted", category: .sync)
    }

    private func fetchLocalAlbums() -> [PHAssetCollection] {
        let result = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: nil
        )
        var albums: [PHAssetCollection] = []
        albums.reserveCapacity(result.count)
        result.enumerateObjects { album, _, _ in
            albums.append(album)
        }
        return albums
    }


    private func loadMappings() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.albumMappingsKey) as? [String: String] ?? [:]
    }

}
