// Unit tests for measure_deviation (surface Hausdorff between two bodies).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("measure_deviation")
struct DeviationToolsTests {

    /// Seed a tempdir scene with two real BREP bodies, return its ManifestStore.
    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-dev-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "dev", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String { (store.path as NSString).deletingLastPathComponent }

    // Decodable mirror of the encode-only report.
    struct DeviationReport: Decodable {
        struct Dir: Decodable { let max: Double; let rms: Double; let mean: Double; let worstPoint: [Double]; let samples: Int }
        let from: String; let to: String; let deflection: Double
        let fromToTo: Dir; let toToFrom: Dir; let symmetricHausdorff: Double
    }

    @Test("identical bodies → ~zero deviation")
    func identical() async throws {
        let a = Shape.box(width: 10, height: 10, depth: 10)!
        let b = Shape.box(width: 10, height: 10, depth: 10)!
        let store = try scene([("a", a), ("b", b)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await DeviationTools.measureDeviation(fromBodyId: "a", toBodyId: "b", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(DeviationReport.self, from: Data(result.text.utf8))
        #expect(r.symmetricHausdorff < 1e-6)
        #expect(r.fromToTo.samples > 0)
        #expect(r.toToFrom.samples > 0)
    }

    @Test("coaxial cylinders → deviation ≈ radius delta")
    func radialOffset() async throws {
        // Same axis/height, radius differs by 0.5 — the worst surface gap
        // (radial) must be ≈ 0.5, well above any tessellation noise.
        let inner = Shape.cylinder(radius: 5.0, height: 20)!
        let outer = Shape.cylinder(radius: 5.5, height: 20)!
        let store = try scene([("inner", inner), ("outer", outer)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await DeviationTools.measureDeviation(
            fromBodyId: "inner", toBodyId: "outer", deflection: 0.05, store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(DeviationReport.self, from: Data(result.text.utf8))
        // Lateral surface gap is 0.5; allow tessellation slack.
        #expect(r.symmetricHausdorff > 0.4)
        #expect(r.symmetricHausdorff < 0.65)
    }

    @Test("missing body errors cleanly")
    func missingBody() async throws {
        let a = Shape.box(width: 1, height: 1, depth: 1)!
        let store = try scene([("a", a)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await DeviationTools.measureDeviation(fromBodyId: "a", toBodyId: "nope", store: store)
        #expect(result.text.contains("nope"))
    }
}
