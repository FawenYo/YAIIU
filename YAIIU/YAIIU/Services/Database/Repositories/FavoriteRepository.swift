import Foundation
import SQLite3

final class FavoriteRepository {
    private let connection: SQLiteConnection
    
    init(connection: SQLiteConnection = .shared) {
        self.connection = connection
    }
    
    // MARK: - Query Methods
    
    func getUploadedAssetsFavoriteStatus() -> [UploadedAssetFavoriteInfo] {
        connection.ensureInitialized()
        var results: [UploadedAssetFavoriteInfo] = []
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = """
                SELECT asset_id, immich_id, is_favorite
                FROM uploaded_assets
                WHERE immich_id IS NOT NULL AND immich_id != ''
                GROUP BY asset_id;
            """
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                while sqlite3_step(statement) == SQLITE_ROW {
                    if let assetIdCStr = sqlite3_column_text(statement, 0),
                       let immichIdCStr = sqlite3_column_text(statement, 1) {
                        let assetId = String(cString: assetIdCStr)
                        let immichId = String(cString: immichIdCStr)
                        let isFavorite = sqlite3_column_int(statement, 2) == 1
                        
                        results.append(UploadedAssetFavoriteInfo(
                            localIdentifier: assetId,
                            immichId: immichId,
                            storedFavorite: isFavorite
                        ))
                    }
                }
            }
            sqlite3_finalize(statement)
        }
        
        return results
    }
    
    func getImmichId(for localIdentifier: String) -> String? {
        connection.ensureInitialized()
        var immichId: String?
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "SELECT immich_id FROM uploaded_assets WHERE asset_id = ? LIMIT 1;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (localIdentifier as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) == SQLITE_ROW,
                   let cString = sqlite3_column_text(statement, 0) {
                    immichId = String(cString: cString)
                }
            }
            sqlite3_finalize(statement)
        }
        
        return immichId
    }
    
    // MARK: - Update Methods
    
    func updateAssetFavoriteStatus(localIdentifier: String, isFavorite: Bool) {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            let sql = "UPDATE uploaded_assets SET is_favorite = ? WHERE asset_id = ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
                sqlite3_bind_text(statement, 2, (localIdentifier as NSString).utf8String, -1, nil)
                
                if sqlite3_step(statement) != SQLITE_DONE {
                    logError("Failed to update asset favorite status: \(self.connection.lastErrorMessage)", category: .database)
                }
            }
            sqlite3_finalize(statement)
        }
    }
    
    func batchUpdateAssetFavoriteStatus(updates: [(localIdentifier: String, isFavorite: Bool)]) {
        connection.ensureInitialized()
        
        connection.dbQueue.sync { [weak self] in
            guard let self = self else { return }
            
            self.connection.beginTransaction()
            
            let sql = "UPDATE uploaded_assets SET is_favorite = ? WHERE asset_id = ?;"
            var statement: OpaquePointer?
            
            if sqlite3_prepare_v2(self.connection.db, sql, -1, &statement, nil) == SQLITE_OK {
                for (localIdentifier, isFavorite) in updates {
                    sqlite3_bind_int(statement, 1, isFavorite ? 1 : 0)
                    sqlite3_bind_text(statement, 2, (localIdentifier as NSString).utf8String, -1, nil)
                    sqlite3_step(statement)
                    sqlite3_reset(statement)
                }
            }
            sqlite3_finalize(statement)
            
            self.connection.commitTransaction()
        }
    }
}
