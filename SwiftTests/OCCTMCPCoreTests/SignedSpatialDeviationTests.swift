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

    enum TestError: Error { case fixture(String) }

    // ── decode mirrors ──────────────────────────────────────────────────

    struct DevReport: Decodable {
        struct Dir: Decodable {
            let max, rms, mean, p95, signedMean, signedMin, signedMax: Double
            let worstPoint: [Double]; let samples: Int
        }
        struct Section: Decodable { let offset, signedMean, rms: Double; let samples: Int }
        let fromToTo: Dir; let toToFrom: Dir; let symmetricHausdorff: Double
        let sections: [Section]?
    }

    struct HistReport: Decodable {
        struct Bucket: Decodable { let lo, hi: Double; let count: Int }
        let mean, std, median, p95, signedMin, signedMax, maxAbs: Double
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

        // Inner surface is inside the outer solid ⇒ systematically shy.
        #expect(r.fromToTo.signedMean < -0.25)
        #expect(r.fromToTo.signedMean > -0.7)
        #expect(r.fromToTo.signedMin < -0.4)        // deepest shy ≈ −0.5
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

        #expect(r.mean < -0.2 && r.mean > -0.7)
        #expect(r.signedMin < -0.4)
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
}
