// What `ExecuteScriptTool.runProcess` does between the child exiting and the call returning (#265).
// None of it touches the script workspace: every call runs in a scratch directory of its own.

import Foundation
@testable import OCCTMCPCore
import Testing

@Suite("execute_script child process")
struct ExecuteScriptProcessTests {

    /// A scratch directory for a child's working directory, removed afterwards.
    private func withScratch<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("occtmcp-process-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }

    /// What the repeated calls in `returnsAfterEveryChild` produced.
    private struct Run: Sendable {
        let statuses: [Int32]
        let outputs: Set<String>
    }

    @Test(
        "runProcess returns after every child exits, call after call",
        .timeLimit(.minutes(2))
    )
    func returnsAfterEveryChild() async throws {
        // Regression for #265: `waitUntilExit()` after the drains' awaits, on a process with no
        // termination handler, waits on the run loop of the thread that launched the child. The
        // task can resume on another thread, and then the call never returns. A standalone copy of
        // the old shape stalled within 32 calls in each of 25 tries on macOS 27.2, so 100 calls
        // leave a wide margin there; this test has not been run on another OS version. The
        // deadline turns the hang into a failure instead of a stopped suite.
        let runs = 100
        let outcome = try await withScratch { scratch in
            await finishing(within: 90) {
                var statuses: [Int32] = []
                var outputs: Set<String> = []
                for index in 0..<runs {
                    let result = try await ExecuteScriptTool.runProcess(
                        executable: "/bin/sh",
                        args: ["-c", "echo out; echo err 1>&2; exit \(index % 2)"],
                        currentDirectory: scratch)
                    statuses.append(result.exitCode)
                    outputs.insert("\(result.stdout)|\(result.stderr)")
                }
                return Run(statuses: statuses, outputs: outputs)
            }
        }
        let finished = try #require(outcome, "runProcess stopped returning within 90 s")
        let run = try finished.get()
        let expected: [Int32] = (0..<runs).map { Int32($0 % 2) }
        #expect(run.statuses == expected, "each call reports its own child's exit status")
        let expectedOutputs: Set<String> = ["out\n|err\n"]
        #expect(run.outputs == expectedOutputs, "each call returns its child's stdout and stderr")
    }

    @Test(
        "a cancelled caller still gets the exit status of a child that finished",
        .timeLimit(.minutes(1))
    )
    func cancellationDoesNotEndTheWait() async throws {
        // The wait is not cancellation-aware on purpose: ending it early would leave the caller
        // reading the status of a child that is still running. The child closes both pipes first,
        // so the drains finish at once and the cancellation lands while it is still alive; a child
        // that held the pipes until it exited would be over before the wait began.
        let outcome = try await withScratch { scratch in
            await finishing(within: 30) {
                let task = Task {
                    try await ExecuteScriptTool.runProcess(
                        executable: "/bin/sh", args: ["-c", "exec >&- 2>&-; sleep 1; exit 5"],
                        currentDirectory: scratch)
                }
                try await Task.sleep(for: .milliseconds(200))
                task.cancel()
                return try await task.value.exitCode
            }
        }
        let finished = try #require(outcome, "the cancelled call never returned")
        #expect(try finished.get() == 5)
    }

    @Test(
        "ProcessExit delivers an exit that happened before anyone waited",
        .timeLimit(.minutes(1))
    )
    func exitBeforeWait() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 7"]
        let exited = ProcessExit(process)
        try process.run()
        // Long enough for the child to exit and the handler to run with no waiter yet.
        try await Task.sleep(for: .milliseconds(500))
        let outcome = await finishing(within: 20) { await exited.status() }
        let finished = try #require(outcome, "an exit that came first was lost")
        #expect(try finished.get() == 7)
    }

    @Test("ProcessExit resumes a waiter when the child exits later", .timeLimit(.minutes(1)))
    func exitAfterWait() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; exit 3"]
        let exited = ProcessExit(process)
        try process.run()
        let outcome = await finishing(within: 20) { await exited.status() }
        let finished = try #require(outcome, "a waiter was never resumed")
        #expect(try finished.get() == 3)
    }

    @Test("ProcessExit can be asked again, and by several waiters at once", .timeLimit(.minutes(1)))
    func askedMoreThanOnce() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.5; exit 4"]
        let exited = ProcessExit(process)
        try process.run()
        let outcome = await finishing(within: 20) {
            async let first = exited.status()
            async let second = exited.status()
            let together = await [first, second]
            let later = await exited.status()
            return together + [later]
        }
        let finished = try #require(outcome, "a second wait never returned")
        let statuses: [Int32] = try finished.get()
        let expected: [Int32] = [4, 4, 4]
        #expect(statuses == expected)
    }
}

/// Runs `work` and gives up after `seconds`, returning nil.
///
/// A call that never returns is left running rather than awaited, so a hang fails the test
/// instead of stopping the suite. A task group would wait for it.
private func finishing<T: Sendable>(
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
