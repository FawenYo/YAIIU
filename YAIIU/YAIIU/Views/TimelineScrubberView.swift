import SwiftUI
import Photos
import UIKit

// MARK: - Timeline Month Data (Lightweight struct)

struct TimelineMonth: Equatable {
    let id: Int
    let year: Int
    let month: Int
    let firstIndex: Int
    
    /// Creates a unique ID from year and month (e.g., 202401 for Jan 2024)
    static func makeId(year: Int, month: Int) -> Int {
        return year * 100 + month
    }
}

// MARK: - Shared Month Formatter (avoid repeated allocations)

private enum MonthFormatter {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        return f
    }()
    
    static func format(year: Int, month: Int) -> String {
        let monthName = formatter.shortMonthSymbols[month - 1]
        return "\(monthName) \(year)"
    }
}

// MARK: - Timeline Scrubber Coordinator (UIKit-based, throttled)

final class TimelineScrubberCoordinator: NSObject {
    var timelineData: [TimelineMonth] = []
    var onScrollToIndex: ((Int) -> Void)?
    var onDragStateChange: ((Bool) -> Void)?
    var onMonthChange: ((TimelineMonth) -> Void)?
    var onPositionChange: ((CGFloat) -> Void)?
    
    private var lastScrolledMonthId: Int = -1
    private var availableHeight: CGFloat = 0
    private var isDragging = false
    
    // Throttling for position updates (limit to ~30fps)
    private var lastPositionUpdateTime: CFTimeInterval = 0
    private let positionUpdateInterval: CFTimeInterval = 1.0 / 30.0
    
    // Lazy haptic generator
    private lazy var feedbackGenerator: UISelectionFeedbackGenerator = {
        let gen = UISelectionFeedbackGenerator()
        return gen
    }()
    
    func updateHeight(_ height: CGFloat) {
        availableHeight = height
    }
    
    @objc func handlePan(_ gesture: UIGestureRecognizer) {
        guard !timelineData.isEmpty, availableHeight > 0 else { return }
        
        let location = gesture.location(in: gesture.view)
        let y = location.y
        
        switch gesture.state {
        case .began:
            feedbackGenerator.prepare()
            lastScrolledMonthId = -1
            isDragging = true
            onDragStateChange?(true)
            
            if let month = monthAt(y: y) {
                onMonthChange?(month)
            }
            onPositionChange?(y)
            
        case .changed:
            // Throttle position updates
            let now = CACurrentMediaTime()
            if now - lastPositionUpdateTime >= positionUpdateInterval {
                lastPositionUpdateTime = now
                onPositionChange?(y)
            }
            
            // Month change check (only triggers scroll when month changes)
            if let month = monthAt(y: y), month.id != lastScrolledMonthId {
                lastScrolledMonthId = month.id
                onMonthChange?(month)
                feedbackGenerator.selectionChanged()
                onScrollToIndex?(month.firstIndex)
            }
            
        case .ended, .cancelled, .failed:
            if isDragging {
                isDragging = false
                onDragStateChange?(false)
                lastScrolledMonthId = -1
            }
            
        default:
            break
        }
    }
    
    private func monthAt(y: CGFloat) -> TimelineMonth? {
        guard !timelineData.isEmpty else { return nil }
        
        let clampedY = max(0, min(y, availableHeight))
        let normalizedY = clampedY / availableHeight
        let monthIndex = Int(normalizedY * CGFloat(timelineData.count))
        let safeIndex = max(0, min(monthIndex, timelineData.count - 1))
        
        return timelineData[safeIndex]
    }
}

// MARK: - UIKit Touch Area View

struct ScrubberTouchArea: UIViewRepresentable {
    let coordinator: TimelineScrubberCoordinator
    let height: CGFloat
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        
        // Single gesture for both tap and pan
        let longPress = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(TimelineScrubberCoordinator.handlePan(_:))
        )
        longPress.minimumPressDuration = 0
        longPress.allowableMovement = .greatestFiniteMagnitude
        view.addGestureRecognizer(longPress)
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        coordinator.updateHeight(height)
    }
}

// MARK: - Timeline Scrubber View (Edge Touch Style - Optimized)

struct TimelineScrubberView: View {
    let photoLibraryManager: PhotoLibraryManager
    let totalCount: Int
    let onScrollToIndex: (Int) -> Void
    
    @State private var timelineData: [TimelineMonth] = []
    @State private var isDragging: Bool = false
    @State private var thumbPosition: CGFloat = 0
    @State private var displayedMonthText: String = ""
    
    @StateObject private var coordinatorHolder = CoordinatorHolder()
    
    private let touchAreaWidth: CGFloat = 44
    
    var body: some View {
        GeometryReader { geometry in
            let availableHeight = geometry.size.height
            
            HStack(spacing: 0) {
                Spacer()
                
                ZStack(alignment: .topTrailing) {
                    // Date label (only render when dragging)
                    if isDragging {
                        dateLabelView(availableHeight: availableHeight)
                    }
                    
                    // UIKit-based touch area
                    ScrubberTouchArea(
                        coordinator: coordinatorHolder.coordinator,
                        height: availableHeight
                    )
                    .frame(width: touchAreaWidth)
                }
            }
        }
        .onAppear {
            setupCoordinator()
            buildTimelineData()
        }
        .onChange(of: totalCount) { _, _ in
            buildTimelineData()
        }
    }
    
    private func setupCoordinator() {
        let coordinator = coordinatorHolder.coordinator
        
        coordinator.onScrollToIndex = { [onScrollToIndex] index in
            onScrollToIndex(index)
        }
        
        coordinator.onDragStateChange = { dragging in
            withAnimation(.easeOut(duration: 0.12)) {
                isDragging = dragging
            }
        }
        
        coordinator.onMonthChange = { month in
            displayedMonthText = MonthFormatter.format(year: month.year, month: month.month)
        }
        
        coordinator.onPositionChange = { position in
            thumbPosition = position
        }
    }
    
    // MARK: - Date Label View (Simplified)
    
    @ViewBuilder
    private func dateLabelView(availableHeight: CGFloat) -> some View {
        let clampedY = max(20, min(thumbPosition - 20, availableHeight - 50))
        
        HStack(spacing: 6) {
            Text(displayedMonthText)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.75))
        )
        .offset(x: -(touchAreaWidth + 8), y: clampedY)
    }
    
    // MARK: - Timeline Data Building (Optimized)
    
    private func buildTimelineData() {
        guard totalCount > 0 else {
            timelineData = []
            coordinatorHolder.coordinator.timelineData = []
            return
        }
        
        let manager = photoLibraryManager
        
        Task.detached(priority: .utility) {
            var months: [TimelineMonth] = []
            months.reserveCapacity(200) // Pre-allocate for typical use
            
            var currentYearValue: Int = 0
            var currentMonthValue: Int = 0
            var currentStartIndex: Int = 0
            
            let calendar = Calendar.current
            
            guard let fetchResult = manager.fetchResult else {
                await MainActor.run {
                    timelineData = []
                    coordinatorHolder.coordinator.timelineData = []
                }
                return
            }
            
            fetchResult.enumerateObjects { asset, index, _ in
                guard let date = asset.creationDate else { return }
                
                let year = calendar.component(.year, from: date)
                let month = calendar.component(.month, from: date)
                
                if year != currentYearValue || month != currentMonthValue {
                    if currentYearValue != 0 {
                        let monthData = TimelineMonth(
                            id: TimelineMonth.makeId(year: currentYearValue, month: currentMonthValue),
                            year: currentYearValue,
                            month: currentMonthValue,
                            firstIndex: currentStartIndex
                        )
                        months.append(monthData)
                    }
                    
                    currentYearValue = year
                    currentMonthValue = month
                    currentStartIndex = index
                }
            }
            
            // Add last month
            if currentYearValue != 0 {
                let monthData = TimelineMonth(
                    id: TimelineMonth.makeId(year: currentYearValue, month: currentMonthValue),
                    year: currentYearValue,
                    month: currentMonthValue,
                    firstIndex: currentStartIndex
                )
                months.append(monthData)
            }
            
            await MainActor.run {
                timelineData = months
                coordinatorHolder.coordinator.timelineData = months
            }
        }
    }
}

// MARK: - Coordinator Holder

private final class CoordinatorHolder: ObservableObject {
    let coordinator = TimelineScrubberCoordinator()
}

// MARK: - Preview

#Preview {
    ZStack {
        Color(.systemGray6)
            .ignoresSafeArea()
        
        HStack {
            Spacer()
            TimelineScrubberView(
                photoLibraryManager: PhotoLibraryManager(),
                totalCount: 1000,
                onScrollToIndex: { index in
                    print("Scroll to index: \(index)")
                }
            )
            .frame(height: 600)
        }
    }
}
