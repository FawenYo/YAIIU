import Foundation
import XCTest
@testable import YAIIU

final class FavoriteChangeDetectorTests: XCTestCase {
    func testLargeLibraryIsComparedInBoundedBatchesWithoutLosingChanges() {
        let assets = (0..<601).map {
            UploadedAssetFavoriteInfo(localIdentifier: "asset-\($0)", immichId: "server-\($0)", storedFavorite: false)
        }
        var sizes: [Int] = []
        let changes = FavoriteChangeDetector.detectChanges(in: assets) { identifiers in
            sizes.append(identifiers.count)
            return Dictionary(uniqueKeysWithValues: identifiers.map { ($0, true) })
        }
        XCTAssertEqual(sizes, [300, 300, 1])
        XCTAssertEqual(changes.count, 601)
        XCTAssertEqual(changes.first, .init(localIdentifier: "asset-0", immichId: "server-0", newFavorite: true))
        XCTAssertEqual(changes.last, .init(localIdentifier: "asset-600", immichId: "server-600", newFavorite: true))
    }

    func testMissingAndUnchangedAssetsAreSkippedAndBothDirectionsPreserved() {
        let assets = [
            UploadedAssetFavoriteInfo(localIdentifier: "add", immichId: "a", storedFavorite: false),
            UploadedAssetFavoriteInfo(localIdentifier: "remove", immichId: "b", storedFavorite: true),
            UploadedAssetFavoriteInfo(localIdentifier: "same", immichId: "c", storedFavorite: true),
            UploadedAssetFavoriteInfo(localIdentifier: "missing", immichId: "d", storedFavorite: true)
        ]
        let changes = FavoriteChangeDetector.detectChanges(in: assets, batchSize: 2) { identifiers in
            ["add": true, "remove": false, "same": true].filter { identifiers.contains($0.key) }
        }
        XCTAssertEqual(changes, [
            .init(localIdentifier: "add", immichId: "a", newFavorite: true),
            .init(localIdentifier: "remove", immichId: "b", newFavorite: false)
        ])
    }

    func testEmptyLibraryDoesNotFetchPhotoKit() {
        let changes = FavoriteChangeDetector.detectChanges(in: []) { _ in
            XCTFail("Empty library must not fetch PhotoKit")
            return [:]
        }
        XCTAssertTrue(changes.isEmpty)
    }

    private final class Temporary: NSObject {}

    func testFetchTemporariesAreReleasedBeforeNextBatch() {
        let assets = (0..<3).map {
            UploadedAssetFavoriteInfo(localIdentifier: "asset-\($0)", immichId: "server-\($0)", storedFavorite: false)
        }
        weak var previous: Temporary?
        autoreleasepool {
            _ = FavoriteChangeDetector.detectChanges(in: assets, batchSize: 1) { _ in
                XCTAssertNil(previous)
                let temporary = Temporary()
                previous = temporary
                _ = Unmanaged.passRetained(temporary).autorelease()
                return [:]
            }
            XCTAssertNil(previous)
        }
    }
}
