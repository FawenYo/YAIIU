import Foundation
import Photos

/// Mirrors Apple Photos user albums to Immich. Synchronization is additive: it
/// creates missing albums and adds uploaded assets, but never removes server data.
actor AlbumSyncService {
    static let shared = AlbumSyncService()
    static let albumMappingsKey = "immich_apple_photos_album_mappings"

    private let batchSize = 500

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
        guard !serverURL.isEmpty, !apiKey.isEmpty else { return }

        let localAlbums = fetchLocalAlbums()
        guard !localAlbums.isEmpty else { return }

        let remoteAlbums = try await ImmichAPIService.shared.fetchOwnedAlbums(
            serverURL: serverURL,
            apiKey: apiKey
        )
        var mappings = loadMappings()
        let remoteById = Dictionary(uniqueKeysWithValues: remoteAlbums.map { ($0.id, $0) })
        let remoteByName = Dictionary(grouping: remoteAlbums, by: \ImmichAlbum.albumName)
        let uploadedMappings = Dictionary(
            DatabaseManager.shared.getAllUploadedAssetMappings().map { ($0.localIdentifier, $0.immichId) },
            uniquingKeysWith: { first, _ in first }
        )

        var createdCount = 0
        var addedCount = 0

        for localAlbum in localAlbums {
            if Task.isCancelled { throw CancellationError() }

            let remoteAlbum: ImmichAlbum
            if let mappedId = mappings[localAlbum.localIdentifier],
               let mappedAlbum = remoteById[mappedId] {
                remoteAlbum = mappedAlbum
            } else if let matches = remoteByName[localAlbum.localizedTitle ?? ""], matches.count == 1,
                      let match = matches.first {
                remoteAlbum = match
                mappings[localAlbum.localIdentifier] = match.id
                saveMappings(mappings)
            } else {
                let title = localAlbum.localizedTitle ?? "Untitled Album"
                remoteAlbum = try await ImmichAPIService.shared.createAlbum(
                    name: title,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                mappings[localAlbum.localIdentifier] = remoteAlbum.id
                saveMappings(mappings)
                createdCount += 1
            }

            let assetIds = uploadedImmichIds(in: localAlbum, uploadedMappings: uploadedMappings)
            for start in stride(from: 0, to: assetIds.count, by: batchSize) {
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

    private func uploadedImmichIds(
        in album: PHAssetCollection,
        uploadedMappings: [String: String]
    ) -> [String] {
        let result = PHAsset.fetchAssets(in: album, options: nil)
        var ids = Set<String>()
        result.enumerateObjects { asset, _, _ in
            if let immichId = uploadedMappings[asset.localIdentifier] {
                ids.insert(immichId)
            }
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
