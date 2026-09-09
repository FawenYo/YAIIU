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
    private var scheduledSyncTask: Task<Void, Never>?
    private let debounceDuration: Duration = .seconds(2)
    private struct Session {
        let serverURL: String
        let apiKey: String
        let generation: String?
        let externalURL: String
    }

    private init() {}

    func syncIfEnabled() {
        scheduledSyncTask?.cancel()
        scheduledSyncTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounceDuration ?? .seconds(2))
            } catch {
                return
            }
            await self?.runIfEnabled()
        }
    }

    private func runIfEnabled() async {
        let settings = await MainActor.run { SettingsManager() }
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
                               generation: UserDefaults.standard.string(forKey: Self.sessionKey), externalURL: settings.serverURL)
            }
            do {
                try await performSync(current)
            } catch {
                if !needsSync { throw error }
                logDebug("Album sync interrupted; processing pending request", category: .sync)
            }
        } while needsSync
    }

    private func performSync(_ snapshot: Session) async throws {
        let serverURL = snapshot.serverURL
        let apiKey = snapshot.apiKey
        guard !serverURL.isEmpty, !apiKey.isEmpty else { return }
        let session = snapshot.generation
        @Sendable func checkSession() throws {
            try Task.checkCancellation()
            guard UserDefaults.standard.bool(forKey: "immich_sync_apple_photos_albums"),
                  UserDefaults.standard.bool(forKey: "immich_is_logged_in"),
                  UserDefaults.standard.string(forKey: Self.sessionKey) == session else {
                throw CancellationError()
            }
        }
        try checkSession()
        let user = try await ImmichAPIService.shared.getCurrentUser(serverURL: serverURL, apiKey: apiKey)
        try checkSession()
        let mappingKey = Self.albumMappingsKey + "." + user.id
        let legacyMappingKey = Self.albumMappingsKey + "." + Data((snapshot.externalURL + "|" + user.id).utf8).base64EncodedString()

        let localAlbums = fetchLocalAlbums()
        guard !localAlbums.isEmpty else { return }

        let remoteAlbums = try await ImmichAPIService.shared.fetchOwnedAlbums(
            serverURL: serverURL,
            apiKey: apiKey
        )
        try checkSession()
        var mappings = UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: String]
            ?? UserDefaults.standard.dictionary(forKey: legacyMappingKey) as? [String: String]
            ?? [:]
        if UserDefaults.standard.dictionary(forKey: mappingKey) == nil, !mappings.isEmpty {
            UserDefaults.standard.set(mappings, forKey: mappingKey)
        }
        let remoteById = Dictionary(remoteAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var createdCount = 0
        var addedCount = 0

        for localAlbum in localAlbums {
            do {
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
                    mappings[localAlbum.localIdentifier] = remoteAlbum.id
                    UserDefaults.standard.set(mappings, forKey: mappingKey)
                    createdCount += 1
                    try checkSession()
                }

                let assets = PHAsset.fetchAssets(in: localAlbum, options: nil)
                for start in stride(from: 0, to: assets.count, by: batchSize) {
                    try checkSession()
                    let batch = try autoreleasepool {
                        var ids = Set<String>()
                        let repository = UploadRecordRepository()
                        for index in start..<min(start + batchSize, assets.count) {
                            ids.formUnion(try repository.albumAssetIds(for: assets.object(at: index).localIdentifier))
                        }
                        return ids.sorted()
                    }
                    guard !batch.isEmpty else { continue }
                    let cacheKey = (session ?? "") + remoteAlbum.id + batch.joined(separator: ",")
                    if let date = recentBatches[cacheKey], Date().timeIntervalSince(date) < 60 { continue }
                    let rejected = try await ImmichAPIService.shared.addAssets(
                        batch,
                        toAlbum: remoteAlbum.id,
                        serverURL: serverURL,
                        apiKey: apiKey
                    )
                    addedCount += batch.count - rejected.count
                    if !rejected.isEmpty {
                        logWarning("Album \(remoteAlbum.id): \(rejected.count) memberships rejected; continuing remaining albums", category: .sync)
                    }
                    try checkSession()
                    if recentBatches.count >= 128 { recentBatches.removeAll(keepingCapacity: true) }
                    if rejected.isEmpty { recentBatches[cacheKey] = Date() }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logError("Album sync skipped \(localAlbum.localIdentifier): \(error.localizedDescription)", category: .sync)
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



}
