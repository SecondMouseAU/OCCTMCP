// AlignTools — `align_bodies` (#104, Phase 2 of the mesh-analysis expansion). Was blocked on the
// upstream registration primitive (SecondMouseAU/OCCTSwiftMesh#22); closed by OCCTSwiftMesh v1.5.0's
// `Mesh.aligned(to:options:)` (point-to-plane ICP: Chen & Medioni's objective, Rusinkiewicz & Levoy's
// normal-space sampling, Low's linearized point-to-plane solve — see OCCTSwiftMesh's own
// docs/algorithms/alignment.md for the algorithm itself). Scan-vs-CAD deviation measurement
// (measure_deviation, cross_section_compare, the heatmap) is meaningless before the two bodies are
// actually registered to a shared frame; none of those tools do any alignment step of their own.
//
// This tool is a thin GOM-style wrapper layered over the upstream primitive per #104's proposed
// shape: `bestFit` runs the full PCA-pre-align + ICP pipeline; `preAlign` stops after the coarse PCA/
// bbox stage (`maxIterations: 0`) — GOM's "pre-align" tier. `localBestFit` / `3-2-1` / RPS-datum
// alignment are further out and explicitly out of scope for this first version.
//
// Two documented upstream limitations are surfaced here (in the tool description AND in
// docs/reference/mesh-analysis.md) rather than re-derived: near-degenerate principal axes make the
// PCA pre-align orientation ambiguous (a square-section prism / near-cubic body can converge to a
// locally-plausible WRONG pose, the same failure family SymmetryTools documents for its own PCA
// axes); and a body with continuous symmetry about an axis (a cylinder) has an inherently
// unobservable rotation about that axis — any such rotation is an equally valid alignment, and which
// one comes back is a sampling artifact, not an error. `converged == false` or an outsized
// `residualRmsMm` is the signal; both are surfaced as explicit warnings rather than silently trusted.
//
// `apply: true` mirrors ConstructionTools.transformBody's in-place path exactly: SceneHistory
// snapshot before the write, the SAME HistoryRegistry generation reset (`commit(ref: nil)` — no
// *WithFullHistory variant exists for an arbitrary caller-supplied 4x4, only for the named
// translate/rotate/scale/mirror/pattern primitives, see CLAUDE.md's transform_body row), and the
// same "file unchanged, just bump the timestamp" `store.write` convention so the viewport watcher
// reloads. The transform itself goes through `Shape.transformed(matrix:)` — OCCTSwift's ONE
// general-affine (rotation + translation) primitive (BRepBuilderAPI_Transform / gp_Trsf) — applied
// as a single rigid transform, not decomposed back into a rotate-then-translate pair, so no
// composition error is introduced round-tripping our own recovered axis-angle through two separate
// OCCT calls.

import Foundation
import OCCTSwift
import OCCTSwiftMesh
import simd
import ScriptHarness

public enum AlignTools {

    public enum Mode: String, Sendable {
        case bestFit
        case preAlign
    }

    public struct AlignReport: Encodable {
        public let bodyId: String
        public let referenceBodyId: String
        public let mode: String
        /// 4 rows x 4 columns, ROW-MAJOR: `transform[i]` is row `i`. Maps a SOURCE-body point
        /// `[x, y, z, 1]` into the reference body's frame (`transform * point`, standard
        /// row-dot-column convention — the trivial 4th row is always `[0, 0, 0, 1]`).
        public let transform: [[Double]]
        /// `[transform[0][3], transform[1][3], transform[2][3]]` — the translation column.
        public let translationMm: [Double]
        /// Unit axis of the transform's 3x3 rotation block (axis-angle decomposition).
        public let rotationAxis: [Double]
        public let rotationAngleDegrees: Double
        public let residualRmsMm: Double
        public let iterations: Int
        public let converged: Bool
        public let applied: Bool
        public let warnings: [String]
    }

    /// A residual above this fraction of the SOURCE body's bbox diagonal is flagged: at that scale
    /// the two bodies plausibly don't correspond, or ICP converged to the wrong pose.
    static let largeResidualBboxFraction = 0.02

    @MainActor
    public static func alignBodies(
        bodyId: String,
        referenceBodyId: String,
        mode: Mode = .bestFit,
        maxSamples: Int = 2000,
        trimFraction: Double = 0.1,
        correspondenceDistanceCapMm: Double? = nil,
        maxIterations: Int = 50,
        deflection: Double? = nil,
        apply: Bool = false,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard bodyId != referenceBodyId else {
            return .init(
                "align_bodies requires two distinct bodies: bodyId and referenceBodyId are both \"\(bodyId)\".",
                isError: true
            )
        }

        let loadedSource: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        let loadedRef: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loadedSource = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
            loadedRef = try IntrospectionTools.loadShape(bodyId: referenceBodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let sourceShape = loadedSource.shape
        let referenceShape = loadedRef.shape

        guard maxSamples > 0 else { return .init("maxSamples must be positive.", isError: true) }
        guard trimFraction >= 0 else { return .init("trimFraction must be >= 0.", isError: true) }
        guard maxIterations >= 0 else { return .init("maxIterations must be >= 0.", isError: true) }
        if let cap = correspondenceDistanceCapMm, cap <= 0 {
            return .init("correspondenceDistanceCapMm must be positive when supplied.", isError: true)
        }

        let defl = deflection ?? DeviationTools.defaultDeflection(for: sourceShape)
        guard defl > 0 else { return .init("deflection must be positive.", isError: true) }

        // The standard mesh recipe shared with DeviationTools/MeshZoneTools/MeshDiagnoseTools: both
        // bodies meshed at the SAME (source-derived, unless overridden) deflection.
        var meshParams = MeshParameters.default
        meshParams.deflection = defl
        meshParams.internalVertices = true
        meshParams.inParallel = true
        meshParams.allowQualityDecrease = true
        guard let sourceMesh = sourceShape.mesh(parameters: meshParams), sourceMesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(bodyId)' for alignment.", isError: true)
        }
        guard let referenceMesh = referenceShape.mesh(parameters: meshParams), referenceMesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(referenceBodyId)' for alignment.", isError: true)
        }

        var options = Mesh.AlignOptions()
        options.maxSamples = maxSamples
        options.trimFraction = trimFraction
        options.correspondenceDistanceCap = correspondenceDistanceCapMm
        options.normalSpaceSampling = true
        switch mode {
        case .bestFit:
            options.maxIterations = maxIterations
            options.preAlign = true
        case .preAlign:
            // The GOM "pre-align" tier: PCA/bbox coarse pose only, no ICP refinement.
            options.maxIterations = 0
            options.preAlign = true
        }

        guard let result = sourceMesh.aligned(to: referenceMesh, options: options) else {
            return .init(
                "Alignment failed: '\(bodyId)' or '\(referenceBodyId)' has fewer than 3 points after " +
                "welding — too few points to register.",
                isError: true
            )
        }

        var warnings: [String] = []
        // preAlign mode never runs an ICP iteration, so `converged` is always false there by
        // construction — not a meaningful signal, unlike in bestFit mode where it means the
        // refinement genuinely didn't settle.
        if mode == .bestFit, !result.converged {
            warnings.append(
                "converged=false: did not converge — treat the transform as unreliable. Near-symmetric " +
                "bodies make the PCA pre-align orientation ambiguous, and the subsequent ICP refinement " +
                "(a local optimizer) can converge to a wrong pose or not at all; see " +
                "docs/reference/mesh-analysis.md#align_bodies for the near-degenerate-axes and " +
                "continuous-symmetry limitations."
            )
        }
        let sourceBboxDiag = simd_length(sourceShape.bounds.max - sourceShape.bounds.min)
        if sourceBboxDiag > 0, result.residualRMS > largeResidualBboxFraction * sourceBboxDiag {
            warnings.append(
                "residualRmsMm=\(fmt(result.residualRMS)) is more than \(Int(largeResidualBboxFraction * 100))% " +
                "of the source body's bounding-box diagonal (\(fmt(sourceBboxDiag))mm) — large residual, the two " +
                "bodies may not actually correspond, or the alignment converged to the wrong pose."
            )
        }

        let rows = rowMajor(result.transform)
        let translation = [rows[0][3], rows[1][3], rows[2][3]]
        let (axis, angleDegrees) = axisAngle(fromRotationRows: rows)

        var applied = false
        if apply {
            let matrix12 = align3x4RowMajorBlock(result.transform)
            guard let transformedShape = sourceShape.transformed(matrix: matrix12) else {
                return .init("apply=true requested, but applying the recovered transform to '\(bodyId)' failed.", isError: true)
            }
            let outputPath = loadedSource.path

            await history.snapshot(store: store)
            do {
                try Exporter.writeBREP(shape: transformedShape, to: URL(fileURLWithPath: outputPath))
            } catch {
                return .init(
                    "apply=true requested, but writing the transformed BREP failed: \(error.localizedDescription)",
                    isError: true
                )
            }
            // Generation reset, exactly transform_body's convention (see this file's header):
            // no *WithFullHistory primitive exists for an arbitrary general matrix.
            await HistoryRegistry.shared.commit(
                bodyId: bodyId, path: outputPath, output: transformedShape,
                ref: nil, from: nil, operationName: "align_bodies"
            )
            // Body file unchanged in the manifest sense (same path, new content) — just bump the
            // timestamp so OCCTSwiftViewport's ScriptWatcher reloads, same as transform_body's
            // in-place branch.
            try? store.write(loadedSource.manifest)
            applied = true
        }

        let report = AlignReport(
            bodyId: bodyId,
            referenceBodyId: referenceBodyId,
            mode: mode.rawValue,
            transform: rows,
            translationMm: translation,
            rotationAxis: [axis.x, axis.y, axis.z],
            rotationAngleDegrees: angleDegrees,
            residualRmsMm: result.residualRMS,
            iterations: result.iterations,
            converged: result.converged,
            applied: applied,
            warnings: warnings
        )
        return IntrospectionTools.encode(report)
    }

    // MARK: - Matrix helpers

    /// Full 4x4, row-major: `rows[i][j] = transform.columns[j][i]` (simd's `simd_mul(m, v)` computes
    /// `result[i] = sum_j m.columns[j][i] * v[j]`, i.e. exactly "row i dot v" under this reading).
    /// The trivial 4th row is always `[0, 0, 0, 1]` for a rigid transform.
    static func rowMajor(_ m: simd_double4x4) -> [[Double]] {
        [
            [m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x],
            [m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y],
            [m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z],
            [m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w],
        ]
    }

    /// OCCTSwift's `Shape.transformed(matrix:)` (BRepBuilderAPI_Transform / gp_Trsf) wants matrix12
    /// laid out as the 9 rotation entries ROW-MAJOR FIRST, then the 3 translation entries appended —
    /// NOT the per-row-interleaved `[r,r,r,t, r,r,r,t, r,r,r,t]` layout its sibling
    /// `gTransformed(matrix:)` (gp_GTrsf, general/non-rigid) uses. Confirmed against both bridge
    /// implementations (OCCTBridge_Modeling.mm): `gp_Trsf::SetValues(m[0],m[1],m[2],m[9],
    /// m[3],m[4],m[5],m[10], m[6],m[7],m[8],m[11])` for `transformed`, vs
    /// `gp_GTrsf::SetValue(1,1,m[0])...(1,4,m[3])...` (interleaved) for `gTransformed` — an easy
    /// mix-up since the two sibling calls disagree on the layout despite near-identical doc
    /// comments.
    static func align3x4RowMajorBlock(_ m: simd_double4x4) -> [Double] {
        [
            m.columns.0.x, m.columns.1.x, m.columns.2.x,
            m.columns.0.y, m.columns.1.y, m.columns.2.y,
            m.columns.0.z, m.columns.1.z, m.columns.2.z,
            m.columns.3.x, m.columns.3.y, m.columns.3.z,
        ]
    }

    /// Axis-angle decomposition of the 3x3 rotation block of a row-major 4x4 (`rows[0..2][0..2]`).
    /// Guards the two degenerate cases the general formula can't handle: identity (angle ~ 0, axis
    /// undefined — returns a placeholder unit axis) and a 180-degree rotation (the antisymmetric
    /// off-diagonal term the general formula divides by vanishes there; the axis instead comes from
    /// the symmetric part `S = (R + I) / 2 = axis ⊗ axis`, pivoting on whichever diagonal entry of
    /// `S` is largest to avoid dividing by a near-zero component).
    static func axisAngle(fromRotationRows r: [[Double]]) -> (axis: SIMD3<Double>, angleDegrees: Double) {
        let trace = r[0][0] + r[1][1] + r[2][2]
        let cosTheta = Swift.max(-1.0, Swift.min(1.0, (trace - 1) / 2))
        let theta = acos(cosTheta)

        if theta < 1e-7 {
            return (SIMD3<Double>(0, 0, 1), 0)
        }
        if Double.pi - theta < 1e-6 {
            // R = -I + 2·axis⊗axis at theta == pi: diagonal gives axis_i^2, off-diagonal
            // (averaged, for float noise) gives axis_i * axis_j.
            let sxx = Swift.max(0, (r[0][0] + 1) / 2)
            let syy = Swift.max(0, (r[1][1] + 1) / 2)
            let szz = Swift.max(0, (r[2][2] + 1) / 2)
            var axis: SIMD3<Double>
            if sxx >= syy, sxx >= szz, sxx > 1e-12 {
                let ax = sxx.squareRoot()
                axis = SIMD3<Double>(ax, (r[0][1] + r[1][0]) / 4 / ax, (r[0][2] + r[2][0]) / 4 / ax)
            } else if syy >= szz, syy > 1e-12 {
                let ay = syy.squareRoot()
                axis = SIMD3<Double>((r[0][1] + r[1][0]) / 4 / ay, ay, (r[1][2] + r[2][1]) / 4 / ay)
            } else if szz > 1e-12 {
                let az = szz.squareRoot()
                axis = SIMD3<Double>((r[0][2] + r[2][0]) / 4 / az, (r[1][2] + r[2][1]) / 4 / az, az)
            } else {
                axis = SIMD3<Double>(0, 0, 1)
            }
            let len = simd_length(axis)
            return (len > 1e-9 ? axis / len : SIMD3<Double>(0, 0, 1), 180)
        }

        let s = sin(theta)
        let axis = SIMD3<Double>(
            (r[2][1] - r[1][2]) / (2 * s),
            (r[0][2] - r[2][0]) / (2 * s),
            (r[1][0] - r[0][1]) / (2 * s)
        )
        let len = simd_length(axis)
        return (len > 1e-9 ? axis / len : SIMD3<Double>(0, 0, 1), theta * 180 / .pi)
    }

    private static func fmt(_ v: Double) -> String { String(format: "%.3f", v) }
}
