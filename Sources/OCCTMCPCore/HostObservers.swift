// Hooks for an embedding host: which tool is running, what each manifest write carries, and a
// per-call event stream. All are scoped to the call through task-locals or an ordered pump, so
// two servers in one process never see each other's calls.

import Foundation
import MCP

/// Called under the manifest lock with the exact bytes about to be written and the running tool.
///
/// `tool` is nil for a write made outside any tool call. Throwing aborts the write.
public typealias ManifestWriteObserver = @Sendable (_ data: Data, _ tool: String?) throws -> Void

public enum OCCTMCPContext {
    /// The name of the tool whose handler is running on this task.
    ///
    /// Set around each `CallTool` dispatch; child tasks inherit it, `Task.detached` does not.
    @TaskLocal public static var currentTool: String?

    /// The observer an embedding host asked for, scoped to the current task.
    @TaskLocal public static var manifestWriteObserver: ManifestWriteObserver?
}

/// One step in the life of a `tools/call`, delivered to the host's `ToolCallObserver`.
public struct ToolCallEvent: Sendable {
    public enum Phase: Sendable, Equatable {
        case started
        case finished(isError: Bool)
    }

    /// Ties a `started` event to its `finished` event; unique per call.
    public let callID: UUID
    public let name: String
    public let arguments: [String: Value]
    public let phase: Phase
    public let timestamp: Date
}

/// Receives each tool call's events, one at a time and in order, off the tool's critical path.
public typealias ToolCallObserver = @Sendable (ToolCallEvent) -> Void

/// Delivers events to an observer on a single consumer task, so a slow observer never delays
/// a tool result and events arrive in the order they were emitted.
struct ToolCallEventPump: Sendable {
    private let continuation: AsyncStream<ToolCallEvent>.Continuation

    init(observer: @escaping ToolCallObserver) {
        let (stream, continuation) = AsyncStream.makeStream(of: ToolCallEvent.self)
        self.continuation = continuation
        Task {
            for await event in stream { observer(event) }
        }
    }

    func emit(_ name: String, _ arguments: [String: Value], _ phase: ToolCallEvent.Phase, id: UUID)
    {
        continuation.yield(
            ToolCallEvent(
                callID: id, name: name, arguments: arguments, phase: phase, timestamp: Date()))
    }
}
