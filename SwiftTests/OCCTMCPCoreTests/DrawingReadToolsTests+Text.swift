// The text the drawing read tools return is the text the reader decodes (SwiftDXF 0.5.0, through
// OCCTSwiftIO 2.0.0-beta.10, #274): a control code such as `%%c` comes back as the character it
// stands for. The decode is SwiftDXF's, so these tests pin what this server hands on, not how it
// is done.

import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

extension DrawingReadToolsTests {

    @Test("TEXT and MTEXT come back decoded: %%c is the diameter sign")
    func textIsDecoded() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fixture = DrawingFixture()
        fixture.add(
            "text", "TEXT", layer: "0",
            [(10, "0"), (20, "0"), (30, "0"), (40, "2.5"), (1, "%%c10")])
        fixture.add(
            "mtext", "MTEXT", layer: "0",
            [(10, "0"), (20, "5"), (30, "0"), (40, "2.5"), (1, "%%c12")])
        let path = try fixture.write(to: dir)
        let all = try await entities(["types": ["text"]], path).all
        let byId = Dictionary(
            all.compactMap { entity -> (String, String)? in
                guard let id = entity["id"] as? String, let text = entity["text"] as? String
                else { return nil }
                return (id, text)
            }, uniquingKeysWith: { first, _ in first })
        #expect(all.count == 2, "\(all)")
        #expect(byId[fixture.id("text")] == "\u{2300}10", "\(byId)")
        #expect(byId[fixture.id("mtext")] == "\u{2300}12", "\(byId)")
    }
}
