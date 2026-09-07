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
    private var needsSync = false

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
            try await sync(serverURL: settings.activeServerURL, apiKey: settings.apiKey)
        } catch {
            logError("Album sync failed: \(error.localizedDescription)", category: .sync)
        }
    }
    func sync(serverURL: String, apiKey: String) async throws {
        needsSync = true
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsSync = false
            let current = await MainActor.run { () -> (String, String) in
                let settings = SettingsManager()
                return (settings.activeServerURL, settings.apiKey)
            }
            try await performSync(serverURL: current.0, apiKey: current.1)
        } while needsSync
    }

    private func performSync(serverURL: String, apiKey: String) async throws {
        guard !serverURL.isEmpty, !apiKey.isEmpty else { return }
        let session = UserDefaults.standard.string(forKey: Self.sessionKey)
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
                saveMappings(mappings)
                createdCount += 1
            }

            let assetIds = uploadedImmichIds(in: localAlbum)
            for start in stride(from: 0, to: assetIds.count, by: batchSize) {
                try checkSession()
                let batch = Array(assetIds[start..<min(start + batchSize, assetIds.count)])
                try await ImmichAPIService.shared.addAssets(
                    batch,
                    toAlbum: remoteAlbum.id,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                addedCount += batch.count
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

    private func uploadedImmichIds(in album: PHAssetCollection) -> [String] {
        let result = PHAsset.fetchAssets(in: album, options: nil)
        let repository = UploadRecordRepository()
        var ids = Set<String>()
        result.enumerateObjects { asset, _, _ in
            ids.formUnion(repository.albumAssetIds(for: asset.localIdentifier))
        }
        return Array(ids)
    }

    private func loadMappings() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.albumMappingsKey) as? [String: String] ?? [:]
    }

    private func saveMappings(_ mappings: [String: String]) {
        UserDefaults.standard.set(mappings, forKey: Self.albumMappingsKey)
    }
}
