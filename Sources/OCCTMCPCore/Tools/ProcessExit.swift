// ProcessExit: the exit status of a child process, awaited without `Process.waitUntilExit()` (#265).

import Foundation

/// The exit status of a child process, delivered by `Process.terminationHandler`.
///
/// Create it before `Process.run()`. `status()` may be awaited any number of times, before or
/// after the exit, and is not cut short when the awaiting task is cancelled.
final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []

    init(_ process: Process) {
        process.terminationHandler = { [self] finished in
            deliver(finished.terminationStatus)
        }
    }

    private func deliver(_ status: Int32) {
        lock.lock()
        code = status
        let pending = waiters
        waiters = []
        lock.unlock()
        for waiter in pending { waiter.resume(returning: status) }
    }

    /// The child's exit status, once it has exited.
    func status() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let code {
                lock.unlock()
                continuation.resume(returning: code)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}
