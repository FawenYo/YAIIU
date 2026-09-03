import XCTest
@testable import YAIIU

final class HashPipelinePolicyTests: XCTestCase {
    actor ConcurrencyProbe {
        private(set) var activeCount = 0
        private(set) var maximumActiveCount = 0
        private(set) var totalCount = 0

        func begin() {
            activeCount += 1
            totalCount += 1
            maximumActiveCount = max(maximumActiveCount, activeCount)
        }

        func end() {
            activeCount -= 1
        }

        func bump() {
            totalCount += 1
        }
    }

    func testProcessesHashOperationsWithBoundedConcurrency() async {
        let probe = ConcurrencyProbe()
        let limit = 3

        await HashPipelinePolicy.processConcurrently(Array(1...10), limit: limit) { _ in
            await probe.begin()
            try? await Task.sleep(nanoseconds: 10_000_000)
            await probe.end()
        }

        let maximumActiveCount = await probe.maximumActiveCount
        let total = await probe.totalCount
        XCTAssertEqual(total, 10)
        XCTAssertLessThanOrEqual(maximumActiveCount, limit)
    }

    func testProcessConcurrentlyRunsEveryElementOnce() async {
        let counter = ConcurrencyProbe()

        await HashPipelinePolicy.processConcurrently(Array(1...25), limit: 4) { _ in
            await counter.bump()
        }

        let total = await counter.totalCount
        XCTAssertEqual(total, 25)
    }

    func testCancellationStopsBeforeNextOperation() async {
        let firstOperationStarted = expectation(description: "first operation starts")
        let startedSecondOperation = expectation(description: "second operation starts")
        startedSecondOperation.isInverted = true

        let task = Task {
            await HashPipelinePolicy.processConcurrently([1, 2], limit: 1) { value in
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

    func testFinishedRunCannotOwnStateAfterRestart() {
        let state = HashPipelinePolicy.RunState()
        let oldRunID = state.beginIfIdle()

        guard let oldRunID else {
            return XCTFail("Expected the first run to start")
        }
        XCTAssertTrue(state.finish(oldRunID))

        let newRunID = state.beginIfIdle()

        guard let newRunID else {
            return XCTFail("Expected the second run to start")
        }
        XCTAssertFalse(state.owns(oldRunID))
        XCTAssertTrue(state.owns(newRunID))
    }

    func testFinishingRunPreventsItFromOwningState() {
        let state = HashPipelinePolicy.RunState()
        let runID = state.beginIfIdle()

        guard let runID else {
            return XCTFail("Expected the run to start")
        }
        XCTAssertTrue(state.finish(runID))

        XCTAssertFalse(state.owns(runID))
    }

    func testStaleFinishCannotReleaseCurrentRun() {
        let state = HashPipelinePolicy.RunState()
        guard let oldRunID = state.beginIfIdle() else {
            return XCTFail("Expected the old run to start")
        }
        XCTAssertTrue(state.finish(oldRunID))
        guard let currentRunID = state.beginIfIdle() else {
            return XCTFail("Expected the current run to start")
        }

        XCTAssertFalse(state.finish(oldRunID))
        XCTAssertTrue(state.owns(currentRunID))
    }

    func testStaleFinishCannotReleaseStoppingPhase() {
        let state = HashPipelinePolicy.RunState()
        guard let runID = state.beginIfIdle() else {
            return XCTFail("Expected the run to start")
        }
        XCTAssertTrue(state.beginStopping())

        XCTAssertFalse(state.finish(runID))
        XCTAssertNil(state.beginIfIdle())

        state.finishStopping()
        XCTAssertNotNil(state.beginIfIdle())
    }

    func testRejectedAdmissionDoesNotRunSideEffects() {
        let state = HashPipelinePolicy.RunState()
        XCTAssertNotNil(state.beginIfIdle())
        var sideEffectCount = 0

        let rejectedRunID = HashPipelinePolicy.admitIfIdle(using: state) { _ in
            sideEffectCount += 1
        }

        XCTAssertNil(rejectedRunID)
        XCTAssertEqual(sideEffectCount, 0)
    }

    func testSuccessfulAdmissionRunsSideEffectsOnce() {
        let state = HashPipelinePolicy.RunState()
        var sideEffectCount = 0

        let runID = HashPipelinePolicy.admitIfIdle(using: state) { admittedRunID in
            XCTAssertTrue(state.owns(admittedRunID))
            sideEffectCount += 1
        }

        XCTAssertNotNil(runID)
        XCTAssertEqual(sideEffectCount, 1)
    }

    func testStoppingAdmissionRejectsStartWithoutSideEffects() {
        let state = HashPipelinePolicy.RunState()
        XCTAssertTrue(state.beginStopping())
        var sideEffectCount = 0

        let rejectedRunID = HashPipelinePolicy.admitIfIdle(using: state) { _ in
            sideEffectCount += 1
        }

        XCTAssertNil(rejectedRunID)
        XCTAssertEqual(sideEffectCount, 0)

        state.finishStopping()
        XCTAssertNotNil(HashPipelinePolicy.admitIfIdle(using: state) { _ in
            sideEffectCount += 1
        })
        XCTAssertEqual(sideEffectCount, 1)
    }

    func testRunStateRejectsOverlappingRunUntilInvalidated() {
        let state = HashPipelinePolicy.RunState()

        let firstRunID = state.beginIfIdle()
        let overlappingRunID = state.beginIfIdle()

        XCTAssertNotNil(firstRunID)
        XCTAssertNil(overlappingRunID)

        XCTAssertTrue(state.finish(firstRunID!))

        XCTAssertNotNil(state.beginIfIdle())
    }

    func testRunStateRejectsStartsWhileStopping() {
        let state = HashPipelinePolicy.RunState()
        let runID = state.beginIfIdle()

        XCTAssertNotNil(runID)
        XCTAssertTrue(state.beginStopping())
        XCTAssertNil(state.beginIfIdle())

        state.finishStopping()

        XCTAssertNotNil(state.beginIfIdle())
    }

    func testRunStateAllowsExactlyOneConcurrentStart() async {
        let state = HashPipelinePolicy.RunState()
        let winners = await withTaskGroup(of: UUID?.self, returning: [UUID].self) { group in
            for _ in 0..<100 {
                group.addTask {
                    state.beginIfIdle()
                }
            }

            var runIDs: [UUID] = []
            for await runID in group {
                if let runID {
                    runIDs.append(runID)
                }
            }
            return runIDs
        }

        guard let winner = winners.only else {
            return XCTFail("Expected exactly one run to start, got \(winners.count)")
        }
        XCTAssertTrue(state.owns(winner))
    }

    func testRunStateIsSafeAcrossConcurrentAccess() async {
        let state = HashPipelinePolicy.RunState()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    if let runID = state.beginIfIdle() {
                        _ = state.owns(runID)
                        _ = state.finish(runID)
                    }
                }
                group.addTask {
                    if state.beginStopping() {
                        state.finishStopping()
                    }
                }
            }
        }

        let finalRunID = state.beginIfIdle()
        guard let finalRunID else {
            return XCTFail("Expected a run after concurrent access")
        }
        XCTAssertTrue(state.owns(finalRunID))
        XCTAssertTrue(state.finish(finalRunID))
        XCTAssertFalse(state.owns(finalRunID))
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}
