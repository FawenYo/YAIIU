import Foundation
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

    func testPreparingPlaceholderMustNotCountAsAnAdmittedHashRun() {
        let state = HashPipelinePolicy.RunState()
        XCTAssertFalse(state.isRunning)
        guard let runID = state.beginIfIdle() else {
            return XCTFail("Expected a hash run")
        }
        XCTAssertTrue(state.isRunning)
        XCTAssertTrue(state.finish(runID))
        XCTAssertFalse(state.isRunning)
    }

    func testProcessingStageExplainsWhyPreparationIsTakingTime() {
        XCTAssertEqual(
            PhotoGridProcessingStage.resolve(
                statusMessage: "Preparing...",
                processed: 0,
                total: 0,
                isSyncing: true,
                foregroundWorkPreparing: false
            ),
            .syncingServer
        )
        XCTAssertEqual(
            PhotoGridProcessingStage.resolve(
                statusMessage: "Preparing...",
                processed: 0,
                total: 0,
                isSyncing: false,
                foregroundWorkPreparing: true
            ),
            .readingPhotoLibrary
        )
        XCTAssertEqual(
            PhotoGridProcessingStage.resolve(
                statusMessage: "Preparing...",
                processed: 0,
                total: 0,
                isSyncing: false,
                foregroundWorkPreparing: false
            ),
            .preparingComparison
        )
    }

    func testProcessingStripRevealsOnlyAfterSustainedProcessing() {
        XCTAssertEqual(
            PhotoGridProcessingStripPolicy.transition(isProcessing: true, isRevealed: false),
            .init(revealed: true, after: PhotoGridProcessingStripPolicy.revealDelay)
        )
        XCTAssertNil(PhotoGridProcessingStripPolicy.transition(isProcessing: true, isRevealed: true))
    }

    func testProcessingStripHidesAfterGraceOnlyWhenRevealed() {
        XCTAssertEqual(
            PhotoGridProcessingStripPolicy.transition(isProcessing: false, isRevealed: true),
            .init(revealed: false, after: PhotoGridProcessingStripPolicy.hideDelay)
        )
        XCTAssertNil(PhotoGridProcessingStripPolicy.transition(isProcessing: false, isRevealed: false))
    }

    func testProcessingStripDelaysOutlastZeroWorkReconciliation() {
        XCTAssertGreaterThanOrEqual(PhotoGridProcessingStripPolicy.revealDelay, .milliseconds(500))
        XCTAssertGreaterThan(PhotoGridProcessingStripPolicy.hideDelay, .zero)
    }

    func testProcessingStripStaysOutOfBaselineProgress() {
        XCTAssertTrue(PhotoGridProcessingStripPolicy.isVisible(isRevealed: true, baselineInProgress: false))
        XCTAssertFalse(PhotoGridProcessingStripPolicy.isVisible(isRevealed: true, baselineInProgress: true))
        XCTAssertFalse(PhotoGridProcessingStripPolicy.isVisible(isRevealed: false, baselineInProgress: false))
    }

    func testPreparationStagesUseDedicatedProcessingScreen() {
        XCTAssertTrue(PhotoGridProcessingStage.syncingServer.showsDedicatedScreen)
        XCTAssertTrue(PhotoGridProcessingStage.readingPhotoLibrary.showsDedicatedScreen)
        XCTAssertTrue(PhotoGridProcessingStage.preparingComparison.showsDedicatedScreen)
        XCTAssertTrue(PhotoGridProcessingStage.defaultStatus.showsDedicatedScreen)
        XCTAssertFalse(PhotoGridProcessingStage.analyzing(current: 1, total: 111).showsDedicatedScreen)
        XCTAssertFalse(PhotoGridProcessingStage.checking(current: 1, total: 111).showsDedicatedScreen)
    }

    func testPhotoKitBaselineProgressReportsBoundedFraction() {
        let progress = PhotoKitBaselineProgress(completed: 17_700, total: 101_731, stage: .hashVersions)
        XCTAssertEqual(progress.fraction, 17_700.0 / 101_731.0, accuracy: 0.000_001)
        XCTAssertFalse(progress.isComplete)

        let completed = PhotoKitBaselineProgress(completed: 200, total: 100, stage: .hashVersions)
        XCTAssertEqual(completed.fraction, 1)
        XCTAssertTrue(completed.isComplete)
    }

    func testPhotoKitBaselineProgressDescribesEachStageDifferently() {
        let inventory = PhotoKitBaselineProgress(completed: 3, total: 10, stage: .inventory)
        let versions = PhotoKitBaselineProgress(completed: 3, total: 10, stage: .hashVersions)
        XCTAssertNotEqual(L10n.PhotoGrid.processingBaseline(inventory), L10n.PhotoGrid.processingBaseline(versions))
        XCTAssertTrue(L10n.PhotoGrid.processingBaseline(inventory).contains("3/10"))
        XCTAssertTrue(L10n.PhotoGrid.processingBaseline(versions).contains("3/10"))
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

        guard winners.count == 1, let winner = winners.first else {
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

    func testMemoryPressureThrottleUsesFastPathBeforeWarning() async {
        let throttle = HashMemoryPressureThrottle()

        let permit = await throttle.acquireIfNeeded()

        XCTAssertEqual(permit, false)
        XCTAssertFalse(throttle.isThrottled)
    }

    func testMemoryPressureThrottleSerializesAfterWarning() async {
        let throttle = HashMemoryPressureThrottle()
        throttle.signal(cooldown: 0)

        guard let firstPermit = await throttle.acquireIfNeeded() else {
            return XCTFail("Expected first pressure-mode permit")
        }
        XCTAssertTrue(firstPermit)
        XCTAssertTrue(throttle.isThrottled)

        let probe = ConcurrencyProbe()
        let waiter = Task {
            guard let permit = await throttle.acquireIfNeeded() else { return }
            await probe.bump()
            throttle.releaseIfNeeded(permit)
        }

        try? await Task.sleep(nanoseconds: 50_000_000)
        let admittedWhileHeld = await probe.totalCount
        XCTAssertEqual(admittedWhileHeld, 0)

        throttle.releaseIfNeeded(firstPermit)
        await waiter.value
        let admittedAfterRelease = await probe.totalCount
        XCTAssertEqual(admittedAfterRelease, 1)
    }

    func testFileHasherProducesExpectedSHA1WithExplicitCancellationHook() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data("abc".utf8).write(to: url)
        let result = try FileHasher.sha1Hex(ofFileAt: url, shouldCancel: { false })

        XCTAssertEqual(result.hash, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(result.size, 3)
    }

    func testFileHasherHonorsExplicitCancellationHook() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hash-cancel-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }

        try Data(repeating: 0xAB, count: 1024).write(to: url)

        XCTAssertThrowsError(
            try FileHasher.sha1Hex(ofFileAt: url, shouldCancel: { true })
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPhotoKitRequestSlotsAdmitUpToRequestWindow() async {
        let slots = ResourceBudget(limit: Int64(HashPipelinePolicy.photoKitRequestWindow))

        for _ in 0..<HashPipelinePolicy.photoKitRequestWindow {
            let admitted = await slots.acquire(1)
            XCTAssertTrue(admitted)
        }

        let waiter = Task { await slots.acquire(1) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let extraAdmitted = await waiter.value
        XCTAssertFalse(extraAdmitted)
    }

    func testHashRunStatsSummarizesThroughput() {
        let stats = HashRunStats(startedAt: 100)
        stats.recordHashed(bytes: 1024 * 1024)
        stats.recordHashed(bytes: 3 * 1024 * 1024)
        stats.recordFailed()

        let summary = stats.summary(now: 102)

        XCTAssertEqual(summary.hashedAssets, 2)
        XCTAssertEqual(summary.failedAssets, 1)
        XCTAssertEqual(summary.bytes, 4 * 1024 * 1024)
        XCTAssertEqual(summary.elapsed, 2, accuracy: 0.0001)
        XCTAssertEqual(summary.mebibytesPerSecond, 2, accuracy: 0.0001)
    }

    func testHashRunStatsReportsProgressEveryInterval() {
        let stats = HashRunStats(startedAt: 100)
        var reports: [Int] = []

        for _ in 0..<(HashRunStats.progressInterval * 2 + 1) {
            if let progress = stats.recordHashed(bytes: 1) {
                reports.append(progress.hashedAssets)
            }
        }

        XCTAssertEqual(reports, [HashRunStats.progressInterval, HashRunStats.progressInterval * 2])
    }

    func testHashRunStatsReportsZeroThroughputWithoutElapsedTime() {
        let stats = HashRunStats(startedAt: 100)
        stats.recordHashed(bytes: 1024)

        XCTAssertEqual(stats.summary(now: 100).mebibytesPerSecond, 0)
    }

    func testStreamingHashMatchesFileHasherForSameBytes() async throws {
        let first = Data(repeating: 0x11, count: 700_000)
        let second = Data(repeating: 0x22, count: 300_001)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stream-hash-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try (first + second).write(to: url)
        let expected = try FileHasher.sha1Hex(ofFileAt: url, shouldCancel: { false })

        let request = StreamingHashRequest()
        let result = try await withCheckedThrowingContinuation { continuation in
            guard request.install(continuation) else { return }
            request.receive(first)
            request.receive(second)
            request.finish(error: nil)
        }

        XCTAssertEqual(result.hash, expected.hash)
        XCTAssertEqual(result.size, expected.size)
    }

    func testStreamingHashPropagatesDeliveryError() async {
        struct DeliveryError: Error {}
        let request = StreamingHashRequest()

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                request.receive(Data("abc".utf8))
                request.finish(error: DeliveryError())
            }
            XCTFail("Expected delivery error")
        } catch {
            XCTAssertTrue(error is DeliveryError)
        }
    }

    func testStreamingHashCancelledBeforeInstallThrowsAndCancelsLateRequest() async {
        let request = StreamingHashRequest()
        request.cancel()

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                _ = request.install(continuation)
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        var cancelledRequest = false
        request.attachCancellation { cancelledRequest = true }
        XCTAssertTrue(cancelledRequest)
    }

    func testStreamingHashCancellationWaitsForCompletionAndIgnoresLateDelivery() async {
        let request = StreamingHashRequest()
        var cancelCount = 0
        var resumedBeforeCompletion = true

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                request.attachCancellation { cancelCount += 1 }
                request.receive(Data("abc".utf8))
                request.cancel()
                request.receive(Data("late".utf8))
                request.cancel()
                resumedBeforeCompletion = false
                request.finish(error: nil)
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(resumedBeforeCompletion)
    }

    func testStreamingHashCancelBeforeAttachCancelsRequestImmediately() async {
        let request = StreamingHashRequest()
        var cancelledRequest = false

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                request.cancel()
                request.attachCancellation { cancelledRequest = true }
                request.finish(error: nil)
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(cancelledRequest)
    }

    func testStreamingHashCancellationOverridesDeliveryError() async {
        struct DeliveryError: Error {}
        let request = StreamingHashRequest()

        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                request.cancel()
                request.finish(error: DeliveryError())
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testHashPipelineRequestWindow() {
        XCTAssertEqual(HashPipelinePolicy.photoKitRequestWindow, 3)
    }

    func testBudgetBlocksWhenExhaustedThenAdmitsOnRelease() async {
        let budget = ResourceBudget(limit: 10)
        let first = await budget.acquire(6)
        XCTAssertTrue(first)

        let probe = ConcurrencyProbe()
        let second = Task {
            if await budget.acquire(6) {
                await probe.bump()
            }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let markedEarly = await probe.totalCount
        XCTAssertEqual(markedEarly, 0, "second acquire must block while the budget is exhausted")

        budget.release(6)
        await second.value
        let markedAfter = await probe.totalCount
        XCTAssertEqual(markedAfter, 1)
    }

    func testOversizedRequestAdmittedAloneButNeverOverlapping() async {
        let budget = ResourceBudget(limit: 10)
        // Larger than the whole limit: admitted alone while idle.
        let big = await budget.acquire(25)
        XCTAssertTrue(big)

        let probe = ConcurrencyProbe()
        let smallFirst = Task {
            if await budget.acquire(1) { await probe.bump() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let oversized = Task {
            if await budget.acquire(20) { await probe.bump() }
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let markedEarly = await probe.totalCount
        XCTAssertEqual(markedEarly, 0, "no admission may overlap an oversized reservation")

        budget.release(25)
        await smallFirst.value
        // Strict FIFO: the small waiter got in; the oversized one must still
        // wait for a fully idle budget even though headroom exists.
        let markedPartial = await probe.totalCount
        XCTAssertEqual(markedPartial, 1)

        budget.release(1)
        await oversized.value
        let markedFinal = await probe.totalCount
        XCTAssertEqual(markedFinal, 2)
    }

    func testOversizedQueueHeadAdmitsWhenBudgetBecomesIdleWithFollowers() async {
        let budget = ResourceBudget(limit: 10)
        let held = await budget.acquire(10)
        XCTAssertTrue(held)

        let oversized = Task { await budget.acquire(20) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let follower = Task { await budget.acquire(1) }
        try? await Task.sleep(nanoseconds: 50_000_000)

        budget.release(10)
        let oversizedAcquired = await oversized.value
        XCTAssertTrue(oversizedAcquired)

        follower.cancel()
        let followerAcquired = await follower.value
        XCTAssertFalse(followerAcquired)
        budget.release(20)
    }

    func testAlreadyCancelledBudgetAcquireReturnsFalse() async {
        let budget = ResourceBudget(limit: 1)
        let held = await budget.acquire(1)
        XCTAssertTrue(held)

        let waiter = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await budget.acquire(1)
        }

        let acquired = await waiter.value
        XCTAssertFalse(acquired)
        budget.release(1)
    }

    func testCancelledWaiterIsNotAdmittedAndHoldsNothing() async {
        let budget = ResourceBudget(limit: 5)
        let held = await budget.acquire(5)
        XCTAssertTrue(held)

        let waiter = Task { await budget.acquire(4) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        let acquired = await waiter.value
        XCTAssertFalse(acquired)

        // Cancellation must not consume or corrupt the budget.
        budget.release(5)
        let next = await budget.acquire(5)
        XCTAssertTrue(next)
    }
}

 
final class PhotoLibraryFilterTests: XCTestCase {
    func testMatchingIndicesFollowGridOrderAndIgnoreUnavailableAssets() {
        let grid = ["new", "shared", "old", "hidden", "last"]
        let members: Set<String> = ["old", "shared", "not-in-library"]
        XCTAssertEqual(
            PhotoLibraryManager.matchingIndices(in: grid, members: members),
            [1, 2]
        )
    }

    func testMatchingIndicesHandleEmptyAndDuplicateMembership() {
        let grid = ["a", "b", "c"]
        XCTAssertEqual(PhotoLibraryManager.matchingIndices(in: grid, members: []), [])
        XCTAssertEqual(
            PhotoLibraryManager.matchingIndices(in: grid, members: Set(["a", "a", "c"])),
            [0, 2]
        )
    }
}
