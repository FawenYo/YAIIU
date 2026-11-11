import XCTest
@testable import YAIIU

final class LogFileWriterTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogFileWriterTests-\(UUID().uuidString).log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testAppendsAreNeverTruncatedAndResumeAfterRemoval() throws {
        let writer = LogFileWriter(fileURL: fileURL)
        for index in 0..<2_000 {
            writer.appendLine(String(format: "line-%04d", index))
        }
        // appendSync drains the serial queue, so all async appends are on disk.
        writer.appendSync(level: .info, category: "Test", message: "last")
        let lines = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2_001)
        XCTAssertEqual(lines.first, "line-0000")

        writer.removeFile()
        writer.appendSync(level: .info, category: "Test", message: "fresh")
        let fresh = try String(contentsOf: fileURL, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(fresh.count, 1)
        XCTAssertTrue(fresh[0].hasSuffix("fresh"))
    }

    func testReadTailDropsLeadingPartialLine() throws {
        try Data("alpha\nbravo\ncharlie\n".utf8).write(to: fileURL)
        let tail = try XCTUnwrap(LogFileWriter.readTail(of: fileURL, maxBytes: 10))
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), "charlie\n")
    }

    func testReadTailKeepsFirstLineStartingExactlyAtOffset() throws {
        try Data("alpha\nbravo\ncharlie\n".utf8).write(to: fileURL)
        let tail = try XCTUnwrap(LogFileWriter.readTail(of: fileURL, maxBytes: 14))
        XCTAssertEqual(String(decoding: tail, as: UTF8.self), "bravo\ncharlie\n")
    }
}
