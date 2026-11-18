import Foundation
import Photos
import ImageIO

/// Delivers original photo-library bytes through a temp file for uploads, which
/// need a re-readable body for URLSession retries. Hashing streams through
/// `ResourceStreamHasher` instead.
///
/// The file is byte-identical to the concatenated `requestData` chunks, so
/// checksums computed from it match hash-cache entries. An earlier iOS release
/// was observed retaining ~10 MB per asset inside PhotoLibraryServicesCore when
/// using `requestData`; on iOS 27.0.1 streamed hashing stayed flat in memory,
/// including a 185 MB video.
enum ResourceFileAccess {

    /// Writes the resource's original data to a fresh temp file and returns its
    /// URL. The caller owns the file and must delete it when done.
    ///
    /// `writeData` has no public cancellation API; cancellation is reported
    /// after PhotoKit finishes so callers keep their admission until then.
    static func tempFile(for resource: PHAssetResource) async throws -> URL {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-\(UUID().uuidString)")
            .appendingPathExtension("bin")

        let state = WriteState(fileURL: fileURL)
        let startedAt = Date()
        logDebug(
            "Resource file request started: type=\(String(describing: resource.type)), networkAllowed=true",
            category: .hash
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard state.install(continuation) else { return }
                manager.writeData(for: resource, toFile: fileURL, options: options) { error in
                    if state.complete(error: error) {
                        let size = state.fileSize(at: fileURL)
                        logDebug(
                            "Resource file request finished: type=\(String(describing: resource.type)), bytes=\(size), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s",
                            category: .hash
                        )
                    }
                    // Cancellation cannot stop PhotoKit; cleanup and caller
                    // resumption happen only after the write actually finishes.
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    /// Byte size of a delivered temp file; 0 if it no longer exists.
    static func size(of fileURL: URL) -> Int64 {
        Int64(((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0)
    }

    /// Final state of a `writeData` request: exactly one resume; file cleanup on
    /// every terminal path (error, cancellation-after-completion).
    private final class WriteState: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var isCancelled = false
        private let fileURL: URL

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        func install(_ continuation: CheckedContinuation<URL, Error>) -> Bool {
            lock.lock()
            if isCancelled {
                lock.unlock()
                removeFile()
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }
        /// Returns true if the continuation was resumed here with success.
        func complete(error: Error?) -> Bool {
            lock.lock()
            guard let continuation else {
                lock.unlock()
                removeFile()
                return false
            }
            self.continuation = nil
            let cancelled = isCancelled
            lock.unlock()

            if cancelled {
                removeFile()
                continuation.resume(throwing: CancellationError())
                return false
            }
            if let error {
                removeFile()
                continuation.resume(throwing: error)
                return false
            }
            continuation.resume(returning: fileURL)
            return true
        }

        /// Cancellation cannot stop the in-flight write. Keep the continuation
        /// pending until PhotoKit completes so callers retain disk accounting.
        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        private func removeFile() {
            try? FileManager.default.removeItem(at: fileURL)
        }

        func fileSize(at url: URL) -> Int {
            ((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize) ?? 0
        }
    }
}

/// Exactly-once state for one streamed `requestData` hash. Like the `writeData`
/// path, cancellation stops hashing but keeps the continuation pending until
/// PhotoKit reports completion, so callers hold their admission until the
/// request has actually drained.
final class StreamingHashRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let sha1 = StreamingSHA1()
    private var continuation: CheckedContinuation<(hash: String, size: Int), Error>?
    private var cancelRequest: (() -> Void)?
    private var isCancelled = false
    private var isFinished = false

    /// Returns false when already cancelled; the continuation is resumed here.
    func install(_ continuation: CheckedContinuation<(hash: String, size: Int), Error>) -> Bool {
        lock.lock()
        if isCancelled {
            isFinished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Runs `cancel` immediately when cancellation already happened.
    func attachCancellation(_ cancel: @escaping () -> Void) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            cancel()
            return
        }
        cancelRequest = cancel
        lock.unlock()
    }

    func receive(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled, !isFinished else { return }
        sha1.update(data: chunk)
    }

    func finish(error: Error?) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        let cancelled = isCancelled
        let result = !cancelled && error == nil ? (sha1.finalize(), sha1.totalSize) : nil
        lock.unlock()

        if cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else if let result {
            continuation.resume(returning: result)
        }
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }
        isCancelled = true
        let cancelRequest = self.cancelRequest
        self.cancelRequest = nil
        lock.unlock()

        cancelRequest?()
    }
}

/// Hashes a resource from `requestData` chunks without writing a temp file.
enum ResourceStreamHasher {
    static func sha1Hex(of resource: PHAssetResource) async throws -> (hash: String, size: Int) {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let request = StreamingHashRequest()
        let startedAt = Date()

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { chunk in
                        // Drain anything autoreleased while consuming a chunk so
                        // profiling isolates retention inside PhotoKit itself.
                        autoreleasepool {
                            request.receive(chunk)
                        }
                    },
                    completionHandler: { error in
                        request.finish(error: error)
                    }
                )
                request.attachCancellation {
                    manager.cancelDataRequest(requestID)
                }
            }
        } onCancel: {
            request.cancel()
        }

        logDebug(
            "Resource stream hashed: type=\(String(describing: resource.type)), bytes=\(result.size), elapsed=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s",
            category: .hash
        )
        return result
    }
}

/// Reads image properties from the head of a resource instead of copying the
/// whole original: the PhotoKit request is cancelled as soon as ImageIO finds
/// EXIF. JPEG, HEIF and DNG keep their metadata ahead of the image data.
enum ResourceMetadataReader {
    /// Files whose EXIF sits past this point (e.g. trailing TIFF IFDs) report none
    /// rather than holding a whole RAW original in memory.
    static let maxBytes = 16 * 1024 * 1024

    /// Returns an empty dictionary on failure or task cancellation; cancelling
    /// the task also cancels the PhotoKit request and any iCloud download.
    static func properties(of resource: PHAssetResource) async -> [String: Any] {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let request = MetadataRequest()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard request.install(continuation) else { return }
                let requestID = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { chunk in
                        autoreleasepool {
                            request.receive(chunk)
                        }
                    },
                    completionHandler: { _ in
                        request.finish()
                    }
                )
                request.attachCancellation {
                    manager.cancelDataRequest(requestID)
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    static func imageProperties(from data: Data) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
    }

    /// Exactly-once resume; the PhotoKit request is cancelled on every early exit.
    private final class MetadataRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var continuation: CheckedContinuation<[String: Any], Never>?
        private var cancelRequest: (() -> Void)?
        private var isDone = false

        /// Returns false when already cancelled; the continuation is resumed here.
        func install(_ continuation: CheckedContinuation<[String: Any], Never>) -> Bool {
            lock.lock()
            if isDone {
                lock.unlock()
                continuation.resume(returning: [:])
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        /// Runs `cancel` immediately when the read already ended.
        func attachCancellation(_ cancel: @escaping () -> Void) {
            lock.lock()
            if isDone {
                lock.unlock()
                cancel()
                return
            }
            cancelRequest = cancel
            lock.unlock()
        }

        func receive(_ chunk: Data) {
            lock.lock()
            guard !isDone else {
                lock.unlock()
                return
            }
            data.append(chunk)
            let properties = ResourceMetadataReader.imageProperties(from: data)
            let hasExif = properties?[kCGImagePropertyExifDictionary as String] != nil
            guard hasExif || data.count >= ResourceMetadataReader.maxBytes else {
                lock.unlock()
                return
            }
            let (continuation, cancelRequest) = end()
            lock.unlock()
            cancelRequest?()
            continuation?.resume(returning: properties ?? [:])
        }

        /// The request delivered the whole file (or failed) without EXIF being found early.
        func finish() {
            lock.lock()
            guard !isDone else {
                lock.unlock()
                return
            }
            let properties = ResourceMetadataReader.imageProperties(from: data)
            let (continuation, _) = end()
            lock.unlock()
            continuation?.resume(returning: properties ?? [:])
        }

        func cancel() {
            lock.lock()
            guard !isDone else {
                lock.unlock()
                return
            }
            let (continuation, cancelRequest) = end()
            lock.unlock()
            cancelRequest?()
            continuation?.resume(returning: [:])
        }

        /// Caller holds the lock.
        private func end() -> (CheckedContinuation<[String: Any], Never>?, (() -> Void)?) {
            isDone = true
            data = Data()
            defer {
                continuation = nil
                cancelRequest = nil
            }
            return (continuation, cancelRequest)
        }
    }
}

/// Reads `fileURL` with a fixed-size buffer and returns its SHA1 hex digest.
/// Memory is bounded by `chunkSize` regardless of file size.
enum FileHasher {
    static let chunkSize = 512 * 1024

    /// Throws `CancellationError` between chunks so a stopped run releases
    /// large-file hashing promptly.
    static func sha1Hex(
        ofFileAt fileURL: URL,
        shouldCancel: () -> Bool = { Task.isCancelled }
    ) throws -> (hash: String, size: Int) {
        let sha1 = StreamingSHA1()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        while true {
            if shouldCancel() {
                throw CancellationError()
            }

            let chunk = try autoreleasepool(invoking: {
                try handle.read(upToCount: chunkSize)
            })
            guard let chunk, !chunk.isEmpty else { break }
            sha1.update(data: chunk)
        }

        if shouldCancel() {
            throw CancellationError()
        }
        return (sha1.finalize(), sha1.totalSize)
    }
}
