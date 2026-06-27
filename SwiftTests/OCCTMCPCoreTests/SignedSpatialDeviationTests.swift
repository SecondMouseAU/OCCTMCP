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
            let station: Int; let offset, fromArea, referenceArea, areaRatio: Double
            let centroidOffset, signedMean, rms, maxAbs, shapeL2: Double
        }
        let meanSignedAcrossSections, maxAbsSignedSection: Double
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
