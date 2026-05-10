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

    public indirect enum TransformHint: Sendable, Codable {
        case translate(offset: SIMD3<Double>)
        case mirror(planeOrigin: SIMD3<Double>, planeNormal: SIMD3<Double>)
        case rotate(axisOrigin: SIMD3<Double>, axisDirection: SIMD3<Double>, angleDeg: Double)
        case compound(steps: [TransformHint])

        private enum CodingKeys: String, CodingKey {
            case kind, offset, planeOrigin, planeNormal, axisOrigin, axisDirection, angleDeg, steps
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let kind = try c.decode(String.self, forKey: .kind)
            switch kind {
            case "translate":
                let arr = try c.decode([Double].self, forKey: .offset)
                guard arr.count == 3 else {
                    throw DecodingError.dataCorruptedError(forKey: .offset, in: c,
                        debugDescription: "translate.offset must be [x, y, z]")
                }
                self = .translate(offset: SIMD3(arr[0], arr[1], arr[2]))
            case "mirror":
                let nArr = try c.decode([Double].self, forKey: .planeNormal)
                guard nArr.count == 3 else {
                    throw DecodingError.dataCorruptedError(forKey: .planeNormal, in: c,
                        debugDescription: "mirror.planeNormal must be [x, y, z]")
                }
                let origin: SIMD3<Double>
                if let oArr = try c.decodeIfPresent([Double].self, forKey: .planeOrigin),
                   oArr.count == 3 {
                    origin = SIMD3(oArr[0], oArr[1], oArr[2])
                } else {
                    origin = .zero
                }
                self = .mirror(planeOrigin: origin,
                               planeNormal: SIMD3(nArr[0], nArr[1], nArr[2]))
            case "rotate":
                let oArr = try c.decode([Double].self, forKey: .axisOrigin)
                let dArr = try c.decode([Double].self, forKey: .axisDirection)
                let angle = try c.decode(Double.self, forKey: .angleDeg)
                guard oArr.count == 3, dArr.count == 3 else {
                    throw DecodingError.dataCorruptedError(forKey: .axisOrigin, in: c,
                        debugDescription: "rotate.axisOrigin / axisDirection must be [x, y, z]")
                }
                self = .rotate(
                    axisOrigin: SIMD3(oArr[0], oArr[1], oArr[2]),
                    axisDirection: SIMD3(dArr[0], dArr[1], dArr[2]),
                    angleDeg: angle
                )
            case "compound":
                let steps = try c.decode([TransformHint].self, forKey: .steps)
                self = .compound(steps: steps)
            default:
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                    debugDescription: "unknown transform kind: \(kind)")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .translate(let o):
                try c.encode("translate", forKey: .kind)
                try c.encode([o.x, o.y, o.z], forKey: .offset)
            case .mirror(let origin, let normal):
                try c.encode("mirror", forKey: .kind)
                try c.encode([origin.x, origin.y, origin.z], forKey: .planeOrigin)
                try c.encode([normal.x, normal.y, normal.z], forKey: .planeNormal)
            case .rotate(let origin, let dir, let angle):
                try c.encode("rotate", forKey: .kind)
                try c.encode([origin.x, origin.y, origin.z], forKey: .axisOrigin)
                try c.encode([dir.x, dir.y, dir.z], forKey: .axisDirection)
                try c.encode(angle, forKey: .angleDeg)
            case .compound(let steps):
                try c.encode("compound", forKey: .kind)
                try c.encode(steps, forKey: .steps)
            }
        }

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
            case .compound(let steps):
                return steps.reduce(p) { $1.apply($0) }
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
        /// Where the effective transform came from:
        /// `"explicit"` (caller-supplied), `"provenance"` (read from
        /// `<output_dir>/provenance.json`), `"bbox-inference"`
        /// (translation derived from bbox alignment), or
        /// `"identity-fallback"` (no hint and inference failed —
        /// returns a zero-translation default).
        public let transformSource: String
    }

    /// Resolve correspondences from `sourceSelectionIds` onto `targetBodyId`
    /// under the given `transform`. Each source id resolves through the
    /// SelectionRegistry to its anchor; the anchor's centroid (cached in
    /// the snapshot, or recomputed from the source BREP) is transformed,
    /// then matched against the same-kind sub-shapes of the target body
    /// by minimum centroid distance. Tolerance defaults to 1% of the
    /// target body's bbox diagonal — same sizing as remap_selection's
    /// heuristic so confidence values are directly comparable.
    ///
    /// `transform` is optional. When omitted:
    ///   1. read `<output_dir>/provenance.json` — `mirror_or_pattern`
    ///      records its mirror plane there for every output body.
    ///   2. fall back to bbox-translation inference: source and
    ///      target bbox sizes match, transform is the centroid delta.
    /// Both fallbacks are best-effort. Callers that want a specific
    /// transform should pass it explicitly.
    public static func findCorrespondences(
        sourceSelectionIds: [String],
        targetBodyId: String,
        transform: TransformHint?,
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

        // Resolve the effective transform — explicit hint wins; then
        // provenance.json (mirror_or_pattern's record); then bbox
        // inference. If all three fail we report transform=nil but
        // continue with identity, since the caller might just want
        // index-aligned matching on truly identical bodies.
        let resolvedTransform: TransformHint
        let transformSource: String
        if let hint = transform {
            resolvedTransform = hint
            transformSource = "explicit"
        } else if let prov = ProvenanceStore(outputDir: outputDir).read()[targetBodyId] {
            resolvedTransform = prov.transform
            transformSource = "provenance"
        } else if let inferred = inferTranslation(
            manifest: manifest, outputDir: outputDir,
            targetShape: targetShape, targetBodyId: targetBodyId
        ) {
            resolvedTransform = inferred
            transformSource = "bbox-inference"
        } else {
            resolvedTransform = .translate(offset: .zero)
            transformSource = "identity-fallback"
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

            let transformed = resolvedTransform.apply(sc)

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

        return IntrospectionTools.encode(CorrespondencesReport(
            correspondences: out,
            transformSource: transformSource
        ))
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

    /// Infer a translation transform from how source and target
    /// bounding boxes align. Returns nil if the boxes have meaningfully
    /// different sizes (which would imply rotation / scale / mirror —
    /// none of which we attempt to recover from bbox alone).
    ///
    /// The provenance path handles `mirror_or_pattern` outputs cleanly;
    /// this is the catch-all for "the LLM duplicated something via
    /// `execute_script` and didn't bother to record a transform."
    private static func inferTranslation(
        manifest: ScriptManifest,
        outputDir: String,
        targetShape: Shape,
        targetBodyId: String
    ) -> TransformHint? {
        // Pick any source body that isn't the target. Multi-source
        // selection workflows pass the source explicitly via the
        // selectionId prefix, but for inference we just need ONE shape
        // to compare bboxes against.
        guard let sourceBody = manifest.bodies.first(where: { $0.id != targetBodyId }),
              let sourceShape = try? Shape.loadBREP(fromPath: "\(outputDir)/\(sourceBody.file)") else {
            return nil
        }
        let s = sourceShape.bounds
        let t = targetShape.bounds
        let sourceSize = s.max - s.min
        let targetSize = t.max - t.min
        let sizeDiag = simd_length(sourceSize)
        let sizeDelta = simd_length(sourceSize - targetSize)
        // Allow 0.1% size mismatch for tessellation / numerical noise.
        guard sizeDiag > 1e-6, sizeDelta / sizeDiag < 1e-3 else { return nil }
        let sourceCentre = (s.min + s.max) * 0.5
        let targetCentre = (t.min + t.max) * 0.5
        return .translate(offset: targetCentre - sourceCentre)
    }
}
