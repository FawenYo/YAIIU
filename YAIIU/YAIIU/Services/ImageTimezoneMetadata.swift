import Foundation
import ImageIO

/// Preserve camera originals. Only safe image formats without a capture offset
/// may receive an additional timezone in a temporary upload copy.
enum ImageTimezoneMetadata {
    private static let offsetPath = "exif:OffsetTimeOriginal" as CFString

    /// PhotoKit exports to a .bin temporary file. Use the resource's actual name
    /// and MIME type, never the temporary file's extension.
    static func canRewrite(filename: String, mimeType: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg": return mimeType.lowercased() == "image/jpeg"
        case "png": return mimeType.lowercased() == "image/png"
        default: return false // RAW, HEIF, video, and all unverified formats
        }
    }

    /// Returns the original file on any unsupported input or validation failure.
    /// A rewritten temporary copy belongs to the caller.
    static func addingOffsetIfMissing(
        to fileURL: URL,
        filename: String,
        mimeType: String,
        timezone: TimeZone,
        at date: Date
    ) throws -> URL {
        guard canRewrite(filename: filename, mimeType: mimeType),
              let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              (type as String) == (mimeType.lowercased() == "image/png" ? "public.png" : "public.jpeg")
        else {
            return fileURL
        }

        // Check the native ExifIFD first: the XMP path alone may miss a camera's
        // original OffsetTimeOriginal and incorrectly trigger a rewrite.
        guard existingOffset(in: source) == nil else { return fileURL }

        let offset = formattedOffset(timezone.secondsFromGMT(for: date))
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueWithPath(metadata, nil, offsetPath, offset as CFString) else {
            return fileURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-timezone-\(UUID().uuidString)")
            .appendingPathExtension(fileURL.pathExtension.isEmpty ? "bin" : fileURL.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, type, CGImageSourceGetCount(source), nil
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

        // ImageIO reporting success is not proof that EXIF/GPS survived.
        // Validate the new offset and pre-existing image metadata before upload.
        guard let rewritten = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceGetCount(rewritten) == CGImageSourceGetCount(source),
              existingOffset(in: rewritten) == offset,
              preservesOriginalProperties(from: source, to: rewritten)
        else {
            try? FileManager.default.removeItem(at: outputURL)
            return fileURL
        }
        return outputURL
    }

    private static func existingOffset(in source: CGImageSource) -> String? {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
           !offset.isEmpty {
            return offset
        }
        if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let offset = CGImageMetadataCopyStringValueWithPath(metadata, nil, offsetPath),
           !String(offset).isEmpty {
            return offset as String
        }
        return nil
    }

    /// Existing EXIF and GPS fields must survive the copy unchanged.
    private static func preservesOriginalProperties(from original: CGImageSource, to rewritten: CGImageSource) -> Bool {
        guard let before = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any],
              let after = CGImageSourceCopyPropertiesAtIndex(rewritten, 0, nil) as? [String: Any] else {
            return false
        }
        for key in [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
            kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
            kCGImagePropertyPNGDictionary, kCGImagePropertyProfileName
        ] {
            guard equalIfPresent(before[key as String], after[key as String]) else { return false }
        }
        if let beforeExif = before[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            guard let afterExif = after[kCGImagePropertyExifDictionary as String] as? [String: Any] else {
                return false
            }
            for (key, value) in beforeExif where key != (kCGImagePropertyExifOffsetTimeOriginal as String) {
                guard equalIfPresent(value, afterExif[key]) else { return false }
            }
        }
        return true
    }

    private static func equalIfPresent(_ before: Any?, _ after: Any?) -> Bool {
        guard let before else { return true }
        guard let first = before as? NSObject, let second = after as? NSObject else { return false }
        return first.isEqual(second)
    }

    static func formattedOffset(_ secondsFromGMT: Int) -> String {
        let sign = secondsFromGMT < 0 ? "-" : "+"
        let absoluteSeconds = abs(secondsFromGMT)
        return String(format: "%@%02d:%02d", sign, absoluteSeconds / 3600, (absoluteSeconds % 3600) / 60)
    }
}
