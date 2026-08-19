import Foundation
import OCCTSwift
import ScriptHarness
import Testing
import simd

@testable import OCCTMCPCore

// A body with NO bounding box at all is the case OCCTSwift 3.0.0 (#943) made
// representable: `Shape.bounds` and friends return nil for a void `Bnd_Box`
// instead of fabricating `(0,0,0)-(0,0,0)`, which no caller could tell apart
// from a real zero-sized body sitting at the world origin.
//
// These tests pin the repin's central rule (OCCTMCP#175): every tool here either
// returns an explicit error or omits the field, and none of them substitutes a
// zero-sized box. The distinction matters more here than in a library, because
// every one of these values leaves as an LLM tool result, where a fabricated
// measurement does not degrade, it reads as a real one.

@Suite("bodies with no bounding box (OCCTSwift #943)")
struct VoidBoundingBoxTests {

    /// A genuinely void shape: the intersection of two far-disjoint boxes, which
    /// still builds a valid `TopoDS_Shape` holding nothing, so OCCT's own
    /// `Bnd_Box::IsVoid()` is true and every extent accessor reports nil.
    /// `Shape.compound([])` is not usable here (the bridge requires at least one
    /// member); this is the same fixture OCCTSwift's own #943 tests use.
    func voidShape() throws -> Shape {
        let b1 = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let b2 = try #require(
            Shape.box(origin: SIMD3(1000, 1000, 1000), width: 10, height: 10, depth: 10))
        let shape = try #require(b1.intersection(b2), "a disjoint intersection should still build")
        try #require(
            shape.bounds == nil,
            "fixture assumption broken: a disjoint intersection must have no bounding box")
        return shape
    }

    /// A one-body scene holding `shape`. `allowInvalid` is required: a shape
    /// with nothing in it does not pass the BREP write-gate.
    func scene(bodyId: String, shape: Shape) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-voidbbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "void bbox",
                bodies: [BodyDescriptor(id: bodyId, file: "\(bodyId).brep", color: [1, 1, 1, 1])]
            ))
        try Exporter.writeBREP(
            shape: shape, to: URL(fileURLWithPath: "\(dir)/\(bodyId).brep"), allowInvalid: true)
        return store
    }

    @Test("show_bounding_box errors instead of reporting a zero-sized box at the origin")
    func showBoundingBoxErrors() async throws {
        let store = try scene(bodyId: "empty", shape: try voidShape())

        let result = await GapFillerTools.showBoundingBox(bodyId: "empty", store: store)

        #expect(result.isError, "expected an error, got: \(result.text)")
        #expect(result.text.contains("no bounding box"))
        // The old fabricated answer, which must never come back.
        #expect(!result.text.contains("\"extent\""))
        #expect(!result.text.contains("\"center\""))
    }

    @Test("compute_metrics omits boundingBox rather than reporting one")
    func computeMetricsOmitsBoundingBox() async throws {
        let store = try scene(bodyId: "empty", shape: try voidShape())

        let result = await IntrospectionTools.computeMetrics(
            bodyId: "empty", metrics: ["boundingBox"], store: store)

        #expect(!result.isError, "unexpected error: \(result.text)")
        // Absent, not zeroed: `MetricsReport.boundingBox` is Optional and
        // Encodable drops a nil, the same shape `boundingBoxOptimal` always had.
        #expect(!result.text.contains("boundingBox"))
    }

    @Test("select_topology's body anchor errors: the anchor IS the bbox centre")
    func selectBodyAnchorErrors() async throws {
        let store = try scene(bodyId: "empty", shape: try voidShape())

        let result = await SelectionTools.selectTopology(
            bodyId: "empty", kind: "body", store: store)

        #expect(result.isError, "expected an error, got: \(result.text)")
        #expect(result.text.contains("no bounding box"))
    }

    @Test("defaultDeflection returns nil, so no tool derives a model scale from nothing")
    func defaultDeflectionIsNil() throws {
        #expect(DeviationTools.defaultDeflection(for: try voidShape()) == nil)
    }

    @Test("read_brep refuses an empty BREP and leaves the scene untouched")
    func readBrepRefusesAndDoesNotMutate() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-voidbbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "void bbox", bodies: []))
        let brep = "\(dir)/empty.brep"
        try Exporter.writeBREP(
            shape: try voidShape(), to: URL(fileURLWithPath: brep), allowInvalid: true)

        let result = await IOTools.readBrep(
            inputPath: brep, bodyId: "empty", store: store, history: SceneHistory())

        #expect(result.isError, "expected an error, got: \(result.text)")
        #expect(result.text.contains("Nothing was added to the scene"))
        #expect((try store.read())?.bodies.isEmpty == true, "the scene must not have been mutated")
    }
}
