// MeshFeatureTools — `detect_mesh_features` (#108, closes the crease-
// detection piece of the mesh-analysis expansion's Phase 3 backlog;
// unblocked by SecondMouseAU/OCCTSwiftMesh#28, shipped in OCCTSwiftMesh
// v1.7.0 alongside #27's RANSAC primitive fitting).
//
// Crease-ring feature outlines (doors, panels, window returns, recesses) on
// raw scan meshes where `recognize_features` (BREP/AAG) cannot operate at
// all — a scanned/STL body has no B-rep face/edge structure to recognize
// features against in the first place.
//
// PIPELINE — loadShape -> mesh (the standard MeshParameters recipe shared
// with DeviationTools/MeshZoneTools/MeshCurvatureTools) -> `mesh.welded()`
// -> `welded.creaseEdges(minAngleDegrees:)`. Detection, reporting, AND
// render geometry all live on the WELDED mesh — `CreaseRing.vertexIndices`
// indexes it directly — so there is no triangle/vertex-index correspondence
// problem between the stats and the render to guard against, the same
// MANDATORY-weld-first shape MeshCurvatureTools documents for
// `vertexCurvatures()`: `creaseEdges()`'s own precondition is a welded mesh
// (on unwelded input every edge is used by exactly one triangle, so the
// dihedral angle is undefined and every edge comes back "boundary," never
// "crease" — see OCCTSwiftMesh's docs/algorithms/crease-detection.md).
//
// UNWELDABLE-SOUP WARNING — the same topology-fact trigger MeshCurvatureTools
// uses (`welded.vertexCount == welded.triangleCount * 3`, i.e. the weld pass
// demonstrably merged nothing): a genuinely flat/uncreased body would ALSO
// legitimately return zero rings, so "zero rings found" can't itself be the
// warning trigger without false-positiving on an ordinary flat/uncreased
// part.
//
// ZONE INTERPLAY (#108) — when `segment_mesh_zones` has already been run for
// this body, each ring reports `containingZones`: the zone id(s) whose
// triangles are incident to the ring's own (welded) vertices, majority
// first. This needs the SAME welded-mesh + triangle-COUNT-survival guard
// `MeshZoneTools.adjacentZones` established (`welded.triangleCount ==
// mesh.triangleCount` — proof the weld here didn't drop a degenerate
// triangle, so triangle index `t` means the same triangle in both the
// welded mesh and the zones' own UNWELDED `triangleIndices`), PLUS a
// mesh-signature check (`ZoneRecord.meshSignature`, the same staleness
// check `ZoneSweepTool` performs before trusting a resolved zone's
// `triangleIndices` — the zone table might have been minted from a
// different mesh state, e.g. the body was re-meshed at a different
// deflection since). Any stale zone or a failed guard omits
// `containingZones` (nil on every ring) with an honest warning; no zones
// registered for this body at all is not a warning — zones are optional
// context, not a prerequisite.
//
// RENDER — the body surface as a neutral translucent grey `ViewportBody`
// (built straight off the welded mesh via `ViewportBody.directMesh`), plus
// one edges-only `ViewportBody` per ring (`edges: [[ring vertex positions,
// wrapped if closed]]`, no mesh triangles at all) in a categorical color.
// `OffscreenRenderer` draws a body's wireframe unconditionally whenever it
// has no mesh triangles of its own (`hasEdges && (displayMode.showsEdges ||
// !hasMesh)` in `OffscreenRenderer.swift`), so an edges-only ring body
// renders regardless of `displayMode` — no tube-strip-quad fallback needed.
// Composited with `ChartRenderer.overlayZoneLegend`, the same per-group
// ViewportBody + legend trick `MeshZoneTools`/`MeshCurvatureTools` use.

import Foundation
import simd
import OCCTSwift
import OCCTSwiftMesh
import OCCTSwiftViewport
import ScriptHarness

public enum MeshFeatureTools {

    public struct FeatureReport: Encodable {
        public let bodyId: String
        public let ringCount: Int
        public let unchainedCreaseEdgeCount: Int
        public let rings: [RingEntry]
        public let renderPath: String?
        public let warnings: [String]

        public struct RingEntry: Encodable {
            public let id: String
            public let closed: Bool
            public let lengthMm: Double
            public let bbox: BBox
            public let meanFoldAngleDegrees: Double
            public let maxFoldAngleDegrees: Double
            public let edgeCount: Int
            /// Zone id(s) whose triangles touch this ring's vertices, majority
            /// first. `nil` when no zones are registered for this body (silent
            /// — zones are optional context) OR when zones exist but couldn't
            /// be trusted (stale, or the weld-correspondence guard failed —
            /// see the file header; a warning names the reason in that case).
            public let containingZones: [String]?
        }
        public struct BBox: Encodable {
            public let min: [Double]
            public let max: [Double]
        }
    }

    @MainActor
    public static func detectMeshFeatures(
        bodyId: String,
        minAngleDegrees: Double = 30,
        maxRings: Int = 64,
        deflection: Double? = nil,
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

        guard minAngleDegrees > 0, minAngleDegrees <= 180 else {
            return .init("minAngleDegrees must be in (0, 180].", isError: true)
        }

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

        // MANDATORY precondition, see the file header: creaseEdges() needs a
        // welded mesh. Everything downstream (stats AND render) is indexed
        // against `welded`, never `mesh`.
        let welded = mesh.welded()
        guard welded.triangleCount > 0, welded.vertexCount > 0 else {
            return .init("Welding '\(bodyId)' produced an empty mesh.", isError: true)
        }

        var warnings: [String] = []
        if welded.vertexCount == welded.triangleCount * 3 {
            warnings.append(
                "mesh appears unweldable (no shared vertices found); crease detection needs a welded mesh and will find zero rings/paths regardless of the body's actual geometry."
            )
        }

        let result = welded.creaseEdges(minAngleDegrees: Float(minAngleDegrees))
        if result.unchainedCreaseEdgeCount > 0 {
            warnings.append(
                "\(result.unchainedCreaseEdgeCount) crease edge(s) could not be chained into a ring/path (a defensive walk-length-cap backstop; not expected to fire on well-formed input)."
            )
        }

        let cap = max(0, maxRings)
        let allRings = result.rings   // already sorted largest-first (CreaseRing.order)
        let rings = Array(allRings.prefix(cap))
        if allRings.count > cap {
            warnings.append(
                "\(allRings.count - cap) ring(s)/path(s) beyond maxRings=\(cap) were truncated (largest-first order preserved)."
            )
        }

        // ── zone interplay (#108) — see the file header for the guard chain.
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let zonesStore = ZonesStore(outputDir: outputDir)
        await registry.loadSidecarIfNeeded(store: zonesStore)
        let zones = await registry.zones(forBody: bodyId)

        var vertexZones: [UInt32: Set<String>]? = nil
        if !zones.isEmpty {
            let bb = shape.bounds
            let currentSig = MeshSignature(
                triangleCount: mesh.triangleCount,
                bboxMin: [Double(bb.min.x), Double(bb.min.y), Double(bb.min.z)],
                bboxMax: [Double(bb.max.x), Double(bb.max.y), Double(bb.max.z)]
            )
            let stale = zones.filter { !$0.meshSignature.matches(currentSig) }
            if !stale.isEmpty {
                warnings.append(
                    "containingZones omitted: \(stale.count) of \(zones.count) zone(s) for body \"\(bodyId)\" are stale (the body's mesh no longer matches the mesh they were segmented from). Re-run segment_mesh_zones."
                )
            } else if welded.triangleCount != mesh.triangleCount {
                warnings.append(
                    "containingZones omitted: welding the mesh for crease detection dropped degenerate triangles, breaking triangle-index correspondence with the stored zones' triangleIndices."
                )
            } else {
                var triToZones: [Int: [String]] = [:]
                for z in zones {
                    for t in z.triangleIndices { triToZones[t, default: []].append(z.zoneId) }
                }
                var vz: [UInt32: Set<String>] = [:]
                let wIdx = welded.indices
                for t in 0..<welded.triangleCount {
                    guard let zids = triToZones[t] else { continue }
                    for k in 0..<3 {
                        let v = wIdx[t * 3 + k]
                        vz[v, default: []].formUnion(zids)
                    }
                }
                vertexZones = vz
            }
        }

        func containingZones(for ring: CreaseRing) -> [String]? {
            guard let vz = vertexZones else { return nil }
            var counts: [String: Int] = [:]
            for v in ring.vertexIndices {
                for z in vz[v] ?? [] { counts[z, default: 0] += 1 }
            }
            // Majority first, then any others touched (tie-break: zoneId ascending — deterministic).
            return counts.sorted { a, b in
                a.value != b.value ? a.value > b.value : a.key < b.key
            }.map(\.key)
        }

        let entries = rings.enumerated().map { (i, ring) -> FeatureReport.RingEntry in
            FeatureReport.RingEntry(
                id: "ring:\(bodyId)#\(i)",
                closed: ring.closed,
                lengthMm: ring.length,
                bbox: .init(
                    min: [Double(ring.bbox.min.x), Double(ring.bbox.min.y), Double(ring.bbox.min.z)],
                    max: [Double(ring.bbox.max.x), Double(ring.bbox.max.y), Double(ring.bbox.max.z)]
                ),
                meanFoldAngleDegrees: ring.meanFoldAngleDegrees,
                maxFoldAngleDegrees: ring.maxFoldAngleDegrees,
                edgeCount: ring.closed ? ring.vertexIndices.count : ring.vertexIndices.count - 1,
                containingZones: containingZones(for: ring)
            )
        }

        // ── optional render ──────────────────────────────────────────────
        var writtenRenderPath: String? = nil
        if render {
            let path = renderPath ?? "\(outputDir)/\(bodyId)_features.png"
            if rings.count > ChartRenderer.categoricalPalette.count {
                warnings.append(
                    "\(rings.count) rings exceed the \(ChartRenderer.categoricalPalette.count)-color palette; colors repeat past #\(ChartRenderer.categoricalPalette.count - 1) and are not visually distinct beyond it."
                )
            }
            if let err = renderFeatures(
                welded: welded, rings: rings, bodyId: bodyId, outputPath: path, options: options
            ) {
                warnings.append("Render failed: \(err)")
            } else {
                writtenRenderPath = path
            }
        }

        return IntrospectionTools.encode(FeatureReport(
            bodyId: bodyId, ringCount: entries.count, unchainedCreaseEdgeCount: result.unchainedCreaseEdgeCount,
            rings: entries, renderPath: writtenRenderPath, warnings: warnings
        ))
    }

    // MARK: - Rendering (neutral surface + one edges-only ViewportBody per ring)

    @MainActor
    private static func renderFeatures(
        welded: Mesh, rings: [CreaseRing], bodyId: String, outputPath: String, options: RenderPreviewTool.Options
    ) -> String? {
        let verts = welded.vertices
        // welded() rebuilds the Mesh without normals, so welded.normals is
        // empty; compute real area-weighted vertex normals for the backdrop's
        // shading instead of falling back to a constant direction (review nit
        // on #113 — flat lighting made the translucent surface read unlit).
        let normals = welded.normals.count == welded.vertices.count ? welded.normals : welded.vertexNormals()
        let idx = welded.indices
        let hasNormals = normals.count == verts.count
        guard welded.triangleCount > 0 else { return "no triangles to render" }

        var positions: [Float] = []
        var bnormals: [Float] = []
        positions.reserveCapacity(verts.count * 3)
        bnormals.reserveCapacity(verts.count * 3)
        for i in 0..<verts.count {
            let p = verts[i]
            positions.append(p.x); positions.append(p.y); positions.append(p.z)
            let n = hasNormals ? normals[i] : SIMD3<Float>(0, 0, 1)
            bnormals.append(n.x); bnormals.append(n.y); bnormals.append(n.z)
        }
        // Neutral translucent grey — the ring overlays are the point of this
        // render, not the surface itself (see file header).
        let baseBody = ViewportBody.directMesh(
            id: "\(bodyId)#surface", positions: positions, normals: bnormals, indices: idx,
            color: SIMD4<Float>(0.75, 0.75, 0.78, 0.55)
        )

        var bodies: [ViewportBody] = [baseBody]
        var legend: [(label: String, color: SIMD4<Float>)] = []
        for (i, ring) in rings.enumerated() {
            var poly = ring.vertexIndices.map { verts[Int($0)] }
            if ring.closed, let first = poly.first { poly.append(first) }
            guard poly.count >= 2 else { continue }
            let color = ChartRenderer.categoricalColor(i)
            // Edges-only body: no mesh triangles at all, so OffscreenRenderer
            // draws its wireframe unconditionally regardless of displayMode
            // (see file header). `vertices` carries the same points so the
            // body still contributes to camera framing (combinedBoundsSphere)
            // and its own boundingBox (shadow-pass scene bounds) rather than
            // reading as empty.
            bodies.append(ViewportBody(
                id: "\(bodyId)#ring\(i)", vertexData: [], indices: [], edges: [poly],
                vertices: poly, color: color
            ))
            legend.append((label: "ring:\(bodyId)#\(i)\(ring.closed ? "" : " (open)")", color: color))
        }

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
        if !legend.isEmpty {
            try? ChartRenderer.overlayZoneLegend(on: url, entries: legend)
        }
        return nil
    }
}
