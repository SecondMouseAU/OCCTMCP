// A deadline for a test that must not hang the suite: run some work, and give up on it after a
// while instead of waiting for it. Shared by the tests that guard against a call that never returns.

import Foundation

/// Runs `work` and gives up after `seconds`, returning nil.
///
/// A call that never returns is left running rather than awaited, so a hang fails the test
/// instead of stopping the suite. A task group would wait for it.
func finishing<T: Sendable>(
    within seconds: Double, _ work: @escaping @Sendable () async throws -> T
) async -> Result<T, Error>? {
    await withCheckedContinuation { (continuation: CheckedContinuation<Result<T, Error>?, Never>) in
        let gate = Gate(continuation)
        Task {
            do { gate.open(.success(try await work())) } catch { gate.open(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            gate.open(nil)
        }
    }
}

/// Resumes a continuation once, whichever caller gets there first.
private final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

    func open(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
