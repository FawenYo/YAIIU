import Foundation
import ImageIO

/// Adds an EXIF capture-time offset without recompressing the image payload.
enum ImageTimezoneMetadata {
    private static let offsetPath = "exif:OffsetTimeOriginal" as CFString

    /// Returns either `fileURL` unchanged or a new temp file owned by the caller.
    static func addingOffsetIfMissing(to fileURL: URL, timezone: TimeZone, at date: Date) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source)
        else {
            return fileURL
        }

        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let offset = CGImageMetadataCopyStringValueWithPath(metadata, nil, offsetPath),
           !String(offset).isEmpty {
            return fileURL
        }

        let offset = formattedOffset(timezone.secondsFromGMT(for: date))
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueWithPath(metadata, nil, offsetPath, offset as CFString) else {
            return fileURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-timezone-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension)

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            type,
            CGImageSourceGetCount(source),
            nil
        ) else {
            return fileURL
        }

        let options = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            try? FileManager.default.removeItem(at: outputURL)
            return fileURL
        }

        return outputURL
    }

    static func formattedOffset(_ secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let absoluteSeconds = abs(secondsFromGMT)
        return String(format: "%@%02d:%02d", sign, absoluteSeconds / 3600, (absoluteSeconds % 3600) / 60)
    }
}
