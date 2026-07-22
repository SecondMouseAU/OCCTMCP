// MeshZoneTools — `segment_mesh_zones` (#101). The MCP surface over
// OCCTSwiftMesh's `Mesh.segmented(_:)` (dihedral region-growing with
// primitive-fit merge, SecondMouseAU/OCCTSwiftMesh#16/#17): splits a body's
// mesh into surface zones (plane / cylinder / sphere / cone), each with a
// stable `zone:<bodyId>#<n>` id minted into ZoneRegistry so a later
// `zone_continuity_sweep` (#102) can resolve one without re-segmenting.
//
// Pipeline: load body -> mesh (same MeshParameters recipe as
// DeviationTools.TriMesh) -> segmented(options) -> zone table (largest-first,
// matching SegmentedMesh.regions' own order) -> mint into ZoneRegistry ->
// optional categorical render -> optional capped sub-body registration.
//
// Rendering reuses HeatmapTools' proven trick: OffscreenRenderer has no
// per-triangle SURFACE color pass, so each zone becomes its own flat-colored
// `ViewportBody.directMesh` group, composited with a legend.
//
// adjacentZones (#101 design decision): triangle-level adjacency is only
// meaningful on a WELDED mesh (OCCTSwiftMesh's own docs), but the only public
// weld entry point, `Mesh.welded(tolerance:)`, also silently DROPS degenerate
// triangles — which would shift triangle indices relative to the UNWELDED
// mesh `MeshRegion.triangleIndices` (and this tool's `triangleIndices`) are
// indexed against. Rather than risk mis-attributing adjacency under that
// shift, this tool welds independently, checks the triangle COUNT survived
// unchanged (proof no triangle was dropped, so index correspondence holds
// exactly), and reports an honest empty adjacency + warning instead of
// guessing when it didn't.
//
// slippage (#109, OCCTSwiftMesh#26/#31 `Mesh.slippage(forTriangles:
// maxSamples:)`): the SAME correspondence problem applies, since the
// classifier also needs `vertexNormals()` off a genuinely welded mesh, and
// gets the exact same fix — reuse the one `welded` mesh + triangle-count
// guard above rather than welding a second time or risking a second silent
// index shift. When the guard fails, slippage is omitted (nil) per zone
// alongside `adjacentZones`, with its own warning in the same wording
// family. `axisDirection`'s sign is arbitrary and its meaning is
// kind-dependent (surface NORMAL for plane, no axis at all for sphere) —
// see `ZoneSlippage`'s doc comment in ZoneRegistry.swift.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftMesh
import OCCTSwiftViewport
import ScriptHarness

public enum MeshZoneTools {

    public struct ZoneReport: Encodable {
        public let bodyId: String
        public let zoneCount: Int
        public let truncatedTriangleCount: Int
        public let zones: [ZoneEntry]
        public let renderPath: String?
        public let registeredBodyIds: [String]?
        public let warnings: [String]

        public struct ZoneEntry: Encodable {
            public let id: String
            public let triangleCount: Int
            public let areaMm2: Double
            public let areaFraction: Double
            public let bbox: BBox
            public let meanNormal: [Double]
            public let boundaryLoops: Int
            public let adjacentZones: [String]
            public let fit: FitEntry
            public let slippage: ZoneSlippage?
        }
        public struct BBox: Encodable {
            public let min: [Double]
            public let max: [Double]
        }
        public struct FitEntry: Encodable {
            public let kind: String
            public let params: [Double]
            public let residualRmsMm: Double
            public let residualMaxMm: Double
            public let inlierRatio: Double
        }
    }

    @MainActor
    public static func segmentMeshZones(
        bodyId: String,
        maxDihedralDegrees: Double = 20,
        mergeToleranceMm: Double? = nil,
        minRegionTriangles: Int = 8,
        maxZones: Int = 64,
        deflection: Double? = nil,
        registerZones: Bool = false,
        registerCap: Int = 32,
        render: Bool = true,
        renderPath: String? = nil,
        options: RenderPreviewTool.Options = .init(),
        registry: ZoneRegistry = .shared,
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

        var meshParams = MeshParameters.default
        meshParams.deflection = defl
        meshParams.internalVertices = true
        meshParams.inParallel = true
        meshParams.allowQualityDecrease = true
        guard let mesh = shape.mesh(parameters: meshParams), mesh.triangleCount > 0 else {
            return .init("Failed to tessellate '\(bodyId)'.", isError: true)
        }

        let bb = shape.bounds
        let bboxDiag = Double(simd_length(bb.max - bb.min))

        var segOptions = Mesh.SegmentOptions()
        segOptions.maxDihedralDegrees = Float(maxDihedralDegrees)
        if let mm = mergeToleranceMm {
            segOptions.mergeRelativeTolerance = mm / max(bboxDiag, 1e-9)
        }
        segOptions.minRegionTriangles = max(1, minRegionTriangles)
        segOptions.maxRegions = maxZones

        let segmented = mesh.segmented(segOptions)
        var warnings: [String] = []
        if segmented.fitMergeSkipped {
            warnings.append(
                "fit-gated merge pass skipped: raw region count exceeded the merge cap even after " +
                "the coplanar pre-merge; zones are unmerged seed regions (coarse-tessellation " +
                "confetti was not collapsed). Consider pre-decimating with simplify_mesh or raising " +
                "minRegionTriangles."
            )
        }
        if segmented.truncatedTriangleCount > 0 {
            warnings.append(
                "\(segmented.truncatedTriangleCount) triangles were excluded from every zone " +
                "(regions under minRegionTriangles=\(segOptions.minRegionTriangles), or the smallest " +
                "regions past maxZones=\(maxZones))."
            )
        }
        guard !segmented.regions.isEmpty else {
            return IntrospectionTools.encode(ZoneReport(
                bodyId: bodyId, zoneCount: 0, truncatedTriangleCount: segmented.truncatedTriangleCount,
                zones: [], renderPath: nil, registeredBodyIds: nil,
                warnings: warnings + ["Segmentation produced no zones."]
            ))
        }

        let totalArea = totalMeshArea(mesh)
        let faceNormals = mesh.faceNormals()
        let verts = mesh.vertices
        let idx = mesh.indices

        let zoneIds = (0..<segmented.regions.count).map { "zone:\(bodyId)#\($0)" }

        // adjacentZones: see the file header for why this needs an
        // independent weld + a triangle-count guard rather than trusting
        // index correspondence blindly.
        let welded = mesh.welded()
        var adjacentZones = [[String]](repeating: [], count: segmented.regions.count)
        var zoneSlippage = [ZoneSlippage?](repeating: nil, count: segmented.regions.count)
        if welded.triangleCount == mesh.triangleCount {
            let adjacency = welded.triangleAdjacency()
            var triToZone = [Int: Int](minimumCapacity: mesh.triangleCount)
            for (zi, region) in segmented.regions.enumerated() {
                for t in region.triangleIndices { triToZone[t] = zi }
            }
            var adjSets = [Set<Int>](repeating: [], count: segmented.regions.count)
            for t in 0..<welded.triangleCount {
                guard let za = triToZone[t] else { continue }
                for nb in adjacency[t] {
                    guard let zb = triToZone[nb], zb != za else { continue }
                    adjSets[za].insert(zb)
                }
            }
            for zi in adjSets.indices { adjacentZones[zi] = adjSets[zi].sorted().map { zoneIds[$0] } }

            for (zi, region) in segmented.regions.enumerated() {
                let slip = welded.slippage(forTriangles: region.triangleIndices, maxSamples: 2000)
                zoneSlippage[zi] = ZoneSlippage(
                    kind: slip.kind.rawValue,
                    axisPoint: slip.axisPoint.map { [$0.x, $0.y, $0.z] },
                    axisDirection: slip.axisDirection.map { [$0.x, $0.y, $0.z] },
                    pitchPerRadianMm: slip.pitch,
                    confidence: slip.confidence
                )
            }
        } else {
            warnings.append("adjacentZones omitted: welding the mesh to compute adjacency dropped degenerate triangles, breaking triangle-index correspondence.")
            warnings.append("slippage omitted: welding the mesh to compute it dropped degenerate triangles, breaking triangle-index correspondence.")
        }

        var entries: [ZoneReport.ZoneEntry] = []
        var zoneRecords: [ZoneRecord] = []
        entries.reserveCapacity(segmented.regions.count)
        zoneRecords.reserveCapacity(segmented.regions.count)

        let paramsUsed = SegmentParamsUsed(
            maxDihedralDegrees: maxDihedralDegrees,
            mergeRelativeTolerance: Double(segOptions.mergeRelativeTolerance),
            maxMergeAngleDegrees: Double(segOptions.maxMergeAngleDegrees),
            minRegionTriangles: segOptions.minRegionTriangles,
            maxZones: maxZones,
            deflection: defl
        )
        let signature = MeshSignature(
            triangleCount: mesh.triangleCount,
            bboxMin: [Double(bb.min.x), Double(bb.min.y), Double(bb.min.z)],
            bboxMax: [Double(bb.max.x), Double(bb.max.y), Double(bb.max.z)]
        )

        for (zi, region) in segmented.regions.enumerated() {
            var lo = SIMD3<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude, .greatestFiniteMagnitude)
            var hi = SIMD3<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
            var normalSum = SIMD3<Double>(0, 0, 0)
            for t in region.triangleIndices {
                for k in 0..<3 {
                    let v = verts[Int(idx[t * 3 + k])]
                    lo = simd_min(lo, v)
                    hi = simd_max(hi, v)
                }
                let n = faceNormals[t]
                normalSum += SIMD3<Double>(Double(n.x), Double(n.y), Double(n.z))
            }
            let normalLen = simd_length(normalSum)
            let meanNormal = normalLen > 1e-12 ? normalSum / normalLen : SIMD3<Double>(0, 0, 0)

            var boundaryCount = 0
            if let sub = mesh.subMesh(triangleIndices: region.triangleIndices) {
                boundaryCount = sub.welded().boundaryLoops().count
            }

            let fit = segmented.fits[zi]
            let fitEntry = ZoneReport.FitEntry(
                kind: fit.kind.rawValue, params: fit.params,
                residualRmsMm: fit.residualRMS, residualMaxMm: fit.residualMax, inlierRatio: fit.inlierRatio
            )

            entries.append(ZoneReport.ZoneEntry(
                id: zoneIds[zi],
                triangleCount: region.triangleIndices.count,
                areaMm2: region.area,
                areaFraction: totalArea > 1e-12 ? region.area / totalArea : 0,
                bbox: .init(min: [Double(lo.x), Double(lo.y), Double(lo.z)], max: [Double(hi.x), Double(hi.y), Double(hi.z)]),
                meanNormal: [meanNormal.x, meanNormal.y, meanNormal.z],
                boundaryLoops: boundaryCount,
                adjacentZones: adjacentZones[zi],
                fit: fitEntry,
                slippage: zoneSlippage[zi]
            ))
            zoneRecords.append(ZoneRecord(
                zoneId: zoneIds[zi], bodyId: bodyId, index: zi,
                triangleIndices: region.triangleIndices, areaMm2: region.area,
                fit: ZoneFit(kind: fit.kind.rawValue, params: fit.params, residualRmsMm: fit.residualRMS,
                             residualMaxMm: fit.residualMax, inlierRatio: fit.inlierRatio),
                params: paramsUsed, meshSignature: signature, slippage: zoneSlippage[zi]
            ))
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent
        let zonesStore = ZonesStore(outputDir: outputDir)
        await registry.loadSidecarIfNeeded(store: zonesStore)
        await registry.recordBatch(zoneRecords, store: zonesStore)

        // ── optional render ────────────────────────────────────────────
        var writtenRenderPath: String? = nil
        if render {
            let path = renderPath ?? "\(outputDir)/\(bodyId)_zones.png"
            if segmented.regions.count > ChartRenderer.categoricalPalette.count {
                warnings.append(
                    "\(segmented.regions.count) zones exceed the \(ChartRenderer.categoricalPalette.count)-color palette; colors repeat past #\(ChartRenderer.categoricalPalette.count - 1) and are not visually distinct beyond it."
                )
            }
            if let err = renderZones(
                mesh: mesh, regions: segmented.regions, bodyId: bodyId,
                outputPath: path, options: options
            ) {
                warnings.append("Render failed: \(err)")
            } else {
                writtenRenderPath = path
            }
        }

        // ── optional sub-body registration ─────────────────────────────
        var registeredBodyIds: [String]? = nil
        if registerZones {
            let cap = max(0, registerCap)
            let toRegister = Array(segmented.regions.prefix(cap))
            if segmented.regions.count > cap {
                warnings.append("registerCap=\(cap) truncated registration: \(segmented.regions.count - cap) zones were not registered as bodies.")
            }
            var ids: [String] = []
            var manifest = (try? store.read()) ?? ScriptManifest(description: nil, bodies: [])
            let bodyName = loaded.body.name ?? bodyId
            for (zi, region) in toRegister.enumerated() {
                guard let sub = mesh.subMesh(triangleIndices: region.triangleIndices) else {
                    warnings.append("zone:\(bodyId)#\(zi): subMesh extraction failed, skipped registration.")
                    continue
                }
                let outId = "\(bodyId)_zone\(zi)"
                if manifest.bodies.contains(where: { $0.id == outId }) {
                    warnings.append("Body id \"\(outId)\" already exists; skipped registration for zone:\(bodyId)#\(zi).")
                    continue
                }
                let tmpSTL = NSTemporaryDirectory() + "occtmcp-zone-\(UUID().uuidString).stl"
                defer { try? FileManager.default.removeItem(atPath: tmpSTL) }
                do {
                    try MeshTools.writeMesh(mesh: sub, path: tmpSTL)
                    let zoneShape = try Shape.loadSTL(fromPath: tmpSTL)
                    let outFile = "\(outId).brep"
                    try Exporter.writeBREP(shape: zoneShape, to: URL(fileURLWithPath: "\(outputDir)/\(outFile)"), allowInvalid: true)
                    manifest = ScriptManifest(
                        version: manifest.version, timestamp: Date(), description: manifest.description,
                        bodies: manifest.bodies + [BodyDescriptor(id: outId, file: outFile, name: "\(bodyName) zone \(zi)")],
                        graphs: manifest.graphs, metadata: manifest.metadata
                    )
                    ids.append(outId)
                } catch {
                    warnings.append("zone:\(bodyId)#\(zi) registration failed: \(error.localizedDescription)")
                }
            }
            if !ids.isEmpty {
                await SceneHistory.shared.snapshot(store: store)
                try? store.write(manifest)
            }
            registeredBodyIds = ids
        }

        return IntrospectionTools.encode(ZoneReport(
            bodyId: bodyId, zoneCount: entries.count, truncatedTriangleCount: segmented.truncatedTriangleCount,
            zones: entries, renderPath: writtenRenderPath, registeredBodyIds: registeredBodyIds,
            warnings: warnings
        ))
    }

    // MARK: - Rendering (band-group trick, mirrors HeatmapTools)

    @MainActor
    private static func renderZones(
        mesh: Mesh, regions: [MeshRegion], bodyId: String, outputPath: String,
        options: RenderPreviewTool.Options
    ) -> String? {
        let verts = mesh.vertices
        let normals = mesh.normals
        let idx = mesh.indices
        let hasNormals = normals.count == verts.count
        let faceNormals = mesh.faceNormals()

        func buildBody(id: String, tris: [Int], color: SIMD4<Float>) -> ViewportBody {
            var positions: [Float] = []
            var bnormals: [Float] = []
            var indices: [UInt32] = []
            positions.reserveCapacity(tris.count * 9)
            bnormals.reserveCapacity(tris.count * 9)
            indices.reserveCapacity(tris.count * 3)
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

        var bodies: [ViewportBody] = []
        var legend: [(label: String, color: SIMD4<Float>)] = []
        for (zi, region) in regions.enumerated() where !region.triangleIndices.isEmpty {
            let color = ChartRenderer.categoricalColor(zi)
            bodies.append(buildBody(id: "\(bodyId)#zone\(zi)", tris: region.triangleIndices, color: color))
            legend.append((label: "zone#\(zi) (\(region.triangleIndices.count) tri)", color: color))
        }
        guard !bodies.isEmpty else { return "no zone triangles to render" }

        guard let renderer = OffscreenRenderer() else {
            return "OffscreenRenderer init failed (no Metal device available)."
        }
        var ro = OffscreenRenderOptions(
            width: options.width, height: options.height,
            displayMode: .shaded, backgroundColor: options.background.color
        )
        ro.cameraState = RenderPreviewTool.makeCameraState(options: options, bodies: bodies)

        let url = URL(fileURLWithPath: outputPath)
        do {
            _ = try renderer.renderToPNG(bodies: bodies, url: url, options: ro)
        } catch {
            return error.localizedDescription
        }
        try? ChartRenderer.overlayZoneLegend(on: url, entries: legend)
        return nil
    }

    // MARK: - Helpers

    static func totalMeshArea(_ mesh: Mesh) -> Double {
        let verts = mesh.vertices
        let idx = mesh.indices
        var sum = 0.0
        var t = 0
        while t + 2 < idx.count {
            let a = verts[Int(idx[t])], b = verts[Int(idx[t + 1])], c = verts[Int(idx[t + 2])]
            sum += Double(simd_length(simd_cross(b - a, c - a)) * 0.5)
            t += 3
        }
        return sum
    }
}
