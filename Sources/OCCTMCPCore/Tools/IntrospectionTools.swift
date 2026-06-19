// IntrospectionTools — pure-read tools backed by direct OCCTSwift calls
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
        let inertia = (wants("volume") || wants("centerOfMass") || wants("principalAxes"))
            ? shape.volumeInertia : nil

        if wants("volume") { report.volume = inertia?.volume }
        if wants("surfaceArea") { report.surfaceArea = shape.surfaceArea }
        if wants("centerOfMass"), let i = inertia {
            report.centerOfMass = [i.centerOfMass.x, i.centerOfMass.y, i.centerOfMass.z]
        }
        if wants("boundingBox") {
            // Default Bnd_Box: for B-spline / curved faces this is the
            // control-point hull and over-reports the true extent
            // (OCCTSwift #232 / #213). Use boundingBoxOptimal for a tight box.
            let b = shape.bounds
            report.boundingBox = .init(
                min: [b.min.x, b.min.y, b.min.z],
                max: [b.max.x, b.max.y, b.max.z]
            )
        }
        // Opt-in only (not part of default-all): AddOptimal is costlier than
        // the Bnd_Box, and most callers want the cheap footprint.
        if metrics?.contains("boundingBoxOptimal") == true, let o = shape.boundingBoxOptimal() {
            // BRepBndLib::AddOptimal — tight extent that matches the exact
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
            public let surfaceType: String?
            public let curveType: String?
            public let area: Double?
            public let boundingBox: MetricsReport.BBox?
        }
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
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        var results: [QueryReport.Result] = []
        var totalScanned = 0

        switch entity {
        case "face":
            for (i, face) in shape.faces().enumerated() {
                totalScanned += 1
                let kind = String(describing: face.surfaceType)
                if let want = filter.surfaceType, want != kind { continue }
                let a = face.area()
                if let lo = filter.minArea, a < lo { continue }
                if let hi = filter.maxArea, a > hi { continue }
                results.append(.init(
                    id: "face[\(i)]",
                    surfaceType: kind,
                    curveType: nil,
                    area: a,
                    boundingBox: nil
                ))
            }
        case "edge":
            for (i, edge) in shape.edges().enumerated() {
                totalScanned += 1
                let kind = String(describing: edge.curveType)
                if let want = filter.curveType, want != kind { continue }
                results.append(.init(
                    id: "edge[\(i)]",
                    surfaceType: nil,
                    curveType: kind,
                    area: nil,
                    boundingBox: nil
                ))
            }
        case "vertex":
            for (i, _) in shape.vertices().enumerated() {
                totalScanned += 1
                results.append(.init(
                    id: "vertex[\(i)]",
                    surfaceType: nil,
                    curveType: nil,
                    area: nil,
                    boundingBox: nil
                ))
            }
        default:
            return .init("Unknown entity '\(entity)'. Expected one of: face, edge, vertex.")
        }

        let truncated = limit.map { results.count > $0 } ?? false
        if let n = limit { results = Array(results.prefix(n)) }

        return encode(QueryReport(
            entity: entity,
            results: results,
            total: totalScanned,
            truncated: truncated
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
