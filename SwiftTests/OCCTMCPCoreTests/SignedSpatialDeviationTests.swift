// Tests for the signed / spatially-resolved deviation diagnostics:
// measure_deviation vector upgrade + per-section (#62), deviation_histogram
// (#62), cross_section_compare (#61), signed_deviation_heatmap / overlay_render
// (#63).
//
// Two fixtures (see helpers): concentric spheres for the 3D signed / histogram /
// render tests (the whole inner surface is a uniform 0.5 inside the outer solid,
// so signedMean is unambiguously ≈ −0.5), and coaxial cylinders for the 2D
// cross-section test (its circular profiles see only the uniformly-offset
// lateral face). In both the inner body sits INSIDE the outer, so every signed
// figure is negative — shy / under-build.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
import simd
@testable import OCCTMCPCore

@Suite("signed + spatial deviation (#61/#62/#63)")
struct SignedSpatialDeviationTests {

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-sdev-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "sdev", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String { (store.path as NSString).deletingLastPathComponent }

    /// Coaxial cylinders (lateral face uniformly offset; caps near-coincident).
    /// Used by cross_section_compare, whose 2D circles see only the lateral face.
    func coaxialCylinders() throws -> ManifestStore {
        let inner = Shape.cylinder(radius: 5.0, height: 20)!
        let outer = Shape.cylinder(radius: 5.5, height: 20)!
        return try scene([("inner", inner), ("outer", outer)])
    }

    /// Concentric spheres — the ENTIRE inner surface is a uniform 0.5 inside the
    /// outer solid, so the signed mean is unambiguously ≈ −0.5 (no flat caps to
    /// dilute it). Used by the 3D signed / histogram / render tests.
    func concentricSpheres() throws -> ManifestStore {
        let inner = Shape.sphere(radius: 5.0)!
        let outer = Shape.sphere(radius: 5.5)!
        return try scene([("inner", inner), ("outer", outer)])
    }

    /// An OPEN half-cylinder shell (reference) + a solid cylinder (from). Slicing
    /// the shell perpendicular to Z yields an OPEN arc — a `MeshCrossSection`
    /// `openPath`, not a closed contour — the exact shape a raw scan / STL skin
    /// takes, and the case #66 dropped (referenceContours: 0 at every station).
    func openShellVsSolid() throws -> ManifestStore {
        let R = 5.0, H = 20.0, M = 24
        var verts: [SIMD3<Float>] = []
        var idx: [UInt32] = []
        for j in 0...M {
            let a = Double.pi * Double(j) / Double(M)     // half turn: 0…π (open)
            let x = Float(R * cos(a)), y = Float(R * sin(a))
            verts.append(SIMD3(x, y, 0))                  // bottom  (2j)
            verts.append(SIMD3(x, y, Float(H)))           // top     (2j+1)
        }
        for j in 0..<M {
            let b0 = UInt32(2 * j), t0 = UInt32(2 * j + 1)
            let b1 = UInt32(2 * (j + 1)), t1 = UInt32(2 * (j + 1) + 1)
            idx += [b0, b1, t1, b0, t1, t0]
        }
        guard let mesh = OCCTSwift.Mesh(vertices: verts, indices: idx),
              let shell = mesh.toShape() else {
            throw TestError.fixture("failed to build open half-cylinder shell")
        }
        let solid = Shape.cylinder(radius: 4.8, height: H)!   // z∈[0,H], overlaps fully
        return try scene([("from", solid), ("reference", shell)])
    }

    /// Two disconnected, near-parallel quads 0.1 apart, BOTH with outward (+z)
    /// face normals — an outer-skin-plus-inner-wall sandwich a small gap apart,
    /// the open thin-wall shape from #72. A point sitting in the gap is exactly
    /// equidistant to both patches, and the two candidate signs disagree (the
    /// upper patch reads it as shy, the lower as proud), so `signedQuery` must
    /// flag it `ambiguous` rather than pick a coin-flip winner.
    func thinWallSandwichReference() throws -> Shape {
        func quad(z: Float, xOffset: Float) -> ([SIMD3<Float>], [UInt32]) {
            let v: [SIMD3<Float>] = [
                SIMD3(-5 + xOffset, -5, z), SIMD3(5 + xOffset, -5, z),
                SIMD3(5 + xOffset, 5, z), SIMD3(-5 + xOffset, 5, z),
            ]
            return (v, [0, 1, 2, 0, 2, 3])   // CCW from +z ⇒ normal (0,0,1)
        }
        func patch(z: Float, xOffset: Float) throws -> Shape {
            let (v, i) = quad(z: z, xOffset: xOffset)
            guard let mesh = OCCTSwift.Mesh(vertices: v, indices: i), let shape = mesh.toShape() else {
                throw TestError.fixture("failed to build sandwich patch at z=\(z)")
            }
            return shape
        }
        let upper = try patch(z: 0.05, xOffset: 0)
        let lower = try patch(z: -0.05, xOffset: 0.5)   // offset so the two patches share no vertex
        guard let combined = Shape.compound([upper, lower]) else {
            throw TestError.fixture("failed to compound sandwich patches")
        }
        return combined
    }

    /// A flat 10×10 patch at height `z`, densely tessellated, facing +z (`faceUp`)
    /// or −z. Dense on purpose: a sample a few units off it then has ONLY this
    /// patch's vertices in its k-nearest neighbourhood, which is what forces the
    /// robust gate down its widened-search path — a 4-vertex quad would skip it.
    func gridPatch(z: Float, faceUp: Bool, n: Int = 12) throws -> Shape {
        var v: [SIMD3<Float>] = []
        for j in 0...n {
            for i in 0...n {
                v.append(SIMD3(-5 + 10 * Float(i) / Float(n),
                               -5 + 10 * Float(j) / Float(n), z))
            }
        }
        var idx: [UInt32] = []
        for j in 0..<n {
            for i in 0..<n {
                let a = UInt32(j * (n + 1) + i), b = a + 1
                let c = UInt32((j + 1) * (n + 1) + i), d = c + 1
                // CCW seen from +z ⇒ normal +z; reversed winding ⇒ −z.
                idx += faceUp ? [a, b, d, a, d, c] : [a, d, b, a, c, d]
            }
        }
        guard let mesh = OCCTSwift.Mesh(vertices: v, indices: idx),
              let shape = mesh.toShape() else {
            throw TestError.fixture("failed to build grid patch at z=\(z)")
        }
        return shape
    }

    /// A thin-walled OPEN reference whose two surfaces face OPPOSITE ways — the
    /// real shape of a scanned wall, and the case #72 reported. Outer skin at z=0
    /// faces +z (out of the part); inner wall at z=−2 faces −z (into the cavity
    /// below).
    func thinWallOppositeFacesReference() throws -> Shape {
        let outerSkin = try gridPatch(z: 0, faceUp: true)     // faces +z, out of the part
        let innerWall = try gridPatch(z: -2, faceUp: false)   // faces −z, into the cavity
        guard let combined = Shape.compound([outerSkin, innerWall]) else {
            throw TestError.fixture("failed to compound thin wall")
        }
        return combined
    }

    enum TestError: Error { case fixture(String) }

    // ── decode mirrors ──────────────────────────────────────────────────

    struct DevReport: Decodable {
        struct Dir: Decodable {
            let max, rms, mean, p95: Double
            let signedMean, signedMin, signedMax: Double?
            let worstPoint: [Double]; let samples: Int
            let signedSamples, ambiguousSamples: Int; let ambiguousFraction: Double
        }
        struct Section: Decodable { let offset, signedMean, rms: Double; let samples: Int }
        let fromToTo: Dir; let toToFrom: Dir; let symmetricHausdorff: Double
        let signMode: String
        let sections: [Section]?
    }

    struct HistReport: Decodable {
        struct Bucket: Decodable { let lo, hi: Double; let count: Int }
        let mean, std, median, signedMin, signedMax: Double?
        let p95, maxAbs: Double
        let withinTolerance: Double?; let buckets: [Bucket]; let samples: Int
    }

    struct CompareReport: Decodable {
        struct Section: Decodable {
            let station: Int; let offset, axisCoord, fromArea, referenceArea, areaRatio: Double
            let centroidOffset, signedMean, rms, maxAbs, shapeL2: Double
            let fromContours, referenceContours, fromOpenPaths, referenceOpenPaths: Int
            let registrationSmell, openProfile: Bool
        }
        let meanSignedAcrossSections, maxAbsSignedSection, worstAxisCoord: Double
        let referenceMode: String
        let overlap: [Double]; let warnings: [String]
        let sections: [Section]
    }

    struct HeatReport: Decodable {
        let outputPath: String; let bands, triangles: Int
        let clamp, signedMin, signedMax, signedMean: Double
    }

    // ── #62: measure_deviation vector + per-section ──────────────────────

    @Test("measure_deviation reports a negative signedMean + per-section array")
    func signedAndSections() async throws {
        let store = try concentricSpheres()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await DeviationTools.measureDeviation(
            fromBodyId: "inner", toBodyId: "outer", deflection: 0.05,
            sectionAxis: SIMD3(0, 0, 1), sectionCount: 5, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(DevReport.self, from: Data(result.text.utf8))

        // Inner surface is inside the outer solid ⇒ systematically shy. A
        // watertight reference must yield the signed figures, never nil.
        let signedMean = try #require(r.fromToTo.signedMean)
        let signedMin = try #require(r.fromToTo.signedMin)
        #expect(signedMean < -0.25)
        #expect(signedMean > -0.7)
        #expect(signedMin < -0.4)                   // deepest shy ≈ −0.5
        #expect(r.fromToTo.p95 > 0.3)
        #expect(r.fromToTo.samples > 0)

        // Per-section sweep present and consistently shy (systematic).
        let sections = try #require(r.sections)
        #expect(sections.count >= 3)
        #expect(sections.contains { $0.signedMean < -0.4 })
        #expect(sections.allSatisfy { $0.signedMean < 0.05 })
    }

    @Test("measure_deviation omits sections when no axis given")
    func noSections() async throws {
        let store = try coaxialCylinders()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let result = await DeviationTools.measureDeviation(
            fromBodyId: "inner", toBodyId: "outer", deflection: 0.1, store: store)
        let r = try JSONDecoder().decode(DevReport.self, from: Data(result.text.utf8))
        #expect(r.sections == nil)
    }

    // ── #62: deviation_histogram ─────────────────────────────────────────

    @Test("deviation_histogram: negative mean + within-tolerance + buckets")
    func histogram() async throws {
        let store = try concentricSpheres()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let png = dirOf(store) + "/hist.png"
        let result = await DeviationHistogramTool.deviationHistogram(
            fromBodyId: "inner", referenceBodyId: "outer", deflection: 0.05,
            tolerance: 1.0, outputPath: png, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(HistReport.self, from: Data(result.text.utf8))

        let mean = try #require(r.mean)
        let signedMin = try #require(r.signedMin)
        #expect(mean < -0.2 && mean > -0.7)
        #expect(signedMin < -0.4)
        #expect(!r.buckets.isEmpty)
        #expect(r.samples > 0)
        // Every |dev| ≈ 0.5 ≤ 1.0 ⇒ all within tolerance.
        let within = try #require(r.withinTolerance)
        #expect(within > 0.9)
        #expect(FileManager.default.fileExists(atPath: png))
    }

    // ── #61: cross_section_compare ───────────────────────────────────────

    @Test("cross_section_compare: area ratio + shy signedMean + matching shape")
    func crossSection() async throws {
        let store = try coaxialCylinders()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await CrossSectionCompareTool.crossSectionCompare(
            fromBodyId: "inner", referenceBodyId: "outer", axis: SIMD3(0, 0, 1),
            stations: 6, deflection: 0.05, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(CompareReport.self, from: Data(result.text.utf8))

        let valid = r.sections.filter { $0.fromArea > 0 }
        #expect(!valid.isEmpty)
        for s in valid {
            #expect(s.areaRatio > 0.7 && s.areaRatio < 0.95)   // (5/5.5)^2 ≈ 0.826
            #expect(s.signedMean < -0.2)                        // inner shy vs outer
            #expect(s.shapeL2 < 0.1)                            // same circular shape
        }
        #expect(r.meanSignedAcrossSections < -0.2)
        // #70: default is the outer-envelope basis; stations carry a world axisCoord.
        #expect(r.referenceMode == "envelope")
        let coords = r.sections.map { $0.axisCoord }
        #expect(zip(coords, coords.dropFirst()).allSatisfy { $0 < $1 })   // increasing along Z
        // axisCoord is the WORLD z — cylinders span z∈[0,20], so it lands inside that
        // (NOT the overlap-relative `offset`). This is the #70 localisation fix.
        #expect(coords.allSatisfy { $0 > 0 && $0 < 20 })
    }

    // ── #70: outer-envelope excludes inner structure; open-profile shapeL2 ──

    @Test("outer-envelope drops inner window-return paths; shapeL2 defined for open")
    func outerEnvelope() {
        func arc(_ rx: Double, _ ry: Double, from a0: Double, to a1: Double, _ n: Int) -> [SIMD2<Double>] {
            (0...n).map { let a = a0 + (a1 - a0) * Double($0) / Double(n); return SIMD2(rx * cos(a), ry * sin(a)) }
        }
        func circle(_ r: Double, _ n: Int) -> [SIMD2<Double>] { arc(r, r, from: 0, to: 2 * .pi - (2 * .pi / Double(n)), n) }

        // Reference = outer skin r=5 PLUS an inner window-return ring r=2.
        let ref = circle(5, 160) + circle(2, 160)

        // Candidate matches the OUTER envelope: the inner ring must not pollute.
        let ok = CrossSectionCompareTool.envelopeDeviation(candidate: circle(5, 160), reference: ref)
        #expect(abs(ok.signedMean) < 0.15)
        #expect(ok.rms < 0.15)
        #expect(ok.shapeL2 < 0.03)

        // A uniformly smaller candidate reads shy (≈ −1) — sign is meaningful.
        let shy = CrossSectionCompareTool.envelopeDeviation(candidate: circle(4, 160), reference: ref)
        #expect(shy.signedMean < -0.8 && shy.signedMean > -1.2)

        // OPEN profiles (half arcs): shapeL2 is DEFINED (not forced 0) — same shape ≈ 0,
        // a squashed shape clearly > 0.
        let openRef = arc(5, 5, from: 0, to: .pi, 80)
        let same = CrossSectionCompareTool.envelopeDeviation(candidate: arc(5, 5, from: 0, to: .pi, 80), reference: openRef)
        #expect(same.shapeL2 < 0.05)
        let squashed = CrossSectionCompareTool.envelopeDeviation(candidate: arc(6, 2, from: 0, to: .pi, 80), reference: openRef)
        #expect(squashed.shapeL2 > 0.05)
    }

    // ── #66: open-shell reference must not read as un-sliced ──────────────

    @Test("cross_section_compare: open reference shell still produces sections")
    func openShellReference() async throws {
        let store = try openShellVsSolid()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await CrossSectionCompareTool.crossSectionCompare(
            fromBodyId: "from", referenceBodyId: "reference", axis: SIMD3(0, 0, 1),
            stations: 8, deflection: 0.2, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(CompareReport.self, from: Data(result.text.utf8))

        // The bodies overlap fully along Z, so the stations span a real range.
        #expect(r.overlap.count == 2)
        #expect(r.overlap[1] - r.overlap[0] > 10)

        // The reference is an OPEN shell: its sections are open arcs, not closed
        // contours. Before #66 these were dropped → referenceContours: 0 and no
        // numeric comparison. Now the open paths drive the comparison.
        let openSections = r.sections.filter { $0.referenceOpenPaths >= 1 }
        #expect(!openSections.isEmpty, "no station picked up the open reference arc")
        // At least one interior station must yield a real, open-profile comparison.
        #expect(openSections.contains { $0.referenceContours == 0 && $0.openProfile && $0.rms > 0 })
    }

    // ── #63: heatmap + overlay (render; skip if no Metal device) ──────────

    @MainActor
    @Test("signed_deviation_heatmap renders a PNG")
    func heatmap() async throws {
        let store = try concentricSpheres()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let png = dirOf(store) + "/heat.png"
        let result = await HeatmapTools.signedDeviationHeatmap(
            fromBodyId: "inner", referenceBodyId: "outer", outputPath: png,
            deflection: 0.2, store: store)
        if result.isError && result.text.contains("Metal") { return }   // headless w/o GPU
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(HeatReport.self, from: Data(result.text.utf8))
        #expect(r.triangles > 0)
        #expect(r.signedMin < 0)            // shy somewhere
        #expect(FileManager.default.fileExists(atPath: png))
    }

    @MainActor
    @Test("overlay_render renders a PNG")
    func overlay() async throws {
        let store = try concentricSpheres()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let png = dirOf(store) + "/overlay.png"
        let result = await HeatmapTools.overlayRender(
            solidBodyId: "inner", meshBodyId: "outer", outputPath: png,
            transparency: 0.4, store: store)
        if result.isError && result.text.contains("Metal") { return }
        #expect(!result.isError, "unexpected error: \(result.text)")
        #expect(FileManager.default.fileExists(atPath: png))
    }

    // ── #72: sign ambiguity against an open thin-wall reference ─────────

    @Test("signedQuery flags sign-ambiguous samples between two close near-parallel patches")
    func signAmbiguityFlagged() throws {
        let refShape = try thinWallSandwichReference()
        let refTris = try #require(DeviationTools.TriMesh(shape: refShape, deflection: 0.05))

        // Equidistant (0.05) to both patches; the upper patch's normal reads it
        // shy (−), the lower patch's reads it proud (+) — a coin-flip winner.
        var stamp = [Int](repeating: -1, count: refTris.triangles.count)
        let hit = try #require(DeviationTools.signedQuery(
            SIMD3(0, 0, 0), target: refTris, k: 6, stamp: &stamp, stampToken: 0))
        #expect(hit.ambiguous)
        #expect(abs(abs(hit.signed) - 0.05) < 0.01)

        // Far below both patches, only the lower one is in reach ⇒ unambiguous.
        var stamp2 = [Int](repeating: -1, count: refTris.triangles.count)
        let clear = try #require(DeviationTools.signedQuery(
            SIMD3(0, 0, -5), target: refTris, k: 6, stamp: &stamp2, stampToken: 0))
        #expect(!clear.ambiguous)
    }

    @Test("robust sign rejects an open thin wall's far surface as the counterpart")
    func robustSignRejectsFarWall() throws {
        let refShape = try thinWallOppositeFacesReference()
        let refTris = try #require(DeviationTools.TriMesh(shape: refShape, deflection: 0.5))

        // Fixture premise: the reference really does carry two opposite-facing
        // surfaces. The whole gate rests on that winding surviving the mesh.
        let up = refTris.triangles.indices.filter { refTris.faceNormal($0).z > 0.9 }
        let down = refTris.triangles.indices.filter { refTris.faceNormal($0).z < -0.9 }
        #expect(!up.isEmpty, "fixture lost its +z outer skin")
        #expect(!down.isEmpty, "fixture lost its −z inner wall")

        // A candidate flank 4.5 SHY of the outer skin it corresponds to, its own
        // surface facing +z — the kiha40 geometry from #72, scaled.
        let p = SIMD3<Double>(0, 0, -4.5)
        let n = SIMD3<Double>(0, 0, 1)

        var stamp = [Int](repeating: -1, count: refTris.triangles.count)
        let naive = try #require(DeviationTools.signedQuery(
            p, target: refTris, k: 6, stamp: &stamp, stampToken: 0, signMode: .nearest))
        // The bug, reproduced: the inner wall is nearer (2.5 vs 4.5) and faces the
        // cavity, so a shy flank reads PROUD — wrong side, wrong magnitude.
        #expect(abs(naive.signed - 2.5) < 0.01, "expected the #72 artifact, got \(naive.signed)")
        // And nothing ties at 15%, so the coin-flip guard never fires. A confident
        // wrong answer is exactly what cost a dispatch cycle.
        #expect(!naive.ambiguous, "the artifact is unflagged — that's what makes it dangerous")

        var stamp2 = [Int](repeating: -1, count: refTris.triangles.count)
        let robust = try #require(DeviationTools.signedQuery(
            p, normal: n, target: refTris, k: 6, stamp: &stamp2, stampToken: 0, signMode: .robust))
        // The fix: the inner wall's normal opposes the sample's, so it can't claim
        // the correspondence — the outer skin does, at the true 4.5 shy.
        #expect(abs(robust.signed + 4.5) < 0.01, "expected true −4.5 shy, got \(robust.signed)")
        #expect(!robust.ambiguous)

        // The gate steers the SIGN channel only. `nearest` is the closest surface
        // full stop — the inner wall, 2.5 away — in both modes, so the unsigned
        // figures built on it (max / rms / p95 / symmetricHausdorff) keep meaning
        // exactly what they meant before the gate existed.
        #expect(abs(robust.nearest - 2.5) < 0.01, "robust must not move `nearest`, got \(robust.nearest)")
        #expect(abs(naive.nearest - robust.nearest) < 1e-9, "`nearest` must not depend on signMode")
    }

    @Test("every tool on the signed engine exposes signMode, and it defaults to robust")
    func signModeIsWiredIntoTheToolSurface() throws {
        // The three tools share DeviationTools' engine, so they must share the
        // knob — and an LLM only sees the ones the schema advertises.
        for name in ["measure_deviation", "deviation_histogram", "signed_deviation_heatmap"] {
            let tool = try #require(catalogTools().first { $0.name == name },
                                    "\(name) missing from the catalog")
            let props = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            let signMode = try #require(props["signMode"]?.objectValue,
                                        "\(name) must expose signMode")
            let options = try #require(signMode["enum"]?.arrayValue).compactMap(\.stringValue)
            #expect(options.sorted() == ["nearest", "robust"])
        }
        // Absent or unparseable ⇒ the mode that can't silently invert a sign.
        #expect(parseSignMode(nil) == .robust)
        #expect(parseSignMode(.string("robust")) == .robust)
        #expect(parseSignMode(.string("nearest")) == .nearest)
        #expect(parseSignMode(.string("Nearest")) == .robust)
        #expect(parseSignMode(.int(3)) == .robust)
    }

    @Test("robust sign flags ambiguous rather than guess when no counterpart exists")
    func robustSignAmbiguousWithoutCounterpart() throws {
        // Both sandwich patches face +z, so a sample whose own surface faces −z
        // has no counterpart anywhere in this reference — the miniature of a
        // reference whose winding is inverted relative to the sampled body. The
        // side is unknowable; say so rather than pick one.
        let refShape = try thinWallSandwichReference()
        let refTris = try #require(DeviationTools.TriMesh(shape: refShape, deflection: 0.05))
        var stamp = [Int](repeating: -1, count: refTris.triangles.count)
        let hit = try #require(DeviationTools.signedQuery(
            SIMD3(0, 0, -5), normal: SIMD3(0, 0, -1), target: refTris,
            k: 6, stamp: &stamp, stampToken: 0, signMode: .robust))
        #expect(hit.ambiguous)
        // The magnitude is still the honest nearest-surface distance (lower patch
        // at z=−0.05) — only the sign channel is withheld.
        #expect(abs(hit.nearest - 4.95) < 0.01)
    }

    @Test("no trustworthy sign anywhere reports nil signed stats, not a centred zero")
    func allAmbiguousYieldsNilSignedStats() async throws {
        // Every reference face points +z while every candidate face points −z:
        // nothing corresponds to anything, the miniature of an inverted-winding
        // reference. A zeroed signedMean here would read as a perfectly centred
        // model, so the figures must come back absent instead.
        let reference = try gridPatch(z: 0, faceUp: true)
        let candidate = try gridPatch(z: -3, faceUp: false)
        let store = try scene([("from", candidate), ("reference", reference)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await DeviationTools.measureDeviation(
            fromBodyId: "from", toBodyId: "reference", deflection: 0.5, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(DevReport.self, from: Data(result.text.utf8))
        #expect(r.fromToTo.ambiguousFraction == 1.0)
        #expect(r.fromToTo.signedSamples == 0)
        #expect(r.fromToTo.signedMean == nil, "got \(String(describing: r.fromToTo.signedMean))")
        #expect(r.fromToTo.signedMin == nil)
        #expect(r.fromToTo.signedMax == nil)
        // The invariant the report's own field docs promise.
        #expect(r.fromToTo.signedSamples + r.fromToTo.ambiguousSamples == r.fromToTo.samples)
        // Magnitudes are unaffected — the candidate really is 3 away.
        #expect(abs(r.fromToTo.mean - 3.0) < 0.05, "got \(r.fromToTo.mean)")
    }

    @Test("measure_deviation reads a shy skin as shy against an open thin-wall reference")
    func measureDeviationSignedMeanAgainstThinWall() async throws {
        // End-to-end over the shared engine, the reported case in miniature: a
        // candidate skin that should sit ON the reference's outer skin but is 4.5
        // shy of it, parked below the wall's inner surface. Every one of its
        // samples corresponds to the outer skin, so signedMean must read ≈ −4.5.
        // Under nearest-triangle the inner wall claims all of them and it comes
        // back ≈ +2.5 — a confident proud reading of a shy part.
        let wall = try thinWallOppositeFacesReference()
        let candidate = try gridPatch(z: -4.5, faceUp: true)
        let store = try scene([("from", candidate), ("reference", wall)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let robust = await DeviationTools.measureDeviation(
            fromBodyId: "from", toBodyId: "reference", deflection: 0.5,
            signMode: .robust, store: store)
        #expect(!robust.isError, "unexpected error: \(robust.text)")
        let rr = try JSONDecoder().decode(DevReport.self, from: Data(robust.text.utf8))
        #expect(rr.signMode == "robust")
        let robustMean = try #require(rr.fromToTo.signedMean)
        #expect(abs(robustMean + 4.5) < 0.05, "shy skin must read ≈ −4.5 shy, got \(robustMean)")
        // Reverse direction: the wall's inner surface has no counterpart on a
        // one-sided candidate, so those samples withhold their sign instead of
        // padding the mean — roughly half the reference is inner wall.
        #expect(rr.toToFrom.ambiguousSamples > 0)
        #expect(rr.toToFrom.signedSamples + rr.toToFrom.ambiguousSamples == rr.toToFrom.samples)

        let naive = await DeviationTools.measureDeviation(
            fromBodyId: "from", toBodyId: "reference", deflection: 0.5,
            signMode: .nearest, store: store)
        let nr = try JSONDecoder().decode(DevReport.self, from: Data(naive.text.utf8))
        let naiveMean = try #require(nr.fromToTo.signedMean)
        #expect(naiveMean > 0, "expected the #72 artifact under .nearest, got \(naiveMean)")
        // The unsigned channel is the same measurement in both modes: the nearest
        // reference surface is the inner wall, 2.5 away, whichever mode ran.
        #expect(abs(rr.fromToTo.mean - nr.fromToTo.mean) < 1e-9,
                "signMode must not move the unsigned figures")
        #expect(abs(rr.fromToTo.mean - 2.5) < 0.05, "got \(rr.fromToTo.mean)")
    }
}
