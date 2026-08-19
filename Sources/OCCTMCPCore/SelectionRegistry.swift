// SelectionRegistry: server-side store of named topology picks. The
// LLM gets back a stable selectionId from `select_topology`, then refers
// to it from `remap_selection`, `add_dimension`, and any future tool
// that wants to anchor to a sub-shape.
//
// selectionId format: `sel:<bodyId>#<kind>[<index>]`. Self-describing
// and parseable, so consumers can inspect a selection without
// dereferencing the registry, but the registry caches the resolved
// anchor metadata (centroid, normal, area / length) so subsequent
// calls don't have to re-load the BREP.
//
// #182 (phase 5 of the fleet-wide picking consolidation, ecosystem#43):
// re-keyed on BRepGraph.GraphUID rather than a parallel `graphUIDs` side
// table. Before this, the registry held THREE dictionaries all keyed by
// the same selectionId string (`anchors`, `snapshots`, `graphUIDs`), and
// nothing enforced that `graphUIDs`'s keys stayed a subset of `anchors`'s:
// several call sites minted a GraphUID via a separate `recordGraphUID`
// call that could run even when the paired `record(anchor:snapshot:)`
// never had (see SelectionRegistryTests' now-superseded
// `countAndClearIncludeGraphUIDOnlyEntries`, and the `refreshAfterHistoryRemap`
// / `CorrespondenceTools.mintUID` write-up in git history for the two real
// call sites that could produce that orphan). `uid` is now a field ON
// `TopologyAnchor` itself (`.face`/`.edge`/`.vertex` carry an optional
// `BRepGraph.GraphUID`), written in the SAME `record` call as the anchor
// and snapshot, so an orphan uid with no backing anchor is no longer
// representable through this actor's public API at all, not just
// defended against after the fact.
//
// This mirrors (without literally adopting) OCCTSwiftInteraction's new
// `SubShapeRef`, which bundles `shape`/`uid`/`ordinal` into one durable
// handle rather than three parallel stores. OCCTMCP does NOT adopt
// `SubShapeRef`/`SubShape`/`InteractiveObject` directly (see the PR body
// for #182 for the full reasoning): `SubShapeRef.shape` is a live OCCT
// `Shape` handle, and this actor already deliberately avoids holding
// native OCCT handles in long-lived state (`AnchorSnapshot` exists
// specifically to pre-extract plain `[Double]` values instead); `SubShape`
// is built around `InteractiveObject` (a live-viewport `UUID` + `Shape`
// pairing for an `OCCTSwiftAIS.InteractiveContext`), and OCCTMCP has no
// persistent `InteractiveContext` and identifies bodies by a stable
// `bodyId: String` read from the JSON manifest across process restarts,
// not a `UUID`. The (bodyId, kind, index, uid) shape is what's adopted;
// the concrete types stay MCP-owned.

import Foundation
import OCCTSwift

/// A named pick into the topology of a scene body.
///
/// Mirrors the shape of the AIS `SubShape` enum (and, post-#182, of
/// `OCCTSwiftTools.SubShapeRef`'s `(shape, uid, ordinal)` bundling) but
/// keyed by `bodyId` so it survives without an `InteractiveContext`, and
/// carries a `BRepGraph.GraphUID` directly rather than a native `Shape`
/// handle (see the file-level doc comment for why).
public enum TopologyAnchor: Sendable, Hashable {
    case body(bodyId: String)
    /// `uid`: the BRepGraph-durable identity minted for this anchor, when
    /// it was resolved against a HistoryRegistry-retained lineage graph.
    /// nil when no graph was in scope, or the anchor came from a
    /// disposable (non-retained) graph a uid would never resolve against
    /// again (see `RemapTools`' rung-3 centroid fallback, which
    /// deliberately never attaches one). Defaults to nil so every existing
    /// construction call site that only cares about `bodyId`/`index`
    /// keeps compiling unchanged.
    case face(bodyId: String, index: Int, uid: BRepGraph.GraphUID? = nil)
    case edge(bodyId: String, index: Int, uid: BRepGraph.GraphUID? = nil)
    case vertex(bodyId: String, index: Int, uid: BRepGraph.GraphUID? = nil)

    public var bodyId: String {
        switch self {
        case .body(let id): return id
        case .face(let id, _, _): return id
        case .edge(let id, _, _): return id
        case .vertex(let id, _, _): return id
        }
    }

    public var kind: String {
        switch self {
        case .body: return "body"
        case .face: return "face"
        case .edge: return "edge"
        case .vertex: return "vertex"
        }
    }

    public var index: Int? {
        switch self {
        case .body: return nil
        case .face(_, let idx, _): return idx
        case .edge(_, let idx, _): return idx
        case .vertex(_, let idx, _): return idx
        }
    }

    /// This anchor's `BRepGraph.NodeKind`.
    ///
    /// nil for `.body` (never a graph node). Pairs with `index` to address
    /// a graph node, and with `uid` below to check/attach its durable
    /// identity.
    public var nodeKind: BRepGraph.NodeKind? {
        switch self {
        case .body: return nil
        case .face: return .face
        case .edge: return .edge
        case .vertex: return .vertex
        }
    }

    /// The GraphUID carried by this anchor (#182). nil for `.body`, and
    /// for any face/edge/vertex anchor minted with no uid available.
    public var uid: BRepGraph.GraphUID? {
        switch self {
        case .body: return nil
        case .face(_, _, let uid): return uid
        case .edge(_, _, let uid): return uid
        case .vertex(_, _, let uid): return uid
        }
    }

    /// A copy of this anchor with `uid` attached (or cleared, if nil).
    ///
    /// A no-op for `.body`. Lets a caller resolve the anchor's index first
    /// (e.g. via `SelectionTools.graphIndex`), then attach whatever uid
    /// that index resolves to in one step before the single `record` call,
    /// rather than writing the anchor and its uid to the registry
    /// separately.
    public func withUID(_ uid: BRepGraph.GraphUID?) -> TopologyAnchor {
        switch self {
        case .body: return self
        case .face(let id, let idx, _): return .face(bodyId: id, index: idx, uid: uid)
        case .edge(let id, let idx, _): return .edge(bodyId: id, index: idx, uid: uid)
        case .vertex(let id, let idx, _): return .vertex(bodyId: id, index: idx, uid: uid)
        }
    }

    /// Self-describing selectionId: `sel:<bodyId>#<kind>[<index>]` for
    /// face/edge/vertex; `sel:<bodyId>#body` for whole-body picks.
    ///
    /// `uid` never appears in the wire format: it's an opaque,
    /// instance-scoped handle (see `BRepGraph.GraphUID`'s own persistence
    /// caveat), not something a caller could usefully pass back in.
    public var selectionId: String {
        switch self {
        case .body(let id):
            return "sel:\(id)#body"
        case .face(let id, let idx, _):
            return "sel:\(id)#face[\(idx)]"
        case .edge(let id, let idx, _):
            return "sel:\(id)#edge[\(idx)]"
        case .vertex(let id, let idx, _):
            return "sel:\(id)#vertex[\(idx)]"
        }
    }

    /// Parse a selectionId back into an anchor.
    ///
    /// Returns nil if the string doesn't match the documented format.
    /// Always produces `uid: nil`: the wire format carries no uid
    /// component (see `selectionId` above), so a parsed anchor's identity
    /// is index-only until something re-attaches a uid via `withUID`.
    public static func parse(_ selectionId: String) -> TopologyAnchor? {
        guard selectionId.hasPrefix("sel:") else { return nil }
        let body = selectionId.dropFirst(4)
        guard let hashIdx = body.firstIndex(of: "#") else { return nil }
        let bodyId = String(body[..<hashIdx])
        let rest = body[body.index(after: hashIdx)...]
        if rest == "body" { return .body(bodyId: bodyId) }
        // rest is `face[3]` / `edge[7]` / `vertex[2]`
        guard let openBracket = rest.firstIndex(of: "["),
            rest.last == "]"
        else { return nil }
        let kindStr = String(rest[..<openBracket])
        let inside = rest[rest.index(after: openBracket)..<rest.index(before: rest.endIndex)]
        guard let idx = Int(inside) else { return nil }
        switch kindStr {
        case "face": return .face(bodyId: bodyId, index: idx)
        case "edge": return .edge(bodyId: bodyId, index: idx)
        case "vertex": return .vertex(bodyId: bodyId, index: idx)
        default: return nil
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
    /// Geometric centre of a circular edge, the centre of curvature,
    /// distinct from `center` (which holds the parameter-midpoint *rim*
    /// point for edges).
    ///
    /// Lets `add_dimension(radial)` compute an exact
    /// radius from geometry and lets `AnnotationsRenderer.dimension`
    /// draw a leader from circleCenter to the rim. nil for non-edges and
    /// non-circular edges.
    public var circleCenter: [Double]?
    /// Edge start and end points (`[start, end]`, world coordinates), in the
    /// edge's own topological orientation.
    ///
    /// Populated for every edge kind,
    /// not just lines: a colinearity / endpoint-error check against a source
    /// mesh needs the two endpoints regardless of curve type (#119). nil for
    /// faces/vertices.
    public var endpoints: [[Double]]?
    /// Unit tangent direction.
    ///
    /// Populated for LINE edges only, where a single
    /// direction fully describes the edge as a vector in space (#119); a
    /// curved edge's tangent varies along its length and has no single
    /// "direction" to report here. nil for faces/vertices/non-line edges.
    public var direction: [Double]?
    /// Circle radius (mm).
    ///
    /// Populated for circular edges only, alongside
    /// `circleCenter` (#119). nil otherwise.
    public var radius: Double?
    /// Unit normal of the circle's plane (its rotation axis).
    ///
    /// Populated for
    /// circular edges only (#119). nil otherwise.
    public var axis: [Double]?
    /// Start/end parameter of the edge's curve, in radians, measured from the
    /// circle's own xAxis direction (OCCT's Geom_Circle parametrization:
    /// point(u) = center + radius * (cos(u) * xDir + sin(u) * yDir), so u IS
    /// the angle).
    ///
    /// Populated for circular edges only (#119). nil otherwise.
    public var startAngle: Double?
    public var endAngle: Double?
    public init(
        center: [Double],
        normal: [Double]? = nil,
        area: Double? = nil,
        length: Double? = nil,
        surfaceType: String? = nil,
        curveType: String? = nil,
        circleCenter: [Double]? = nil,
        endpoints: [[Double]]? = nil,
        direction: [Double]? = nil,
        radius: Double? = nil,
        axis: [Double]? = nil,
        startAngle: Double? = nil,
        endAngle: Double? = nil
    ) {
        self.center = center
        self.normal = normal
        self.area = area
        self.length = length
        self.surfaceType = surfaceType
        self.curveType = curveType
        self.circleCenter = circleCenter
        self.endpoints = endpoints
        self.direction = direction
        self.radius = radius
        self.axis = axis
        self.startAngle = startAngle
        self.endAngle = endAngle
    }
}

/// Single source of truth for selection metadata across an MCP session.
public actor SelectionRegistry {
    public static let shared = SelectionRegistry()

    private var snapshots: [String: AnchorSnapshot] = [:]
    /// selectionId → the recorded anchor, `uid` (#182) included: there is
    /// no separate GraphUID table any more. A `TopologyAnchor`'s uid is
    /// just one more field on the same value already keyed by
    /// `selectionId`, written by the same `record` call as everything
    /// else about that selection.
    private var anchors: [String: TopologyAnchor] = [:]

    public init() {}

    /// Record a fresh selection.
    ///
    /// Re-recording the same selectionId overwrites the cached snapshot
    /// (and anchor, uid included), useful when remapping. Callers that
    /// have a `BRepGraph.GraphUID` for this anchor should attach it via
    /// `anchor.withUID(uid)` before calling this, rather than recording
    /// the uid separately: `uid` MUST be minted from a
    /// HistoryRegistry-retained lineage graph, never a disposable one,
    /// since a uid only ever resolves against the graph instance that
    /// minted it.
    public func record(anchor: TopologyAnchor, snapshot: AnchorSnapshot) {
        let id = anchor.selectionId
        anchors[id] = anchor
        snapshots[id] = snapshot
    }

    /// Record a snapshot under an arbitrary selectionId that isn't a
    /// topology sub-shape, e.g. a `pick:<bodyId>#N` surface point from
    /// `pick_surface_point`.
    ///
    /// There's no `TopologyAnchor` for a free point,
    /// so only the snapshot is stored; `add_dimension` resolves anchors via
    /// `snapshot(for:)`, so the picked point composes as a dimension anchor.
    public func recordPointSnapshot(selectionId: String, snapshot: AnchorSnapshot) {
        snapshots[selectionId] = snapshot
    }

    public func anchor(for selectionId: String) -> TopologyAnchor? {
        if let cached = anchors[selectionId] { return cached }
        // Fall back to parsing: selectionId is self-describing so a
        // cache miss doesn't mean "unknown", it means "registry was
        // cold for this id". A parsed anchor's uid is always nil (#182:
        // the wire format carries no uid component), which is the
        // correct answer here too: a cache miss means this actor never
        // minted or saw a uid for it either.
        return TopologyAnchor.parse(selectionId)
    }

    public func snapshot(for selectionId: String) -> AnchorSnapshot? {
        return snapshots[selectionId]
    }

    /// The GraphUID recorded for a selectionId, if any (#182).
    ///
    /// Reads straight off the stored `TopologyAnchor`: there is no
    /// separate side-table to fall out of sync with `anchors` any more,
    /// so this can never report a uid for a selectionId `anchors` itself
    /// has no entry for (the exact gap the pre-#182 `graphUIDs` table
    /// could open, since it was written to independently of `anchors`).
    public func graphUID(for selectionId: String) -> BRepGraph.GraphUID? {
        return anchors[selectionId]?.uid
    }

    /// Total distinct registry entries: anchor-based selections (from
    /// `select_topology` et al.) plus point-snapshot-only picks (from
    /// `pick_surface_point`), which have no `TopologyAnchor`.
    ///
    /// Union of `anchors.keys` and `snapshots.keys` (#150), not
    /// `anchors.count` alone: `recordPointSnapshot` only ever populates
    /// `snapshots`, so an anchors-only count would silently under-report
    /// every point pick `clear()` actually discards. Post-#182 there is no
    /// third `graphUIDs.keys` term to union in any more: a uid is a field
    /// on the stored `TopologyAnchor`, not a separate dictionary entry, so
    /// it cannot exist without (or diverge from) an `anchors` entry the
    /// way the old side-table could. Shared by `count()` and `clear()` so
    /// the two can never drift apart.
    private var totalEntryCount: Int {
        Set(anchors.keys).union(snapshots.keys).count
    }

    /// Drop every selection.
    ///
    /// Returns the count cleared, atomically with the
    /// clear itself (mirrors `ZoneRegistry.clear`): a caller that needs to
    /// report how many were removed must read the count in the SAME actor
    /// call as the mutation, since a separate `count()` call beforehand can
    /// race against another task recording or clearing on this actor between
    /// the two awaits.
    @discardableResult
    public func clear() -> Int {
        let cleared = totalEntryCount
        snapshots.removeAll()
        anchors.removeAll()
        return cleared
    }

    public func count() -> Int {
        return totalEntryCount
    }

    /// Snapshot of the registry: used by `list_selections` to surface
    /// active picks back to the LLM.
    ///
    /// Sorted by selectionId for stable
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
