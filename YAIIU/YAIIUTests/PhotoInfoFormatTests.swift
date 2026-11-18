import XCTest
@testable import YAIIU

final class PhotoInfoFormatTests: XCTestCase {
    func testFormatters() {
        XCTAssertEqual(PhotoInfoFormat.aperture(1.78), "ƒ1.78")
        XCTAssertEqual(PhotoInfoFormat.aperture(2.8), "ƒ2.8")
        XCTAssertEqual(PhotoInfoFormat.aperture(2.0), "ƒ2")

        XCTAssertEqual(PhotoInfoFormat.shutter(1.0 / 60), "1/60 s")
        XCTAssertEqual(PhotoInfoFormat.shutter(0.008), "1/125 s")
        XCTAssertEqual(PhotoInfoFormat.shutter(2.5), "2.5 s")

        XCTAssertEqual(PhotoInfoFormat.exposureBias(0), "0 ev")
        XCTAssertEqual(PhotoInfoFormat.exposureBias(0.667), "+0.67 ev")
        XCTAssertEqual(PhotoInfoFormat.exposureBias(-1), "-1 ev")

        XCTAssertEqual(PhotoInfoFormat.megapixels(width: 6048, height: 8064), "48 MP")
        XCTAssertNil(PhotoInfoFormat.megapixels(width: 640, height: 480))

        XCTAssertEqual(PhotoInfoFormat.formatBadge(fileName: "IMG_8783.HEIC"), "HEIF")
        XCTAssertEqual(PhotoInfoFormat.formatBadge(fileName: "a.jpg"), "JPEG")
        XCTAssertEqual(PhotoInfoFormat.formatBadge(fileName: "a.DNG"), "DNG")
        XCTAssertNil(PhotoInfoFormat.formatBadge(fileName: "noext"))
        XCTAssertNil(PhotoInfoFormat.formatBadge(fileName: nil))
    }
}
