// SelectionRegistry — server-side store of named topology picks. The
// LLM gets back a stable selectionId from `select_topology`, then refers
// to it from `remap_selection`, `add_dimension`, and any future tool
// that wants to anchor to a sub-shape.
//
// selectionId format: `sel:<bodyId>#<kind>[<index>]`. Self-describing
// and parseable, so consumers can inspect a selection without
// dereferencing the registry — but the registry caches the resolved
// anchor metadata (centroid, normal, area / length) so subsequent
// calls don't have to re-load the BREP.

import Foundation

/// A named pick into the topology of a scene body. Mirrors the AIS
/// `SubShape` enum but keyed by `bodyId` so it survives without an
/// `InteractiveContext`.
public enum TopologyAnchor: Sendable, Hashable {
    case body(bodyId: String)
    case face(bodyId: String, index: Int)
    case edge(bodyId: String, index: Int)
    case vertex(bodyId: String, index: Int)

    public var bodyId: String {
        switch self {
        case .body(let id):           return id
        case .face(let id, _):        return id
        case .edge(let id, _):        return id
        case .vertex(let id, _):      return id
        }
    }

    public var kind: String {
        switch self {
        case .body:    return "body"
        case .face:    return "face"
        case .edge:    return "edge"
        case .vertex:  return "vertex"
        }
    }

    public var index: Int? {
        switch self {
        case .body:                   return nil
        case .face(_, let idx):       return idx
        case .edge(_, let idx):       return idx
        case .vertex(_, let idx):     return idx
        }
    }

    /// Self-describing selectionId: `sel:<bodyId>#<kind>[<index>]` for
    /// face/edge/vertex; `sel:<bodyId>#body` for whole-body picks.
    public var selectionId: String {
        switch self {
        case .body(let id):
            return "sel:\(id)#body"
        case .face(let id, let idx):
            return "sel:\(id)#face[\(idx)]"
        case .edge(let id, let idx):
            return "sel:\(id)#edge[\(idx)]"
        case .vertex(let id, let idx):
            return "sel:\(id)#vertex[\(idx)]"
        }
    }

    /// Parse a selectionId back into an anchor. Returns nil if the
    /// string doesn't match the documented format.
    public static func parse(_ selectionId: String) -> TopologyAnchor? {
        guard selectionId.hasPrefix("sel:") else { return nil }
        let body = selectionId.dropFirst(4)
        guard let hashIdx = body.firstIndex(of: "#") else { return nil }
        let bodyId = String(body[..<hashIdx])
        let rest = body[body.index(after: hashIdx)...]
        if rest == "body" { return .body(bodyId: bodyId) }
        // rest is `face[3]` / `edge[7]` / `vertex[2]`
        guard let openBracket = rest.firstIndex(of: "["),
              rest.last == "]" else { return nil }
        let kindStr = String(rest[..<openBracket])
        let inside = rest[rest.index(after: openBracket)..<rest.index(before: rest.endIndex)]
        guard let idx = Int(inside) else { return nil }
        switch kindStr {
        case "face":    return .face(bodyId: bodyId, index: idx)
        case "edge":    return .edge(bodyId: bodyId, index: idx)
        case "vertex":  return .vertex(bodyId: bodyId, index: idx)
        default:        return nil
        }
    }
}

/// Anchor metadata captured at selection time. Used by `add_dimension`
/// (so it doesn't need to re-load the BREP), by `remap_selection`'s
/// position-matching fallback, and surfaced back to the LLM as a
/// readable description of what was picked.
public struct AnchorSnapshot: Sendable, Codable {
    /// Centroid for faces, midpoint for edges, position for vertices.
    public var center: [Double]
    /// Normal at face midpoint UV. nil for edges/vertices.
    public var normal: [Double]?
    /// Face area (mm^2). nil for edges/vertices.
    public var area: Double?
    /// Edge length (mm). nil for faces/vertices.
    public var length: Double?
    /// Face surface type (plane / cylinder / ...). nil for edges/vertices.
    public var surfaceType: String?
    /// Edge curve type (line / circle / ...). nil for faces/vertices.
    public var curveType: String?
    /// Geometric centre of a circular edge — the centre of curvature,
    /// distinct from `center` (which holds the parameter-midpoint *rim*
    /// point for edges). Lets `add_dimension(radial)` compute an exact
    /// radius from geometry and lets `AnnotationsRenderer.dimension`
    /// draw a leader from circleCenter → rim. nil for non-edges and
    /// non-circular edges.
    public var circleCenter: [Double]?
    public init(
        center: [Double],
        normal: [Double]? = nil,
        area: Double? = nil,
        length: Double? = nil,
        surfaceType: String? = nil,
        curveType: String? = nil,
        circleCenter: [Double]? = nil
    ) {
        self.center = center
        self.normal = normal
        self.area = area
        self.length = length
        self.surfaceType = surfaceType
        self.curveType = curveType
        self.circleCenter = circleCenter
    }
}

/// Single source of truth for selection metadata across an MCP session.
public actor SelectionRegistry {
    public static let shared = SelectionRegistry()

    private var snapshots: [String: AnchorSnapshot] = [:]
    private var anchors: [String: TopologyAnchor] = [:]

    public init() {}

    /// Record a fresh selection. Re-recording the same selectionId
    /// overwrites the cached snapshot — useful when remapping.
    public func record(anchor: TopologyAnchor, snapshot: AnchorSnapshot) {
        let id = anchor.selectionId
        anchors[id] = anchor
        snapshots[id] = snapshot
    }

    /// Record a snapshot under an arbitrary selectionId that isn't a
    /// topology sub-shape — e.g. a `pick:<bodyId>#N` surface point from
    /// `pick_surface_point`. There's no `TopologyAnchor` for a free point,
    /// so only the snapshot is stored; `add_dimension` resolves anchors via
    /// `snapshot(for:)`, so the picked point composes as a dimension anchor.
    public func recordPointSnapshot(selectionId: String, snapshot: AnchorSnapshot) {
        snapshots[selectionId] = snapshot
    }

    public func anchor(for selectionId: String) -> TopologyAnchor? {
        if let cached = anchors[selectionId] { return cached }
        // Fall back to parsing — selectionId is self-describing so a
        // cache miss doesn't mean "unknown", it means "registry was
        // cold for this id".
        return TopologyAnchor.parse(selectionId)
    }

    public func snapshot(for selectionId: String) -> AnchorSnapshot? {
        return snapshots[selectionId]
    }

    public func clear() {
        snapshots.removeAll()
        anchors.removeAll()
    }

    public func count() -> Int {
        return anchors.count
    }

    /// Snapshot of the registry — used by `list_selections` to surface
    /// active picks back to the LLM. Sorted by selectionId for stable
    /// output across runs.
    public func listEntries() -> [Entry] {
        return anchors.keys.sorted().map { id in
            Entry(
                selectionId: id,
                bodyId: anchors[id]?.bodyId ?? "",
                kind: anchors[id]?.kind ?? "unknown",
                snapshot: snapshots[id]
            )
        }
    }

    public struct Entry: Sendable, Codable {
        public let selectionId: String
        public let bodyId: String
        public let kind: String
        public let snapshot: AnchorSnapshot?
    }
}
