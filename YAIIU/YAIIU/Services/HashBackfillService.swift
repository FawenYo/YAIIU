import Foundation
import Photos
import SQLite3

final class HashBackfillService {
    static let shared = HashBackfillService()

    private let batchSize = 20

    private init() {}

    func run(serverURL: String, apiKey: String) {
        Task.detached(priority: .background) {
            await self.backfill(serverURL: serverURL, apiKey: apiKey)
        }
    }

    private func backfill(serverURL: String, apiKey: String) async {
        let candidates = fetchCandidates()
        guard !candidates.isEmpty else {
            logDebug("HashBackfillService: no assets need hash backfill", category: .app)
            return
        }

        logInfo("HashBackfillService: backfilling \(candidates.count) asset(s)", category: .app)

        var processed = 0
        var foundOnServer = 0

        for assetId in candidates {
            do {
                let isOnServer = try await processAsset(
                    assetId: assetId,
                    serverURL: serverURL,
                    apiKey: apiKey
                )
                processed += 1
                if isOnServer { foundOnServer += 1 }
            } catch {
                logDebug("HashBackfillService: skipping \(assetId): \(error.localizedDescription)", category: .app)
            }
        }

        logInfo("HashBackfillService: processed \(processed), found \(foundOnServer) on server", category: .app)
    }

    private func fetchCandidates() -> [String] {
        let connection = SQLiteConnection.shared
        var ids = [String]()

        connection.dbQueue.sync {
            connection.ensureInitialized()

            let sql = """
                SELECT DISTINCT ua.asset_id
                FROM uploaded_assets ua
                LEFT JOIN hash_cache hc ON ua.asset_id = hc.asset_id
                WHERE hc.asset_id IS NULL
                LIMIT \(self.batchSize);
            """

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }

            guard sqlite3_prepare_v2(connection.db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cStr = sqlite3_column_text(stmt, 0) {
                    ids.append(String(cString: cStr))
                }
            }
        }

        return ids
    }

    private func processAsset(assetId: String, serverURL: String, apiKey: String) async throws -> Bool {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard let asset = fetchResult.firstObject else {
            return false
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let primary = selectPrimaryResource(from: resources) else {
            return false
        }

        let hash = try await computeSHA1(for: primary)

        HashCacheRepository().saveHashCache(localIdentifier: assetId, sha1Hash: hash)

        let isOnServer = try await ImmichAPIService.shared.checkAssetExists(
            checksum: hash,
            serverURL: serverURL,
            apiKey: apiKey
        )

        HashCacheRepository().updateHashCacheServerStatus(localIdentifier: assetId, isOnServer: isOnServer)

        return isOnServer
    }

    private func selectPrimaryResource(from resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .fullSizePhoto || $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .photo || $0.type == .video }
            ?? resources.first
    }

    private func computeSHA1(for resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let sha1 = StreamingSHA1()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            PHAssetResourceManager.default().requestData(for: resource, options: options) { chunk in
                sha1.update(data: chunk)
            } completionHandler: { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: sha1.finalize())
                }
            }
        }
    }
}
