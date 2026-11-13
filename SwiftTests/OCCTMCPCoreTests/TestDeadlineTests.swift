// The deadline helper the hang-guard tests rely on (TestDeadline.swift): it returns nil when the
// work outlives the deadline, and it cancels that work so a polling loop does not run on.

import Foundation
import Testing

@Suite("test deadline helper")
struct TestDeadlineTests {

    @Test("work that outlives the deadline gives nil, and is cancelled")
    func deadlineCancelsTheWork() async throws {
        let noticed = Flag()
        let outcome = await finishing(within: 0.2) {
            do {
                while true { try await Task.sleep(for: .milliseconds(10)) }
            } catch {
                noticed.set()
                throw error
            }
        }
        #expect(outcome == nil, "work that never finishes was not given up on")
        // Cancellation is cooperative and lands a moment after the deadline, so wait for it.
        let stopped = await finishing(within: 10) {
            while !noticed.isSet { try await Task.sleep(for: .milliseconds(10)) }
            return true
        }
        #expect(try stopped?.get() == true, "the work was left running after the deadline")
    }

    @Test("work that throws before the deadline reports the error, not a timeout")
    func throwingWorkReportsItsError() async throws {
        struct Refused: Error, Equatable {}
        let outcome = await finishing(within: 10) { () async throws -> Int in throw Refused() }
        let finished = try #require(outcome, "a throw was reported as running out of time")
        #expect(throws: Refused.self) { try finished.get() }
    }

    @Test("work that finishes in time returns its result")
    func finishedWorkReturnsItsResult() async throws {
        let outcome = await finishing(within: 10) { 42 }
        #expect(try outcome?.get() == 42)
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
