// Unit test for #136: graph_select's face-neighbors bounds-check error path
// must read the face count off the AAG already built for the lookup rather
// than constructing a second, throwaway one.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("graph_select face-neighbors bounds check")
struct AnalysisToolsTests {

    @Test("out-of-range face reports the correct face count")
    func faceNeighborsOutOfRangeReportsFaceCount() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-graphselect-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let brep = "\(dir)/box.brep"
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: brep))

        let result = await AnalysisTools.graphSelect(
            brepPath: brep, query: "face-neighbors",
            face: 999, edge: nil, vertex: nil, edgeClass: nil)
        #expect(result.isError)
        #expect(result.text == "face-neighbors requires `face` in 0..<6")
    }
}
