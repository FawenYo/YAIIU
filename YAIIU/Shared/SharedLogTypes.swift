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
    
    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        guard let lhsIndex = order.firstIndex(of: lhs),
              let rhsIndex = order.firstIndex(of: rhs) else {
            return false
        }
        return lhsIndex < rhsIndex
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
        guard let regex = try? NSRegularExpression(pattern: unifiedLogPattern, options: []),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
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
public final class LogFileWriter: @unchecked Sendable {
    
    private let fileURL: URL
    private let queue: DispatchQueue
    
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
        let data = (line + "\n").data(using: .utf8)
        
        queue.async { [fileURL] in
            guard let data = data else { return }
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                handle.write(data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
    
    /// Append synchronously (blocks until write completes).
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
        
        guard let data = (entry + "\n").data(using: .utf8) else { return }
        
        if FileManager.default.fileExists(atPath: fileURL.path) {
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: fileURL)
        }
    }
}
