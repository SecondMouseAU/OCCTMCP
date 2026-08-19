// OCCTMCPServer: executable entry point. Builds the MCP server, binds it
// to stdio, and parks until the client disconnects.

import Foundation
import MCP
import OCCTMCPCore

@main
struct OCCTMCPServerMain {
    static func main() async throws {
        let server = await makeOCCTMCPServer()
        let transport = StdioTransport()
        try await server.start(transport: transport)
        await server.waitUntilCompleted()
    }
}
