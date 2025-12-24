import Foundation
import os.log

// MARK: - Log Level

enum LogLevel: String, CaseIterable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
    
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
    
    var symbol: String {
        switch self {
        case .debug: return "[D]"
        case .info: return "[I]"
        case .warning: return "[W]"
        case .error: return "[E]"
        }
    }
    
    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        let order: [LogLevel] = [.debug, .info, .warning, .error]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

// MARK: - Log Category

enum LogCategory: String {
    case app = "App"
    case api = "API"
    case upload = "Upload"
    case database = "Database"
    case photoLibrary = "PhotoLibrary"
    case hash = "Hash"
    case settings = "Settings"
    case importer = "Importer"
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
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
    
    var formattedEntry: String {
        let levelSymbol: String
        switch level {
        case "DEBUG": levelSymbol = "[D]"
        case "INFO": levelSymbol = "[I]"
        case "WARNING": levelSymbol = "[W]"
        case "ERROR": levelSymbol = "[E]"
        default: levelSymbol = "[?]"
        }
        return "\(formattedTimestamp) \(levelSymbol) [\(category)] \(message)"
    }
    
    var detailedEntry: String {
        return "\(formattedEntry) (\(file):\(line) \(function))"
    }
}

// MARK: - Log Service

class LogService {
    static let shared = LogService()
    
    private let osLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "com.immich.uploader", category: "ImmichUploader")
    
    private var logEntries: [LogEntry] = []
    private let logQueue = DispatchQueue(label: "com.immich_uploader.logservice", qos: .utility)
    private let maxLogEntries = 10000
    private let logFileName = "immich_uploader.log"
    
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
            // Silent fail - we can't log an error about logging
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
        // Format: "2024-01-01 12:00:00.000 [I] [Category] Message"
        let pattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}) \[([DIWE])\] \[([^\]]+)\] (.+)$"#
        
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: line, options: [], range: NSRange(line.startIndex..., in: line)) else {
            return nil
        }
        
        guard let timestampRange = Range(match.range(at: 1), in: line),
              let levelRange = Range(match.range(at: 2), in: line),
              let categoryRange = Range(match.range(at: 3), in: line),
              let messageRange = Range(match.range(at: 4), in: line) else {
            return nil
        }
        
        let timestampStr = String(line[timestampRange])
        let levelChar = String(line[levelRange])
        let category = String(line[categoryRange])
        let message = String(line[messageRange])
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        guard let timestamp = formatter.date(from: timestampStr) else {
            return nil
        }
        
        let level: String
        switch levelChar {
        case "D": level = "DEBUG"
        case "I": level = "INFO"
        case "W": level = "WARNING"
        case "E": level = "ERROR"
        default: level = "INFO"
        }
        
        return LogEntry(
            id: UUID(),
            timestamp: timestamp,
            level: level,
            category: category,
            message: message,
            file: "",
            function: "",
            line: 0
        )
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
        let fileName = "immich_uploader_log_\(dateFormatter.string(from: Date())).txt"
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
        
        info("Logs cleared", category: .app)
    }
    
    func getLogCount() -> Int {
        return logQueue.sync { logEntries.count }
    }
    
    func getLogFileSizeString() -> String {
        let fileURL = logFileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let fileSize = attributes[.size] as? Int64 else {
            return "0 KB"
        }
        
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
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
