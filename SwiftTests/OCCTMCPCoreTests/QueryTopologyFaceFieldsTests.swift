// QueryTopologyFaceFieldsTests (#197): query_topology's face results carry
// `index`, `center` and `normal` so an agent can compare faces without
// selecting each one first, and no component prints as negative zero.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("query_topology face fields (#197)")
struct QueryTopologyFaceFieldsTests {

    @Test("face results carry index matching id, a center, and a -0-free normal")
    func faceFields() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-qtface-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "qt",
                bodies: [BodyDescriptor(id: "box", file: "box.brep", color: [1, 1, 1, 1])]))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(dir)/box.brep"))

        let result = await IntrospectionTools.queryTopology(
            bodyId: "box", entity: "face", store: store)
        #expect(!result.isError, "unexpected error: \(result.text)")
        #expect(!result.text.contains("-0,") && !result.text.contains("-0\n"))
        let obj = try #require(
            try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        let faces = try #require(obj["results"] as? [[String: Any]])
        #expect(faces.count == 6)
        for f in faces {
            let index = try #require(f["index"] as? Int)
            #expect(f["id"] as? String == "face[\(index)]")
            let center = try #require(f["center"] as? [Double])
            let normal = try #require(f["normal"] as? [Double])
            #expect(center.count == 3 && normal.count == 3)
            let len = (normal.map { $0 * $0 }.reduce(0, +)).squareRoot()
            #expect(abs(len - 1) < 1e-6)
        }
    }
}
