// highlight_selection with an empty or blank `question` (SecondMouseAU/OCCTMCP#293). The viewport
// host reads nil, the empty string and a string that draws nothing as no question
// (SecondMouseAU/OCCTSwiftInteraction#62), and applies the same blank rule to a `label`
// (SecondMouseAU/OCCTSwiftInteraction#54). These tests drive the real tool and read the request
// file it wrote. The fixture scene and the lock helper are the ones in
// SelectionBridgeToolsTests.swift.

import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

/// One string a test feeds the tool, with a name that says which blank class it is.
struct BlankSample: Sendable, CustomTestStringConvertible {
    let name: String
    let text: String
    var testDescription: String { name }
}

extension SelectionBridgeToolsTests {

    // MARK: - fixtures

    /// Strings the host reads as blank, one per class of the rule plus a mix.
    static let blankSamples: [BlankSample] = [
        BlankSample(name: "empty", text: ""),
        BlankSample(name: "spaces", text: "   "),
        BlankSample(name: "newline and tab", text: "\n\t "),
        BlankSample(name: "hangul filler U+3164", text: "\u{3164}"),
        BlankSample(name: "braille blank U+2800", text: "\u{2800}"),
        BlankSample(name: "zero width joiner U+200D", text: "\u{200D}"),
        BlankSample(name: "bell U+0007", text: "\u{0007}"),
        BlankSample(name: "object replacement U+FFFC", text: "\u{FFFC}"),
        BlankSample(name: "interlinear anchor U+FFF9", text: "\u{FFF9}"),
        BlankSample(name: "interlinear separator U+FFFA", text: "\u{FFFA}"),
        BlankSample(name: "interlinear terminator U+FFFB", text: "\u{FFFB}"),
        BlankSample(name: "khitan filler U+16FE4", text: "\u{16FE4}"),
        BlankSample(name: "null notehead U+1D159", text: "\u{1D159}"),
        BlankSample(
            name: "a mix of every kind",
            text:
                " \u{3164}\u{2800}\u{200D}\u{0007}\u{FFFC}\u{FFF9}\u{FFFA}\u{FFFB}\u{16FE4}\u{1D159}\n"
        ),
    ]

    /// What one `highlight_selection` call returned and wrote.
    struct HighlightCall {
        let result: ToolText
        /// The request file's JSON object; nil when the call wrote no request.
        let request: [String: Any]?
    }

    /// Calls `highlight_selection` against a live host that never answers.
    func callHighlight(
        kind: String = "face", target: String = SelectionBridgeTools.defaultTarget,
        question: String?, label: String? = nil
    ) async throws -> HighlightCall {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: kind, index: 1, scheme: "replace", target: target,
            question: question, label: label, store: store,
            timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        let requestsDir = "\(dir)/highlight_requests"
        guard FileManager.default.fileExists(atPath: requestsDir) else {
            return HighlightCall(result: result, request: nil)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: requestsDir)
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 1, "expected exactly one request file, found \(files)")
        let name = try #require(files.first)
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(requestsDir)/\(name)"))
        let raw = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return HighlightCall(result: result, request: raw)
    }

    /// Plays the host: waits for the request file, then writes `handled` as its answer.
    func answerHandled(
        dir: String, _ handled: SelectionBridgeTools.HandledOutcome
    ) async throws {
        let requestsDir = "\(dir)/highlight_requests"
        var requestId: String?
        for _ in 0..<200 {
            if let files = try? FileManager.default.contentsOfDirectory(atPath: requestsDir),
                let match = files.first(where: { $0.hasSuffix(".json") })
            {
                requestId = String(match.dropLast(".json".count))
                break
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        let id = try #require(requestId, "highlight_selection never wrote a request file")
        let handledDir = "\(requestsDir)/handled"
        try FileManager.default.createDirectory(
            atPath: handledDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(handled).write(
            to: URL(fileURLWithPath: "\(handledDir)/\(id).json"), options: .atomic)
    }

    /// The keys of a request that carries no `question` and no `label`.
    static let bareRequestKeys: Set<String> = [
        "id", "bodyId", "kind", "index", "scheme", "target",
    ]

    // MARK: - the sample list

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): the blank samples are the classes the host's rule names"
    )
    func blankSampleMembership() {
        // A list a parameterized test walks must not shrink unseen: an empty or short list
        // would let every test below pass over fewer rows.
        let names = Set(Self.blankSamples.map(\.name))
        #expect(Self.blankSamples.count == 14)
        #expect(names.count == Self.blankSamples.count, "a sample name is repeated")
        let expected: Set<String> = [
            "empty", "spaces", "newline and tab", "hangul filler U+3164", "braille blank U+2800",
            "zero width joiner U+200D", "bell U+0007", "object replacement U+FFFC",
            "interlinear anchor U+FFF9", "interlinear separator U+FFFA",
            "interlinear terminator U+FFFB", "khitan filler U+16FE4", "null notehead U+1D159",
            "a mix of every kind",
        ]
        #expect(names == expected)
    }

    // MARK: - the helper

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): isBlank follows the host's rule scalar by scalar"
    )
    func isBlankFollowsTheHostRule() {
        for sample in Self.blankSamples {
            #expect(SelectionBridgeTools.isBlank(sample.text), "\(sample.name) is blank")
        }
        // One scalar short of each named class, and ordinary marks, are not blank.
        let visible = [
            "a", "?", "0", "\u{2801}", "\u{FFFD}", "\u{16FE3}", "\u{1D158}", "\u{1D15A}",
            "\u{0301}", "\u{00B7}", "\u{3042}",
        ]
        #expect(visible.count == 11)
        for text in visible {
            #expect(!SelectionBridgeTools.isBlank(text), "\(text.debugDescription) is visible")
        }
        // One visible scalar among blank ones is enough, wherever it sits.
        #expect(!SelectionBridgeTools.isBlank("\u{3164}a"))
        #expect(!SelectionBridgeTools.isBlank("a\u{3164}"))
        #expect(!SelectionBridgeTools.isBlank("\u{3164}\u{0301}"))
        #expect(!SelectionBridgeTools.isBlank(" \u{200D}x\u{200D} "))
    }

    // MARK: - a blank question is no question

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a blank question is not written and the label is validated and written",
        arguments: SelectionBridgeToolsTests.blankSamples)
    func blankQuestionIsNoQuestion(_ sample: BlankSample) async throws {
        let call = try await callHighlight(
            target: "attention", question: sample.text, label: "mounting face")
        #expect(!call.result.isError, "unexpected error: \(call.result.text)")
        let raw = try #require(call.request, "nothing was written for \(sample.name)")
        #expect(raw["question"] == nil, "the blank question was written: \(raw)")
        #expect(raw["target"] as? String == "attention")
        #expect(raw["label"] as? String == "mounting face")
        #expect(Set(raw.keys) == Self.bareRequestKeys.union(["label"]))
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a blank question under target selection is not written either",
        arguments: SelectionBridgeToolsTests.blankSamples)
    func blankQuestionUnderSelection(_ sample: BlankSample) async throws {
        let call = try await callHighlight(
            target: "selection", question: sample.text, label: "ignored here")
        #expect(!call.result.isError, "unexpected error: \(call.result.text)")
        let raw = try #require(call.request)
        #expect(raw["question"] == nil, "the blank question was written: \(raw)")
        #expect(raw["label"] == nil, "a label under target selection is ignored")
        #expect(Set(raw.keys) == Self.bareRequestKeys)
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a blank question gets the same error as no question for body under attention",
        arguments: SelectionBridgeToolsTests.blankSamples)
    func blankQuestionBodyAttentionRefused(_ sample: BlankSample) async throws {
        let reference = try await callHighlight(kind: "body", question: nil)
        #expect(reference.result.isError)
        #expect(
            reference.result.text.contains("no whole-body attention marker"),
            "the reference is not the tool's own error: \(reference.result.text)")

        let call = try await callHighlight(kind: "body", question: sample.text)
        #expect(call.result.isError, "kind body under attention was accepted")
        #expect(call.result.text == reference.result.text)
        #expect(call.request == nil, "a refused request must never be written")
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a blank question with kind body under selection is written without it"
    )
    func blankQuestionBodySelection() async throws {
        let call = try await callHighlight(kind: "body", target: "selection", question: "\u{3164}")
        #expect(!call.result.isError, "unexpected error: \(call.result.text)")
        let raw = try #require(call.request)
        #expect(raw["kind"] as? String == "body")
        #expect(raw["target"] as? String == "selection")
        #expect(raw["question"] == nil)
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a blank label is refused beside a blank question, a real one is written"
    )
    func blankQuestionDoesNotRescueABlankLabel() async throws {
        let refused = try await callHighlight(question: "\u{2800}", label: "\u{3164}")
        #expect(refused.result.isError)
        #expect(refused.result.text.contains("label must not be empty"))
        #expect(refused.request == nil)
    }

    // MARK: - a question with a visible character is a question

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a question with a visible character is written exactly as sent",
        arguments: [
            BlankSample(name: "one mark among spaces", text: "  ?  "),
            BlankSample(name: "letter between hangul fillers", text: "\u{3164}a\u{3164}"),
            BlankSample(name: "a lone question mark", text: "?"),
            BlankSample(name: "a combining mark after a filler", text: "\u{3164}\u{0301}"),
            BlankSample(name: "joiner, letter, newline", text: " \u{200D}x\u{200D}\n"),
            BlankSample(name: "an ordinary question", text: "Is this the datum?"),
        ])
    func visibleQuestionIsKeptAsSent(_ sample: BlankSample) async throws {
        // Over-long, so the label would be refused if it were validated: a request with a
        // question lands in the selection and the host ignores a label on it.
        let call = try await callHighlight(
            target: "attention", question: sample.text, label: String(repeating: "x", count: 200))
        #expect(!call.result.isError, "unexpected error: \(call.result.text)")
        let raw = try #require(call.request)
        #expect(raw["question"] as? String == sample.text, "the question was changed: \(raw)")
        #expect(raw["label"] == nil)
        #expect(Set(raw.keys) == Self.bareRequestKeys.union(["question"]))
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a visible question keeps kind body under attention exempt"
    )
    func visibleQuestionBodyAttentionStillExempt() async throws {
        let call = try await callHighlight(kind: "body", question: " ? ")
        #expect(!call.result.isError, "unexpected error: \(call.result.text)")
        let raw = try #require(call.request)
        #expect(raw["kind"] as? String == "body")
        #expect(raw["question"] as? String == " ? ")
    }

    // MARK: - a label blank by the host's rule

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a label that draws nothing is refused with the label error",
        arguments: SelectionBridgeToolsTests.blankSamples)
    func blankLabelIsRefused(_ sample: BlankSample) async throws {
        let call = try await callHighlight(question: nil, label: sample.text)
        #expect(call.result.isError, "blank label \(sample.name) was accepted")
        #expect(
            call.result.text
                == "highlight_selection: label must not be empty or blank (it needs a visible character). "
                + "Omit it to send no label.")
        #expect(call.request == nil, "a refused label must write nothing")
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a label with a visible character is written unchanged"
    )
    func visibleLabelIsKeptAsSent() async throws {
        for label in ["\u{3164}mounting face\u{3164}", " a ", "\u{2800}?\u{2800}"] {
            let call = try await callHighlight(question: nil, label: label)
            #expect(!call.result.isError, "unexpected error: \(call.result.text)")
            let raw = try #require(call.request)
            #expect(raw["label"] as? String == label, "the label was changed: \(raw)")
        }
    }

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a label that draws nothing is ignored, not refused, under selection"
    )
    func blankLabelIgnoredUnderSelection() async throws {
        let call = try await callHighlight(target: "selection", question: nil, label: "\u{3164}")
        #expect(!call.result.isError, "unexpected error: \(call.result.text)")
        let raw = try #require(call.request)
        #expect(raw["label"] == nil)
    }

    // MARK: - the host's answer

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): the reason on an applied answer reaches the result"
    )
    func highlightSurfacesAppliedReason() async throws {
        // A host on a newer Unicode table can call blank a question this server called visible.
        // It then answers applied with a reason, and the agent must see it.
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        async let resultTask = SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", question: "x", store: store,
            timeoutSeconds: 5.0, pollIntervalSeconds: 0.02)
        try await answerHandled(
            dir: dir,
            SelectionBridgeTools.HandledOutcome(
                outcome: "applied", reason: "question dropped: it has no visible character",
                target: "attention"))

        let result = await resultTask
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        #expect(json["outcome"] as? String == "applied")
        #expect(json["reason"] as? String == "question dropped: it has no visible character")
        #expect(json["target"] as? String == "attention")
    }

    // MARK: - through the server

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): a blank question sent over the wire is dropped and the label written"
    )
    func blankQuestionOverTheWire() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        // Through the server, not the tool directly: `arguments["question"]?.stringValue` in
        // Server.swift is the only thing between the wire and the tool.
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(outputDirectory: URL(fileURLWithPath: dir))
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let args: [String: Value] = [
            "bodyId": .string("box"), "kind": .string("face"), "index": .int(1),
            "scheme": .string("replace"), "question": .string("\u{3164}"),
            "label": .string("mounting face"), "timeoutSeconds": .double(0.2),
        ]
        let (content, isError) = try await client.callTool(
            name: "highlight_selection", arguments: args)
        var text = ""
        if case .text(let t, _, _) = content.first { text = t }
        #expect(isError != true, "unexpected error: \(text)")
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let id = try #require(json["id"] as? String, "no request id in \(text)")
        let raw = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/highlight_requests/\(id).json"))
            )
                as? [String: Any])
        #expect(raw["question"] == nil)
        #expect(raw["label"] as? String == "mounting face")
    }

    // MARK: - the tool description

    @Test(
        "highlight_selection (SecondMouseAU/OCCTMCP#293): the description no longer promises that every question selects"
    )
    func descriptionSaysWhatABlankQuestionDoes() throws {
        let tool = try #require(catalogTools().first { $0.name == "highlight_selection" })
        let description = try #require(tool.description)
        #expect(
            !description.localizedCaseInsensitiveContains(
                "requests with a question always land in the selection"),
            "the old promise is back")
        #expect(
            !description.contains("when `question` is given"),
            "the label is not ignored for every question")
        #expect(description.contains("A non-blank question always lands in the selection"))
        #expect(description.contains("an empty or blank one (nothing visible) is dropped"))

        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        func text(_ name: String) throws -> String {
            try #require(properties[name]?.objectValue?["description"]?.stringValue, "\(name)")
        }
        #expect(try text("question").contains("Empty or blank counts as none"))
        let label = try text("label")
        #expect(label.contains("not blank"))
        #expect(!label.contains("whitespace-only"), "the label rule is wider than whitespace")
        #expect(label.contains("without a non-blank `question`"))
    }
}
