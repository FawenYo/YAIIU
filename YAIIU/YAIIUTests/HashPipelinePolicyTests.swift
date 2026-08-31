import XCTest
@testable import YAIIU

final class HashPipelinePolicyTests: XCTestCase {
    actor ConcurrencyProbe {
        private(set) var activeCount = 0
        private(set) var maximumActiveCount = 0

        func begin() {
            activeCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
        }

        func end() {
            activeCount -= 1
        }
    }

    func testProcessesHashOperationsSerially() async {
        let probe = ConcurrencyProbe()

        await HashPipelinePolicy.processSerially([1, 2, 3]) { _ in
            await probe.begin()
            try? await Task.sleep(nanoseconds: 10_000_000)
            await probe.end()
        }

        let maximumActiveCount = await probe.maximumActiveCount
        XCTAssertEqual(maximumActiveCount, 1)
    }

    func testCancellationStopsBeforeNextOperation() async {
        let firstOperationStarted = expectation(description: "first operation starts")
        let startedSecondOperation = expectation(description: "second operation starts")
        startedSecondOperation.isInverted = true

        let task = Task {
            await HashPipelinePolicy.processSerially([1, 2]) { value in
                if value == 1 {
                    firstOperationStarted.fulfill()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    startedSecondOperation.fulfill()
                }
            }
        }

        await fulfillment(of: [firstOperationStarted], timeout: 1.0)
        task.cancel()
        await task.value
        await fulfillment(of: [startedSecondOperation], timeout: 0.1)
    }

    func testOldRunCannotOwnStateAfterRestart() {
        var state = HashPipelinePolicy.RunState()
        let oldRunID = state.begin()
        let newRunID = state.begin()

        XCTAssertFalse(state.owns(oldRunID))
        XCTAssertTrue(state.owns(newRunID))
    }

    func testInvalidationPreventsStoppedRunFromOwningState() {
        var state = HashPipelinePolicy.RunState()
        let runID = state.begin()

        state.invalidate()

        XCTAssertFalse(state.owns(runID))
    }

    func testCancellationCancelsRequestAndWaitsForCompletion() async {
        let requestStarted = expectation(description: "request starts")
        let cancellationForwarded = expectation(description: "cancellation reaches request")
        let taskFinished = expectation(description: "task finishes")
        taskFinished.isInverted = true
        let completion = RequestCompletionBox<Int>()

        let task = Task {
            defer { taskFinished.fulfill() }
            return try await withCancellableRequest(
                start: { handler in
                    completion.store(handler)
                    requestStarted.fulfill()
                    return 42
                },
                cancel: { requestID in
                    XCTAssertEqual(requestID, 42)
                    cancellationForwarded.fulfill()
                }
            )
        }

        await fulfillment(of: [requestStarted], timeout: 1.0)
        task.cancel()
        await fulfillment(of: [cancellationForwarded], timeout: 1.0)
        await fulfillment(of: [taskFinished], timeout: 0.1)

        completion.finish(.success(1))

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after the underlying request reports completion.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class RequestCompletionBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Result<Value, Error>) -> Void)?

    func store(_ handler: @escaping (Result<Value, Error>) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(result)
    }
}
