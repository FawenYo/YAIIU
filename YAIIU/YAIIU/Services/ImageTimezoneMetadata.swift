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
        if mimeType.lowercased() == "image/png" {
            // Keep all PNG chunks intact, replacing only the TIFF eXIf payload.
            // ImageIO's metadata copy changes some screenshots' UserComment.
            guard let outputURL = PNGExifTimezoneEditor.addingOffsetIfMissing(to: fileURL, offset: offset) else {
                logWarning("Capture timezone skipped for \(filename): could not update PNG eXIf safely", category: .upload)
                return fileURL
            }
            guard let verified = CGImageSourceCreateWithURL(outputURL as CFURL, nil),
                  existingOffset(in: verified) == offset,
                  propertyMismatch(from: source, to: verified, mimeType: mimeType) == nil
            else {
                logWarning("Capture timezone skipped for \(filename): PNG EXIF validation failed", category: .upload)
                try? FileManager.default.removeItem(at: outputURL)
                return fileURL
            }
            logInfo("Added capture timezone \(offset) to \(filename)", category: .upload)
            return outputURL
        }

        let metadata: CGMutableImageMetadata
        if let sourceMetadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
           let copiedMetadata = CGImageMetadataCreateMutableCopy(sourceMetadata) {
            metadata = copiedMetadata
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        if mimeType.lowercased() == "image/png",
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
           let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
           let comment = exif[kCGImagePropertyExifUserComment as String] as? String,
           !comment.isEmpty {
            let path = "exif:UserComment" as CFString
            guard CGImageMetadataSetValueWithPath(metadata, nil, path, comment as CFString) else {
                logWarning("Capture timezone skipped for \(filename): unable to carry EXIF UserComment", category: .upload)
                return fileURL
            }
        }
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
            kCGImagePropertyOrientation,
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
            let requiredEXIFKeys = Array(beforeExif.keys).filter {
                $0 != (kCGImagePropertyExifOffsetTimeOriginal as String)
            }
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
                kCGImagePropertyTIFFOrientation as String,
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

    
/// Changes only the PNG eXIf chunk. All IDAT, ICC, XMP and other PNG chunks
/// are copied byte-for-byte, avoiding ImageIO's EXIF UserComment conversions.
private enum PNGExifTimezoneEditor {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private struct Chunk {
        let start: Int
        let end: Int
        let name: String
        let dataStart: Int
        let dataLength: Int
    }

    static func addingOffsetIfMissing(to source: URL, offset: String) -> URL? {
        guard let original = try? Data(contentsOf: source),
              original.count <= 64 * 1024 * 1024,
              let changed = addingOffset(to: original, offset: offset) else {
            return nil
        }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-timezone-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try changed.write(to: output, options: .atomic)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
    }

    private static func addingOffset(to png: Data, offset: String) -> Data? {
        guard png.count >= 20, Array(png.prefix(8)) == signature else { return nil }

        var chunks: [Chunk] = []
        var cursor = 8
        var exifCount = 0
        var reachedEnd = false
        while cursor < png.count {
            guard png.count - cursor >= 12,
                  let dataLength = bigEndian32(png, cursor),
                  dataLength <= png.count - cursor - 12,
                  let name = String(data: png.subdata(in: (cursor + 4)..<(cursor + 8)), encoding: .ascii)
            else { return nil }
            let end = cursor + 12 + dataLength
            if name == "eXIf" { exifCount += 1 }
            chunks.append(Chunk(start: cursor, end: end, name: name,
                                dataStart: cursor + 8, dataLength: dataLength))
            cursor = end
            if name == "IEND" {
                reachedEnd = true
                break
            }
        }
        guard reachedEnd, cursor == png.count, exifCount <= 1,
              chunks.first?.name == "IHDR" else { return nil }

        let existingExif = chunks.first(where: { $0.name == "eXIf" })
        let tiff = existingExif.map { Array(png[$0.dataStart..<($0.dataStart + $0.dataLength)]) } ?? []
        guard let updatedExif = addOffset(toTIFF: tiff, offset: offset) else { return nil }

        var output = Data()
        output.append(contentsOf: signature)
        var inserted = false
        for chunk in chunks {
            if existingExif == nil && !inserted && (chunk.name == "IDAT" || chunk.name == "IEND") {
                output.append(exifChunk(tiff: updatedExif))
                inserted = true
            }
            if chunk.name == "eXIf" {
                output.append(exifChunk(tiff: updatedExif))
                inserted = true
            } else {
                output.append(png[chunk.start..<chunk.end])
            }
        }
        guard inserted else { return nil }
        return output
    }

    // TIFF offsets are relative to the beginning of the eXIf payload, not
    // to the PNG file. Append a new ExifIFD so existing tag data and offsets
    // (including UserComment and maker data) are never relocated.
    private static func addOffset(toTIFF input: [UInt8], offset: String) -> [UInt8]? {
        guard offset.utf8.count == 6,
              (offset.first == "+" || offset.first == "-") else { return nil }
        if input.isEmpty { return minimalTIFF(offset: offset) }

        var tiff = input
        guard tiff.count >= 8,
              tiff[0] == tiff[1],
              (tiff[0] == 0x49 || tiff[0] == 0x4D) else { return nil }
        let little = tiff[0] == 0x49
        guard read16(tiff, 2, little) == 42,
              let ifd0Offset = read32(tiff, 4, little),
              let ifd0 = readIFD(tiff, ifd0Offset, little) else { return nil }

        var originalExifEntries: [[UInt8]] = []
        var originalExifNext = 0
        var pointerEntry: Int?
        for (index, entry) in ifd0.entries.enumerated() {
            if read16(entry, 0, little) == 0x8769 {
                guard pointerEntry == nil, read16(entry, 2, little) == 4,
                      read32(entry, 4, little) == 1,
                      let exifOffset = read32(entry, 8, little) else { return nil }
                pointerEntry = ifd0Offset + 2 + 12 * index
                if exifOffset != 0 {
                    guard let exifIFD = readIFD(tiff, exifOffset, little) else { return nil }
                    originalExifEntries = exifIFD.entries
                    originalExifNext = exifIFD.next
                }
            }
        }
        // Do not overwrite an existing offset even if ImageIO cannot read it.
        if originalExifEntries.contains(where: { read16($0, 0, little) == 0x9011 }) {
            return nil
        }
        guard originalExifEntries.count < Int(UInt16.max),
              tiff.count < Int(UInt32.max) - 4096 else { return nil }

        // New ExifIFD containing the old untouched entries plus OffsetTimeOriginal.
        if tiff.count % 2 != 0 { tiff.append(0) }
        let exifIfdOffset = tiff.count
        let newEntryCount = originalExifEntries.count + 1
        let valueOffset = exifIfdOffset + 2 + 12 * newEntryCount + 4
        var newEntry = [UInt8](repeating: 0, count: 12)
        write16(&newEntry, at: 0, 0x9011, little)
        write16(&newEntry, at: 2, 2, little) // ASCII
        write32(&newEntry, at: 4, 7, little) // "+08:00" + NUL
        write32(&newEntry, at: 8, valueOffset, little)

        var entries = originalExifEntries
        entries.append(newEntry)
        entries.sort { (read16($0, 0, little) ?? 0) < (read16($1, 0, little) ?? 0) }
        append16(&tiff, entries.count, little)
        for entry in entries { tiff.append(contentsOf: entry) }
        append32(&tiff, originalExifNext, little)
        tiff.append(contentsOf: offset.utf8)
        tiff.append(0)

        if let pointerEntry {
            write32(&tiff, at: pointerEntry + 8, exifIfdOffset, little)
        } else {
            // Existing PNG eXIf may contain only IFD0 fields.
            // Append a new IFD0 with the old entries and an ExifIFD pointer.
            if tiff.count % 2 != 0 { tiff.append(0) }
            let newIFD0Offset = tiff.count
            guard ifd0.entries.count < Int(UInt16.max) else { return nil }
            var newPointer = [UInt8](repeating: 0, count: 12)
            write16(&newPointer, at: 0, 0x8769, little)
            write16(&newPointer, at: 2, 4, little) // LONG
            write32(&newPointer, at: 4, 1, little)
            write32(&newPointer, at: 8, exifIfdOffset, little)
            var rootEntries = ifd0.entries
            rootEntries.append(newPointer)
            rootEntries.sort { (read16($0, 0, little) ?? 0) < (read16($1, 0, little) ?? 0) }
            append16(&tiff, rootEntries.count, little)
            for entry in rootEntries { tiff.append(contentsOf: entry) }
            append32(&tiff, ifd0.next, little)
            write32(&tiff, at: 4, newIFD0Offset, little)
        }
        return tiff
    }

    private struct IFD {
        let entries: [[UInt8]]
        let next: Int
    }

    private static func readIFD(_ data: [UInt8], _ start: Int, _ little: Bool) -> IFD? {
        guard let count = read16(data, start, little),
              count <= (data.count - start - 6) / 12,
              start >= 0 else { return nil }
        let afterEntries = start + 2 + count * 12
        guard let next = read32(data, afterEntries, little) else { return nil }
        let entries = (0..<count).map { index in
            Array(data[(start + 2 + 12 * index)..<(start + 2 + 12 * (index + 1))])
        }
        return IFD(entries: entries, next: next)
    }

    private static func minimalTIFF(offset: String) -> [UInt8] {
        // A new eXIf chunk is valid even when the PNG had no previous EXIF.
        var b: [UInt8] = [0x49, 0x49, 42, 0, 8, 0, 0, 0]
        append16(&b, 1, true)
        append16(&b, 0x8769, true)
        append16(&b, 4, true)
        append32(&b, 1, true)
        append32(&b, 26, true)
        append32(&b, 0, true)
        append16(&b, 1, true)
        append16(&b, 0x9011, true)
        append16(&b, 2, true)
        append32(&b, 7, true)
        append32(&b, 44, true)
        append32(&b, 0, true)
        b.append(contentsOf: offset.utf8)
        b.append(0)
        return b
    }

    private static func exifChunk(tiff: [UInt8]) -> Data {
        let type: [UInt8] = [101, 88, 73, 102] // eXIf
        var chunk = Data()
        appendBigEndian32(&chunk, tiff.count)
        chunk.append(contentsOf: type)
        chunk.append(contentsOf: tiff)
        var crc: UInt32 = 0xFFFFFFFF
        for byte in type + tiff {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        appendBigEndian32(&chunk, Int(crc ^ 0xFFFFFFFF))
        return chunk
    }

    private static func bigEndian32(_ data: Data, _ index: Int) -> Int? {
        guard index >= 0, index <= data.count - 4 else { return nil }
        return Int(data[index]) << 24 | Int(data[index + 1]) << 16 |
            Int(data[index + 2]) << 8 | Int(data[index + 3])
    }

    private static func appendBigEndian32(_ output: inout Data, _ value: Int) {
        output.append(UInt8(truncatingIfNeeded: value >> 24))
        output.append(UInt8(truncatingIfNeeded: value >> 16))
        output.append(UInt8(truncatingIfNeeded: value >> 8))
        output.append(UInt8(truncatingIfNeeded: value))
    }

    private static func read16(_ bytes: [UInt8], _ pos: Int, _ little: Bool) -> Int? {
        guard pos >= 0, pos <= bytes.count - 2 else { return nil }
        return little ? Int(bytes[pos]) | (Int(bytes[pos + 1]) << 8)
                      : (Int(bytes[pos]) << 8) | Int(bytes[pos + 1])
    }

    private static func read32(_ bytes: [UInt8], _ pos: Int, _ little: Bool) -> Int? {
        guard pos >= 0, pos <= bytes.count - 4 else { return nil }
        let a = bytes[pos], b = bytes[pos + 1], c = bytes[pos + 2], d = bytes[pos + 3]
        return little ? Int(a) | Int(b) << 8 | Int(c) << 16 | Int(d) << 24
                      : Int(a) << 24 | Int(b) << 16 | Int(c) << 8 | Int(d)
    }

    private static func write16(_ bytes: inout [UInt8], at pos: Int, _ value: Int, _ little: Bool) {
        bytes[pos] = UInt8(truncatingIfNeeded: little ? value : value >> 8)
        bytes[pos + 1] = UInt8(truncatingIfNeeded: little ? value >> 8 : value)
    }

    private static func write32(_ bytes: inout [UInt8], at pos: Int, _ value: Int, _ little: Bool) {
        for index in 0..<4 {
            let shift = little ? index * 8 : (3 - index) * 8
            bytes[pos + index] = UInt8(truncatingIfNeeded: value >> shift)
        }
    }

    private static func append16(_ bytes: inout [UInt8], _ value: Int, _ little: Bool) {
        let start = bytes.count
        bytes.append(contentsOf: [0, 0])
        write16(&bytes, at: start, value, little)
    }

    private static func append32(_ bytes: inout [UInt8], _ value: Int, _ little: Bool) {
        let start = bytes.count
        bytes.append(contentsOf: [0, 0, 0, 0])
        write32(&bytes, at: start, value, little)
    }
}
