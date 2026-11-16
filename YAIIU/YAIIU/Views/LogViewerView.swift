import SwiftUI

// MARK: - Log Viewer View

struct LogViewerView: View {
    @StateObject private var viewModel = LogViewerViewModel()
    @State private var minimumLevel: LogLevel = .info
    @State private var selectedCategory: LogCategory?
    @State private var searchText = ""
    @State private var scrollToBottomRequests = 0
    
    var body: some View {
        let logs = filteredLogs
        
        VStack(spacing: 0) {
            levelBar(matchCount: logs.count)
            Divider()
            
            if !logs.isEmpty {
                logList(logs)
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }
        }
        .navigationTitle(L10n.Settings.viewLogs)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(L10n.Settings.searchLogs)
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Picker(L10n.Settings.logCategory, selection: $selectedCategory) {
                        Text(L10n.Settings.filterAll).tag(LogCategory?.none)
                        ForEach(LogCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(LogCategory?.some(category))
                        }
                    }
                } label: {
                    Label(
                        L10n.Settings.logCategory,
                        systemImage: selectedCategory == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill"
                    )
                }
                
                Menu {
                    Button(action: { viewModel.refreshLogs(minimumLevel: minimumLevel) }) {
                        Label(L10n.Settings.refreshLogs, systemImage: "arrow.clockwise")
                    }
                    
                    Button(action: { scrollToBottomRequests += 1 }) {
                        Label(L10n.Settings.scrollToBottom, systemImage: "arrow.down.to.line")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onChange(of: minimumLevel, initial: true) { _, level in
            viewModel.refreshLogs(minimumLevel: level)
        }
    }
    
    // MARK: - Level Bar
    
    private func levelBar(matchCount: Int) -> some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        // The selection is a threshold, so every level it lets through lights up.
                        FilterChip(
                            title: level.rawValue,
                            isSelected: level >= minimumLevel,
                            color: level.color
                        ) {
                            minimumLevel = level
                        }
                    }
                }
                .padding(.leading)
            }
            
            Text([selectedCategory?.rawValue, "\(matchCount)"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .padding(.trailing)
        }
        .padding(.vertical, 8)
    }
    
    // MARK: - Log List
    
    private func logList(_ logs: [LogEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(logs) { entry in
                        LogEntryRow(entry: entry)
                        Divider()
                    }
                }
            }
            // Entries are chronological; open on the newest.
            .defaultScrollAnchor(.bottom)
            .onChange(of: scrollToBottomRequests) {
                guard let lastEntry = logs.last else { return }
                withAnimation {
                    proxy.scrollTo(lastEntry.id, anchor: .bottom)
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
        viewModel.logEntries.filter { entry in
            if let selectedCategory, entry.category != selectedCategory.rawValue {
                return false
            }
            return searchText.isEmpty
                || entry.message.localizedCaseInsensitiveContains(searchText)
                || entry.category.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Level Color

private extension LogLevel {
    var color: Color {
        switch self {
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(entry.level.color)
                
                Text(entry.category)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Spacer(minLength: 4)
                
                // Drop the year: "MM-dd HH:mm:ss.SSS".
                Text(entry.formattedTimestamp.dropFirst(5))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(entry.level == .debug ? .secondary : .primary)
                .lineLimit(isExpanded ? nil : 3)
        }
        .padding(.vertical, 6)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowTint)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(entry.level.color)
                .frame(width: 3)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        }
    }
    
    private var rowTint: Color {
        switch entry.level {
        case .error: return Color.red.opacity(0.08)
        case .warning: return Color.orange.opacity(0.08)
        case .debug, .info: return .clear
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
                    // Inset stroke: a centered one overflows the chip and the scroll view clips it.
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(isSelected ? color : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - View Model

class LogViewerViewModel: ObservableObject {
    @Published private(set) var logEntries: [LogEntry] = []
    @Published private(set) var isLoading = false
    
    private var loadGeneration = 0
    
    /// Loads the newest entries at or above `minimumLevel` (app + background upload).
    /// Filtering at load keeps lower levels from crowding matches out of the limit.
    func refreshLogs(minimumLevel: LogLevel) {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let entries = LogService.shared.getAllMergedLogEntries(level: minimumLevel, limit: 5000)
            
            DispatchQueue.main.async {
                // A newer request supersedes this one.
                guard let self, generation == self.loadGeneration else { return }
                self.logEntries = entries
                self.isLoading = false
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
