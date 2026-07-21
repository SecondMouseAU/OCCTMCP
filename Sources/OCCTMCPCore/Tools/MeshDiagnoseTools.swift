// MeshDiagnoseTools — `mesh_diagnose` (Phase 2 of the mesh-analysis
// expansion, `.claude/plans/2026-07-21-mesh-analysis-expansion.md`). A
// printability-check-list style integrity report over OCCTSwiftMesh's
// `Mesh.integrityReport(weldTolerance:)` (1.3.0): watertight, manifold,
// orientable, component table, boundary loops, Euler characteristic /
// genus, duplicate/degenerate counts, sliver signals — the cheapest,
// most decision-relevant signals for "is this mesh printable / suitable
// for reconstruction", surfaced as booleans and small counts first per
// the plan's signal-design hierarchy.
//
// IMPORTANT — self-intersection is NOT checked. `integrityReport`'s own
// doc comment is explicit about this (an upstream limitation, not an
// oversight here): a self-intersecting closed manifold still reports
// `isWatertight: true`. Repeated in this tool's own description and in
// docs/reference/mesh-analysis.md so a caller doesn't read `isWatertight`
// as a stronger guarantee than it is.
//
// `checks[]` derives pass/warn/fail verdicts from the raw counts so an LLM
// doesn't have to re-encode the thresholds itself; the raw counts are still
// reported alongside so a caller can apply its own policy.

import Foundation
import OCCTSwift
import OCCTSwiftMesh
import ScriptHarness

public enum MeshDiagnoseTools {

    public struct DiagnoseReport: Encodable {
        public let bodyId: String
        public let triangleCount: Int
        public let isWatertight: Bool
        public let isOrientable: Bool
        public let nonManifoldEdgeCount: Int
        public let nonManifoldVertexCount: Int
        public let boundaryLoopCount: Int
        public let duplicateTriangleCount: Int
        public let degenerateTriangleCount: Int
        public let eulerCharacteristic: Int
        public let genus: Int?
        public let componentCount: Int
        public let components: [ComponentEntry]
        public let minAngleDegrees: MinAngleStat
        public let aspectRatio: AspectStat
        public let checks: [CheckEntry]
        public let warnings: [String]

        public struct ComponentEntry: Encodable {
            public let triangleCount: Int
            public let areaMm2: Double
        }
        public struct MinAngleStat: Encodable {
            public let min: Double
            public let p05: Double
        }
        public struct AspectStat: Encodable {
            public let max: Double
            public let p95: Double
        }
        public struct CheckEntry: Encodable {
            public let check: String
            public let status: String   // "pass" | "warn" | "fail"
            public let detail: String
        }
    }

    static let componentDisplayCap = 16
    /// A p05 minimum interior angle below this, or a p95 aspect ratio
    /// above it, is reported as a "slivers" warning.
    static let sliverMinAngleFloorDegrees = 5.0
    static let sliverAspectCeiling = 20.0

    @MainActor
    public static func meshDiagnose(
        bodyId: String,
        deflection: Double? = nil,
        weldToleranceMm: Double = 0,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        let defl = deflection ?? DeviationTools.defaultDeflection(for: shape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }
        guard weldToleranceMm >= 0 else { return .init("weldToleranceMm must be >= 0.", isError: true) }

        var meshParams = MeshParameters.default
        meshParams.deflection = defl
        meshParams.internalVertices = true
        meshParams.inParallel = true
        meshParams.allowQualityDecrease = true
        guard let mesh = shape.mesh(parameters: meshParams), mesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(bodyId)'.", isError: true)
        }

        let report = mesh.integrityReport(weldTolerance: weldToleranceMm)
        var warnings: [String] = []

        // `report.components` is already largest-first (MeshRegion's
        // deterministic ordering, per OCCTSwiftMesh's connectedComponents()).
        let shown = Array(report.components.prefix(componentDisplayCap))
            .map { DiagnoseReport.ComponentEntry(triangleCount: $0.triangleCount, areaMm2: $0.area) }
        if report.components.count > componentDisplayCap {
            warnings.append(
                "\(report.components.count) connected components exceed the \(componentDisplayCap)-entry display cap; " +
                "\(report.components.count - componentDisplayCap) more not shown (componentCount is the true total)."
            )
        }

        let checks = buildChecks(report)

        let diag = DiagnoseReport(
            bodyId: bodyId,
            triangleCount: mesh.triangleCount,
            isWatertight: report.isWatertight,
            isOrientable: report.isOrientable,
            nonManifoldEdgeCount: report.nonManifoldEdgeCount,
            nonManifoldVertexCount: report.nonManifoldVertexCount,
            boundaryLoopCount: report.boundaryLoopCount,
            duplicateTriangleCount: report.duplicateTriangleCount,
            degenerateTriangleCount: report.degenerateTriangleCount,
            eulerCharacteristic: report.eulerCharacteristic,
            genus: report.genus,
            componentCount: report.components.count,
            components: shown,
            minAngleDegrees: .init(min: report.minAngleDegrees.min, p05: report.minAngleDegrees.p05),
            aspectRatio: .init(max: report.aspectRatio.max, p95: report.aspectRatio.p95),
            checks: checks,
            warnings: warnings
        )
        return IntrospectionTools.encode(diag)
    }

    // MARK: - Check-list derivation (pure; no geometry)

    static func buildChecks(_ report: MeshIntegrityReport) -> [DiagnoseReport.CheckEntry] {
        var checks: [DiagnoseReport.CheckEntry] = []

        checks.append(.init(
            check: "watertight",
            status: report.isWatertight ? "pass" : "fail",
            detail: report.isWatertight
                ? "Every welded edge is shared by exactly two triangles and every vertex is manifold."
                : "Not watertight: \(report.boundaryLoopCount) boundary loop(s), \(report.nonManifoldEdgeCount) non-manifold edge(s), \(report.nonManifoldVertexCount) non-manifold vertex/vertices."
        ))

        if report.nonManifoldEdgeCount > 0 {
            checks.append(.init(
                check: "orientable", status: "warn",
                detail: "Not evaluated: orientability is only meaningful over 2-triangle edges, and this mesh has \(report.nonManifoldEdgeCount) non-manifold edge(s)."
            ))
        } else {
            checks.append(.init(
                check: "orientable",
                status: report.isOrientable ? "pass" : "fail",
                detail: report.isOrientable
                    ? "Consistent winding across every 2-triangle edge."
                    : "Inconsistent winding: at least one edge's two triangles traverse it the same direction (a flipped face)."
            ))
        }

        checks.append(.init(
            check: "single_component",
            status: report.components.count > 1 ? "warn" : "pass",
            detail: report.components.count > 1
                ? "\(report.components.count) disconnected pieces."
                : "A single connected piece."
        ))

        checks.append(.init(
            check: "non_manifold_edges",
            status: report.nonManifoldEdgeCount > 0 ? "fail" : "pass",
            detail: report.nonManifoldEdgeCount > 0
                ? "\(report.nonManifoldEdgeCount) welded edge(s) shared by 3 or more triangles."
                : "No non-manifold edges."
        ))

        checks.append(.init(
            check: "non_manifold_vertices",
            status: report.nonManifoldVertexCount > 0 ? "fail" : "pass",
            detail: report.nonManifoldVertexCount > 0
                ? "\(report.nonManifoldVertexCount) vertex/vertices whose surrounding triangles don't form a single fan (a pinch point / bowtie)."
                : "No non-manifold vertices."
        ))

        checks.append(.init(
            check: "degenerate_triangles",
            status: report.degenerateTriangleCount > 0 ? "warn" : "pass",
            detail: report.degenerateTriangleCount > 0
                ? "\(report.degenerateTriangleCount) triangle(s) collapsed to an edge or point after welding."
                : "No degenerate triangles."
        ))

        checks.append(.init(
            check: "duplicate_triangles",
            status: report.duplicateTriangleCount > 0 ? "warn" : "pass",
            detail: report.duplicateTriangleCount > 0
                ? "\(report.duplicateTriangleCount) triangle(s) repeat an earlier triangle's vertex set."
                : "No duplicate triangles."
        ))

        let sliverBad = report.minAngleDegrees.p05 < sliverMinAngleFloorDegrees
            || report.aspectRatio.p95 > sliverAspectCeiling
        checks.append(.init(
            check: "slivers",
            status: sliverBad ? "warn" : "pass",
            detail: "minAngleDegrees.p05=\(fmt(report.minAngleDegrees.p05))\u{b0}, aspectRatio.p95=\(fmt(report.aspectRatio.p95))"
                + (sliverBad ? " (sliver triangles present)." : ".")
        ))

        return checks
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
