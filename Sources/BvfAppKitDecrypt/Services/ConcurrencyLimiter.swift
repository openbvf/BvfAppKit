import Foundation

final class ConcurrencyLimiter: @unchecked Sendable {
    static let shared = ConcurrencyLimiter(limit: BvfAppKitConfig.decryptionConcurrencyLimit)

    private var value: Int
    private var suspensions: [Suspension] = []
    private let _lock = NSRecursiveLock()

    // Wrapper methods to avoid Swift 6 compiler warning about
    // lock methods being unavailable from async contexts
    private func lock() { _lock.lock() }
    private func unlock() { _lock.unlock() }

    init(limit: Int) {
        self.value = limit
    }

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await wait()
        defer { signal() }
        return try await operation()
    }

    func runSync<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await wait()
        defer { signal() }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try operation()
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func wait() async throws {
        lock()
        value -= 1
        if value >= 0 {
            unlock()
            return
        }

        let suspension = Suspension()
        suspensions.append(suspension)
        unlock()

        await withTaskCancellationHandler {
            await withUnsafeContinuation { continuation in
                suspension.resume(with: continuation)
            }
        } onCancel: {
            self.lock()
            if suspension.cancel() {
                self.value += 1
                self.suspensions.removeAll { $0 === suspension }
            }
            self.unlock()
        }

        if suspension.wasCancelled {
            throw CancellationError()
        }
    }

    private func signal() {
        lock()
        defer { unlock() }
        value += 1
        guard !suspensions.isEmpty else { return }
        suspensions.removeFirst().signal()
    }
}

private final class Suspension: @unchecked Sendable {
    enum State {
        case pending
        case suspended(UnsafeContinuation<Void, Never>)
        case cancelled
        case signalled
    }

    private var state: State = .pending
    private let _lock = NSLock()

    private func lock() { _lock.lock() }
    private func unlock() { _lock.unlock() }

    func resume(with continuation: UnsafeContinuation<Void, Never>) {
        lock()
        switch state {
        case .pending:
            state = .suspended(continuation)
            unlock()
        case .signalled:
            unlock()
            continuation.resume()
        case .cancelled:
            unlock()
            continuation.resume()  // Let caller check cancellation
        case .suspended:
            fatalError("Already suspended")
        }
    }

    func signal() {
        lock()
        switch state {
        case .pending:
            state = .signalled
            unlock()
        case .suspended(let continuation):
            state = .signalled
            unlock()
            continuation.resume()
        case .cancelled, .signalled:
            unlock()
        }
    }

    /// Returns true if cancellation was handled (caller should release slot)
    func cancel() -> Bool {
        lock()
        switch state {
        case .pending:
            state = .cancelled
            unlock()
            return true
        case .suspended(let continuation):
            state = .cancelled
            unlock()
            continuation.resume()
            return true
        case .cancelled, .signalled:
            unlock()
            return false
        }
    }

    var wasCancelled: Bool {
        lock()
        defer { unlock() }
        if case .cancelled = state { return true }
        return false
    }
}
