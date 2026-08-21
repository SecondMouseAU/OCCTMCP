// SelectionBridgeTools: get_selection / highlight_selection, the read and
// write halves of the agent <-> viewport-host selection bridge (#189/#190).
//
// OCCTMCP is a stdio MCP process with no persistent link to any app's live
// InteractiveContext/ViewportService, so this doesn't call into a live
// selection directly. Instead it speaks the sidecar-file wire format from
// SecondMouseAU/OCCTSwiftInteraction#17 (the ADR): a host process (e.g.
// ACADStudio) writes `selection.json` and watches `highlight_requests/` in
// the SAME resolved output directory every other OCCTMCP sidecar already
// uses. That host also holds an exclusive flock on `host.lock` for its
// whole lifetime, which is this file's one piece of shared plumbing: a
// non-blocking shared-lock probe distinguishes "no host is running" from
// "a host is running but nothing (yet) selected": the three-state
// distinction #189's own acceptance criteria calls out explicitly, since an
// agent that reads "nothing selected" when the truth is "no viewport"
// inherits a wrong premise into every later call.
//
// File layout (all under the resolved output directory):
//   host.lock                            : empty file, host holds LOCK_EX for its lifetime
//   host.json                            : {pid, startedAt, hostName, hostVersion, schemaVersion}
//   selection.json                       : {selections: [{bodyId,kind,index,uid?}], revision, updatedAt}
//   highlight_requests/<id>.json         : written here: {id,bodyId,kind,index,scheme,question?}
//   highlight_requests/handled/<id>.json : written by the host: {outcome,reason?}
//
// Every writer (ours included) uses atomic write (temp name + rename, i.e.
// `Data.write(to:options:.atomic)`); reads tolerate a missing file (no host
// has run yet) without crashing, except where a running host demonstrably
// should be maintaining the file (see `getSelection` below).

import Foundation
import OCCTSwift
import ScriptHarness

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Tri-state result of probing `host.lock`.
enum HostLiveness: Sendable, Equatable {
    case noHost
    case hostRunning
}

/// Non-blocking `host.lock` probe (#189 ADR): a host holds an exclusive
/// flock on this file for its whole lifetime.
///
/// Trying a non-blocking SHARED
/// lock and seeing whether that succeeds is the documented check: success
/// means nothing holds the exclusive lock (no host), failure with
/// `EWOULDBLOCK` means something does (a host is running). A missing lock
/// file is the same as no host, trivially: nothing can be holding a lock on
/// a file that was never created. An `open` failure for any other reason
/// (permissions, a TOCTOU race with a deletion), and a `flock` failure for
/// any reason OTHER than `EWOULDBLOCK` (locking unsupported on the
/// filesystem, an interrupted call), fails open to `.noHost` rather than
/// claiming a positive "host running" signal this probe never actually
/// observed: only `EWOULDBLOCK` is evidence of a live exclusive holder, and
/// nothing else is treated as if it were.
enum HostLock {
    static func checkLiveness(outputDir: String) -> HostLiveness {
        let path = "\(outputDir)/host.lock"
        guard FileManager.default.fileExists(atPath: path) else {
            return .noHost
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return .noHost
        }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return .noHost
        }
        return (errno == EWOULDBLOCK) ? .hostRunning : .noHost
    }
}

public enum SelectionBridgeTools {

    // MARK: - Wire types (SecondMouseAU/OCCTSwiftInteraction#17)

    public struct HostInfo: Codable, Sendable {
        public let pid: Int
        public let startedAt: String
        public let hostName: String
        public let hostVersion: String
        public let schemaVersion: Int
    }

    /// One entry from `selection.json`, exactly as the host wrote it.
    ///
    /// `uid` here is the HOST's own opaque identity string, from whatever
    /// `BRepGraph.GraphUID` its own process minted; it is passed through
    /// as-is and never treated as a uid this server's own
    /// `SelectionRegistry`/`HistoryRegistry` graph could resolve (those are
    /// separate process-local graph instances, and a `GraphUID` is
    /// documented as instance-scoped).
    public struct SelectionJSONEntry: Codable, Sendable {
        public let bodyId: String
        public let kind: String
        public let index: Int
        public let uid: String?
    }

    public struct SelectionSidecar: Codable, Sendable {
        public let selections: [SelectionJSONEntry]
        public let revision: Int
        public let updatedAt: String
    }

    /// A `highlight_requests/<id>.json` request, before a host has consumed it.
    public struct HighlightRequest: Codable, Sendable {
        public let id: String
        public let bodyId: String
        public let kind: String
        public let index: Int
        public let scheme: String
        public let question: String?
    }

    /// A `highlight_requests/handled/<id>.json` response, written by the host.
    public struct HandledOutcome: Codable, Sendable {
        public let outcome: String
        public let reason: String?
    }

    // MARK: - get_selection

    /// One resolved selection entry in the `get_selection` response.
    ///
    /// `index`/`uid` mirror the wire entry as-received; `selectionId`/`anchor`
    /// are populated only when resolution against this server's OWN scene
    /// succeeded (bad `bodyId`, or an `index` outside this body's current
    /// topology, leaves both nil and populates `error` instead, without
    /// failing the rest of the response).
    public struct ResolvedSelection: Encodable {
        public let selectionId: String?
        public let bodyId: String
        public let kind: String
        public let index: Int
        public let uid: String?
        public let anchor: AnchorSnapshot?
        public let error: String?
    }

    public struct GetSelectionResult: Encodable {
        /// "noHost" | "hostRunning".
        ///
        /// Never a bare bool/empty-array: an agent
        /// must not be able to confuse "no viewport" with "viewport, nothing
        /// selected".
        public let state: String
        /// nil for `noHost`; an array (possibly empty) for `hostRunning`.
        public let selections: [ResolvedSelection]?
        public let revision: Int?
        public let updatedAt: String?
        public let host: HostInfo?
    }

    public static func getSelection(
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent

        guard HostLock.checkLiveness(outputDir: outputDir) == .hostRunning else {
            return IntrospectionTools.encode(
                GetSelectionResult(
                    state: "noHost", selections: nil, revision: nil, updatedAt: nil, host: nil))
        }

        let selectionPath = "\(outputDir)/selection.json"
        guard FileManager.default.fileExists(atPath: selectionPath) else {
            // A host is running (host.lock held) but never wrote its
            // sidecar: per the ADR the host is expected to maintain this
            // file for its whole lifetime, so this is anomalous, not
            // "nothing selected", and must not be swallowed into an empty
            // result.
            return ToolText(
                "get_selection: a host is running (host.lock held at \(outputDir)/host.lock) "
                    + "but selection.json is missing at \(selectionPath). The host is expected "
                    + "to maintain this sidecar for its whole lifetime; this looks like a startup "
                    + "race or a host that hasn't wired up the writer yet, not \"nothing selected\".",
                isError: true
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: selectionPath))
        } catch {
            return ToolText(
                "get_selection: could not read selection.json: \(error.localizedDescription)",
                isError: true
            )
        }

        let sidecar: SelectionSidecar
        do {
            sidecar = try JSONDecoder().decode(SelectionSidecar.self, from: data)
        } catch {
            // A torn read (the ADR's atomicity rule not yet honored by some
            // future writer) or genuinely corrupt JSON both land here. Either
            // way this is a real failure to surface, not an empty selection.
            return ToolText(
                "get_selection: selection.json is malformed (a torn/partial write, or invalid "
                    + "JSON): \(error.localizedDescription). Not treating this as \"nothing selected\".",
                isError: true
            )
        }

        let host = readHostInfo(outputDir: outputDir)

        var resolved: [ResolvedSelection] = []
        resolved.reserveCapacity(sidecar.selections.count)
        for entry in sidecar.selections {
            resolved.append(await resolveSelection(entry: entry, store: store, registry: registry))
        }

        return IntrospectionTools.encode(
            GetSelectionResult(
                state: "hostRunning", selections: resolved,
                revision: sidecar.revision, updatedAt: sidecar.updatedAt, host: host
            ))
    }

    static func readHostInfo(outputDir: String) -> HostInfo? {
        let path = "\(outputDir)/host.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder().decode(HostInfo.self, from: data)
    }

    /// Resolve one `selection.json` entry against THIS server's own scene,
    /// the same way `select_topology` resolves a match: enumerate the
    /// body's faces/edges/vertices in the same order `select_topology` does,
    /// index into that enumeration, then convert to a `BRepGraph` node index
    /// via `SelectionTools.graphIndex(...)` before minting the
    /// `SelectionRegistry` entry, so the resulting `selectionId` composes
    /// with `remap_selection`/`measure_distance`/etc. exactly like one
    /// `select_topology` minted itself.
    static func resolveSelection(
        entry: SelectionJSONEntry,
        store: ManifestStore,
        registry: SelectionRegistry
    ) async -> ResolvedSelection {
        func failure(_ message: String) -> ResolvedSelection {
            ResolvedSelection(
                selectionId: nil, bodyId: entry.bodyId, kind: entry.kind, index: entry.index,
                uid: entry.uid, anchor: nil, error: message)
        }

        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: entry.bodyId, store: store)
        } catch {
            return failure("\(error)")
        }

        let lineage: (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool)
        do {
            lineage = try await HistoryRegistry.shared.currentInput(
                bodyId: entry.bodyId, path: loaded.path)
        } catch {
            return failure("\(error)")
        }
        let shape = lineage.shape
        let graph = lineage.graph

        switch entry.kind {
        case "body":
            guard let bb = shape.bounds else {
                return failure("no bounding box for body \(entry.bodyId)")
            }
            let center = [
                (bb.min.x + bb.max.x) * 0.5,
                (bb.min.y + bb.max.y) * 0.5,
                (bb.min.z + bb.max.z) * 0.5,
            ]
            let anchor = TopologyAnchor.body(bodyId: entry.bodyId)
            let snapshot = AnchorSnapshot(center: center)
            await registry.record(anchor: anchor, snapshot: snapshot)
            return ResolvedSelection(
                selectionId: anchor.selectionId, bodyId: entry.bodyId, kind: entry.kind,
                index: entry.index, uid: entry.uid, anchor: snapshot, error: nil)

        case "face":
            let faces = shape.faces()
            guard entry.index >= 0, entry.index < faces.count else {
                return failure(
                    "face index \(entry.index) out of range (\(faces.count) faces on \(entry.bodyId))"
                )
            }
            let face = faces[entry.index]
            let (center, normal) = SelectionTools.faceCenterAndNormal(face: face)
            let area = face.area()
            let surfaceType = String(describing: face.surfaceType)
            let graphIdx = SelectionTools.graphIndex(
                for: Shape.fromFace(face), kind: .face, in: graph, fallback: entry.index)
            let uid = graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: graphIdx)
            let anchor = TopologyAnchor.face(bodyId: entry.bodyId, index: graphIdx, uid: uid)
            let snapshot = AnchorSnapshot(
                center: [center.x, center.y, center.z],
                normal: normal.map { [$0.x, $0.y, $0.z] },
                area: area,
                surfaceType: surfaceType
            )
            await registry.record(anchor: anchor, snapshot: snapshot)
            return ResolvedSelection(
                selectionId: anchor.selectionId, bodyId: entry.bodyId, kind: entry.kind,
                index: entry.index, uid: entry.uid, anchor: snapshot, error: nil)

        case "edge":
            let edges = shape.edges()
            guard entry.index >= 0, entry.index < edges.count else {
                return failure(
                    "edge index \(entry.index) out of range (\(edges.count) edges on \(entry.bodyId))"
                )
            }
            let edge = edges[entry.index]
            let length = SelectionTools.edgeLength(edge: edge)
            let curveType = String(describing: edge.curveType)
            let center = SelectionTools.edgeMidpoint(edge: edge)
            let geom = SelectionTools.edgeGeometryFields(edge: edge)
            let graphIdx = SelectionTools.graphIndex(
                for: Shape.fromEdge(edge), kind: .edge, in: graph, fallback: entry.index)
            let uid = graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.edge.rawValue), index: graphIdx)
            let anchor = TopologyAnchor.edge(bodyId: entry.bodyId, index: graphIdx, uid: uid)
            let snapshot = AnchorSnapshot(
                center: center.map { [$0.x, $0.y, $0.z] } ?? [0, 0, 0],
                length: length,
                curveType: curveType,
                circleCenter: geom.circleCenter,
                endpoints: geom.endpoints,
                direction: geom.direction,
                radius: geom.radius,
                axis: geom.axis,
                startAngle: geom.startAngle,
                endAngle: geom.endAngle
            )
            await registry.record(anchor: anchor, snapshot: snapshot)
            return ResolvedSelection(
                selectionId: anchor.selectionId, bodyId: entry.bodyId, kind: entry.kind,
                index: entry.index, uid: entry.uid, anchor: snapshot, error: nil)

        case "vertex":
            let vertices = shape.subShapes(ofType: .vertex)
            guard entry.index >= 0, entry.index < vertices.count else {
                return failure(
                    "vertex index \(entry.index) out of range (\(vertices.count) vertices on \(entry.bodyId))"
                )
            }
            let vertexShape = vertices[entry.index]
            guard let point = SelectionTools.vertexPoint(vertexShape) else {
                return failure(
                    "could not resolve vertex position for \(entry.bodyId)#vertex[\(entry.index)]")
            }
            let graphIdx = SelectionTools.graphIndex(
                for: vertexShape, kind: .vertex, in: graph, fallback: entry.index)
            let uid = graph.uid(
                ofNodeKind: Int(BRepGraph.NodeKind.vertex.rawValue), index: graphIdx)
            let anchor = TopologyAnchor.vertex(bodyId: entry.bodyId, index: graphIdx, uid: uid)
            let snapshot = AnchorSnapshot(center: [point.x, point.y, point.z])
            await registry.record(anchor: anchor, snapshot: snapshot)
            return ResolvedSelection(
                selectionId: anchor.selectionId, bodyId: entry.bodyId, kind: entry.kind,
                index: entry.index, uid: entry.uid, anchor: snapshot, error: nil)

        default:
            return failure(
                "unknown kind '\(entry.kind)'. Expected one of: body, face, edge, vertex.")
        }
    }

    // MARK: - highlight_selection

    static let validKinds = ["body", "face", "edge", "vertex"]
    static let validSchemes = ["replace", "add", "remove", "xor"]
    public static let defaultTimeoutSeconds: Double = 5.0
    public static let defaultPollIntervalSeconds: Double = 0.1

    public struct HighlightSelectionResult: Encodable {
        /// nil only for the `noHost` outcome: no request was written, so
        /// there is no id to report.
        public let id: String?
        /// "applied" | "rejected" | "superseded" (from the host's handled/
        /// file) | "timeout" (no handled/ file within the deadline) |
        /// "noHost" (no viewport host is running at all) | "error" (a
        /// handled/ file exists but did not decode) | "cancelled" (the
        /// request was cancelled while waiting for a response).
        public let outcome: String
        public let reason: String?
    }

    /// Write a `highlight_requests/<id>.json` request and poll
    /// `highlight_requests/handled/<id>.json` for the real outcome.
    ///
    /// `bodyId`/`kind`/`index` are written through UNVALIDATED against this
    /// server's own scene (per #190's own scope: this tool has no other
    /// access to the live viewport's scene to validate against, so a bad
    /// reference is still written and comes back as the host's own
    /// `rejected` outcome through the same poll, not a client-side
    /// pre-check). `kind`/`scheme` ARE validated against the wire format's
    /// own closed enums before writing anything, since those aren't a scene
    /// fact to defer, they're the request's own shape.
    ///
    /// The id is generated
    /// here (never supplied by the caller), so a caller never needs to
    /// invent or coordinate its own id across concurrent highlight calls;
    /// combined with the atomic (temp name + rename) write, a single call's
    /// own request write can never land torn or collide with another call's.
    public static func highlightSelection(
        bodyId: String,
        kind: String,
        index: Int,
        scheme: String,
        question: String? = nil,
        store: ManifestStore = ManifestStore(),
        timeoutSeconds: Double = defaultTimeoutSeconds,
        pollIntervalSeconds: Double = defaultPollIntervalSeconds
    ) async -> ToolText {
        guard validKinds.contains(kind) else {
            return ToolText(
                "highlight_selection: unknown kind '\(kind)'. Expected one of: "
                    + validKinds.joined(separator: ", ") + ".",
                isError: true
            )
        }
        guard validSchemes.contains(scheme) else {
            return ToolText(
                "highlight_selection: unknown scheme '\(scheme)'. Expected one of: "
                    + validSchemes.joined(separator: ", ") + ".",
                isError: true
            )
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent

        guard HostLock.checkLiveness(outputDir: outputDir) == .hostRunning else {
            // Fail fast rather than writing a request nothing will ever read
            // and hanging out the full poll timeout for no reason.
            return IntrospectionTools.encode(
                HighlightSelectionResult(
                    id: nil, outcome: "noHost",
                    reason:
                        "No host.lock is held at \(outputDir)/host.lock: no viewport host is running to consume highlight_requests/."
                ))
        }

        let id = UUID().uuidString
        let request = HighlightRequest(
            id: id, bodyId: bodyId, kind: kind, index: index, scheme: scheme, question: question)

        let requestsDir = "\(outputDir)/highlight_requests"
        let handledDir = "\(requestsDir)/handled"
        do {
            try FileManager.default.createDirectory(
                atPath: requestsDir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(request)
            try data.write(to: URL(fileURLWithPath: "\(requestsDir)/\(id).json"), options: .atomic)
        } catch {
            return ToolText(
                "highlight_selection: failed to write request: \(error.localizedDescription)",
                isError: true
            )
        }

        let handledPath = "\(handledDir)/\(id).json"
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            switch pollHandledOutcome(path: handledPath) {
            case .decoded(let outcome):
                return IntrospectionTools.encode(
                    HighlightSelectionResult(
                        id: id, outcome: outcome.outcome, reason: outcome.reason)
                )
            case .malformed(let reason):
                // The host DID respond, just not readably: report that
                // immediately rather than waiting out the rest of the
                // timeout for a response that has already arrived.
                return IntrospectionTools.encode(
                    HighlightSelectionResult(
                        id: id, outcome: "error",
                        reason:
                            "highlight_requests/handled/\(id).json exists but did not decode: \(reason)"
                    ))
            case .pending:
                break
            }
            // `Task.sleep` throws `CancellationError` when the ambient task
            // is cancelled (e.g. the MCP client disconnected); `try?`
            // swallows that so cancellation doesn't propagate as an error,
            // but `Task.isCancelled` still reports it, so check explicitly
            // rather than sleeping out the rest of the deadline for a caller
            // that has already gone away.
            try? await Task.sleep(
                nanoseconds: UInt64(max(pollIntervalSeconds, 0.001) * 1_000_000_000))
            if Task.isCancelled {
                return IntrospectionTools.encode(
                    HighlightSelectionResult(
                        id: id, outcome: "cancelled",
                        reason: "The request was cancelled before a response arrived."
                    ))
            }
        }

        return IntrospectionTools.encode(
            HighlightSelectionResult(
                id: id, outcome: "timeout",
                reason:
                    "No response written to highlight_requests/handled/\(id).json within \(timeoutSeconds)s."
            ))
    }

    /// One poll of `highlight_requests/handled/<id>.json`.
    ///
    /// Distinguishes "nothing there yet" (`.pending`, keep polling) from "the
    /// host wrote something that doesn't decode" (`.malformed`, worth
    /// surfacing immediately): the ADR's atomic-write rule (temp name, then
    /// `rename(2)`) means a fully-renamed file should always read cleanly, so
    /// a decode failure here is a genuine anomaly (a host bug, or a
    /// filesystem where rename isn't truly atomic), not a timing window.
    /// Reporting it as `.pending` and waiting out the whole timeout would
    /// hide that the host DID respond, just not readably.
    enum HandledPoll {
        case pending
        case decoded(HandledOutcome)
        case malformed(String)
    }

    static func pollHandledOutcome(path: String) -> HandledPoll {
        guard FileManager.default.fileExists(atPath: path) else {
            return .pending
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // A transient read failure (e.g. racing a rename that hasn't
            // landed yet on some filesystem) is treated the same as "not
            // there yet", not as malformed: the file existing but being
            // unreadable for a moment is a timing window, not evidence the
            // host wrote bad content.
            return .pending
        }
        do {
            return .decoded(try JSONDecoder().decode(HandledOutcome.self, from: data))
        } catch {
            return .malformed(error.localizedDescription)
        }
    }
}
