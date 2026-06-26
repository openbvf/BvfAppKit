import Testing
import Foundation
@testable import BvfAppKitDecrypt

@MainActor
struct ConcurrencyLimiterTests {

    private struct TestError: Error, Equatable {
        let id: Int
    }

    private struct TimeoutError: Error {}

    private final class ConcurrencyTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var inflight = 0
        private var peakValue = 0

        func enter() {
            lock.lock()
            inflight += 1
            peakValue = max(peakValue, inflight)
            lock.unlock()
        }

        func exit() {
            lock.lock()
            inflight -= 1
            lock.unlock()
        }

        var peak: Int {
            lock.lock()
            defer { lock.unlock() }
            return peakValue
        }
    }

    @discardableResult
    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    @Test func runEnforcesConcurrencyCap() async throws {
        let limit = 3
        let total = 20
        let limiter = ConcurrencyLimiter(limit: limit)
        let tracker = ConcurrencyTracker()

        try await withTimeout(.seconds(10)) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<total {
                    group.addTask {
                        try? await limiter.run {
                            tracker.enter()
                            try await Task.sleep(for: .milliseconds(20))
                            tracker.exit()
                        }
                    }
                }
            }
        }

        #expect(tracker.peak <= limit)
        #expect(tracker.peak == limit, "expected saturation; observed peak=\(tracker.peak)")
    }

    @Test func runSyncEnforcesConcurrencyCap() async throws {
        let limit = 2
        let total = 16
        let limiter = ConcurrencyLimiter(limit: limit)
        let tracker = ConcurrencyTracker()

        try await withTimeout(.seconds(10)) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<total {
                    group.addTask {
                        try? await limiter.runSync {
                            tracker.enter()
                            Thread.sleep(forTimeInterval: 0.02)
                            tracker.exit()
                        }
                    }
                }
            }
        }

        #expect(tracker.peak <= limit)
        #expect(tracker.peak == limit, "expected saturation; observed peak=\(tracker.peak)")
    }

    @Test func runRethrowsOperationError() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        await #expect(throws: TestError.self) {
            try await limiter.run { throw TestError(id: 1) }
        }
    }

    @Test func runSyncRethrowsClosureError() async {
        let limiter = ConcurrencyLimiter(limit: 1)
        await #expect(throws: TestError.self) {
            try await limiter.runSync { throw TestError(id: 2) }
        }
    }

    @Test func cancelWhileWaitingThrowsCancellationError() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let (acquiredStream, ack) = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await limiter.run {
                ack.yield()
                try await Task.sleep(for: .seconds(60))
            }
        }
        var iter = acquiredStream.makeAsyncIterator()
        _ = await iter.next()

        let waiter = Task {
            try await limiter.run { () }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()

        try await withTimeout(.seconds(5)) {
            await #expect(throws: CancellationError.self) {
                try await waiter.value
            }
        }

        holder.cancel()
        _ = try? await holder.value
    }

    @Test func cancelledWaitersReleaseSlots() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let (acquiredStream, ack) = AsyncStream<Void>.makeStream()

        let holder = Task {
            try await limiter.run {
                ack.yield()
                try await Task.sleep(for: .seconds(60))
            }
        }
        var iter = acquiredStream.makeAsyncIterator()
        _ = await iter.next()

        var waiters: [Task<Void, Error>] = []
        for _ in 0..<8 {
            waiters.append(Task { try await limiter.run { () } })
        }
        try await Task.sleep(for: .milliseconds(100))

        for w in waiters { w.cancel() }
        for w in waiters { _ = try? await w.value }

        holder.cancel()
        _ = try? await holder.value

        try await withTimeout(.seconds(2)) {
            let start = ContinuousClock.now
            try await limiter.run { () }
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .milliseconds(500))
        }
    }

    @Test func cancelDuringOperationReleasesSlot() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let (acquiredStream, ack) = AsyncStream<Void>.makeStream()

        let task = Task {
            try await limiter.run {
                ack.yield()
                try await Task.sleep(for: .seconds(60))
            }
        }
        var iter = acquiredStream.makeAsyncIterator()
        _ = await iter.next()

        task.cancel()
        _ = try? await task.value

        try await withTimeout(.seconds(2)) {
            let start = ContinuousClock.now
            try await limiter.run { () }
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .milliseconds(500))
        }
    }

    @Test func waitersWakeInArrivalOrder() async throws {
        let limiter = ConcurrencyLimiter(limit: 1)
        let (stream, cont) = AsyncStream<Int>.makeStream()

        let holder = Task {
            try await limiter.run {
                _ = cont.yield(0)
                try await Task.sleep(for: .seconds(60))
            }
        }
        var iter = stream.makeAsyncIterator()
        _ = await iter.next()  // holder has the slot

        var waiters: [Task<Void, Error>] = []
        for i in 1...3 {
            waiters.append(Task<Void, Error> {
                try await limiter.run { _ = cont.yield(i) }
            })
            try await Task.sleep(for: .milliseconds(50))  // ensure enqueue order
        }

        holder.cancel()
        _ = try? await holder.value

        var order: [Int] = []
        for _ in 0..<3 { if let v = await iter.next() { order.append(v) } }
        #expect(order == [1, 2, 3])

        for w in waiters { _ = try? await w.value }
    }

    @Test func peakConcurrencyStaysAtOrBelowLimitUnderCancellation() async throws {
        let limit = 4
        let limiter = ConcurrencyLimiter(limit: limit)

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var peak = 0
            private var current = 0
            func enter() {
                lock.lock(); defer { lock.unlock() }
                current += 1
                if current > peak { peak = current }
            }
            func exit() {
                lock.lock(); defer { lock.unlock() }
                current -= 1
            }
        }

        let counter = Counter()

        try await withTimeout(.seconds(30)) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<500 {
                    group.addTask {
                        let task = Task {
                            try await limiter.run {
                                counter.enter()
                                defer { counter.exit() }
                                try await Task.sleep(for: .milliseconds(1))
                            }
                        }
                        if i % 3 == 0 {
                            try? await Task.sleep(for: .microseconds(Int.random(in: 0...2000)))
                            task.cancel()
                        }
                        _ = try? await task.value
                    }
                }
            }
        }

        #expect(counter.peak <= limit)
    }

    @Test func stressNoSlotLeakUnderRandomCancellation() async throws {
        let limit = 4
        let total = 200
        let limiter = ConcurrencyLimiter(limit: limit)

        try await withTimeout(.seconds(60)) {
            await withTaskGroup(of: Void.self) { group in
                for i in 0..<total {
                    group.addTask {
                        let task = Task {
                            try await limiter.run {
                                try await Task.sleep(for: .milliseconds(5))
                            }
                        }
                        if i % 2 == 0 {
                            try? await Task.sleep(
                                for: .microseconds(Int.random(in: 0...3000))
                            )
                            task.cancel()
                        }
                        _ = try? await task.value
                    }
                }
            }
        }

        try await withTimeout(.seconds(2)) {
            let start = ContinuousClock.now
            try await limiter.run { () }
            let elapsed = ContinuousClock.now - start
            #expect(elapsed < .seconds(1))
        }
    }
}
