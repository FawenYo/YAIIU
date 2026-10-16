import ImageIO
import UIKit
import XCTest
@testable import YAIIU

final class ImageTimezoneMetadataTests: XCTestCase {
    private let taipeiTimeZone = TimeZone(secondsFromGMT: 8 * 3_600)!

    func testRAWAndHEICRemainByteIdentical() throws {
        let original = Data([0x49, 0x49, 0x2a, 0x00, 0xff, 0x01])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for (filename, mimeType) in [
            ("DSC01387.ARW", "image/x-sony-arw"),
            ("DSC01387.CR3", "image/x-canon-cr3"),
            ("DSC01387.NEF", "image/x-nikon-nef"),
            ("DSC01387.DNG", "image/x-adobe-dng"),
            ("IMG_0001.HEIC", "image/heic")
        ] {
            let output = try ImageTimezoneMetadata.addingOffsetIfMissing(
                to: url, filename: filename, mimeType: mimeType,
                timezone: taipeiTimeZone, at: Date()
            )
            XCTAssertEqual(output, url, filename)
            XCTAssertEqual(try Data(contentsOf: output), original, filename)
        }
    }

    func testExistingJPEGEXIFOffsetDoesNotTriggerRewrite() throws {
        let image = makeImage()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil
        ))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: "2026:10:17 00:21:00",
                kCGImagePropertyExifOffsetTimeOriginal as String: "+08:00"
            ],
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 25.06639,
                kCGImagePropertyGPSLongitude as String: 121.65402
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let original = try Data(contentsOf: url)

        let output = try ImageTimezoneMetadata.addingOffsetIfMissing(
            to: url, filename: "DSC01387.JPG", mimeType: "image/jpeg",
            timezone: TimeZone(secondsFromGMT: 9 * 3_600)!, at: Date()
        )
        XCTAssertEqual(output, url)
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testPNGWithoutOffsetStillGetsTimezone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("bin")
        try XCTUnwrap(makeImage().pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let output = try ImageTimezoneMetadata.addingOffsetIfMissing(
            to: url, filename: "Screenshot.PNG", mimeType: "image/png",
            timezone: taipeiTimeZone, at: Date()
        )
        defer { if output != url { try? FileManager.default.removeItem(at: output) } }
        XCTAssertNotEqual(output, url, "PNG screenshots must continue receiving capture offsets")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let offset = CGImageMetadataCopyStringValueWithPath(
            metadata, nil, "exif:OffsetTimeOriginal" as CFString
        )
        XCTAssertEqual(offset.map { String($0) }, "+08:00")
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { renderer in
            renderer.cgContext.setFillColor(UIColor.orange.cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
