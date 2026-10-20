import Foundation

@MainActor
final class CoalescingRefresh<Value> {
    typealias Loader = (@escaping (Value) -> Void) -> Void
    private let load: Loader
    private let publish: (Value) -> Void
    private var isLoading = false
    private var needsReload = false
    private var completions: [(Value) -> Void] = []

    init(load: @escaping Loader, publish: @escaping (Value) -> Void) {
        self.load = load
        self.publish = publish
    }

    func refresh(completion: ((Value) -> Void)? = nil) {
        if let completion { completions.append(completion) }
        guard !isLoading else {
            needsReload = true
            return
        }
        isLoading = true
        startLoad()
    }

    private func startLoad() {
        load { [weak self] value in
            guard let self else { return }
            // A request during the read may follow a database write. Discard
            // this snapshot and read again before publishing or resuming callers.
            if self.needsReload {
                self.needsReload = false
                self.startLoad()
                return
            }
            self.isLoading = false
            let callbacks = self.completions
            self.completions = []
            self.publish(value)
            callbacks.forEach { $0(value) }
        }
    }
}
