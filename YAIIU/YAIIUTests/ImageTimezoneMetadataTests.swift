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

    /// Reproduces the screenshot path: a PNG with an existing EXIF capture date,
    /// TIFF date, and a user comment, rather than the blank 4x4 PNG used before.
    func testPNGWithScreenshotEXIFKeepsCaptureDateAndAddsTimezone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }

        let capture = "2026:10:17 00:14:46"
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil
        ))
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: [
                kCGImagePropertyExifDateTimeOriginal as String: capture,
                kCGImagePropertyExifUserComment as String: "Screenshot",
            ],
            kCGImagePropertyTIFFDictionary as String: [
                kCGImagePropertyTIFFDateTime as String: capture,
            ]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(makeImage().cgImage), properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let inputSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let originalProps = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(inputSource, 0, nil) as? [String: Any])
        let originalExif = try XCTUnwrap(originalProps[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(originalExif[kCGImagePropertyExifDateTimeOriginal as String] as? String, capture)
        let originalBytes = try Data(contentsOf: url)

        let output = try ImageTimezoneMetadata.addingOffsetIfMissing(
            to: url, filename: "IMG_8425.PNG", mimeType: "image/png",
            timezone: taipeiTimeZone, at: Date()
        )
        defer { if output != url { try? FileManager.default.removeItem(at: output) } }
        XCTAssertNotEqual(output, url, "Existing EXIF in screenshots must not block adding a missing offset")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, capture)
        XCTAssertEqual(exif[kCGImagePropertyExifUserComment as String] as? String, "Screenshot")
        // Pixel payload and every PNG ancillary chunk except eXIf stay byte-identical.
        XCTAssertEqual(nonExifPNGChunks(originalBytes), nonExifPNGChunks(try Data(contentsOf: output)))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        let offset = CGImageMetadataCopyStringValueWithPath(
            metadata, nil, "exif:OffsetTimeOriginal" as CFString
        )
        XCTAssertEqual(offset.map { String($0) }, "+08:00")
    }

    private func nonExifPNGChunks(_ data: Data) -> [[UInt8]] {
        guard data.count >= 8 else { return [] }
        var result: [[UInt8]] = []
        var pos = 8
        while pos + 12 <= data.count {
            let length = Int(data[pos]) << 24 |
                Int(data[pos + 1]) << 16 |
                Int(data[pos + 2]) << 8 | Int(data[pos + 3])
            guard length <= data.count - pos - 12 else { return [] }
            let name = String(data: data[(pos + 4)..<(pos + 8)], encoding: .ascii) ?? ""
            if name != "eXIf" { result.append(Array(data[pos..<(pos + 12 + length)])) }
            pos += 12 + length
        }
        return result
    }

    private func makeImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { renderer in
            renderer.cgContext.setFillColor(UIColor.orange.cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }
}
