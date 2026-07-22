// ZoneSweepTool — `zone_continuity_sweep` (#102). A zone's (or a whole
// body's) loftable-extent map: slice along an axis, compare each station's
// profile against a running reference, and report the maximal within-
// tolerance runs (the completable / loftable extents) plus the deviation
// intervals between them.
//
// Composition, not a new engine: resolves the zone's triangles from
// ZoneRegistry (#101) or the whole mesh, `subMesh`s them, then slices with
// the SAME `Mesh.crossSection` / shared-`CutPlane`-frame machinery
// `cross_section_compare` uses (CrossSectionCompareTool.mesh/.projectRange,
// ProfileMath for the profile itself). Slicing only the zone's own triangles
// is what keeps a neighbouring feature (a door recess, say) from polluting a
// side panel's own verdict at a station it doesn't actually touch.
//
// Per the mandatory-analytic-verification policy this tool's aggregation
// logic (ZoneSweepMath below) is independent of any OCCTReconstruct code;
// it is written here, from OCCTSwiftMesh primitives only.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftMesh
import OCCTSwiftViewport
import ScriptHarness

public enum ZoneSweepTool {

    // MARK: - Pure change-point logic (testable without geometry)

    /// A per-station comparison against a fixed reference station's profile.
    public struct Signals: Sendable {
        public let lateralOffsetMm: Double
        public let profileRmsMm: Double
        public let profileMaxMm: Double
        public let arcLengthDeltaMm: Double
        public init(lateralOffsetMm: Double, profileRmsMm: Double, profileMaxMm: Double, arcLengthDeltaMm: Double) {
            self.lateralOffsetMm = lateralOffsetMm
            self.profileRmsMm = profileRmsMm
            self.profileMaxMm = profileMaxMm
            self.arcLengthDeltaMm = arcLengthDeltaMm
        }
    }

    public enum Verdict: String, Sendable { case constant, deviating, missed }

    public struct RunInterval: Sendable {
        public let startIndex: Int
        public let endIndex: Int      // inclusive, always a non-missed station
        public let kind: String       // "constant" | "deviation"
    }

    /// Greedy run-building over station indices `0..<stationCount`.
    ///
    /// A station joins the CURRENT run while its signals (measured against
    /// the run's reference, the first in-tolerance station of that run) are
    /// within tolerance; otherwise the run closes and a deviation interval
    /// opens, comparing every subsequent station against that SAME
    /// (now-closed) reference until one returns within tolerance, at which
    /// point the deviation interval closes and a NEW run starts with a
    /// fresh reference (that station). Missed stations are skipped
    /// entirely: excluded from every run's start/end and never disturb the
    /// active reference.
    ///
    /// `missed(i)` flags a station with no usable profile at all.
    /// `signals(reference, candidate)` computes candidate's signals against
    /// `reference`'s profile; nil means the pair genuinely can't be compared
    /// (treated conservatively as deviating, never silently dropped).
    public static func detectRunsAndDeviations(
        stationCount: Int,
        missed: (Int) -> Bool,
        signals: (_ reference: Int, _ candidate: Int) -> Signals?,
        toleranceMm: Double,
        lateralToleranceMm: Double
    ) -> (verdicts: [Verdict], runs: [RunInterval]) {
        var verdicts = [Verdict](repeating: .missed, count: stationCount)
        guard stationCount > 0, let first = (0..<stationCount).first(where: { !missed($0) }) else {
            return (verdicts, [])
        }
        verdicts[first] = .constant

        var runs: [RunInterval] = []
        var reference = first
        var runStart = first
        var deviationStart = -1
        var inDeviation = false
        var prevIndex = first

        func within(_ s: Signals) -> Bool {
            abs(s.lateralOffsetMm) <= lateralToleranceMm && abs(s.profileRmsMm) <= toleranceMm
        }

        var i = first + 1
        while i < stationCount {
            if missed(i) { verdicts[i] = .missed; i += 1; continue }
            let ok: Bool
            if let s = signals(reference, i) {
                ok = within(s)
            } else {
                ok = false   // incomparable pair: treat conservatively, never silently constant
            }
            if ok {
                if inDeviation {
                    runs.append(RunInterval(startIndex: deviationStart, endIndex: prevIndex, kind: "deviation"))
                    inDeviation = false
                    runStart = i
                    reference = i
                }
                verdicts[i] = .constant
            } else {
                if !inDeviation {
                    runs.append(RunInterval(startIndex: runStart, endIndex: prevIndex, kind: "constant"))
                    inDeviation = true
                    deviationStart = i
                }
                verdicts[i] = .deviating
            }
            prevIndex = i
            i += 1
        }
        if inDeviation {
            runs.append(RunInterval(startIndex: deviationStart, endIndex: prevIndex, kind: "deviation"))
        } else {
            runs.append(RunInterval(startIndex: runStart, endIndex: prevIndex, kind: "constant"))
        }
        return (verdicts, runs)
    }

    /// Slippage kinds (#109, OCCTSwiftMesh#26/#31) whose `axisDirection` is a
    /// valid SWEEP direction. Plane's axis is the surface NORMAL — sweeping
    /// along it is exactly wrong, not merely unhelpful. Sphere has no
    /// preferred axis at all, and freeform has neither; both are excluded by
    /// construction (their `ZoneSlippage.axisDirection` is `nil`), but kept
    /// out of this set explicitly too, defense in depth against a future
    /// upstream change populating it.
    static let axisEligibleSlippageKinds: Set<String> = ["cylinder", "extrusion", "revolution", "helix"]

    /// Confidence floor below which a slippage classification is too
    /// uncertain to default the sweep axis to. Mirrors the upstream
    /// semantics of `SlippageResult.confidence` (a spectral-gap diagnostic,
    /// not a probability — docs/algorithms/slippage.md, OCCTSwiftMesh#26/
    /// #31): a gap barely past the detection floor means the classification
    /// itself is close to arbitrary, which is exactly the case a near-
    /// symmetric body (no clean eigenvalue separation to begin with)
    /// produces.
    static let slippageAxisConfidenceFloor = 0.25

    /// The resolved sweep axis plus which rung resolved it, so the caller
    /// can report `axisSource` faithfully.
    public struct AxisSelection: Sendable {
        public let axis: SIMD3<Double>?
        public let source: String   // "explicit" | "slippage" | "pca"
        public let warning: String?
    }

    /// Picks the sweep axis in priority order — pure and geometry-free (the
    /// actual PCA computation, when this returns `axis: nil`, is the
    /// caller's job; this only decides WHETHER to use it):
    ///
    /// 1. An explicit caller-supplied axis always wins outright.
    /// 2. Otherwise, a zoneId-scoped sweep (`record` non-nil) whose stored
    ///    `ZoneRecord.slippage` has a kind in `axisEligibleSlippageKinds`, a
    ///    non-nil `axisDirection`, AND `confidence >= slippageAxisConfidenceFloor`
    ///    defaults to that axis.
    /// 3. Anything else (no record, no slippage, an ineligible kind, or a
    ///    low-confidence eligible kind) falls back to PCA — the low-
    ///    confidence case additionally returns a warning naming the kind and
    ///    confidence that was rejected.
    static func selectSweepAxis(record: ZoneRecord?, explicit: SIMD3<Double>?) -> AxisSelection {
        if let explicit {
            return AxisSelection(axis: explicit, source: "explicit", warning: nil)
        }
        guard let slip = record?.slippage else {
            return AxisSelection(axis: nil, source: "pca", warning: nil)
        }
        guard axisEligibleSlippageKinds.contains(slip.kind),
              let dir = slip.axisDirection, dir.count == 3 else {
            return AxisSelection(axis: nil, source: "pca", warning: nil)
        }
        guard slip.confidence >= slippageAxisConfidenceFloor else {
            return AxisSelection(
                axis: nil, source: "pca",
                warning: "zone has a low-confidence slippage classification (\(slip.kind), confidence \(slip.confidence)); sweep axis fell back to PCA"
            )
        }
        return AxisSelection(axis: SIMD3(dir[0], dir[1], dir[2]), source: "slippage", warning: nil)
    }

    /// Dominant eigenvector of a point cloud's covariance (power iteration,
    /// ~50 steps: cheap and sufficient for a station axis, no Accelerate
    /// dependency needed). Sign is arbitrary (a flipped axis just reverses
    /// station order; still a correct sweep). Falls back to +Z for a
    /// degenerate (empty / all-coincident) input.
    static func principalAxis(of points: [SIMD3<Double>]) -> SIMD3<Double> {
        guard points.count >= 2 else { return SIMD3(0, 0, 1) }
        var mean = SIMD3<Double>(0, 0, 0)
        for p in points { mean += p }
        mean /= Double(points.count)

        var cxx = 0.0, cxy = 0.0, cxz = 0.0, cyy = 0.0, cyz = 0.0, czz = 0.0
        for p in points {
            let d = p - mean
            cxx += d.x * d.x; cxy += d.x * d.y; cxz += d.x * d.z
            cyy += d.y * d.y; cyz += d.y * d.z; czz += d.z * d.z
        }
        var v = SIMD3<Double>(1, 1, 1)
        for _ in 0..<50 {
            let nv = SIMD3<Double>(
                cxx * v.x + cxy * v.y + cxz * v.z,
                cxy * v.x + cyy * v.y + cyz * v.z,
                cxz * v.x + cyz * v.y + czz * v.z
            )
            let len = simd_length(nv)
            guard len > 1e-15 else { return SIMD3(0, 0, 1) }
            v = nv / len
        }
        return v
    }

    // MARK: - Tool

    public struct SweepReport: Encodable {
        public let bodyId: String
        public let zoneId: String?
        public let axis: [Double]
        public let axisSource: String
        public let overlap: [Double]
        public let stations: [StationEntry]
        public let runs: [RunEntry]
        public let warnings: [String]
        public let renderPath: String?
        public let chartPath: String?

        public struct StationEntry: Encodable {
            public let index: Int
            public let axisCoord: Double
            public let offset: Double
            public let lateralOffsetMm: Double?
            public let profileRmsMm: Double?
            public let profileMaxMm: Double?
            public let arcLengthDeltaMm: Double?
            public let openProfile: Bool
            public let verdict: String
        }
        public struct RunEntry: Encodable {
            public let startAxisCoord: Double
            public let endAxisCoord: Double
            public let stationCount: Int
            public let kind: String
            public let maxProfileRmsMm: Double
            public let maxLateralOffsetMm: Double
        }
    }

    @MainActor
    public static func zoneContinuitySweep(
        bodyId: String,
        zoneId: String? = nil,
        axis: SIMD3<Double>? = nil,
        stations: Int = 32,
        toleranceMm: Double = 0.5,
        lateralToleranceMm: Double? = nil,
        deflection: Double? = nil,
        render: Bool = true,
        renderPath: String? = nil,
        chart: Bool = false,
        chartPath: String? = nil,
        options: RenderPreviewTool.Options = .init(),
        registry: ZoneRegistry = .shared,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard stations >= 2 else { return .init("stations must be >= 2.", isError: true) }
        let lateralTol = lateralToleranceMm ?? toleranceMm

        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape

        var warnings: [String] = []
        var zoneRecord: ZoneRecord? = nil
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let zonesStore = ZonesStore(outputDir: outputDir)

        // A zone-scoped sweep MUST re-mesh at the SAME deflection the zone
        // was segmented with, or `triangleIndices` no longer lines up with a
        // freshly-built mesh's triangle order.
        var meshDeflection = deflection ?? DeviationTools.defaultDeflection(for: shape)
        if let zid = zoneId {
            await registry.loadSidecarIfNeeded(store: zonesStore)
            guard let rec = await registry.zone(zid) else {
                return .init("Unknown zoneId \"\(zid)\". Run segment_mesh_zones first, or list_zones to see what's registered.", isError: true)
            }
            guard rec.bodyId == bodyId else {
                return .init("zoneId \"\(zid)\" belongs to body \"\(rec.bodyId)\", not \"\(bodyId)\".", isError: true)
            }
            zoneRecord = rec
            meshDeflection = rec.params.deflection
            if let requested = deflection, abs(requested - rec.params.deflection) > 1e-12 {
                warnings.append("deflection argument (\(requested)) ignored for a zoneId-scoped sweep: re-meshing at the zone's own segmentation deflection (\(rec.params.deflection)) so triangleIndices stay valid.")
            }
        }
        guard meshDeflection > 0 else { return .init("deflection must be positive.", isError: true) }

        var meshParams = MeshParameters.default
        meshParams.deflection = meshDeflection
        meshParams.internalVertices = true
        meshParams.inParallel = true
        meshParams.allowQualityDecrease = true
        guard let fullMesh = shape.mesh(parameters: meshParams), fullMesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(bodyId)'.", isError: true)
        }

        let sliceMesh: Mesh
        if let rec = zoneRecord {
            let bb = shape.bounds
            let sig = MeshSignature(
                triangleCount: fullMesh.triangleCount,
                bboxMin: [Double(bb.min.x), Double(bb.min.y), Double(bb.min.z)],
                bboxMax: [Double(bb.max.x), Double(bb.max.y), Double(bb.max.z)]
            )
            guard sig.matches(rec.meshSignature) else {
                return .init(
                    "Zone \"\(rec.zoneId)\" is stale: body \"\(bodyId)\"'s mesh no longer matches the mesh it was segmented from (triangle count / bounding box changed). Re-run segment_mesh_zones.",
                    isError: true
                )
            }
            guard let sub = fullMesh.subMesh(triangleIndices: rec.triangleIndices) else {
                return .init("Failed to extract zone \"\(rec.zoneId)\"'s triangles from the current mesh.", isError: true)
            }
            sliceMesh = sub
        } else {
            sliceMesh = fullMesh
        }

        // ── axis + station placement (mirrors CrossSectionCompareTool) ──
        let sliceVerts = sliceMesh.vertices
        guard !sliceVerts.isEmpty else { return .init("Zone/body has no triangles to sweep.", isError: true) }

        // Axis resolution: explicit > zone's own slippage axis (cylinder/
        // extrusion/revolution/helix only, confidence-gated) > PCA. See
        // `selectSweepAxis`'s doc comment for the full rule; a whole-body
        // sweep (zoneRecord == nil) can never see rung 2 since there is no
        // zone-scoped slippage classification to consult.
        let selection = selectSweepAxis(record: zoneRecord, explicit: axis)
        if let w = selection.warning { warnings.append(w) }

        let axisSource: String
        let axisUnit: SIMD3<Double>
        if let a = selection.axis {
            guard simd_length(a) > 1e-12 else { return .init("axis must be non-zero.", isError: true) }
            axisUnit = simd_normalize(a)
            axisSource = selection.source
        } else {
            let pts = sliceVerts.map { SIMD3<Double>(Double($0.x), Double($0.y), Double($0.z)) }
            axisUnit = principalAxis(of: pts)
            axisSource = "pca"
        }
        let axisF = SIMD3<Float>(Float(axisUnit.x), Float(axisUnit.y), Float(axisUnit.z))

        var meanV = SIMD3<Float>(0, 0, 0)
        for v in sliceVerts { meanV += v }
        meanV /= Float(sliceVerts.count)
        let through = SIMD3<Double>(Double(meanV.x), Double(meanV.y), Double(meanV.z))

        let (loF, hiF) = CrossSectionCompareTool.projectRange(sliceVerts, origin: meanV, axis: axisF)
        let lo = Double(loF), hi = Double(hiF)
        guard hi - lo > 1e-9 else { return .init("Zone/body has no extent along the sweep axis.", isError: true) }
        let margin = (hi - lo) * 0.02
        let start = lo + margin, end = hi - margin
        let span = max(1e-9, end - start)
        let step = span / Double(stations - 1)
        let axisBase = simd_dot(through, axisUnit)

        var profiles: [ProfileMath.Profile?] = []
        var stationAxisCoords: [Double] = []
        var stationOffsets: [Double] = []
        profiles.reserveCapacity(stations)
        for s in 0..<stations {
            let t = start + Double(s) * step
            let plane = CutPlane(point: through + axisUnit * t, normal: axisUnit)
            let sec = sliceMesh.crossSection(plane: plane)
            let profile = ProfileMath.mainProfile(closed: sec?.contours ?? [], open: sec?.openPaths ?? [])
            profiles.append(profile?.usable == true ? profile : nil)
            stationAxisCoords.append(axisBase + t)
            stationOffsets.append(t - lo)
        }

        let missedCount = profiles.filter { $0 == nil }.count
        if missedCount > 0 {
            warnings.append("\(missedCount)/\(stations) stations missed the zone/body entirely (no profile at that plane); excluded from runs.")
        }

        let (verdicts, runs) = detectRunsAndDeviations(
            stationCount: stations,
            missed: { profiles[$0] == nil },
            signals: { ref, cand in
                guard let r = profiles[ref], let c = profiles[cand],
                      let d = ProfileMath.profileDelta(reference: r, candidate: c) else { return nil }
                return Signals(lateralOffsetMm: d.lateralOffsetMm, profileRmsMm: d.rmsMm,
                               profileMaxMm: d.maxMm, arcLengthDeltaMm: d.arcLengthDeltaMm)
            },
            toleranceMm: toleranceMm, lateralToleranceMm: lateralTol
        )

        // Per-station reported signals: relative to whatever reference was
        // ACTIVE for that station in the run-building pass above (that
        // run's own reference for a constant run; the closed constant run's
        // reference for the deviation interval that follows it). Recomputed
        // here (not threaded out of the pure pass) since
        // detectRunsAndDeviations only returns verdicts + runs. `runs` is
        // built strictly in chronological order and always starts with a
        // "constant" kind (the seed station is always constant, even if
        // it's a run of one), so a running `lastConstantStart` suffices.
        var referenceForStation = [Int](repeating: -1, count: stations)
        var lastConstantStart = -1
        for run in runs {
            if run.kind == "constant" { lastConstantStart = run.startIndex }
            let ref = run.kind == "constant" ? run.startIndex : lastConstantStart
            for s in run.startIndex...run.endIndex where profiles[s] != nil { referenceForStation[s] = ref }
        }

        var stationEntries: [SweepReport.StationEntry] = []
        stationEntries.reserveCapacity(stations)
        for s in 0..<stations {
            guard let profile = profiles[s] else {
                stationEntries.append(.init(
                    index: s, axisCoord: stationAxisCoords[s], offset: stationOffsets[s],
                    lateralOffsetMm: nil, profileRmsMm: nil, profileMaxMm: nil, arcLengthDeltaMm: nil,
                    openProfile: false, verdict: Verdict.missed.rawValue
                ))
                continue
            }
            let ref = referenceForStation[s]
            let d = ref >= 0 ? profiles[ref].flatMap { ProfileMath.profileDelta(reference: $0, candidate: profile) } : nil
            stationEntries.append(.init(
                index: s, axisCoord: stationAxisCoords[s], offset: stationOffsets[s],
                lateralOffsetMm: d?.lateralOffsetMm ?? 0, profileRmsMm: d?.rmsMm ?? 0,
                profileMaxMm: d?.maxMm ?? 0, arcLengthDeltaMm: d?.arcLengthDeltaMm ?? 0,
                openProfile: !profile.closed, verdict: verdicts[s].rawValue
            ))
        }

        let runEntries: [SweepReport.RunEntry] = runs.map { run in
            var maxRms = 0.0, maxLateral = 0.0
            for s in run.startIndex...run.endIndex {
                guard let e = stationEntries[safe: s], let rms = e.profileRmsMm, let lateral = e.lateralOffsetMm else { continue }
                maxRms = max(maxRms, abs(rms))
                maxLateral = max(maxLateral, abs(lateral))
            }
            return SweepReport.RunEntry(
                startAxisCoord: stationAxisCoords[run.startIndex], endAxisCoord: stationAxisCoords[run.endIndex],
                stationCount: run.endIndex - run.startIndex + 1, kind: run.kind,
                maxProfileRmsMm: maxRms, maxLateralOffsetMm: maxLateral
            )
        }

        // ── optional render: zone/body triangles colored by nearest-station verdict ──
        var writtenRenderPath: String? = nil
        if render {
            let path = renderPath ?? "\(outputDir)/\(bodyId)\(zoneId.map { "_" + $0.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "#", with: "_") } ?? "")_sweep.png"
            if let err = renderVerdicts(
                mesh: sliceMesh, axis: axisUnit,
                stationAxisCoords: stationAxisCoords,
                verdicts: verdicts, bodyId: bodyId, outputPath: path, options: options
            ) {
                warnings.append("Render failed: \(err)")
            } else {
                writtenRenderPath = path
            }
        }

        // ── optional strip chart ─────────────────────────────────────────
        var writtenChartPath: String? = nil
        if chart {
            let path = chartPath ?? "\(outputDir)/\(bodyId)_sweep_chart.png"
            let series = stationEntries.compactMap { e -> (axisCoord: Double, value: Double)? in
                guard let rms = e.profileRmsMm else { return nil }
                return (e.axisCoord, rms)
            }
            do {
                try ChartRenderer.stripChart(
                    stations: series, tolerance: toleranceMm,
                    title: "profileRmsMm vs axisCoord (\(zoneId ?? bodyId))", yLabel: "profileRmsMm",
                    to: URL(fileURLWithPath: path)
                )
                writtenChartPath = path
            } catch {
                warnings.append("Chart failed: \(error.localizedDescription)")
            }
        }

        return IntrospectionTools.encode(SweepReport(
            bodyId: bodyId, zoneId: zoneId, axis: [axisUnit.x, axisUnit.y, axisUnit.z], axisSource: axisSource,
            overlap: [lo, hi], stations: stationEntries, runs: runEntries, warnings: warnings,
            renderPath: writtenRenderPath, chartPath: writtenChartPath
        ))
    }

    // MARK: - Rendering (band-group trick, mirrors HeatmapTools/MeshZoneTools)

    @MainActor
    private static func renderVerdicts(
        mesh: Mesh, axis: SIMD3<Double>,
        stationAxisCoords: [Double], verdicts: [Verdict],
        bodyId: String, outputPath: String, options: RenderPreviewTool.Options
    ) -> String? {
        let verts = mesh.vertices
        let normals = mesh.normals
        let idx = mesh.indices
        let hasNormals = normals.count == verts.count
        let faceNormals = mesh.faceNormals()
        let triCount = idx.count / 3
        guard triCount > 0, !stationAxisCoords.isEmpty else { return "no triangles to render" }

        func nearestVerdict(_ centroid: SIMD3<Double>) -> Verdict {
            let coord = simd_dot(centroid, axis)
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, c) in stationAxisCoords.enumerated() {
                let d = abs(c - coord)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            return verdicts[bestIdx]
        }

        var groups: [Verdict: [Int]] = [.constant: [], .deviating: [], .missed: []]
        for t in 0..<triCount {
            let a = verts[Int(idx[t * 3])], b = verts[Int(idx[t * 3 + 1])], c = verts[Int(idx[t * 3 + 2])]
            let centroid = SIMD3<Double>(Double((a.x + b.x + c.x) / 3), Double((a.y + b.y + c.y) / 3), Double((a.z + b.z + c.z) / 3))
            groups[nearestVerdict(centroid), default: []].append(t)
        }

        func buildBody(id: String, tris: [Int], color: SIMD4<Float>) -> ViewportBody {
            var positions: [Float] = []
            var bnormals: [Float] = []
            var indices: [UInt32] = []
            for t in tris {
                let ia = Int(idx[t * 3]), ib = Int(idx[t * 3 + 1]), ic = Int(idx[t * 3 + 2])
                let pa = verts[ia], pb = verts[ib], pc = verts[ic]
                let fn = faceNormals[t]
                for (vi, p) in [(ia, pa), (ib, pb), (ic, pc)] {
                    positions.append(p.x); positions.append(p.y); positions.append(p.z)
                    let nrm = hasNormals ? normals[vi] : fn
                    bnormals.append(nrm.x); bnormals.append(nrm.y); bnormals.append(nrm.z)
                }
                let base = UInt32(indices.count)
                indices.append(base); indices.append(base + 1); indices.append(base + 2)
            }
            return ViewportBody.directMesh(id: id, positions: positions, normals: bnormals, indices: indices, color: color)
        }

        let colors: [Verdict: SIMD4<Float>] = [
            .constant: SIMD4(0.20, 0.42, 0.86, 1),    // blue
            .deviating: SIMD4(0.86, 0.20, 0.18, 1),   // red
            .missed: SIMD4(0.55, 0.55, 0.55, 1),      // grey
        ]
        var bodies: [ViewportBody] = []
        for verdict in [Verdict.constant, .deviating, .missed] {
            guard let tris = groups[verdict], !tris.isEmpty else { continue }
            bodies.append(buildBody(id: "sweep#\(verdict.rawValue)", tris: tris, color: colors[verdict]!))
        }
        guard !bodies.isEmpty else { return "no coloured surface produced" }

        guard let renderer = OffscreenRenderer() else {
            return "OffscreenRenderer init failed (no Metal device available)."
        }
        var ro = OffscreenRenderOptions(width: options.width, height: options.height, displayMode: .shaded, backgroundColor: options.background.color)
        ro.cameraState = RenderPreviewTool.makeCameraState(options: options, bodies: bodies)
        let url = URL(fileURLWithPath: outputPath)
        do {
            _ = try renderer.renderToPNG(bodies: bodies, url: url, options: ro)
        } catch {
            return error.localizedDescription
        }
        let legend: [(label: String, color: SIMD4<Float>)] = [
            ("constant", colors[.constant]!), ("deviating", colors[.deviating]!), ("missed/sparse", colors[.missed]!),
        ]
        try? ChartRenderer.overlayZoneLegend(on: url, entries: legend)
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
