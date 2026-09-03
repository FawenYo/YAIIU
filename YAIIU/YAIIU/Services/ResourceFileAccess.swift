import Foundation
import Photos

/// Delivers original photo-library bytes through a temp file instead of the
/// `requestData` chunk stream.
///
/// PhotoKit's `requestData` retains copies of every delivered chunk inside
/// PhotoLibraryServicesCore and never releases them (verified via Instruments:
/// ~10 MB pinned per hashed asset, app jetsam-killed after a few hundred
/// photos). `writeData(for:toFile:...)` writes the same bytes straight to a
/// caller-owned file, so peak memory stays constant at the read buffer size.
/// The file is byte-identical to the concatenated `requestData` chunks, so
/// checksums computed this way match existing hash-cache entries.
enum ResourceFileAccess {

    /// Writes the resource's original data to a fresh temp file and returns its
    /// URL. The caller owns the file and must delete it when done.
    ///
    /// `writeData` has no public cancellation API; cancellation is reported
    /// after PhotoKit finishes so callers keep disk reservations charged.
    static func tempFile(for resource: PHAssetResource) async throws -> URL {
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("resource-\(UUID().uuidString)")
            .appendingPathExtension("bin")

        let state = WriteState(fileURL: fileURL)
        let startedAt = Date()
        logInfo(
            "Resource file request started: type=\(String(describing: resource.type)), networkAllowed=true",
            category: .hash
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard state.install(continuation) else { return }
                manager.writeData(for: resource, toFile: fileURL, options: options) { error in
                    if state.complete(error: error) {
                        let size = state.fileSize(at: fileURL)
                        logInfo(
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

/// Reads `fileURL` with a fixed-size buffer and returns its SHA1 hex digest.
/// Memory is bounded by `chunkSize` regardless of file size.
enum FileHasher {
    static let chunkSize = 512 * 1024

    /// Throws `CancellationError` between chunks so a stopped run releases
    /// large-file hashing promptly.
    static func sha1Hex(ofFileAt fileURL: URL) throws -> (hash: String, size: Int) {
        let sha1 = StreamingSHA1()
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        while true {
            let chunk = try autoreleasepool(invoking: { () throws -> Data? in
                guard !Task.isCancelled else { return nil }
                return try handle.read(upToCount: chunkSize)
            })
            guard let chunk, !chunk.isEmpty else { break }
            sha1.update(data: chunk)
        }

        if Task.isCancelled {
            throw CancellationError()
        }
        return (sha1.finalize(), sha1.totalSize)
    }
}
