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
        guard canRewrite(filename: filename, mimeType: mimeType) else { return fileURL }
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source),
              (type as String) == (mimeType.lowercased() == "image/png" ? "public.png" : "public.jpeg")
        else {
            logWarning("Capture timezone skipped for \(filename): could not decode expected image format", category: .upload)
            return fileURL
        }

        // Check the native ExifIFD first: the XMP path alone may miss a camera's
        // original OffsetTimeOriginal and incorrectly trigger a rewrite.
        guard existingOffset(in: source) == nil else { return fileURL }

        let offset = formattedOffset(timezone.secondsFromGMT(for: date))
        let metadata = CGImageMetadataCreateMutable()
        guard CGImageMetadataSetValueWithPath(metadata, nil, offsetPath, offset as CFString) else {
            logWarning("Capture timezone skipped for \(filename): could not construct EXIF offset", category: .upload)
            return fileURL
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-timezone-\(UUID().uuidString)")
            .appendingPathExtension(mimeType.lowercased() == "image/png" ? "png" : "jpg")
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, type, CGImageSourceGetCount(source), nil
        ) else {
            logWarning("Capture timezone skipped for \(filename): ImageIO destination unavailable", category: .upload)
            return fileURL
        }

        let options = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ] as CFDictionary
        guard CGImageDestinationCopyImageSource(destination, source, options, nil) else {
            logWarning("Capture timezone skipped for \(filename): ImageIO metadata copy failed", category: .upload)
            try? FileManager.default.removeItem(at: outputURL)
            return fileURL
        }

        // ImageIO reporting success is not proof that EXIF/GPS survived.
        // Validate the new offset and pre-existing image metadata before upload.
        guard let rewritten = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
              CGImageSourceGetCount(rewritten) == CGImageSourceGetCount(source)
        else {
            logWarning("Capture timezone skipped for \(filename): rewritten image could not be decoded", category: .upload)
            try? FileManager.default.removeItem(at: outputURL)
            return fileURL
        }
        guard existingOffset(in: rewritten) == offset else {
            logWarning("Capture timezone skipped for \(filename): output EXIF offset was not retained", category: .upload)
            try? FileManager.default.removeItem(at: outputURL)
            return fileURL
        }
        if let mismatch = propertyMismatch(from: source, to: rewritten, mimeType: mimeType) {
            logWarning("Capture timezone skipped for \(filename): \(mismatch)", category: .upload)
            try? FileManager.default.removeItem(at: outputURL)
            return fileURL
        }
        logInfo("Added capture timezone \(offset) to \(filename)", category: .upload)
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
            return String(offset)
        }
        return nil
    }

    /// Camera JPEGs remain strictly protected. PNG metadata-only copies can
    /// normalize ancillary PNG/TIFF dictionaries; reject only changes to the
    /// screenshot's significant properties instead of whole-dictionary equality.
    private static func propertyMismatch(
        from original: CGImageSource,
        to rewritten: CGImageSource,
        mimeType: String
    ) -> String? {
        guard let before = CGImageSourceCopyPropertiesAtIndex(original, 0, nil) as? [String: Any],
              let after = CGImageSourceCopyPropertiesAtIndex(rewritten, 0, nil) as? [String: Any] else {
            return "image properties were unavailable"
        }

        let isPNG = mimeType.lowercased() == "image/png"
        let pixelKeys: [CFString] = [
            kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
            kCGImagePropertyDepth, kCGImagePropertyColorModel,
            kCGImagePropertyHasAlpha, kCGImagePropertyProfileName,
        ]
        for key in pixelKeys {
            if !equalIfPresent(before[key as String], after[key as String]) {
                return "image dimensions, bit depth, or color profile changed (\(key))"
            }
        }

        // Other formats, notably JPEG, keep the original stricter checks.
        if !isPNG {
            for key in [
                kCGImagePropertyGPSDictionary, kCGImagePropertyTIFFDictionary,
                kCGImagePropertyPNGDictionary,
            ] {
                if !equalIfPresent(before[key as String], after[key as String]) {
                    return "existing metadata changed (\(key))"
                }
            }
        }

        let exifKey = kCGImagePropertyExifDictionary as String
        if let beforeExif = before[exifKey] as? [String: Any] {
            guard let afterExif = after[exifKey] as? [String: Any] else {
                return "EXIF metadata disappeared"
            }
            let requiredEXIFKeys: [String] = isPNG
                ? [
                    kCGImagePropertyExifDateTimeOriginal as String,
                    kCGImagePropertyExifDateTimeDigitized as String,
                    kCGImagePropertyExifUserComment as String,
                ]
                : Array(beforeExif.keys).filter { $0 != (kCGImagePropertyExifOffsetTimeOriginal as String) }
            for key in requiredEXIFKeys {
                if !equalIfPresent(beforeExif[key], afterExif[key]) {
                    return "existing EXIF field changed (\(key))"
                }
            }
        }

        if isPNG {
            let tiffKey = kCGImagePropertyTIFFDictionary as String
            let beforeTIFF = before[tiffKey] as? [String: Any]
            let afterTIFF = after[tiffKey] as? [String: Any]
            for key in [
                kCGImagePropertyTIFFDateTime as String,
                kCGImagePropertyTIFFMake as String,
                kCGImagePropertyTIFFModel as String,
            ] {
                if !equalIfPresent(beforeTIFF?[key], afterTIFF?[key]) {
                    return "existing TIFF field changed (\(key))"
                }
            }

            let gpsKey = kCGImagePropertyGPSDictionary as String
            let beforeGPS = before[gpsKey] as? [String: Any]
            let afterGPS = after[gpsKey] as? [String: Any]
            for key in [
                kCGImagePropertyGPSLatitude as String,
                kCGImagePropertyGPSLatitudeRef as String,
                kCGImagePropertyGPSLongitude as String,
                kCGImagePropertyGPSLongitudeRef as String,
            ] {
                if !equalIfPresent(beforeGPS?[key], afterGPS?[key]) {
                    return "existing GPS field changed (\(key))"
                }
            }

            // Screenshots sometimes carry their creation date only in XMP.
            if let oldMetadata = CGImageSourceCopyMetadataAtIndex(original, 0, nil) {
                let newMetadata = CGImageSourceCopyMetadataAtIndex(rewritten, 0, nil)
                for path in ["photoshop:DateCreated", "xmp:CreateDate", "exif:DateTimeOriginal"] {
                    let tagPath = path as CFString
                    if let oldValue = CGImageMetadataCopyStringValueWithPath(oldMetadata, nil, tagPath),
                       String(oldValue) != newMetadata
                            .flatMap({ CGImageMetadataCopyStringValueWithPath($0, nil, tagPath) })
                            .map({ String($0) }) {
                        return "original XMP capture date changed (\(path))"
                    }
                }
            }
        }
        return nil
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
