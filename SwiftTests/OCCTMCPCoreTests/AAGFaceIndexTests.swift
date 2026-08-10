// AAGFaceIndexTests: OCCTSwift 2.0.0 (#642) changes AAG.detectPockets()/
// detectHoles() to return OCCURRENCE indices into Shape.orientedFaces(),
// not Shape.faces() as before. On a single-solid body (the overwhelming
// common case) the two enumerations agree exactly, so nothing here would
// ever have caught a regression — the divergence only shows up on a body
// with a face shared between two solids in a compound (a boolean or
// pattern result). recognize_features/feature_recognize (AnalysisTools),
// select_by_feature (GapFillerTools) and auto_dimension (AutoDimensionTool)
// all consume that same faceIndex; this pins that each still names the
// hole's REAL face after the OCCTSwift 2.0.0 bump, not some other face
// that happens to sit at the same raw occurrence index.
//
// Fixture: an off-center blind hole (so the split plane doesn't cut
// through it) in a box, split down the middle so the cut face is shared
// between the two resulting solids — same technique
// TopologyIdentityTests.multiShellSharedFaceDivergence already uses for
// the plain face-index divergence, extended here with an actual
// hole/pocket feature to exercise AAG specifically.

import Foundation
import Testing
import simd
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("AAG face-index occurrence/distinct divergence (OCCTSwift 2.0.0, #642)")
struct AAGFaceIndexTests {

    /// Box origin (-10,-10,-10), 20x20x20, with a blind hole (radius 4,
    /// drilled from the top) centered at (5, 0, *) — off the x=0 split
    /// plane — then split at x=0 into two solids sharing the cut face.
    /// The hole survives intact in the x>0 half.
    func multiSolidWithOffCenterHole() throws -> Shape {
        let box = try #require(Shape.box(origin: SIMD3<Double>(-10, -10, -10), width: 20, height: 20, depth: 20))
        let tool = try #require(Shape.cylinder(at: SIMD3<Double>(5, 0, 0), direction: SIMD3<Double>(0, 0, 1), radius: 4, height: 20))
        let drilled = try #require(box.subtracting(tool))
        let pieces = try #require(drilled.split(atPlane: SIMD3<Double>(0, 0, 0), normal: SIMD3<Double>(1, 0, 0)))
        #expect(pieces.count == 2, "expected the split to produce two solids")
        return try #require(Shape.compound(pieces))
    }

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-aagfaceindex-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map { BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1]) }
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "aagfaceindex", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String { (store.path as NSString).deletingLastPathComponent }

    @Test("fixture is genuinely multi-solid with a shared face, and AAG finds the hole")
    func fixtureShape() throws {
        let compound = try multiSolidWithOffCenterHole()
        #expect(
            compound.orientedFaces().count > compound.faces().count,
            "expected the split's cut face to be shared (more occurrences than distinct faces); if this is ever equal the fixture no longer shares a face and needs a different repro"
        )
        let aag = AAG(shape: compound)
        let holes = aag.detectHoles()
        #expect(holes.count == 1, "expected exactly one hole surviving the split, found \(holes.count)")
        if let hole = holes.first {
            #expect(abs(hole.radius - 4.0) < 1e-3)
        }
    }

    @Test("AutoDimensionTool.autoDimension resolves the hole's own rim, not a face collision from the shared cut face")
    func autoDimensionFindsRealHole() async throws {
        let compound = try multiSolidWithOffCenterHole()
        let store = try scene([("part", compound)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await AutoDimensionTool.autoDimension(bodyId: "part", store: store, registry: SelectionRegistry())
        #expect(!result.isError, "unexpected error: \(result.text)")

        struct EntryMirror: Decodable { let kind: String; let value: Double }
        struct SkipMirror: Decodable { let faceIndex: Int; let reason: String }
        struct ResultMirror: Decodable { let added: [EntryMirror]; let skipped: [SkipMirror] }
        let r = try JSONDecoder().decode(ResultMirror.self, from: Data(result.text.utf8))

        #expect(
            r.skipped.isEmpty,
            "hole was skipped rather than dimensioned: \(r.skipped.map(\.reason)) — the classic symptom of edgesInFace(at:) landing on the wrong face"
        )
        let holeEntries = r.added.filter { $0.kind.hasPrefix("hole_") }
        #expect(!holeEntries.isEmpty, "expected at least one hole_radius/hole_diameter dimension")
        for e in holeEntries {
            let expected = e.kind == "hole_diameter" ? 8.0 : 4.0
            #expect(abs(e.value - expected) < 1e-2, "\(e.kind) = \(e.value), expected ~\(expected) — a mismatch means the wrong face's rim was measured")
        }
    }

    @Test("GapFillerTools.selectByFeature mints the hole selection on the hole's own cylindrical wall, not the shared cut face")
    func selectByFeatureFindsRealHole() async throws {
        let compound = try multiSolidWithOffCenterHole()
        let store = try scene([("part", compound)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await GapFillerTools.selectByFeature(bodyId: "part", kinds: ["hole"], store: store, registry: SelectionRegistry())
        #expect(!result.isError, "unexpected error: \(result.text)")

        struct DetailMirror: Decodable { let area: Double?; let surfaceType: String? }
        struct SelectionMirror: Decodable { let kind: String; let detail: DetailMirror }
        struct ResultMirror: Decodable { let selections: [SelectionMirror] }
        let r = try JSONDecoder().decode(ResultMirror.self, from: Data(result.text.utf8))

        let holeSelections = r.selections.filter { $0.kind == "hole" }
        #expect(!holeSelections.isEmpty, "expected a hole selection to be minted")
        for s in holeSelections {
            #expect(
                s.detail.surfaceType?.lowercased().contains("cylind") == true,
                "hole selection landed on a \(s.detail.surfaceType ?? "nil")-type face, not a cylindrical wall — the shared cut face (planar) is exactly the wrong-face symptom this fixture targets"
            )
        }
    }

    @Test("AnalysisTools.recognizeFeatures reports a faceIndex directly usable with edgesInFace(at:) — i.e. faces()-space, not the raw orientedFaces() occurrence index")
    func recognizeFeaturesReportsUsableFaceIndex() async throws {
        let compound = try multiSolidWithOffCenterHole()
        let store = try scene([("part", compound)])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await AnalysisTools.recognizeFeatures(bodyId: "part", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")

        struct HoleMirror: Decodable { let faceIndex: Int; let radius: Double }
        struct ReportMirror: Decodable { let holes: [HoleMirror] }
        let r = try JSONDecoder().decode(ReportMirror.self, from: Data(result.text.utf8))
        #expect(r.holes.count == 1)
        guard let hole = r.holes.first else { return }
        #expect(abs(hole.radius - 4.0) < 1e-3)

        // The reported faceIndex must be usable directly against faces()-space
        // APIs like edgesInFace(at:), the same contract every other face
        // index this MCP hands out (query_topology/select_topology) honors.
        let edges = compound.edgesInFace(at: hole.faceIndex)
        #expect(!edges.isEmpty, "reported faceIndex \(hole.faceIndex) has no edges in the faces() enumeration — it's still a raw orientedFaces() occurrence index")
        #expect(edges.contains(where: { $0.isCircle }), "reported faceIndex \(hole.faceIndex) has no circular rim edge — it names the wrong face")
    }
}
