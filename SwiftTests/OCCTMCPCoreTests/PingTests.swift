import Testing
import MCP
@testable import OCCTMCPCore

@Suite("OCCTMCP server scaffold")
struct PingTests {
    @Test("server lists the ping tool")
    func listsPing() async throws {
        let tools = catalogTools()
        #expect(tools.contains(where: { $0.name == "ping" }))
    }

    @Test("server exposes exactly 77 tools (#118 adds measure_vertex_fit, #121 adds fit_edge_chain)")
    func toolCount() async throws {
        #expect(catalogTools().count == 77)
    }

    @Test("ping handler returns pong")
    func pingPongs() async throws {
        let result = await dispatch(callName: "ping", arguments: [:])
        #expect(result.isError == false)
        guard case .text(let text, _, _) = result.content.first else {
            Issue.record("expected a text content block")
            return
        }
        #expect(text == "pong")
    }

    @Test("unknown tool name produces an error result")
    func unknownToolErrors() async throws {
        let result = await dispatch(callName: "no-such-tool", arguments: [:])
        #expect(result.isError == true)
    }
}
