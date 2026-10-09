// IntrospectionTools: pure-read tools backed by direct OCCTSwift calls
// (no occtkit subprocess). Phase 5.3a covers compute_metrics,
// query_topology, measure_distance. Each resolves a bodyId against the
// scene manifest, loads the body's BREP via Shape.loadBREP(fromPath:),
// and runs the OCCT query in-process.

import Foundation
import OCCTSwift
import ScriptHarness

public enum IntrospectionTools {

    // ── shared body resolver ────────────────────────────────────────────

    static func loadShape(
        bodyId: String,
        store: ManifestStore
    ) throws -> (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String) {
        guard let manifest = try store.read() else {
            throw ToolError.noScene
        }
        guard let body = manifest.body(withId: bodyId) else {
            throw ToolError.bodyNotFound(bodyId)
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let path = "\(outputDir)/\(body.file)"
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.brepMissing(path)
        }
        let shape = try Shape.loadBREP(fromPath: path)
        return (manifest, body, shape, path)
    }

    public enum ToolError: Error, CustomStringConvertible {
        case noScene
        case bodyNotFound(String)
        case brepMissing(String)

        public var description: String {
            switch self {
            case .noScene:
                return "No scene loaded. Run execute_script first."
            case .bodyNotFound(let id):
                return "Body not found: \(id)"
            case .brepMissing(let path):
                return "BREP file missing: \(path)"
            }
        }
    }

    // ── compute_metrics ────────────────────────────────────────────────

    public struct MetricsReport: Encodable {
        public var volume: Double?
        public var surfaceArea: Double?
        public var centerOfMass: [Double]?
        public var boundingBox: BBox?
        public var boundingBoxOptimal: BBox?
        public var principalAxes: PrincipalAxes?

        public struct BBox: Encodable {
            public let min: [Double]
            public let max: [Double]
        }
        public struct PrincipalAxes: Encodable {
            public let axes: [[Double]]
            public let moments: [Double]
        }
    }

    public static func computeMetrics(
        bodyId: String,
        metrics: Set<String>? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        func wants(_ name: String) -> Bool {
            return metrics == nil || metrics!.contains(name)
        }

        var report = MetricsReport()
        let inertia =
            (wants("volume") || wants("centerOfMass") || wants("principalAxes"))
            ? shape.volumeInertia : nil

        if wants("volume") { report.volume = inertia?.volume }
        if wants("surfaceArea") { report.surfaceArea = shape.surfaceArea }
        if wants("centerOfMass"), let i = inertia {
            report.centerOfMass = [i.centerOfMass.x, i.centerOfMass.y, i.centerOfMass.z]
        }
        // A body with no bounding box at all leaves `boundingBox` absent rather
        // than reporting a zero-sized box at the origin (OCCTSwift #943), the
        // same shape the `boundingBoxOptimal` branch below already had.
        if wants("boundingBox"), let b = shape.bounds {
            // Default Bnd_Box: for B-spline / curved faces this is the
            // control-point hull and over-reports the true extent
            // (OCCTSwift #232 / #213). Use boundingBoxOptimal for a tight box.
            report.boundingBox = .init(
                min: [b.min.x, b.min.y, b.min.z],
                max: [b.max.x, b.max.y, b.max.z]
            )
        }
        // Opt-in only (not part of default-all): AddOptimal is costlier than
        // the Bnd_Box, and most callers want the cheap footprint.
        if metrics?.contains("boundingBoxOptimal") == true, let o = shape.boundingBoxOptimal() {
            // BRepBndLib::AddOptimal, tight extent that matches the exact
            // surface (and the mesh) for curved geometry; equal to the
            // Bnd_Box for planar bodies. Needed for extent-vs-mesh
            // reconstruction verification (#44).
            report.boundingBoxOptimal = .init(
                min: [o.min.x, o.min.y, o.min.z],
                max: [o.max.x, o.max.y, o.max.z]
            )
        }
        if wants("principalAxes"), let i = inertia {
            report.principalAxes = .init(
                axes: [
                    [i.principalAxes.0.x, i.principalAxes.0.y, i.principalAxes.0.z],
                    [i.principalAxes.1.x, i.principalAxes.1.y, i.principalAxes.1.z],
                    [i.principalAxes.2.x, i.principalAxes.2.y, i.principalAxes.2.z],
                ],
                moments: [i.principalMoments.x, i.principalMoments.y, i.principalMoments.z]
            )
        }
        return encode(report)
    }

    // ── query_topology ─────────────────────────────────────────────────

    public struct QueryReport: Encodable {
        public let entity: String
        public let results: [Result]
        public let total: Int
        public let truncated: Bool

        public struct Result: Encodable {
            public let id: String
            /// Enumeration index of the entity, the `N` in `id`.
            ///
            /// This is the position in `Shape.faces()/.edges()/.vertices()` order and the
            /// `index` `get_selection` returns for the same entity. It is NOT the index
            /// embedded in a `selectionId` (a BRepGraph node index, which only coincides
            /// for faces); use `select_topology` to mint one (#197).
            public let index: Int?
            public let surfaceType: String?
            public let curveType: String?
            public let area: Double?
            public let boundingBox: MetricsReport.BBox?
            /// Face point at the surface's UV midpoint (same point `select_topology`
            /// anchors use; may lie off a heavily trimmed face). nil for non-faces (#197).
            public let center: [Double]?
            /// Face normal at `center`. nil for non-faces or when it can't be evaluated (#197).
            public let normal: [Double]?
            /// Edge start/end points (`[start, end]`, world coordinates). nil
            /// for faces/vertices (#119).
            public let endpoints: [[Double]]?
            /// Unit tangent direction.
            ///
            /// Populated for LINE edges only (#119).
            public let direction: [Double]?
            /// Geometric centre of a circular edge (centre of curvature).
            ///
            /// Populated for circular edges only (#119).
            public let circleCenter: [Double]?
            public let radius: Double?
            public let axis: [Double]?
            public let startAngle: Double?
            public let endAngle: Double?
            /// Adjacent faces in `faces()` index order, capped at `neighborLimit` (#199).
            public let neighbors: [FaceAdjacency.Neighbour]?
            /// True neighbour count, before any `neighborLimit` cap (#199).
            public let neighborCount: Int?
            /// True when `neighbors` was cut short by `neighborLimit` (#199).
            public let neighborsTruncated: Bool?
            /// Nearest overlapping anti-parallel planar face behind this one (#199).
            public let oppositeFace: OppositeFaces.Hit?

            public init(
                id: String, index: Int? = nil, surfaceType: String? = nil, curveType: String? = nil,
                area: Double? = nil, boundingBox: MetricsReport.BBox? = nil,
                center: [Double]? = nil, normal: [Double]? = nil,
                endpoints: [[Double]]? = nil, direction: [Double]? = nil,
                circleCenter: [Double]? = nil, radius: Double? = nil, axis: [Double]? = nil,
                startAngle: Double? = nil, endAngle: Double? = nil,
                neighbors: [FaceAdjacency.Neighbour]? = nil, neighborCount: Int? = nil,
                neighborsTruncated: Bool? = nil, oppositeFace: OppositeFaces.Hit? = nil
            ) {
                self.id = id
                self.index = index
                self.center = center
                self.normal = normal
                self.surfaceType = surfaceType
                self.curveType = curveType
                self.area = area
                self.boundingBox = boundingBox
                self.endpoints = endpoints
                self.direction = direction
                self.circleCenter = circleCenter
                self.radius = radius
                self.axis = axis
                self.startAngle = startAngle
                self.endAngle = endAngle
                self.neighbors = neighbors
                self.neighborCount = neighborCount
                self.neighborsTruncated = neighborsTruncated
                self.oppositeFace = oppositeFace
            }
        }

        /// Set when an `exact` opposite-face request had to use the box test for some pairs.
        public let warnings: [String]?

        public init(
            entity: String, results: [Result], total: Int, truncated: Bool,
            warnings: [String]? = nil
        ) {
            self.entity = entity
            self.results = results
            self.total = total
            self.truncated = truncated
            self.warnings = warnings
        }
    }

    /// Optional face-relation outputs of `query_topology` (#199).
    public struct FaceRelations {
        public var includeNeighbors = false
        public var neighborLimit = 16
        public var oppositeFaces = false
        public var oppositeMethod = "exact"
        /// Face count above which neighbours/opposites need a `limit` or a `filter`.
        public var maxUnlimitedFaces = 200
        public init() {}
    }

    public struct TopologyFilter {
        public var surfaceType: String?
        public var curveType: String?
        public var minArea: Double?
        public var maxArea: Double?
        public init(
            surfaceType: String? = nil,
            curveType: String? = nil,
            minArea: Double? = nil,
            maxArea: Double? = nil
        ) {
            self.surfaceType = surfaceType
            self.curveType = curveType
            self.minArea = minArea
            self.maxArea = maxArea
        }
    }

    public static func queryTopology(
        bodyId: String,
        entity: String,
        filter: TopologyFilter = .init(),
        limit: Int? = nil,
        relations: FaceRelations = .init(),
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard let method = OppositeFaces.Method(rawValue: relations.oppositeMethod) else {
            return .init("`oppositeMethod` must be exact or bbox.", isError: true)
        }
        guard relations.neighborLimit >= 1, relations.maxUnlimitedFaces >= 0 else {
            return .init(
                "`neighborLimit` must be >= 1 and `maxUnlimitedFaces` >= 0.", isError: true)
        }
        let wantsRelations = relations.includeNeighbors || relations.oppositeFaces
        if wantsRelations && entity != "face" {
            return .init(
                "includeNeighbors and oppositeFaces apply to entity \"face\" only.", isError: true)
        }
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape
        var warnings: [String] = []

        var results: [QueryReport.Result] = []
        var totalScanned = 0
        var totalResultsBeforeLimit: Int?

        switch entity {
        case "face":
            let allFaces = shape.faces()
            let adjacency =
                relations.includeNeighbors ? FaceAdjacency.faceAdjacency(shape: shape) : nil
            let finder =
                relations.oppositeFaces
                ? OppositeFaces.Finder(faces: allFaces, method: method) : nil
            var rows: [(index: Int, face: Face, kind: String, area: Double)] = []
            for (i, face) in allFaces.enumerated() {
                totalScanned += 1
                let kind = String(describing: face.surfaceType)
                if let want = filter.surfaceType, want != kind { continue }
                let a = face.area()
                if let lo = filter.minArea, a < lo { continue }
                if let hi = filter.maxArea, a > hi { continue }
                rows.append((i, face, kind, a))
            }
            // Only guard unbounded work: an explicit `limit` is the caller's consent to the cost.
            if wantsRelations, limit == nil, rows.count > relations.maxUnlimitedFaces {
                return .init(
                    "includeNeighbors/oppositeFaces on \(rows.count) faces needs a `limit` or a `filter`"
                        + " (or raise `maxUnlimitedFaces`, now \(relations.maxUnlimitedFaces)).",
                    isError: true)
            }
            // Relations are only worth computing for rows that survive the limit.
            let kept = limit.map { Array(rows.prefix($0)) } ?? rows
            for row in kept {
                let (center, normal) = SelectionTools.faceCenterAndNormal(face: row.face)
                let hasPoint = row.face.uvBounds != nil
                var neighbors: [FaceAdjacency.Neighbour]?
                var neighborCount: Int?
                var neighborsTruncated: Bool?
                if let adjacency {
                    let all = adjacency.neighbours[row.index] ?? []
                    neighbors = Array(all.prefix(relations.neighborLimit))
                    neighborCount = all.count
                    neighborsTruncated = all.count > relations.neighborLimit
                }
                results.append(
                    .init(
                        id: "face[\(row.index)]",
                        index: row.index,
                        surfaceType: row.kind,
                        curveType: nil,
                        area: row.area,
                        boundingBox: nil,
                        center: hasPoint ? [center.x, center.y, center.z] : nil,
                        normal: normal.map { [$0.x, $0.y, $0.z] },
                        neighbors: neighbors,
                        neighborCount: neighborCount,
                        neighborsTruncated: neighborsTruncated,
                        oppositeFace: finder?.opposite(of: row.index)
                    ))
            }
            if let finder, finder.fallbackCount > 0 {
                warnings.append(
                    "oppositeMethod exact could not trace an outline for \(finder.fallbackCount) reported oppositeFace hit(s); the bbox test decided those (see oppositeFace.method)."
                )
            }
            totalResultsBeforeLimit = rows.count
        case "edge":
            for (i, edge) in shape.edges().enumerated() {
                totalScanned += 1
                let kind = String(describing: edge.curveType)
                if let want = filter.curveType, want != kind { continue }
                let geom = SelectionTools.edgeGeometryFields(edge: edge)
                results.append(
                    .init(
                        id: "edge[\(i)]",
                        index: i,
                        curveType: kind,
                        endpoints: geom.endpoints,
                        direction: geom.direction,
                        circleCenter: geom.circleCenter,
                        radius: geom.radius,
                        axis: geom.axis,
                        startAngle: geom.startAngle,
                        endAngle: geom.endAngle
                    ))
            }
        case "vertex":
            for (i, _) in shape.vertices().enumerated() {
                totalScanned += 1
                results.append(
                    .init(
                        id: "vertex[\(i)]",
                        index: i,
                        surfaceType: nil,
                        curveType: nil,
                        area: nil,
                        boundingBox: nil
                    ))
            }
        default:
            return .init(
                "Unknown entity '\(entity)'. Expected one of: face, edge, vertex.", isError: true)
        }

        let truncated: Bool
        if let before = totalResultsBeforeLimit {
            truncated = limit.map { before > $0 } ?? false
        } else {
            truncated = limit.map { results.count > $0 } ?? false
            if let n = limit { results = Array(results.prefix(n)) }
        }

        return encode(
            QueryReport(
                entity: entity,
                results: results,
                total: totalScanned,
                truncated: truncated,
                warnings: warnings.isEmpty ? nil : warnings
            ))
    }

    // ── measure_distance ───────────────────────────────────────────────

    public struct DistanceReport: Encodable {
        public let minDistance: Double
        public let isParallel: Bool
        public let contacts: [Contact]

        public struct Contact: Encodable {
            public let fromPoint: [Double]
            public let toPoint: [Double]
            public let distance: Double
        }
    }

    public static func measureDistance(
        fromBodyId: String,
        toBodyId: String,
        computeContacts: Bool = false,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let from: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        let to: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            from = try loadShape(bodyId: fromBodyId, store: store)
            to = try loadShape(bodyId: toBodyId, store: store)
        } catch {
            return .init("\(error)")
        }

        if !computeContacts {
            guard let dist = from.shape.minDistance(to: to.shape) else {
                return .init("Distance computation failed.", isError: true)
            }
            return encode(DistanceReport(minDistance: dist, isParallel: false, contacts: []))
        }

        guard let solutions = from.shape.allDistanceSolutions(to: to.shape, maxSolutions: 32) else {
            return .init("Distance computation failed.", isError: true)
        }
        let minD = solutions.map(\.distance).min() ?? .infinity
        let contacts = solutions.map {
            DistanceReport.Contact(
                fromPoint: [$0.point1.x, $0.point1.y, $0.point1.z],
                toPoint: [$0.point2.x, $0.point2.y, $0.point2.z],
                distance: $0.distance
            )
        }
        return encode(DistanceReport(minDistance: minD, isParallel: false, contacts: contacts))
    }

    // ── shared encoder ─────────────────────────────────────────────────

    static func encode<T: Encodable>(_ value: T) -> ToolText {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            return .init(String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            return .init("Failed to encode result: \(error.localizedDescription)", isError: true)
        }
    }
}
