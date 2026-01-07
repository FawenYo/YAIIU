import SwiftUI

// MARK: - Log Viewer View

struct LogViewerView: View {
    @StateObject private var viewModel = LogViewerViewModel()
    @State private var selectedLevel: LogLevel? = nil
    @State private var searchText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            filterBar
            
            // Log content
            if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredLogs.isEmpty {
                emptyState
            } else {
                logList
            }
        }
        .navigationTitle(L10n.Settings.viewLogs)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button(action: viewModel.refreshLogs) {
                        Label(L10n.Settings.refreshLogs, systemImage: "arrow.clockwise")
                    }
                    
                    Button(action: {
                        viewModel.scrollToBottom = true
                    }) {
                        Label(L10n.Settings.scrollToBottom, systemImage: "arrow.down.to.line")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear {
            viewModel.refreshLogs()
        }
    }
    
    // MARK: - Filter Bar
    
    private var filterBar: some View {
        VStack(spacing: 8) {
            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(L10n.Settings.searchLogs, text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
            
            // Level filter
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(
                        title: L10n.Settings.filterAll,
                        isSelected: selectedLevel == nil
                    ) {
                        selectedLevel = nil
                    }
                    
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        FilterChip(
                            title: level.rawValue,
                            isSelected: selectedLevel == level,
                            color: colorForLevel(level)
                        ) {
                            selectedLevel = level
                        }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 4)
        }
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
    }
    
    // MARK: - Log List
    
    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredLogs) { entry in
                        LogEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: viewModel.scrollToBottom) { _, shouldScroll in
                if shouldScroll, let lastEntry = filteredLogs.last {
                    withAnimation {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                    viewModel.scrollToBottom = false
                }
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(L10n.Settings.noLogsAvailable)
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Filtered Logs
    
    private var filteredLogs: [LogEntry] {
        var logs = viewModel.logEntries
        
        // Filter by level
        if let level = selectedLevel {
            logs = logs.filter { entry in
                guard let entryLevel = LogLevel(rawValue: entry.level) else { return false }
                return entryLevel >= level
            }
        }
        
        // Filter by search text
        if !searchText.isEmpty {
            logs = logs.filter { entry in
                entry.message.localizedCaseInsensitiveContains(searchText) ||
                entry.category.localizedCaseInsensitiveContains(searchText)
            }
        }
        
        return logs
    }
    
    // MARK: - Helpers
    
    private func colorForLevel(_ level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Log Entry Row

struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Header line: timestamp, level, category
            HStack(spacing: 4) {
                Text(entry.formattedTimestamp)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Text(levelSymbol)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(levelColor)
                    .fontWeight(.bold)
                
                Text("[\(entry.category)]")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // Message
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(isExpanded ? nil : 3)
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(levelBackgroundColor)
        .cornerRadius(4)
    }
    
    private var levelSymbol: String {
        switch entry.level {
        case "DEBUG": return "[D]"
        case "INFO": return "[I]"
        case "WARNING": return "[W]"
        case "ERROR": return "[E]"
        default: return "[?]"
        }
    }
    
    private var levelColor: Color {
        switch entry.level {
        case "DEBUG": return .gray
        case "INFO": return .blue
        case "WARNING": return .orange
        case "ERROR": return .red
        default: return .secondary
        }
    }
    
    private var levelBackgroundColor: Color {
        switch entry.level {
        case "ERROR": return Color.red.opacity(0.1)
        case "WARNING": return Color.orange.opacity(0.1)
        default: return Color(.systemGray6).opacity(0.5)
        }
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    var color: Color = .blue
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? color.opacity(0.2) : Color(.systemGray6))
                .foregroundColor(isSelected ? color : .secondary)
                .cornerRadius(16)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(isSelected ? color : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View Model

class LogViewerViewModel: ObservableObject {
    @Published var logEntries: [LogEntry] = []
    @Published var isLoading = false
    @Published var scrollToBottom = false
    
    func refreshLogs() {
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Get all merged logs (app + background upload)
            let entries = LogService.shared.getAllMergedLogEntries(limit: 5000)
            
            DispatchQueue.main.async {
                self?.logEntries = entries
                self?.isLoading = false
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        LogViewerView()
    }
}
