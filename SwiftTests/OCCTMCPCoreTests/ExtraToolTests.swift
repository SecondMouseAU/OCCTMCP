import MCP
import Testing

@testable import OCCTMCPCore

@Suite("ExtraTool embedding (#196)")
struct ExtraToolTests {
    struct Boom: Error {}

    static func extra(_ name: String, reply: String) -> ExtraTool {
        ExtraTool(
            tool: Tool(
                name: name, description: "extra \(name)",
                inputSchema: .object(["type": .string("object")])),
            handler: { _ in
                .init(content: [.text(text: reply, annotations: nil, _meta: nil)], isError: false)
            })
    }

    static func text(_ result: CallTool.Result) -> String? {
        if case .text(let t, _, _) = result.content.first { return t }
        return nil
    }

    @Test("no extras leaves the catalog identical")
    func noExtrasUnchanged() {
        #expect(catalogTools(extraTools: []).map(\.name) == catalogTools().map(\.name))
    }

    @Test("extra is listed after the built-ins and is callable")
    func listedAndCallable() async {
        let extras = [Self.extra("host_tool", reply: "hi")]
        let names = catalogTools(extraTools: extras).map(\.name)
        #expect(names.last == "host_tool")
        #expect(Array(names.dropLast()) == catalogTools().map(\.name))
        let result = await dispatch(callName: "host_tool", arguments: [:], extraTools: extras)
        #expect(Self.text(result) == "hi")
    }

    @Test("unknown name still errors")
    func unknownErrors() async {
        let result = await dispatch(
            callName: "nope", arguments: [:], extraTools: [Self.extra("host_tool", reply: "hi")])
        #expect(result.isError == true)
    }

    @Test("collision: extra wins and the name appears once")
    func collision() async {
        let extras = [Self.extra("ping", reply: "custom")]
        let names = catalogTools(extraTools: extras).map(\.name)
        #expect(names.filter { $0 == "ping" }.count == 1)
        #expect(names.count == catalogTools().count)
        let result = await dispatch(callName: "ping", arguments: [:], extraTools: extras)
        #expect(Self.text(result) == "custom")
    }

    @Test("duplicate extras: last wins")
    func duplicateExtras() async {
        let extras = [Self.extra("dup", reply: "a"), Self.extra("dup", reply: "b")]
        #expect(catalogTools(extraTools: extras).map(\.name).filter { $0 == "dup" }.count == 1)
        let result = await dispatch(callName: "dup", arguments: [:], extraTools: extras)
        #expect(Self.text(result) == "b")
    }

    @Test("handler error becomes an error result")
    func handlerThrows() async {
        let bad = ExtraTool(
            tool: Tool(name: "bad", description: "x", inputSchema: .object([:])),
            handler: { _ in throw Boom() })
        let result = await dispatch(callName: "bad", arguments: [:], extraTools: [bad])
        #expect(result.isError == true)
    }

    @Test("get_api_reference mcp_tools includes extras")
    func apiReferenceIncludesExtras() async {
        let result = await dispatch(
            callName: "get_api_reference", arguments: [:],
            extraTools: [Self.extra("host_tool", reply: "hi")])
        #expect(Self.text(result)?.contains("host_tool") == true)
    }
}
