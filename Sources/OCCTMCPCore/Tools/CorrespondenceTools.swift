// CorrespondenceTools — find_correspondences. Maps selectionIds from a
// source body onto a target body that's a known transform of the source
// (typically a `mirror_or_pattern` output, but works for any pair of
// same-topology bodies under a given transform).
//
// Different contract from `remap_selection`:
//   - remap_selection: "selectionId X mutated into selectionId Y on the
//     SAME body". Returns fate per id.
//   - find_correspondences: "selectionId X on body A corresponds to
//     selectionId Y on body B under transform T". Returns target
//     selectionId per source id.
//
// pattern instances aren't OCCT-derivatives of the source — they're
// independent Shapes that share topology under a transform. There's no
// history relationship to walk; the algorithm is pure geometry: apply
// the transform to each source anchor's centroid, then find the
// nearest target sub-shape of the same kind.
//
// Tracks #24. v1 supports translate / mirror / rotate hints; compound
// hints + bbox-alignment inference + reading mirror_or_pattern manifest
// metadata are listed in the issue and queued for follow-ups.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

public enum CorrespondenceTools {

    public enum TransformHint: Sendable {
        case translate(offset: SIMD3<Double>)
        case mirror(planeOrigin: SIMD3<Double>, planeNormal: SIMD3<Double>)
        case rotate(axisOrigin: SIMD3<Double>, axisDirection: SIMD3<Double>, angleDeg: Double)

        /// Apply to a single point.
        func apply(_ p: SIMD3<Double>) -> SIMD3<Double> {
            switch self {
            case .translate(let offset):
                return p + offset
            case .mirror(let origin, let normal):
                let n = simd_normalize(normal)
                let d = simd_dot(p - origin, n)
                return p - 2.0 * d * n
            case .rotate(let origin, let dir, let angleDeg):
                let axis = simd_normalize(dir)
                let theta = angleDeg * .pi / 180.0
                let c = cos(theta), s = sin(theta), oneMinusC = 1 - c
                let v = p - origin
                // Rodrigues rotation
                let rotated =
                    v * c
                    + simd_cross(axis, v) * s
                    + axis * simd_dot(axis, v) * oneMinusC
                return origin + rotated
            }
        }
    }

    public struct Correspondence: Encodable {
        public let sourceSelectionId: String
        public let targetSelectionId: String?
        public let confidenceMm: Double?   // distance from transformed source anchor to chosen target centroid
        public let fate: String            // "matched" | "lost"
    }

    public struct CorrespondencesReport: Encodable {
        public let correspondences: [Correspondence]
    }

    /// Resolve correspondences from `sourceSelectionIds` onto `targetBodyId`
    /// under the given `transform`. Each source id resolves through the
    /// SelectionRegistry to its anchor; the anchor's centroid (cached in
    /// the snapshot, or recomputed from the source BREP) is transformed,
    /// then matched against the same-kind sub-shapes of the target body
    /// by minimum centroid distance. Tolerance defaults to 1% of the
    /// target body's bbox diagonal — same sizing as remap_selection's
    /// heuristic so confidence values are directly comparable.
    public static func findCorrespondences(
        sourceSelectionIds: [String],
        targetBodyId: String,
        transform: TransformHint,
        toleranceMmFraction: Double = 0.01,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded.")
        }
        guard let targetBody = manifest.body(withId: targetBodyId) else {
            return .init("Target body not found: \(targetBodyId)")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let targetPath = "\(outputDir)/\(targetBody.file)"
        guard FileManager.default.fileExists(atPath: targetPath),
              let targetShape = try? Shape.loadBREP(fromPath: targetPath) else {
            return .init("Target BREP missing or unreadable: \(targetPath)")
        }

        let bb = targetShape.bounds
        let diag = simd_length(bb.max - bb.min)
        let tolerance = max(diag * toleranceMmFraction, 1e-6)

        // Pre-compute target sub-shape centroids once per kind — every
        // source id of the same kind reuses the array.
        let targetFaceCentres: [SIMD3<Double>] = targetShape.faces().map {
            SelectionTools.faceCenterAndNormal(face: $0).0
        }
        let targetEdgeCentres: [SIMD3<Double>] = targetShape.edges().compactMap {
            SelectionTools.edgeMidpoint(edge: $0)
        }
        let targetVertices: [SIMD3<Double>] = targetShape.vertices()

        // Cache source-shape loads per source bodyId — multiple
        // selectionIds typically share a source.
        var sourceShapes: [String: Shape] = [:]

        var out: [Correspondence] = []
        for sid in sourceSelectionIds {
            guard let anchor = await registry.anchor(for: sid) else {
                out.append(.init(
                    sourceSelectionId: sid,
                    targetSelectionId: nil,
                    confidenceMm: nil,
                    fate: "lost"
                ))
                continue
            }

            // Resolve source centroid — registry snapshot first (cheap),
            // BREP recompute as fallback.
            let snapshot = await registry.snapshot(for: sid)
            let sourceCentroid: SIMD3<Double>?
            if let snap = snapshot, snap.center.count == 3 {
                sourceCentroid = SIMD3(snap.center[0], snap.center[1], snap.center[2])
            } else {
                sourceCentroid = await loadSourceCentroid(
                    anchor: anchor,
                    manifest: manifest,
                    outputDir: outputDir,
                    cache: &sourceShapes
                )
            }
            guard let sc = sourceCentroid else {
                out.append(.init(
                    sourceSelectionId: sid,
                    targetSelectionId: nil,
                    confidenceMm: nil,
                    fate: "lost"
                ))
                continue
            }

            let transformed = transform.apply(sc)

            switch anchor {
            case .body:
                // Whole-body picks always rebind to the target body —
                // no geometry matching needed.
                let newAnchor = TopologyAnchor.body(bodyId: targetBodyId)
                out.append(.init(
                    sourceSelectionId: sid,
                    targetSelectionId: newAnchor.selectionId,
                    confidenceMm: 0,
                    fate: "matched"
                ))

            case .face:
                let entry = pickNearest(
                    sid: sid,
                    transformed: transformed,
                    centres: targetFaceCentres,
                    tolerance: tolerance
                ) { idx in TopologyAnchor.face(bodyId: targetBodyId, index: idx) }
                if let newAnchor = entry.anchor, let snap = snapshot {
                    await registry.record(anchor: newAnchor, snapshot: snap)
                }
                out.append(entry.report)

            case .edge:
                let entry = pickNearest(
                    sid: sid,
                    transformed: transformed,
                    centres: targetEdgeCentres,
                    tolerance: tolerance
                ) { idx in TopologyAnchor.edge(bodyId: targetBodyId, index: idx) }
                if let newAnchor = entry.anchor, let snap = snapshot {
                    await registry.record(anchor: newAnchor, snapshot: snap)
                }
                out.append(entry.report)

            case .vertex:
                let entry = pickNearest(
                    sid: sid,
                    transformed: transformed,
                    centres: targetVertices,
                    tolerance: tolerance
                ) { idx in TopologyAnchor.vertex(bodyId: targetBodyId, index: idx) }
                if let newAnchor = entry.anchor, let snap = snapshot {
                    await registry.record(anchor: newAnchor, snapshot: snap)
                }
                out.append(entry.report)
            }
        }

        return IntrospectionTools.encode(CorrespondencesReport(correspondences: out))
    }

    private struct PickResult {
        let report: Correspondence
        let anchor: TopologyAnchor?
    }

    private static func pickNearest(
        sid: String,
        transformed: SIMD3<Double>,
        centres: [SIMD3<Double>],
        tolerance: Double,
        anchorMaker: (Int) -> TopologyAnchor
    ) -> PickResult {
        guard !centres.isEmpty else {
            return PickResult(
                report: .init(sourceSelectionId: sid, targetSelectionId: nil,
                              confidenceMm: nil, fate: "lost"),
                anchor: nil
            )
        }
        var bestIdx = 0
        var bestDist = simd_length(centres[0] - transformed)
        for i in 1..<centres.count {
            let d = simd_length(centres[i] - transformed)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        if bestDist > tolerance {
            return PickResult(
                report: .init(sourceSelectionId: sid, targetSelectionId: nil,
                              confidenceMm: bestDist, fate: "lost"),
                anchor: nil
            )
        }
        let newAnchor = anchorMaker(bestIdx)
        return PickResult(
            report: .init(sourceSelectionId: sid, targetSelectionId: newAnchor.selectionId,
                          confidenceMm: bestDist, fate: "matched"),
            anchor: newAnchor
        )
    }

    /// Recompute the source anchor centroid from the source BREP. Only
    /// needed when the SelectionRegistry snapshot was evicted or never
    /// captured (e.g. selectionIds constructed by hand).
    private static func loadSourceCentroid(
        anchor: TopologyAnchor,
        manifest: ScriptManifest,
        outputDir: String,
        cache: inout [String: Shape]
    ) async -> SIMD3<Double>? {
        let bodyId = anchor.bodyId
        let shape: Shape
        if let cached = cache[bodyId] {
            shape = cached
        } else {
            guard let body = manifest.body(withId: bodyId),
                  let loaded = try? Shape.loadBREP(fromPath: "\(outputDir)/\(body.file)") else {
                return nil
            }
            cache[bodyId] = loaded
            shape = loaded
        }
        switch anchor {
        case .body:
            let bb = shape.bounds
            return (bb.min + bb.max) * 0.5
        case .face(_, let idx):
            let faces = shape.faces()
            guard idx < faces.count else { return nil }
            return SelectionTools.faceCenterAndNormal(face: faces[idx]).0
        case .edge(_, let idx):
            let edges = shape.edges()
            guard idx < edges.count else { return nil }
            return SelectionTools.edgeMidpoint(edge: edges[idx])
        case .vertex(_, let idx):
            let vs = shape.vertices()
            guard idx < vs.count else { return nil }
            return vs[idx]
        }
    }
}
