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
        let stream = try XCTUnwrap(CompositeInputStream(
            preamble: Data("before".utf8), fileURL: url, epilogue: Data("after".utf8)
        ))
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), 6)
        XCTAssertEqual(stream.read(&buffer, maxLength: buffer.count), -1)
        XCTAssertEqual(stream.streamStatus, .error)
        XCTAssertNotNil(stream.streamError)
        stream.close()
    }
}
