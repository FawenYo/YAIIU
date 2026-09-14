import Foundation
import Photos

/// Mirrors Apple Photos user albums to Immich. Synchronization is additive: it
/// creates missing albums and adds uploaded assets, but never removes server data.
actor AlbumSyncService {
    static let shared = AlbumSyncService()
    static let albumMappingsKey = "immich_apple_photos_album_mappings"
    static let sessionKey = "immich_album_sync_session"
    private static let syncedMembershipsKey = "immich_apple_photos_album_synced_memberships"
    private static let mappingKeySeparator = "|"

    private let batchSize = 500
    private var isSyncing = false
    private var needsSync = false
    private var debounceTask: Task<Void, Never>?
    private let debounceDuration: Duration = .seconds(2)
    private struct Session {
        let serverURL: String
        let apiKey: String
        let generation: String?
        let externalURL: String
    }
    private struct SettingsSnapshot {
        let generation: String?
        let enabled: Bool
        let loggedIn: Bool
        let activeServerURL: String
        let serverURL: String
        let apiKey: String
    }
    private var cachedSettings: SettingsSnapshot?

    private init() {}
    nonisolated static func invalidateInFlightSync() {
        UserDefaults.standard.set(UUID().uuidString, forKey: sessionKey)
        Task { await AlbumSyncService.shared.invalidateCachedSettings() }
    }

    nonisolated static func clearPersistedState() {
        let defaults = UserDefaults.standard
        let prefixes = [albumMappingsKey + ".", syncedMembershipsKey + "."]
        for key in defaults.dictionaryRepresentation().keys
            where prefixes.contains(where: { key.hasPrefix($0) }) {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: sessionKey)
        Task { await AlbumSyncService.shared.invalidateCachedSettings() }
    }
    nonisolated static var currentSessionGeneration: String? {
        UserDefaults.standard.string(forKey: sessionKey)
    }
    private func invalidateCachedSettings() {
        cachedSettings = nil
    }
    static func mappingKey(serverURL: String, userId: String) -> String {
        scopedKey(prefix: albumMappingsKey, serverURL: serverURL, userId: userId)
    }

    private static func membershipKey(serverURL: String, userId: String) -> String {
        scopedKey(prefix: syncedMembershipsKey, serverURL: serverURL, userId: userId)
    }

    private static func scopedKey(prefix: String, serverURL: String, userId: String) -> String {
        let identity = canonicalServerIdentity(serverURL) + mappingKeySeparator + userId
        return prefix + "." + Data(identity.utf8).base64EncodedString()
    }

    private static func canonicalServerIdentity(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        var normalizedPath = components.path
        while normalizedPath.count > 1 && normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        components.path = normalizedPath == "/" ? "" : normalizedPath
        return components.string ?? trimmed.lowercased()
    }

    func syncIfEnabled() {
        if isSyncing {
            needsSync = true
            return
        }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounceDuration ?? .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.runIfEnabled()
        }
    }

    private func runIfEnabled() async {
        let settings = await loadSettingsSnapshot()
        guard settings.enabled, settings.loggedIn else { return }
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

    private func loadSettingsSnapshot() async -> SettingsSnapshot {
        let generation = UserDefaults.standard.string(forKey: Self.sessionKey)
        let activeServerURL = await MainActor.run { SettingsManager().activeServerURL }
        if let cachedSettings, cachedSettings.generation == generation {
            return SettingsSnapshot(
                generation: generation,
                enabled: cachedSettings.enabled,
                loggedIn: cachedSettings.loggedIn,
                activeServerURL: activeServerURL,
                serverURL: cachedSettings.serverURL,
                apiKey: cachedSettings.apiKey
            )
        }
        let snapshot = await MainActor.run { () -> SettingsSnapshot in
            let settings = SettingsManager()
            return SettingsSnapshot(
                generation: generation,
                enabled: settings.syncApplePhotosAlbums,
                loggedIn: settings.isLoggedIn,
                activeServerURL: settings.activeServerURL,
                serverURL: settings.serverURL,
                apiKey: settings.apiKey
            )
        }
        cachedSettings = snapshot
        return snapshot
    }
    private func sync() async throws {
        needsSync = true
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            needsSync = false
            let settings = await loadSettingsSnapshot()
            guard settings.enabled, settings.loggedIn else { return }
            let current = Session(
                serverURL: settings.activeServerURL,
                apiKey: settings.apiKey,
                generation: settings.generation,
                externalURL: settings.serverURL
            )
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
            guard UserDefaults.standard.bool(forKey: SettingsManager.syncApplePhotosAlbumsKey),
                  UserDefaults.standard.bool(forKey: SettingsManager.isLoggedInKey),
                  UserDefaults.standard.string(forKey: Self.sessionKey) == session else {
                throw CancellationError()
            }
        }
        try checkSession()
        let user = try await ImmichAPIService.shared.getCurrentUser(serverURL: serverURL, apiKey: apiKey)
        try checkSession()
        let mappingKey = Self.mappingKey(serverURL: snapshot.externalURL, userId: user.id)
        let membershipsKey = Self.membershipKey(serverURL: snapshot.externalURL, userId: user.id)

        let localAlbums = fetchLocalAlbums()
        guard !localAlbums.isEmpty else { return }

        let remoteAlbums = try await ImmichAPIService.shared.fetchOwnedAlbums(
            serverURL: serverURL,
            apiKey: apiKey
        )
        let legacyUserKey = Self.albumMappingsKey + "." + user.id
        var mappings = UserDefaults.standard.dictionary(forKey: mappingKey) as? [String: String]
            ?? UserDefaults.standard.dictionary(forKey: legacyUserKey) as? [String: String]
            ?? [:]
        if UserDefaults.standard.dictionary(forKey: mappingKey) == nil, !mappings.isEmpty {
            UserDefaults.standard.set(mappings, forKey: mappingKey)
        }
        var syncedMemberships = UserDefaults.standard.dictionary(forKey: membershipsKey) as? [String: [String]] ?? [:]
        let remoteById = Dictionary(remoteAlbums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var createdCount = 0
        var addedCount = 0

        for localAlbum in localAlbums {
            do {
                try checkSession()

                let previousRemoteAlbumID = mappings[localAlbum.localIdentifier]
                var remoteAlbum = previousRemoteAlbumID.flatMap { remoteById[$0] }
                var syncedIds: Set<String> = []
                if let remoteAlbumID = remoteAlbum?.id, remoteAlbumID == previousRemoteAlbumID {
                    syncedIds = Set(syncedMemberships[localAlbum.localIdentifier] ?? [])
                }
                if remoteAlbum == nil {
                    let title = (localAlbum.localizedTitle ?? "Untitled Album")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let createdAlbum = try await ImmichAPIService.shared.createAlbum(
                        name: title,
                        serverURL: serverURL,
                        apiKey: apiKey
                    )
                    try checkSession()
                    mappings[localAlbum.localIdentifier] = createdAlbum.id
                    UserDefaults.standard.set(mappings, forKey: mappingKey)
                    remoteAlbum = createdAlbum
                    createdCount += 1
                }

                guard let remoteAlbum else { continue }
                let assets = PHAsset.fetchAssets(in: localAlbum, options: nil)
                for start in stride(from: 0, to: assets.count, by: batchSize) {
                    try checkSession()
                    let localIdentifiers = autoreleasepool {
                        (start..<min(start + batchSize, assets.count)).map {
                            assets.object(at: $0).localIdentifier
                        }
                    }
                    let resolvedIds = try UploadRecordRepository()
                        .albumAssetIds(for: localIdentifiers, ownerId: user.id)
                    let batch = resolvedIds.filter { !syncedIds.contains($0) }.sorted()
                    guard !batch.isEmpty else { continue }

                    let rejected = try await ImmichAPIService.shared.addAssets(
                        batch,
                        toAlbum: remoteAlbum.id,
                        serverURL: serverURL,
                        apiKey: apiKey
                    )
                    let accepted = Set(batch).subtracting(rejected)
                    addedCount += accepted.count
                    if !rejected.isEmpty {
                        logWarning("Album \(remoteAlbum.id): \(rejected.count) memberships rejected; continuing remaining albums", category: .sync)
                    }
                    guard !accepted.isEmpty else { continue }
                    syncedIds.formUnion(accepted)
                    syncedMemberships[localAlbum.localIdentifier] = syncedIds.sorted()
                    UserDefaults.standard.set(syncedMemberships, forKey: membershipsKey)
                    try checkSession()
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as ImmichAPIError {
                throw error
            } catch let error as URLError {
                throw error
            } catch {
                throw error
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
