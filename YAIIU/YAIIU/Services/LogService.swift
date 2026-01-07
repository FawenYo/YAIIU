import Foundation
import os.log

// MARK: - OSLog Type Extension

extension LogLevel {
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

// MARK: - Log Entry

struct LogEntry: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let level: String
    let category: String
    let message: String
    let file: String
    let function: String
    let line: Int
    
    var formattedTimestamp: String {
        LogFormatter.formatTimestamp(timestamp)
    }
    
    var formattedEntry: String {
        guard let logLevel = LogLevel(rawValue: level) else {
            return "\(formattedTimestamp) [?] [\(category)] \(message)"
        }
        return LogFormatter.formatLogEntry(
            timestamp: timestamp,
            level: logLevel,
            category: category,
            message: message
        )
    }
    
    var detailedEntry: String {
        "\(formattedEntry) (\(file):\(line) \(function))"
    }
    
    /// Initialize from a parsed log entry (without source location info)
    init(from parsed: ParsedLogEntry) {
        self.id = UUID()
        self.timestamp = parsed.timestamp
        self.level = parsed.level.rawValue
        self.category = parsed.category
        self.message = parsed.message
        self.file = ""
        self.function = ""
        self.line = 0
    }
    
    init(id: UUID, timestamp: Date, level: String, category: String, message: String, file: String, function: String, line: Int) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.file = file
        self.function = function
        self.line = line
    }
}

// MARK: - Log Service

class LogService {
    static let shared = LogService()
    
    private let osLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.fawenyo.yaiiu", category: "PhotosUploader")
    
    private var logEntries: [LogEntry] = []
    private let logQueue = DispatchQueue(label: "com.fawenyo.yaiiu.logservice", qos: .utility)
    private let maxLogEntries = 10000
    private let logFileName = "yaiiu.log"
    private let appGroupID = "group.com.fawenyo.yaiiu"
    private let backgroundLogFileName = "background_upload.log"
    
    var minimumLogLevel: LogLevel = .debug
    
    private init() {
        loadLogsFromDisk()
    }
    
    // MARK: - Logging Methods
    
    func debug(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .debug, category: category, file: file, function: function, line: line)
    }
    
    func info(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .info, category: category, file: file, function: function, line: line)
    }
    
    func warning(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .warning, category: category, file: file, function: function, line: line)
    }
    
    func error(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
        log(message, level: .error, category: category, file: file, function: function, line: line)
    }
    
    private func log(_ message: String, level: LogLevel, category: LogCategory, file: String, function: String, line: Int) {
        guard level >= minimumLogLevel else { return }
        
        let fileName = (file as NSString).lastPathComponent
        
        let entry = LogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level.rawValue,
            category: category.rawValue,
            message: message,
            file: fileName,
            function: function,
            line: line
        )
        
        // Log to system console
        os_log("%{public}@ [%{public}@] %{public}@", log: osLog, type: level.osLogType, level.symbol, category.rawValue, message)
        
        // Store log entry
        logQueue.async { [weak self] in
            self?.storeLogEntry(entry)
        }
    }
    
    private func storeLogEntry(_ entry: LogEntry) {
        logEntries.append(entry)
        
        // Trim old entries if needed
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
        
        // Append to file
        appendToLogFile(entry)
    }
    
    // MARK: - File Operations
    
    private var logFileURL: URL {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsDirectory.appendingPathComponent(logFileName)
    }
    
    private func appendToLogFile(_ entry: LogEntry) {
        let logLine = entry.formattedEntry + "\n"
        let fileURL = logFileURL
        
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let fileHandle = try FileHandle(forWritingTo: fileURL)
                fileHandle.seekToEndOfFile()
                if let data = logLine.data(using: .utf8) {
                    fileHandle.write(data)
                }
                fileHandle.closeFile()
            } else {
                try logLine.write(to: fileURL, atomically: true, encoding: .utf8)
            }
        } catch {
            print("Failed to write to log file: \(error)")
        }
    }
    
    private func loadLogsFromDisk() {
        let fileURL = logFileURL
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            
            // Parse last maxLogEntries lines
            let recentLines = lines.suffix(maxLogEntries)
            
            for line in recentLines {
                if let entry = parseLogLine(line) {
                    logEntries.append(entry)
                }
            }
        } catch {
            print("Failed to load logs from disk: \(error)")
        }
    }
    
    private func parseLogLine(_ line: String) -> LogEntry? {
        guard let parsed = LogFormatter.parseLogLine(line) else {
            return nil
        }
        return LogEntry(from: parsed)
    }
    
    // MARK: - Export Functions
    
    func getLogEntries(level: LogLevel? = nil, category: LogCategory? = nil, limit: Int? = nil) -> [LogEntry] {
        var result = logEntries
        
        if let level = level {
            result = result.filter { LogLevel(rawValue: $0.level)! >= level }
        }
        
        if let category = category {
            result = result.filter { $0.category == category.rawValue }
        }
        
        if let limit = limit {
            result = Array(result.suffix(limit))
        }
        
        return result
    }
    
    func exportLogsAsString(includeDebug: Bool = false) -> String {
        logQueue.sync {
            let entries = includeDebug ? logEntries : logEntries.filter { $0.level != "DEBUG" }
            return entries.map { $0.formattedEntry }.joined(separator: "\n")
        }
    }
    
    func exportLogsAsData(includeDebug: Bool = false) -> Data? {
        return exportLogsAsString(includeDebug: includeDebug).data(using: .utf8)
    }
    
    func getLogFileURL() -> URL? {
        let fileURL = logFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return fileURL
    }
    
    func exportLogsToFile() -> URL? {
        let exportDirectory = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "yaiiu_log_\(dateFormatter.string(from: Date())).txt"
        let exportURL = exportDirectory.appendingPathComponent(fileName)
        
        do {
            let content = exportLogsAsString(includeDebug: true)
            try content.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            self.error("Failed to export logs: \(error.localizedDescription)", category: .app)
            return nil
        }
    }
    
    func clearLogs() {
        logQueue.async { [weak self] in
            guard let self = self else { return }
            self.logEntries.removeAll()
            
            let fileURL = self.logFileURL
            try? FileManager.default.removeItem(at: fileURL)
        }
        
        // Also clear background upload logs
        clearBackgroundLogs()
        
        info("Logs cleared", category: .app)
    }
    
    func getLogCount() -> Int {
        return logQueue.sync { logEntries.count }
    }
    
    func getLogFileSizeString() -> String {
        var totalSize: Int64 = 0
        
        // Main app log file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let fileSize = attributes[.size] as? Int64 {
            totalSize += fileSize
        }
        
        // Background upload log file size
        if let bgLogURL = backgroundLogFileURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: bgLogURL.path),
           let fileSize = attributes[.size] as? Int64 {
            totalSize += fileSize
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSize)
    }
    
    // MARK: - Background Upload Log Integration
    
    private var backgroundLogFileURL: URL? {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) else {
            return nil
        }
        return containerURL.appendingPathComponent(backgroundLogFileName)
    }
    
    /// Read and parse background upload logs from App Group shared container
    private func loadBackgroundLogs() -> [LogEntry] {
        guard let logURL = backgroundLogFileURL,
              FileManager.default.fileExists(atPath: logURL.path),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return []
        }
        
        var entries: [LogEntry] = []
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        
        for line in lines {
            if let entry = parseBackgroundLogLine(line) {
                entries.append(entry)
            }
        }
        
        return entries
    }
    
    /// Parse background upload log line.
    /// Supports unified format and legacy ISO8601 format for backward compatibility.
    private func parseBackgroundLogLine(_ line: String) -> LogEntry? {
        // Try unified format first using shared LogFormatter
        if let parsed = LogFormatter.parseLogLine(line) {
            return LogEntry(from: parsed)
        }
        
        // Fallback: Try legacy ISO8601 format for backward compatibility
        // Format: "[2024-01-01T12:00:00Z] Message"
        return parseLegacyLogLine(line)
    }
    
    /// Parse legacy log format: "[2024-01-01T12:00:00Z] Message"
    private func parseLegacyLogLine(_ line: String) -> LogEntry? {
        let legacyPattern = #"^\[([^\]]+)\] (.+)$"#
        
        guard let regex = try? NSRegularExpression(pattern: legacyPattern, options: []),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)),
              let timestampRange = Range(match.range(at: 1), in: line),
              let messageRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        
        let timestampStr = String(line[timestampRange])
        let message = String(line[messageRange])
        
        let isoFormatter = ISO8601DateFormatter()
        guard let timestamp = isoFormatter.date(from: timestampStr) else {
            return nil
        }
        
        return LogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: LogLevel.info.rawValue,
            category: LogCategory.backgroundUpload.rawValue,
            message: message,
            file: "",
            function: "",
            line: 0
        )
    }
    
    /// Get all logs merged (app logs + background upload logs), sorted by timestamp
    func getAllMergedLogEntries(level: LogLevel? = nil, limit: Int? = nil) -> [LogEntry] {
        var allEntries: [LogEntry] = []
        
        // Get main app logs
        logQueue.sync {
            allEntries.append(contentsOf: logEntries)
        }
        
        // Get background upload logs
        let backgroundLogs = loadBackgroundLogs()
        allEntries.append(contentsOf: backgroundLogs)
        
        // Sort by timestamp
        allEntries.sort { $0.timestamp < $1.timestamp }
        
        // Filter by level if specified
        if let level = level {
            allEntries = allEntries.filter { entry in
                guard let entryLevel = LogLevel(rawValue: entry.level) else { return false }
                return entryLevel >= level
            }
        }
        
        // Apply limit
        if let limit = limit {
            allEntries = Array(allEntries.suffix(limit))
        }
        
        return allEntries
    }
    
    /// Clear background upload logs from App Group container
    func clearBackgroundLogs() {
        guard let logURL = backgroundLogFileURL else { return }
        try? FileManager.default.removeItem(at: logURL)
    }
    
    /// Get total log count including background logs
    func getTotalLogCount() -> Int {
        let mainCount = logQueue.sync { logEntries.count }
        
        guard let logURL = backgroundLogFileURL,
              FileManager.default.fileExists(atPath: logURL.path),
              let content = try? String(contentsOf: logURL, encoding: .utf8) else {
            return mainCount
        }
        
        let backgroundCount = content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        return mainCount + backgroundCount
    }
    
    /// Export all logs (merged) to file
    func exportAllLogsToFile() -> URL? {
        let exportDirectory = FileManager.default.temporaryDirectory
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "yaiiu_log_\(dateFormatter.string(from: Date())).txt"
        let exportURL = exportDirectory.appendingPathComponent(fileName)
        
        do {
            let entries = getAllMergedLogEntries()
            let content = entries.map { $0.formattedEntry }.joined(separator: "\n")
            try content.write(to: exportURL, atomically: true, encoding: .utf8)
            return exportURL
        } catch {
            self.error("Failed to export logs: \(error.localizedDescription)", category: .app)
            return nil
        }
    }
}

// MARK: - Convenience Global Functions

func logDebug(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
    LogService.shared.debug(message, category: category, file: file, function: function, line: line)
}

func logInfo(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
    LogService.shared.info(message, category: category, file: file, function: function, line: line)
}

func logWarning(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
    LogService.shared.warning(message, category: category, file: file, function: function, line: line)
}

func logError(_ message: String, category: LogCategory = .app, file: String = #file, function: String = #function, line: Int = #line) {
    LogService.shared.error(message, category: category, file: file, function: function, line: line)
}
