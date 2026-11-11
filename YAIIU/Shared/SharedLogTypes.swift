import Foundation

// MARK: - Log Level

/// Represents severity levels for log entries.
/// Shared between main app and background upload extension.
public enum LogLevel: String, CaseIterable, Comparable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    
    public var symbol: String {
        switch self {
        case .debug: return "[D]"
        case .info: return "[I]"
        case .warning: return "[W]"
        case .error: return "[E]"
        }
    }
    
    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
    
    /// Initialize from single-character abbreviation (D, I, W, E)
    public init?(abbreviation: String) {
        switch abbreviation.uppercased() {
        case "D": self = .debug
        case "I": self = .info
        case "W": self = .warning
        case "E": self = .error
        default: return nil
        }
    }
}

// MARK: - Log Category

/// Categories for organizing log entries by subsystem.
public enum LogCategory: String, Sendable {
    case app = "App"
    case api = "API"
    case upload = "Upload"
    case database = "Database"
    case photoLibrary = "PhotoLibrary"
    case hash = "Hash"
    case settings = "Settings"
    case importer = "Importer"
    case backgroundUpload = "BackgroundUpload"
    case sync = "Sync"
}

// MARK: - Log Formatting

/// Provides unified log formatting utilities shared across app and extensions.
public enum LogFormatter {
    
    /// Shared timestamp formatter using local timezone.
    /// Format: "yyyy-MM-dd HH:mm:ss.SSS"
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    /// Regex pattern for parsing unified log format.
    /// Captures: (1) timestamp, (2) level char, (3) category, (4) message
    public static let unifiedLogPattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \[([DIWE])\] \[([^\]]+)\] (.+)$"#
    
    private static let unifiedLogRegex = try! NSRegularExpression(pattern: unifiedLogPattern)
    
    /// Format a date to log timestamp string.
    public static func formatTimestamp(_ date: Date) -> String {
        return timestampFormatter.string(from: date)
    }
    
    /// Parse a timestamp string to Date.
    public static func parseTimestamp(_ string: String) -> Date? {
        return timestampFormatter.date(from: string)
    }
    
    /// Format a complete log entry string.
    /// Output: "2024-01-01 12:00:00.000 [I] [Category] Message"
    public static func formatLogEntry(
        timestamp: Date,
        level: LogLevel,
        category: String,
        message: String
    ) -> String {
        let ts = formatTimestamp(timestamp)
        return "\(ts) \(level.symbol) [\(category)] \(message)"
    }
    
    /// Parse a log line into components.
    /// Returns nil if the line doesn't match the expected format.
    public static func parseLogLine(_ line: String) -> ParsedLogEntry? {
        guard let match = unifiedLogRegex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
              let timestampRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let categoryRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line) else {
            return nil
        }
        
        let timestampStr = String(line[timestampRange])
        let levelChar = String(line[levelRange])
        let category = String(line[categoryRange])
        let message = String(line[messageRange])
        
        guard let timestamp = parseTimestamp(timestampStr),
              let level = LogLevel(abbreviation: levelChar) else {
            return nil
        }
        
        return ParsedLogEntry(
            timestamp: timestamp,
            level: level,
            category: category,
            message: message
        )
    }
}

// MARK: - Parsed Log Entry

/// Represents a parsed log entry with structured data.
public struct ParsedLogEntry: Sendable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    
    public init(timestamp: Date, level: LogLevel, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

// MARK: - Log File Writer

/// Handles appending log entries to files in a thread-safe manner.
/// Keeps one handle open per writer.
public final class LogFileWriter: @unchecked Sendable {
    
    private let fileURL: URL
    private let queue: DispatchQueue
    private var handle: FileHandle?
    
    public init(fileURL: URL, queueLabel: String = "com.fawenyo.yaiiu.logwriter") {
        self.fileURL = fileURL
        self.queue = DispatchQueue(label: queueLabel, qos: .utility)
    }
    
    /// Append a formatted log entry to the file.
    public func append(
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String
    ) {
        let entry = LogFormatter.formatLogEntry(
            timestamp: timestamp,
            level: level,
            category: category,
            message: message
        )
        appendLine(entry)
    }
    
    /// Append a raw line to the log file.
    public func appendLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in write(data) }
    }
    
    /// Append synchronously (blocks until write(2) completes, so the line survives a process kill).
    public func appendSync(
        timestamp: Date = Date(),
        level: LogLevel,
        category: String,
        message: String
    ) {
        let entry = LogFormatter.formatLogEntry(
            timestamp: timestamp,
            level: level,
            category: category,
            message: message
        )
        let data = Data((entry + "\n").utf8)
        queue.sync { write(data) }
    }
    
    /// Delete the file after all previously queued writes.
    public func removeFile() {
        queue.async { [self] in
            closeHandle()
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
    
    /// Read at most the last `maxBytes` of a file, dropping a leading partial line.
    public static func readTail(of url: URL, maxBytes: UInt64) -> Data? {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? reader.close() }
        guard let size = try? reader.seekToEnd() else { return nil }
        guard size > maxBytes else {
            guard (try? reader.seek(toOffset: 0)) != nil else { return nil }
            return try? reader.readToEnd()
        }
        // Read one byte before the tail: the first line is partial only when
        // that byte is not a newline.
        guard (try? reader.seek(toOffset: size - maxBytes - 1)) != nil,
              let data = try? reader.readToEnd(),
              let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return data[data.index(after: newline)...]
    }
    
    // MARK: - Private (queue only)
    
    private func write(_ data: Data) {
        if let current = handle, isUnlinked(current) {
            // Another process (or clearLogs) deleted the file; start a new one.
            closeHandle()
        }
        if handle == nil {
            openHandle()
        }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            closeHandle()
        }
    }
    
    private func openHandle() {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let newHandle = try? FileHandle(forWritingTo: fileURL),
              (try? newHandle.seekToEnd()) != nil else { return }
        handle = newHandle
    }
    
    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }
    
    private func isUnlinked(_ handle: FileHandle) -> Bool {
        var info = stat()
        return fstat(handle.fileDescriptor, &info) == 0 && info.st_nlink == 0
    }
}
