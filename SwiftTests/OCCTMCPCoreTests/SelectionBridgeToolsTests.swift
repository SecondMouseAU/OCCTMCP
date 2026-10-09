// SelectionBridgeToolsTests (#189/#190): get_selection / highlight_selection
// against hand-written fixture files in a tempdir, exactly as both
// refined-spec comments describe. No host actually implements the writer
// side yet (SecondMouseAU/OCCTSwiftInteraction#16/ACADStudio#16 are still
// upstream), so every test here plays the host itself: it holds host.lock,
// writes selection.json / handled/<id>.json by hand, and asserts the tool's
// response against that fixture.

import Foundation
import MCP
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Holds an exclusive flock on a file for the lifetime of the test, playing
/// the part of a live viewport host per the ADR (`host.lock`).
final class HeldLock {
    private let fd: Int32

    init?(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        let opened = open(path, O_RDWR)
        guard opened >= 0 else { return nil }
        guard flock(opened, LOCK_EX) == 0 else {
            close(opened)
            return nil
        }
        fd = opened
    }

    func release() {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

@Suite("SelectionBridgeTools (#189/#190)")
struct SelectionBridgeToolsTests {

    // MARK: - fixture scene

    func scene(_ bodies: [(id: String, shape: Shape)]) throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-selbridge-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let descriptors = bodies.map {
            BodyDescriptor(id: $0.id, file: "\($0.id).brep", color: [1, 1, 1, 1])
        }
        let manifest = ScriptManifest(
            version: 1, timestamp: Date(), description: "selbridge", bodies: descriptors)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(manifest)
        for b in bodies {
            try Exporter.writeBREP(shape: b.shape, to: URL(fileURLWithPath: "\(dir)/\(b.id).brep"))
        }
        return store
    }

    func dirOf(_ store: ManifestStore) -> String { (store.path as NSString).deletingLastPathComponent }

    func writeSelectionSidecar(
        dir: String,
        selections: [(bodyId: String, kind: String, index: Int, uid: String?)],
        revision: Int = 1
    ) throws {
        let entries = selections.map {
            SelectionBridgeTools.SelectionJSONEntry(
                bodyId: $0.bodyId, kind: $0.kind, index: $0.index, uid: $0.uid)
        }
        let sidecar = SelectionBridgeTools.SelectionSidecar(
            selections: entries, revision: revision, updatedAt: "2026-08-21T00:00:00Z")
        let data = try JSONEncoder().encode(sidecar)
        try data.write(to: URL(fileURLWithPath: "\(dir)/selection.json"), options: .atomic)
    }

    // MARK: - decode mirrors

    struct ResolvedSelectionMirror: Decodable {
        let selectionId: String?
        let bodyId: String
        let kind: String
        let index: Int
        let uid: String?
        let error: String?
    }
    struct GetSelectionResultMirror: Decodable {
        let state: String
        let selections: [ResolvedSelectionMirror]?
        let revision: Int?
        let updatedAt: String?
    }
    struct HighlightResultMirror: Decodable {
        let id: String?
        let outcome: String
        let reason: String?
    }

    // ── get_selection: three liveness states ─────────────────────────────

    @Test("get_selection: no host.lock at all -> state=noHost, selections=nil")
    func getSelectionNoHost() async throws {
        let store = try scene([])
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }

        let result = await SelectionBridgeTools.getSelection(store: store)
        #expect(!result.isError)
        let r = try JSONDecoder().decode(GetSelectionResultMirror.self, from: Data(result.text.utf8))
        #expect(r.state == "noHost")
        #expect(r.selections == nil)
    }

    @Test("get_selection: host running, selection.json has zero entries -> hostRunning([])")
    func getSelectionHostRunningEmpty() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }
        try writeSelectionSidecar(dir: dir, selections: [])

        let result = await SelectionBridgeTools.getSelection(store: store)
        #expect(!result.isError)
        let r = try JSONDecoder().decode(GetSelectionResultMirror.self, from: Data(result.text.utf8))
        #expect(r.state == "hostRunning")
        #expect(r.selections?.isEmpty == true, "must be an empty array, not nil, when a host is live")
    }

    @Test("get_selection: host running, selection.json has entries -> hostRunning([...]), resolved + registered")
    func getSelectionHostRunningWithEntries() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([("box", box)])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }
        try writeSelectionSidecar(
            dir: dir,
            selections: [(bodyId: "box", kind: "face", index: 0, uid: "host-uid-abc123")])

        let registry = SelectionRegistry()
        let result = await SelectionBridgeTools.getSelection(store: store, registry: registry)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(GetSelectionResultMirror.self, from: Data(result.text.utf8))
        #expect(r.state == "hostRunning")
        let selections = try #require(r.selections)
        #expect(selections.count == 1)
        let entry = selections[0]
        #expect(entry.error == nil, "resolution should have succeeded: \(entry.error ?? "")")
        #expect(entry.uid == "host-uid-abc123", "the host's own wire uid passes through unchanged")
        let selectionId = try #require(entry.selectionId)
        #expect(selectionId.hasPrefix("sel:box#face["))

        // #189 criterion: the minted selectionId must round-trip through
        // SelectionRegistry, so remap_selection/measure_distance/etc. can
        // consume it exactly like one select_topology minted itself.
        let anchor = await registry.anchor(for: selectionId)
        #expect(anchor != nil, "selectionId must resolve through SelectionRegistry")
        let snapshot = await registry.snapshot(for: selectionId)
        #expect(snapshot != nil)
        #expect(snapshot?.area != nil, "a face selection should carry an area, resolved like select_topology's own")
    }

    @Test("get_selection: an entry with a bad bodyId or out-of-range index is reported per-entry, not fatal")
    func getSelectionPartialResolutionFailure() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let store = try scene([("box", box)])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }
        try writeSelectionSidecar(
            dir: dir,
            selections: [
                (bodyId: "box", kind: "face", index: 0, uid: nil),
                (bodyId: "does-not-exist", kind: "face", index: 0, uid: nil),
                (bodyId: "box", kind: "face", index: 9999, uid: nil),
            ])

        let registry = SelectionRegistry()
        let result = await SelectionBridgeTools.getSelection(store: store, registry: registry)
        #expect(!result.isError, "a per-entry failure must not fail the whole call")
        let r = try JSONDecoder().decode(GetSelectionResultMirror.self, from: Data(result.text.utf8))
        let selections = try #require(r.selections)
        #expect(selections.count == 3)
        #expect(selections[0].error == nil)
        #expect(selections[0].selectionId != nil)
        #expect(selections[1].error != nil, "bad bodyId should surface a per-entry error")
        #expect(selections[1].selectionId == nil)
        #expect(selections[2].error != nil, "out-of-range index should surface a per-entry error")
        #expect(selections[2].selectionId == nil)
    }

    // ── get_selection: torn/malformed selection.json ─────────────────────

    @Test("get_selection: host running but selection.json missing -> explicit error, not empty result")
    func getSelectionMissingSidecarIsError() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }
        // Deliberately never write selection.json.

        let result = await SelectionBridgeTools.getSelection(store: store)
        #expect(result.isError, "a running host with no selection.json at all must be an explicit error")
        #expect(result.text.contains("selection.json is missing"), "wrong error: \(result.text)")
    }

    @Test("get_selection: torn/malformed selection.json -> explicit error, not swallowed into an empty result")
    func getSelectionMalformedSidecarIsError() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }
        // A torn write: valid JSON syntax truncated mid-object, simulating a
        // non-atomic writer caught mid-write.
        let torn = Data("{\"selections\": [{\"bodyId\": \"box\", \"kind\"".utf8)
        try torn.write(to: URL(fileURLWithPath: "\(dir)/selection.json"))

        let result = await SelectionBridgeTools.getSelection(store: store)
        #expect(result.isError, "malformed JSON must be reported as an explicit error")
        #expect(result.text.contains("is malformed"), "wrong error: \(result.text)")
    }

    // ── highlight_selection: writes request, generates id, atomic write ──

    @Test("highlight_selection: no host at all -> outcome=noHost immediately, no request written")
    func highlightNoHost() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
            timeoutSeconds: 1.0, pollIntervalSeconds: 0.02)
        #expect(!result.isError)
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.outcome == "noHost")
        #expect(r.id == nil)
        #expect(
            !FileManager.default.fileExists(atPath: "\(dir)/highlight_requests"),
            "must not write a request nothing will ever consume")
    }

    @Test("highlight_selection: rejects an unknown kind/scheme before writing anything")
    func highlightRejectsBadEnumsClientSide() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let badKind = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "diamond", index: 0, scheme: "replace", store: store)
        #expect(badKind.isError)
        #expect(badKind.text.contains("unknown kind 'diamond'"), "wrong error: \(badKind.text)")

        let badScheme = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "toggle-ish", store: store)
        #expect(badScheme.isError)
        #expect(badScheme.text.contains("unknown scheme 'toggle-ish'"), "wrong error: \(badScheme.text)")

        #expect(
            !FileManager.default.fileExists(atPath: "\(dir)/highlight_requests"),
            "a wire-format-invalid request must never be written")
    }

    @Test("highlight_selection: a bad bodyId / out-of-range index is still written, not pre-checked client-side")
    func highlightWritesUnvalidatedSceneReferences() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "does-not-exist", kind: "face", index: 999, scheme: "xor", store: store,
            timeoutSeconds: 0.2, pollIntervalSeconds: 0.02)
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.outcome == "timeout", "no host consumed it in this test, so it should time out, not fail up front")
        let id = try #require(r.id)

        let requestPath = "\(dir)/highlight_requests/\(id).json"
        #expect(FileManager.default.fileExists(atPath: requestPath))
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        let written = try JSONDecoder().decode(SelectionBridgeTools.HighlightRequest.self, from: data)
        #expect(written.bodyId == "does-not-exist")
        #expect(written.index == 999)
        #expect(written.scheme == "xor")
    }

    @Test("highlight_selection: polls handled/<id>.json and returns the host's real outcome")
    func highlightPollsAndReturnsHandledOutcome() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        async let resultTask = SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
            timeoutSeconds: 5.0, pollIntervalSeconds: 0.02)

        // Play the host: wait for the request file to land, read its
        // generated id, then write handled/<id>.json by hand.
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
        try FileManager.default.createDirectory(atPath: handledDir, withIntermediateDirectories: true)
        let handled = SelectionBridgeTools.HandledOutcome(outcome: "applied", reason: nil)
        let data = try JSONEncoder().encode(handled)
        try data.write(to: URL(fileURLWithPath: "\(handledDir)/\(id).json"), options: .atomic)

        let result = await resultTask
        #expect(!result.isError)
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.id == id)
        #expect(r.outcome == "applied")
    }

    @Test("highlight_selection: rejected outcome (with reason) round-trips from handled/")
    func highlightRejectedOutcomeRoundTrips() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        async let resultTask = SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
            timeoutSeconds: 5.0, pollIntervalSeconds: 0.02)

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
        let id = try #require(requestId)

        let handledDir = "\(requestsDir)/handled"
        try FileManager.default.createDirectory(atPath: handledDir, withIntermediateDirectories: true)
        let handled = SelectionBridgeTools.HandledOutcome(
            outcome: "rejected", reason: "bodyId not found in the live scene")
        let data = try JSONEncoder().encode(handled)
        try data.write(to: URL(fileURLWithPath: "\(handledDir)/\(id).json"), options: .atomic)

        let result = await resultTask
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.outcome == "rejected")
        #expect(r.reason == "bodyId not found in the live scene")
    }

    @Test("highlight_selection: times out with an explicit result when nothing consumes the request")
    func highlightTimesOutExplicitly() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "add", store: store,
            timeoutSeconds: 0.3, pollIntervalSeconds: 0.05)
        #expect(!result.isError)
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.outcome == "timeout")
        #expect(r.id != nil)
    }

    // ── atomic write shape ────────────────────────────────────────────────

    @Test("highlight_selection: the written request file matches the ecosystem#43/OCCTSwiftInteraction#17 schema")
    func highlightRequestSchemaShape() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "vertex", index: 2, scheme: "xor", question: "is this the right vertex?",
            store: store, timeoutSeconds: 0.2, pollIntervalSeconds: 0.02)
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        let id = try #require(r.id)

        let requestPath = "\(dir)/highlight_requests/\(id).json"
        let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        let written = try JSONDecoder().decode(SelectionBridgeTools.HighlightRequest.self, from: data)
        #expect(written.id == id)
        #expect(written.bodyId == "box")
        #expect(written.kind == "vertex")
        #expect(written.index == 2)
        #expect(written.scheme == "xor")
        #expect(written.question == "is this the right vertex?")
        #expect(written.target == "attention")
    }

    @Test("highlight_selection (#200): default target is written as attention, explicit selection is honoured")
    func highlightTargetWrittenToRequest() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        func written(_ result: ToolText) throws -> SelectionBridgeTools.HighlightRequest {
            let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
            let id = try #require(r.id)
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/highlight_requests/\(id).json"))
            return try JSONDecoder().decode(SelectionBridgeTools.HighlightRequest.self, from: data)
        }

        let def = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
            timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        #expect(try written(def).target == "attention")

        let sel = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "body", index: 0, scheme: "replace", target: "selection",
            store: store, timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        #expect(try written(sel).target == "selection")
    }

    @Test("highlight_selection (#200): invalid target and body+attention are rejected without writing")
    func highlightRejectsBadTargetAndBodyAttention() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let badTarget = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", target: "everything", store: store)
        #expect(badTarget.isError)
        #expect(badTarget.text.contains("unknown target 'everything'"), "wrong error: \(badTarget.text)")

        let body = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "body", index: 0, scheme: "replace", store: store)
        #expect(body.isError)
        #expect(body.text.contains("target \"selection\""))

        #expect(
            !FileManager.default.fileExists(atPath: "\(dir)/highlight_requests"),
            "a rejected request must never be written")
    }

    // ── highlight_selection label (#209) ──

    /// The raw JSON object of the one request file a call wrote.
    private func rawRequest(_ dir: String) throws -> [String: Any] {
        let files = try FileManager.default.contentsOfDirectory(atPath: "\(dir)/highlight_requests")
            .filter { $0.hasSuffix(".json") }
        #expect(files.count == 1, "expected exactly one request file, found \(files)")
        let name = try #require(files.first)
        let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/highlight_requests/\(name)"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("highlight_selection (#209): a label is written into an attention request")
    func highlightLabelWrittenForAttention() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 1, scheme: "replace", label: "mounting face",
            store: store, timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        #expect(!result.isError)
        let raw = try rawRequest(dir)
        #expect(raw["target"] as? String == "attention")
        #expect(raw["label"] as? String == "mounting face")
    }

    @Test("highlight_selection (#209): a label under target selection is ignored, not written")
    func highlightLabelIgnoredForSelection() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        // An over-long label is also ignored here: nothing to attach to, so no validation.
        let tooLong = String(repeating: "x", count: 200)
        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 1, scheme: "replace", target: "selection",
            label: tooLong, store: store, timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let raw = try rawRequest(dir)
        #expect(raw["target"] as? String == "selection")
        #expect(raw["label"] == nil)
    }

    @Test("highlight_selection (#209): a label on a request that carries a question is ignored, not written")
    func highlightLabelIgnoredWithQuestion() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        // A request with a question always lands in the selection, and the host ignores a label
        // on it (OCCTSwiftInteraction#36), so the tool neither validates nor writes one. The
        // over-long label proves it is not validated; target is attention so only the question
        // can be what gates it.
        let tooLong = String(repeating: "x", count: 200)
        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 1, scheme: "replace", target: "attention",
            question: "Is this the datum?", label: tooLong, store: store,
            timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let raw = try rawRequest(dir)
        #expect(raw["question"] as? String == "Is this the datum?")
        #expect(raw["label"] == nil)
    }

    @Test("highlight_selection (#209): without a label the request has no label key")
    func highlightNoLabelKeyWhenAbsent() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        _ = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 1, scheme: "replace",
            store: store, timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        let raw = try rawRequest(dir)
        #expect(Set(raw.keys) == ["id", "bodyId", "kind", "index", "scheme", "target"])
    }

    @Test("highlight_selection (#209): exactly 80 characters is accepted, 81 is rejected naming the limit")
    func highlightLabelLengthBoundary() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let tooLong = String(repeating: "a", count: 81)
        let rejected = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 1, scheme: "replace", label: tooLong, store: store)
        #expect(rejected.isError)
        #expect(rejected.text.contains("80"), "limit missing: \(rejected.text)")
        #expect(rejected.text.contains("81"), "received length missing: \(rejected.text)")
        #expect(
            !FileManager.default.fileExists(atPath: "\(dir)/highlight_requests"),
            "a rejected label must write nothing")

        let exact = String(repeating: "a", count: 80)
        let accepted = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 1, scheme: "replace", label: exact,
            store: store, timeoutSeconds: 0.1, pollIntervalSeconds: 0.02)
        #expect(!accepted.isError, "unexpected error: \(accepted.text)")
        let raw = try rawRequest(dir)
        #expect((raw["label"] as? String)?.count == 80)
    }

    @Test("highlight_selection (#209): the MCP dispatch passes `label` through to the request")
    func labelReachesTheRequestThroughTheServer() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        // Through the server, not SelectionBridgeTools.highlightSelection directly: the
        // `label: arguments["label"]?.stringValue` line in Server.swift is the only thing
        // between the wire and the tool, and the direct-call tests cannot see it.
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(outputDirectory: URL(fileURLWithPath: dir))
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let args: [String: Value] = [
            "bodyId": .string("box"), "kind": .string("face"), "index": .int(1),
            "scheme": .string("replace"), "target": .string("attention"),
            "label": .string("mounting face"), "timeoutSeconds": .double(0.2),
        ]
        let (content, _) = try await client.callTool(name: "highlight_selection", arguments: args)
        var text = ""
        if case .text(let t, _, _) = content.first { text = t }
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(text.utf8))
        let id = try #require(r.id, "no request id in \(text)")
        let raw = try #require(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: "\(dir)/highlight_requests/\(id).json")))
                as? [String: Any])
        #expect(raw["label"] as? String == "mounting face")

        // And the validation is reachable from the wire too.
        var tooLong = args
        tooLong["label"] = .string(String(repeating: "x", count: 81))
        let (rejected, isError) = try await client.callTool(name: "highlight_selection", arguments: tooLong)
        var rejectedText = ""
        if case .text(let t, _, _) = rejected.first { rejectedText = t }
        #expect(isError == true, "an 81-character label must be rejected through the server: \(rejectedText)")
        #expect(rejectedText.contains("80"), "wrong error: \(rejectedText)")
    }

    @Test("highlight_selection (#209): empty and whitespace-only labels are rejected without writing")
    func highlightLabelRejectsBlank() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let blanks = ["", "   ", "\n\t "]
        #expect(blanks.count == 3)
        for blank in blanks {
            let result = await SelectionBridgeTools.highlightSelection(
                bodyId: "box", kind: "face", index: 1, scheme: "replace", label: blank, store: store)
            #expect(result.isError, "blank label \(blank.debugDescription) was accepted")
            #expect(result.text.contains("label must not be empty"), "wrong error: \(result.text)")
        }
        #expect(
            !FileManager.default.fileExists(atPath: "\(dir)/highlight_requests"),
            "a rejected label must write nothing")
    }

    @Test("highlight_selection (#200): the host's handled target is surfaced in the result")
    func highlightSurfacesHandledTarget() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        async let resultTask = SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
            timeoutSeconds: 5.0, pollIntervalSeconds: 0.02)

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
        let id = try #require(requestId)
        let handledDir = "\(requestsDir)/handled"
        try FileManager.default.createDirectory(atPath: handledDir, withIntermediateDirectories: true)
        let handled = SelectionBridgeTools.HandledOutcome(
            outcome: "applied", reason: nil, target: "attention")
        try JSONEncoder().encode(handled).write(
            to: URL(fileURLWithPath: "\(handledDir)/\(id).json"), options: .atomic)

        let result = await resultTask
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
        #expect(json["outcome"] as? String == "applied")
        #expect(json["target"] as? String == "attention")
    }

    // ── review follow-ups: malformed handled/, cancellation ────────────────

    @Test(
        "highlight_selection: a handled/<id>.json that exists but doesn't decode reports outcome=error immediately, not timeout"
    )
    func highlightMalformedHandledFileReportsErrorNotTimeout() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        // A long timeout: if the malformed file were mistaken for "nothing
        // there yet" this test would have to wait the whole thing out to
        // observe the wrong "timeout" outcome. Asserting `outcome == "error"`
        // (rather than the wall-clock the call took) is what actually proves
        // it didn't fall through to the timeout branch.
        async let resultTask = SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
            timeoutSeconds: 30.0, pollIntervalSeconds: 0.02)

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
        let id = try #require(requestId)

        let handledDir = "\(requestsDir)/handled"
        try FileManager.default.createDirectory(atPath: handledDir, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(
            to: URL(fileURLWithPath: "\(handledDir)/\(id).json"), options: .atomic)

        let result = await resultTask
        #expect(!result.isError)
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.outcome == "error")
        #expect(r.reason?.contains(id) == true)
    }

    @Test("highlight_selection: cancelling the ambient task exits the poll loop instead of running to the deadline")
    func highlightCancellationExitsPollLoopEarly() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        // A long timeout and a fast poll interval: nothing ever writes
        // handled/<id>.json, so the only way this returns before the 30s
        // deadline is the cancellation check firing.
        let task = Task {
            await SelectionBridgeTools.highlightSelection(
                bodyId: "box", kind: "face", index: 0, scheme: "replace", store: store,
                timeoutSeconds: 30.0, pollIntervalSeconds: 0.02)
        }
        // Give it time to write the request and enter the poll loop at least
        // once before cancelling.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()

        let result = await task.value
        let r = try JSONDecoder().decode(HighlightResultMirror.self, from: Data(result.text.utf8))
        #expect(r.outcome == "cancelled")
    }
}
