import Combine
import Photos
import XCTest
@testable import YAIIU

final class UploadQueueTests: XCTestCase {
    // No photo-library fetch or resource download is needed for queue admission.
    private final class Asset: PHAsset, @unchecked Sendable {
        private let identifier: String
        var identifierReads = 0

        init(_ identifier: String) {
            self.identifier = identifier
            super.init()
        }

        override var localIdentifier: String {
            identifierReads += 1
            return identifier
        }

        override var mediaType: PHAssetMediaType { .image }
    }

    func testSelectAllPublishesOneQueueAndReadsIdentifiersLinearly() async {
        await MainActor.run {
            let manager = UploadManager()
            let assets = (0..<10_276).map { Asset("asset-\($0)") }
            let prepared = PreparedUploadQueue(entries: assets.map {
                (asset: $0, filename: "photo.jpg", hasRAW: false, resourceCount: 1)
            }, skippedCount: 0)
            var publishedCounts: [Int] = []
            let subscription = manager.$uploadQueue.dropFirst().sink {
                publishedCounts.append($0.count)
            }

            let added = manager.appendPreparedUploads(prepared)

            XCTAssertEqual(added, 10_276)
            XCTAssertEqual(manager.totalCount, 10_276)
            XCTAssertEqual(publishedCounts, [10_276], "Select All must not publish every intermediate array.")
            XCTAssertLessThanOrEqual(assets.reduce(0) { $0 + $1.identifierReads }, 20_552,
                                     "PhotoKit identifiers must not be read once per pair of assets.")
            withExtendedLifetime(subscription) {}
        }
    }

    func testCommitRechecksCurrentQueueAndDeduplicatesIncomingBatch() async {
        await MainActor.run {
            let manager = UploadManager()
            let pending = UploadItem(asset: Asset("pending"), filename: "pending.jpg", hasRAW: false)
            let failed = UploadItem(asset: Asset("failed"), filename: "failed.jpg", hasRAW: false)
            failed.status = .failed
            let completed = UploadItem(asset: Asset("completed"), filename: "old.jpg", hasRAW: false)
            completed.status = .completed
            manager.uploadQueue = [pending, failed, completed]
            let prepared = PreparedUploadQueue(entries: [
                (Asset("pending"), "duplicate.jpg", false, 1),
                (Asset("new"), "new.raw", true, 2),
                (Asset("failed"), "duplicate.jpg", false, 1),
                (Asset("new"), "duplicate.raw", true, 2),
                (Asset("completed"), "retry.jpg", false, 1)
            ], skippedCount: 0)

            XCTAssertEqual(manager.appendPreparedUploads(prepared), 2)
            XCTAssertEqual(manager.uploadQueue.map(\.filename),
                           ["pending.jpg", "failed.jpg", "old.jpg", "new.raw", "retry.jpg"])
            XCTAssertTrue(manager.uploadQueue[3].hasRAW)
            XCTAssertEqual(manager.uploadQueue[3].totalResources, 2)
            XCTAssertTrue(manager.uploadQueue[0] === pending)
        }
    }

    func testEmptyOrDuplicateBatchDoesNotPublish() async {
        await MainActor.run {
            let manager = UploadManager()
            manager.uploadQueue = [UploadItem(asset: Asset("existing"), filename: "old.jpg", hasRAW: false)]
            var publications = 0
            let subscription = manager.$uploadQueue.dropFirst().sink { _ in publications += 1 }

            XCTAssertEqual(manager.appendPreparedUploads(PreparedUploadQueue(entries: [], skippedCount: 0)), 0)
            XCTAssertEqual(manager.appendPreparedUploads(PreparedUploadQueue(
                entries: [(Asset("existing"), "duplicate.jpg", false, 1)], skippedCount: 0
            )), 0)
            XCTAssertEqual(publications, 0)
            XCTAssertEqual(manager.uploadQueue.count, 1)
            withExtendedLifetime(subscription) {}
        }
    }
}
