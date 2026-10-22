import Foundation

/// A replayable multipart upload body backed by bounded reads from a local file.
/// Create a new instance for each URLSession body-stream request; a stream itself
/// can only be consumed once.
final class CompositeInputStream: InputStream, StreamDelegate {
    private let parts: [InputStream]
    private var partIndex = 0
    private var currentStatus: Stream.Status = .notOpen
    private var currentError: Error?
    // NSStream's delegate must not be retained (avoids URLSession retain cycles).
    // A nil assignment restores the NSStream-defined self-delegation behavior.
    private weak var externalDelegate: StreamDelegate?
    private var scheduledRunLoops: [(RunLoop, RunLoop.Mode)] = []

    init?(preamble: Data, fileURL: URL, epilogue: Data) {
        guard let fileStream = InputStream(url: fileURL) else { return nil }
        parts = [InputStream(data: preamble), fileStream, InputStream(data: epilogue)]
        super.init(data: Data())
    }

    override var delegate: StreamDelegate? {
        get { externalDelegate ?? self }
        set {
            if let newValue, (newValue as AnyObject) !== self {
                externalDelegate = newValue
            } else {
                externalDelegate = nil
            }
        }
    }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {
        // URLSession schedules NSInputStream on its own run loop. The underlying
        // concrete streams must be scheduled as well so they emit readiness events.
        guard !scheduledRunLoops.contains(where: { $0.0 === aRunLoop && $0.1 == mode }) else { return }
        scheduledRunLoops.append((aRunLoop, mode))
        for part in parts { part.schedule(in: aRunLoop, forMode: mode) }
    }

    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {
        for part in parts { part.remove(from: aRunLoop, forMode: mode) }
        scheduledRunLoops.removeAll { $0.0 === aRunLoop && $0.1 == mode }
    }

    #if canImport(ObjectiveC)
    override func property(forKey key: Stream.PropertyKey) -> Any? {
        guard partIndex < parts.count else { return nil }
        return parts[partIndex].property(forKey: key)
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard partIndex < parts.count else { return false }
        return parts[partIndex].setProperty(property, forKey: key)
    }
    #else
    override func property(forKey key: Stream.PropertyKey) -> AnyObject? {
        guard partIndex < parts.count else { return nil }
        return parts[partIndex].property(forKey: key)
    }

    override func setProperty(_ property: AnyObject?, forKey key: Stream.PropertyKey) -> Bool {
        guard partIndex < parts.count else { return false }
        return parts[partIndex].setProperty(property, forKey: key)
    }
    #endif

    override var streamStatus: Stream.Status { currentStatus }
    override var streamError: Error? { currentError }
    override var hasBytesAvailable: Bool {
        (currentStatus == .open || currentStatus == .reading) && partIndex < parts.count
    }

    override func open() {
        guard currentStatus == .notOpen else { return }
        currentStatus = .opening
        for part in parts { part.delegate = self }
        parts[0].open()
        if parts[0].streamStatus == .error {
            fail(parts[0].streamError)
        } else if currentStatus == .opening {
            currentStatus = .open
        }
    }

    override func close() {
        guard currentStatus != .closed else { return }
        for part in parts {
            part.close()
            part.delegate = nil
        }
        for (runLoop, mode) in scheduledRunLoops {
            for part in parts { part.remove(from: runLoop, forMode: mode) }
        }
        scheduledRunLoops.removeAll()
        currentStatus = .closed
    }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        // URLSession can ask for one more read after the final segment ended.
        guard currentStatus != .atEnd else { return 0 }
        guard currentStatus == .open || currentStatus == .reading else { return -1 }
        guard len > 0 else { return 0 }
        currentStatus = .reading

        while partIndex < parts.count {
            let indexBeforeRead = partIndex
            let source = parts[indexBeforeRead]
            let count = source.read(buffer, maxLength: len)
            if count > 0 {
                if currentStatus == .reading { currentStatus = .open }
                return count
            }
            if count < 0 {
                fail(source.streamError)
                return -1
            }
            // Concrete streams may send .endEncountered while inside read().
            // Do not advance twice if the delegate already advanced the part.
            if partIndex == indexBeforeRead { advancePart() }
            if currentStatus == .error { return -1 }
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

    // StreamDelegate receives events emitted by the three concrete InputStreams.
    // Only relay events for the currently active segment, never an intermediate
    // end-of-stream (which would make URLSession truncate the multipart body).
    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard currentStatus != .closed,
              currentStatus != .error,
              partIndex < parts.count,
              aStream === parts[partIndex] else { return }

        if eventCode.contains(.errorOccurred) {
            fail(aStream.streamError)
        } else if eventCode.contains(.endEncountered) {
            advancePart()
        } else {
            if eventCode.contains(.openCompleted) && currentStatus == .opening {
                currentStatus = .open
            }
            notifyClient(eventCode)
        }
    }

    private func advancePart() {
        guard partIndex < parts.count else { return }
        parts[partIndex].close()
        partIndex += 1
        if partIndex == parts.count {
            currentStatus = .atEnd
            notifyClient(.endEncountered)
            return
        }
        parts[partIndex].open()
        if parts[partIndex].streamStatus == .error {
            fail(parts[partIndex].streamError)
        }
    }

    private func notifyClient(_ event: Stream.Event) {
        // On Apple platforms this is an @objc optional protocol requirement;
        // swift-corelibs-foundation exposes it as a required method.
        #if canImport(ObjectiveC)
        externalDelegate?.stream?(self, handle: event)
        #else
        externalDelegate?.stream(self, handle: event)
        #endif
    }

    private func fail(_ error: Error?) {
        guard currentStatus != .error && currentStatus != .closed else { return }
        currentError = error ?? CocoaError(.fileReadUnknown)
        currentStatus = .error
        notifyClient(.errorOccurred)
    }
}
