// Direct unit tests for CorrespondenceTools.findCorrespondences's #155 fix:
// sourceSelectionIds resolving to ZERO source bodies (a genuinely empty
// array, or one where every entry fails to parse as a selectionId) now
// warns explaining why, distinguishing the two sub-cases, instead of
// silently falling to identity-fallback with an empty warnings array. This
// is the same kind of silent gap #131 fixed for the ambiguous (>1 body)
// case; #155 is the review follow-up that noticed the 0-body case was
// left open.
//
// Calls `findCorrespondences` directly, the same test-the-tool-function
// approach `MeshZoneToolsTests` uses for `segmentMeshZones`, rather than
// IntegrationTests.swift's harness/binary route: per that file's own
// header comment, the harness suite is reserved for the wired-up-server
// smoke test, and "the unit suites already cover the deterministic
// logic" is exactly this case.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("find_correspondences: sourceSelectionIds resolving to zero bodies (#155)")
struct CorrespondenceZeroSourceBodyTests {

    /// A minimal one-body scene: just enough for `findCorrespondences` to
    /// get past its target-body/BREP-existence checks. `bodyId` should be
    /// unique per test (a UUID suffix) since `HistoryRegistry.shared` is a
    /// process-wide singleton these direct-call tests share with every
    /// other test in the same run.
    func targetScene(bodyId: String) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-corr155-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let descriptor = BodyDescriptor(id: bodyId, file: "\(bodyId).brep", color: [1, 1, 1, 1])
        let manifest = ScriptManifest(version: 1, timestamp: Date(), description: "correspondence #155 test", bodies: [descriptor])
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/\(bodyId).brep"))
        return store
    }

    struct Report: Decodable {
        let transformSource: String
        let warnings: [String]
    }

    @Test("a genuinely empty sourceSelectionIds warns, distinctly from the unparseable case")
    func emptyArrayWarns() async throws {
        let bodyId = "corr155-empty-\(UUID().uuidString)"
        let store = try targetScene(bodyId: bodyId)
        let result = await CorrespondenceTools.findCorrespondences(
            sourceSelectionIds: [], targetBodyId: bodyId, transform: nil,
            store: store, registry: SelectionRegistry()
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let report = try JSONDecoder().decode(Report.self, from: Data(result.text.utf8))
        #expect(report.transformSource == "identity-fallback")
        #expect(report.warnings.count == 1)
        let warning = try #require(report.warnings.first)
        #expect(warning.contains("sourceSelectionIds is empty"))
        #expect(!warning.contains("no parseable selectionId"))
    }

    @Test("sourceSelectionIds with only unparseable entries warns, distinctly from the empty-array case")
    func unparseableEntriesWarn() async throws {
        let bodyId = "corr155-unparseable-\(UUID().uuidString)"
        let store = try targetScene(bodyId: bodyId)
        let result = await CorrespondenceTools.findCorrespondences(
            sourceSelectionIds: ["not-a-selection-id", "also-not-one"], targetBodyId: bodyId, transform: nil,
            store: store, registry: SelectionRegistry()
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let report = try JSONDecoder().decode(Report.self, from: Data(result.text.utf8))
        #expect(report.transformSource == "identity-fallback")
        #expect(report.warnings.count == 1)
        let warning = try #require(report.warnings.first)
        #expect(warning.contains("no parseable selectionId"))
        #expect(!warning.contains("is empty"))
    }

    @Test("an explicit transform suppresses the zero-source-body warning even with an empty sourceSelectionIds")
    func explicitTransformSuppressesWarning() async throws {
        let bodyId = "corr155-explicit-\(UUID().uuidString)"
        let store = try targetScene(bodyId: bodyId)
        let result = await CorrespondenceTools.findCorrespondences(
            sourceSelectionIds: [], targetBodyId: bodyId,
            transform: .translate(offset: SIMD3(1, 0, 0)),
            store: store, registry: SelectionRegistry()
        )
        #expect(!result.isError, "unexpected error: \(result.text)")
        let report = try JSONDecoder().decode(Report.self, from: Data(result.text.utf8))
        #expect(report.transformSource == "explicit")
        #expect(report.warnings.isEmpty)
    }
}
