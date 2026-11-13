// Hooks for an embedding host: which tool is running, what each manifest write carries, a
// per-call event stream, the shape the host holds for a body, and how a script's stage is
// promoted. All are scoped to the call through task-locals or an ordered pump, so two servers in
// one process never see each other's calls.

import Foundation
import MCP
import OCCTSwift
import ScriptHarness

/// Called under the manifest lock with the exact bytes about to be written and the running tool.
///
/// `tool` is nil for a write made outside any tool call. Throwing aborts the write.
public typealias ManifestWriteObserver = @Sendable (_ data: Data, _ tool: String?) throws -> Void

/// Supplies the shape a host already holds for a body, so a tool reads the host's own copy.
///
/// Called with the body and the scene directory. Return nil to let the tool read the body's file
/// by its `format`. Throwing fails the tool call that asked for the shape.
///
/// It is called synchronously on whichever executor the tool is already running on: the main
/// actor for some tools, the history registry's actor for lineage reads. It must not block
/// waiting on either, so read from state the host guards with a lock.
public typealias BodyShapeProvider =
    @Sendable (_ body: BodyDescriptor, _ outputDir: String) throws -> Shape?

/// Sends one progress update for the `tools/call` it was made for.
///
/// `progress` rises with each call; `total` is the expected final value when known.
public typealias ProgressReporter =
    @Sendable (_ progress: Double, _ total: Double?, _ message: String?) async -> Void

/// Takes a finished `execute_script` run's output into the scene.
///
/// Called with the stage directory the script wrote into and the scene directory, after the run
/// exited zero, left no failure marker, and wrote a manifest that lists only files the stage holds.
/// The stage is outside the scene. Throwing is reported to the agent as a failed promotion.
///
/// Without one, OCCTMCP replaces the scene with the stage's output itself. With one, the host owns
/// the promotion: nothing is copied into the scene for it. OCCTMCP removes the stage when the
/// promoter returns, so a host that wants to keep any of it moves it first.
public typealias ScriptStagePromoter =
    @Sendable (_ stage: URL, _ sceneDirectory: String) async throws -> Void

public enum OCCTMCPContext {
    /// The name of the tool whose handler is running on this task.
    ///
    /// Set around each `CallTool` dispatch; child tasks inherit it, `Task.detached` does not.
    @TaskLocal public static var currentTool: String?

    /// The observer an embedding host asked for, scoped to the current task.
    @TaskLocal public static var manifestWriteObserver: ManifestWriteObserver?

    /// The body shape provider an embedding host asked for, scoped to the current task.
    @TaskLocal public static var bodyShapeProvider: BodyShapeProvider?

    /// The script stage promoter an embedding host asked for, scoped to the current task.
    @TaskLocal public static var scriptStagePromoter: ScriptStagePromoter?

    /// Where this call's progress updates go, set only when the client sent a `progressToken`.
    @TaskLocal public static var progressReporter: ProgressReporter?

    /// Report progress on the tool call this task is running, if the client asked for it.
    ///
    /// A no-op when the request carried no `progressToken` and outside any tool call, so a handler
    /// can call it unconditionally. Send values that rise with each call, as the MCP spec asks.
    /// A notification that cannot be sent is dropped and never fails the call.
    public static func reportProgress(
        _ progress: Double, total: Double? = nil, message: String? = nil
    ) async {
        await progressReporter?(progress, total, message)
    }
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
///
/// The consumer is detached so it never runs on the caller's actor, and it ends when the pump is
/// released. It reads no task-locals, so detaching does not drop anything it needs.
final class ToolCallEventPump: Sendable {
    private let continuation: AsyncStream<ToolCallEvent>.Continuation

    init(observer: @escaping ToolCallObserver) {
        let (stream, continuation) = AsyncStream.makeStream(of: ToolCallEvent.self)
        self.continuation = continuation
        Task.detached {
            for await event in stream { observer(event) }
        }
    }

    deinit { continuation.finish() }

    func emit(_ name: String, _ arguments: [String: Value], _ phase: ToolCallEvent.Phase, id: UUID)
    {
        continuation.yield(
            ToolCallEvent(
                callID: id, name: name, arguments: arguments, phase: phase, timestamp: Date()))
    }
}
