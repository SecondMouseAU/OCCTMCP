// SelectionBridgeToolsTests (#189/#190): get_selection / highlight_selection
// against hand-written fixture files in a tempdir, exactly as both
// refined-spec comments describe. No host actually implements the writer
// side yet (SecondMouseAU/OCCTSwiftInteraction#16/ACADStudio#16 are still
// upstream), so every test here plays the host itself: it holds host.lock,
// writes selection.json / handled/<id>.json by hand, and asserts the tool's
// response against that fixture.

import Foundation
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

        let badScheme = await SelectionBridgeTools.highlightSelection(
            bodyId: "box", kind: "face", index: 0, scheme: "toggle-ish", store: store)
        #expect(badScheme.isError)

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
    }
}
