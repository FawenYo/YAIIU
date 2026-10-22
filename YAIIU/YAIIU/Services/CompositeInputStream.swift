import Foundation

/// Replays a multipart body without buffering the entire asset. Each instance
/// owns fresh streams and must only be read by one URLSession upload task.
final class CompositeInputStream: InputStream {
    private let parts: [InputStream]
    private var partIndex = 0
    private var currentStatus: Stream.Status = .notOpen
    private var currentError: Error?

    init?(preamble: Data, fileURL: URL, epilogue: Data) {
        guard let fileStream = InputStream(url: fileURL) else { return nil }
        parts = [
            InputStream(data: preamble),
            fileStream,
            InputStream(data: epilogue)
        ]
        super.init(data: Data())
    }

    override var streamStatus: Stream.Status { currentStatus }
    override var streamError: Error? { currentError }

    override var hasBytesAvailable: Bool {
        (currentStatus == .open || currentStatus == .reading) && partIndex < parts.count
    }

    override func open() {
        guard currentStatus == .notOpen else { return }
        currentStatus = .opening
        parts[partIndex].open()
        if parts[partIndex].streamStatus == .error {
            currentError = parts[partIndex].streamError ?? CocoaError(.fileReadUnknown)
            currentStatus = .error
        } else {
            currentStatus = .open
        }
    }

    override func close() {
        for stream in parts { stream.close() }
        currentStatus = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard currentStatus == .open || currentStatus == .reading else { return -1 }
        guard len > 0 else { return 0 }

        currentStatus = .reading
        while partIndex < parts.count {
            let part = parts[partIndex]
            let count = part.read(buffer, maxLength: len)
            if count > 0 {
                currentStatus = .open
                return count
            }
            if count < 0 {
                currentError = part.streamError ?? CocoaError(.fileReadUnknown)
                currentStatus = .error
                return -1
            }

            part.close()
            partIndex += 1
            if partIndex < parts.count {
                parts[partIndex].open()
                if parts[partIndex].streamStatus == .error {
                    currentError = parts[partIndex].streamError ?? CocoaError(.fileReadUnknown)
                    currentStatus = .error
                    return -1
                }
            }
        }
        currentStatus = .atEnd
        return 0
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        buffer.pointee = nil
        len.pointee = 0
        return false
    }
}
