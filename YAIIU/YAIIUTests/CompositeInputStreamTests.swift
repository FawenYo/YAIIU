import Foundation
import XCTest
@testable import YAIIU

final class CompositeInputStreamTests: XCTestCase {
    private func readAll(_ stream: InputStream, chunkSize: Int) throws -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        stream.open()
        defer { stream.close() }

        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { break }
            if count < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        XCTAssertEqual(stream.streamStatus, .atEnd)
        return bytes
    }

    private func withTempFile(_ bytes: Data, _ block: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try block(url)
    }

    func testMultipartSegmentsAcrossSmallReads() throws {
        try withTempFile(Data("asset-data".utf8)) { url in
            for chunkSize in [1, 2, 3, 7, 512 * 1024] {
                let stream = try XCTUnwrap(CompositeInputStream(
                    preamble: Data("HEADER".utf8),
                    fileURL: url,
                    epilogue: Data("FOOTER".utf8)
                ))
                XCTAssertEqual(try readAll(stream, chunkSize: chunkSize), Data("HEADERasset-dataFOOTER".utf8))
            }
        }
    }

    func testNewStreamReplaysEntireBodyAfterPartialConsumption() throws {
        try withTempFile(Data(repeating: 0x7b, count: 1024 * 1024)) { url in
            func makeStream() -> CompositeInputStream? {
                CompositeInputStream(preamble: Data("start".utf8), fileURL: url, epilogue: Data("end".utf8))
            }
            let first = try XCTUnwrap(makeStream())
            first.open()
            var prefix = [UInt8](repeating: 0, count: 13)
            XCTAssertEqual(first.read(&prefix, maxLength: prefix.count), 5)
            first.close()

            let replay = try XCTUnwrap(makeStream())
            let expected = Data("start".utf8) + Data(repeating: 0x7b, count: 1024 * 1024) + Data("end".utf8)
            XCTAssertEqual(try readAll(replay, chunkSize: 8192), expected)
        }
    }

    func testEmptyFileStillIncludesBothBoundaries() throws {
        try withTempFile(Data()) { url in
            let stream = try XCTUnwrap(CompositeInputStream(
                preamble: Data("before".utf8), fileURL: url, epilogue: Data("after".utf8)
            ))
            XCTAssertEqual(try readAll(stream, chunkSize: 2), Data("beforeafter".utf8))
        }
    }

    func testDeletedSourceFailsInsteadOfSilentlyTruncatingMultipartBody() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0x55]).write(to: url)
        let stream = try XCTUnwrap(CompositeInputStream(
            preamble: Data("before".utf8), fileURL: url, epilogue: Data("after".utf8)
        ))
        try FileManager.default.removeItem(at: url)
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), 6)
        XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), -1)
        XCTAssertEqual(stream.streamStatus, .error)
        XCTAssertNotNil(stream.streamError)
        stream.close()
    }
    private final class RecordingDelegate: NSObject, StreamDelegate {
        func stream(_ aStream: Stream, handle eventCode: Stream.Event) {}
    }

    func testStreamSupportsObjectiveCDelegateAndRunLoopLifecycle() throws {
        try withTempFile(Data("abc".utf8)) { url in
            let stream = try XCTUnwrap(CompositeInputStream(
                preamble: Data("PRE".utf8), fileURL: url, epilogue: Data("POST".utf8)
            ))
            let listener = RecordingDelegate()
            #if canImport(ObjectiveC)
            // Regression: URLSession previously raised NSInvalidArgumentException
            // when calling the abstract -setDelegate: implementation.
            _ = stream.perform(NSSelectorFromString("setDelegate:"), with: listener)
            #else
            stream.delegate = listener
            #endif
            XCTAssertTrue((stream.delegate as AnyObject) === listener)

            stream.schedule(in: RunLoop.current, forMode: .default)
            let unsupportedKey = Stream.PropertyKey(rawValue: "com.yaiiu.unknownStreamProperty")
            XCTAssertNil(stream.property(forKey: unsupportedKey))
            XCTAssertFalse(stream.setProperty(NSNumber(value: 1), forKey: unsupportedKey))

            XCTAssertEqual(try readAll(stream, chunkSize: 2), Data("PREabcPOST".utf8))
            var tail = [UInt8](repeating: 0, count: 8)
            XCTAssertEqual(stream.read(&tail, maxLength: tail.count), -1, "Closed streams are not readable")
            stream.remove(from: RunLoop.current, forMode: .default)
            stream.delegate = nil
            XCTAssertTrue((stream.delegate as AnyObject) === stream)
        }
    }

    func testReadingAgainAtEndReturnsZero() throws {
        try withTempFile(Data([0x10])) { url in
            let stream = try XCTUnwrap(CompositeInputStream(
                preamble: Data([0x01]), fileURL: url, epilogue: Data([0x02])
            ))
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8)
            while stream.read(&buffer, maxLength: buffer.count) > 0 {}
            XCTAssertEqual(stream.streamStatus, .atEnd)
            XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), 0)
        }
    }
}
