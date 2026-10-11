// A one-thread task executor for tests that need a blocking call to be visible.
//
// The default cooperative pool is no use for that: libdispatch adds threads when a worker blocks.
// A task started with `withTaskExecutorPreference(_:operation:)` on this executor runs its jobs
// strictly one at a time, so a job that blocks holds every other job back.

import Foundation

final class SingleThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "occtmcp.test.single-thread-executor")

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async { unownedJob.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
