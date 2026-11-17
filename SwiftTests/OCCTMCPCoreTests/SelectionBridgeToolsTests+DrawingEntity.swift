// get_selection with a drawing-entity pick (SecondMouseAU/OCCTMCP#277). The host writes the
// entry as literal JSON, as ACADStudio does, so these tests read the wire format and not this
// server's own encoder. The fixture scene and the lock helper are the ones in
// SelectionBridgeToolsTests.swift.

import Foundation
import MCP
import OCCTSwift
import ScriptHarness
import Testing

@testable import OCCTMCPCore

extension SelectionBridgeToolsTests {

    // MARK: - fixtures

    /// One `selection.json` entry as literal JSON.
    func entryJSON(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A drawing-entity entry, with only the fields given.
    func drawingEntry(
        caseName: String = "6575N383", entity: String? = nil, entityType: String? = nil,
        index: Int? = 0
    ) throws -> String {
        var fields: [String: Any] = ["bodyId": caseName, "kind": "drawing-entity"]
        if let index { fields["index"] = index }
        if let entity { fields["entity"] = entity }
        if let entityType { fields["entityType"] = entityType }
        return try entryJSON(fields)
    }

    /// A model entry on the scene body `box`.
    func modelEntry(kind: String, index: Int) throws -> String {
        try entryJSON(["bodyId": "box", "kind": kind, "index": index])
    }

    /// Runs `get_selection` against a live host that wrote exactly `entries`.
    func hostSelection(
        _ entries: [String], bodies: [(id: String, shape: Shape)] = [],
        registry: SelectionRegistry = SelectionRegistry()
    ) async throws -> ToolText {
        let store = try scene(bodies)
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }
        let json = """
            {"revision": 7, "updatedAt": "2026-11-18T09:00:00Z", \
            "selections": [\(entries.joined(separator: ", "))]}
            """
        try Data(json.utf8).write(to: URL(fileURLWithPath: "\(dir)/selection.json"), options: .atomic)
        return await SelectionBridgeTools.getSelection(store: store, registry: registry)
    }

    /// The `get_selection` result as raw JSON, so a test can see which keys a row has.
    func resultObject(_ result: ToolText) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any])
    }

    /// The rows of the `selections` array as raw JSON.
    func selectionRows(_ result: ToolText) throws -> [[String: Any]] {
        try #require(try resultObject(result)["selections"] as? [[String: Any]])
    }

    func box() throws -> Shape {
        try #require(Shape.box(width: 10, height: 20, depth: 30))
    }

    // MARK: - the pass-through

    @Test("get_selection: a drawing-entity pick comes back as itself, not as 'body not found'")
    func drawingEntityPassesThrough() async throws {
        let result = try await hostSelection([
            drawingEntry(entity: "8E/31", entityType: "DIMENSION")
        ])
        try #require(!result.isError, "unexpected error: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 1)
        let row = rows[0]
        #expect(row["bodyId"] as? String == "6575N383")
        #expect(row["kind"] as? String == "drawing-entity")
        #expect(row["entity"] as? String == "8E/31")
        #expect(row["entityType"] as? String == "DIMENSION")
        #expect(
            Set(row.keys) == ["bodyId", "kind", "entity", "entityType"],
            "no selectionId, anchor, error, uid or index: \(row.keys.sorted())")
    }

    @Test(
        "get_selection: the entity string is passed through exactly as the host wrote it",
        arguments: ["2C1", "8E/31", "ENTITIES:12", "BLOCKS:3/ENTITIES:12", "8e/31", " 8E ", "é/ü"])
    func entityStringIsExact(entity: String) async throws {
        let result = try await hostSelection([drawingEntry(entity: entity, entityType: "LINE")])
        try #require(!result.isError, "unexpected error: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 1)
        #expect(rows[0]["entity"] as? String == entity)
        #expect(rows[0]["error"] == nil)
    }

    @Test("get_selection: an entity written with an escaped slash reads back as a plain slash")
    func escapedSlashReadsBack() async throws {
        // Foundation's JSONEncoder writes `/` as `\/` unless told not to, so a host's `8E/31`
        // can arrive as `8E\/31`.
        let raw = #"{"bodyId": "6575N383", "kind": "drawing-entity", "index": 0, "entity": "8E\/31"}"#
        let result = try await hostSelection([raw])
        let rows = try selectionRows(result)
        try #require(rows.count == 1)
        #expect(rows[0]["entity"] as? String == "8E/31")
    }

    @Test("get_selection: the record type is advisory, so a pick without one still passes through")
    func entityTypeIsOptional() async throws {
        let result = try await hostSelection([drawingEntry(entity: "8E/31")])
        try #require(!result.isError, "unexpected error: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 1)
        #expect(rows[0]["entity"] as? String == "8E/31")
        #expect(rows[0]["entityType"] == nil)
        #expect(rows[0]["error"] == nil)
    }

    @Test("get_selection: a drawing case that shares a scene body's id mints no selectionId")
    func drawingEntityIsRoutedBeforeTheBodyLookup() async throws {
        // The scene HAS a body called `box`, so a lookup-first order finds it. The pick still
        // names a drawing case, so it must not reach the registry.
        let registry = SelectionRegistry()
        let result = try await hostSelection(
            [drawingEntry(caseName: "box", entity: "8E/31", entityType: "CIRCLE")],
            bodies: [("box", try box())], registry: registry)
        try #require(!result.isError, "unexpected error: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 1)
        #expect(rows[0]["selectionId"] == nil)
        #expect(rows[0]["anchor"] == nil)
        #expect(rows[0]["error"] == nil, "\(rows[0]["error"] ?? "")")
        #expect(rows[0]["entity"] as? String == "8E/31")
        #expect(await registry.count() == 0, "a drawing pick has no scene geometry to register")
    }

    // MARK: - mixed documents

    @Test("get_selection: model and drawing picks in one file keep their order and their count")
    func mixedEntriesKeepOrderAndCount() async throws {
        let registry = SelectionRegistry()
        let result = try await hostSelection(
            [
                modelEntry(kind: "face", index: 0),
                drawingEntry(entity: "8E/31", entityType: "DIMENSION"),
                modelEntry(kind: "edge", index: 1),
                drawingEntry(entity: "ENTITIES:12"),
                drawingEntry(caseName: "other-case", entity: "2C1", entityType: "LINE"),
                modelEntry(kind: "vertex", index: 0),
            ],
            bodies: [("box", try box())], registry: registry)
        try #require(!result.isError, "unexpected error: \(result.text)")
        let object = try resultObject(result)
        #expect(object["revision"] as? Int == 7)
        #expect(object["updatedAt"] as? String == "2026-11-18T09:00:00Z")

        let rows = try selectionRows(result)
        try #require(rows.count == 6)
        #expect(
            rows.map { $0["kind"] as? String }
                == ["face", "drawing-entity", "edge", "drawing-entity", "drawing-entity", "vertex"])
        #expect(
            rows.map { $0["bodyId"] as? String }
                == ["box", "6575N383", "box", "6575N383", "other-case", "box"])
        #expect(
            rows.map { $0["entity"] as? String } == [nil, "8E/31", nil, "ENTITIES:12", "2C1", nil])

        // The model rows resolved, so the drawing rows were not skipped by an early exit.
        for position in [0, 2, 5] {
            #expect(rows[position]["selectionId"] is String, "row \(position): \(rows[position])")
            #expect(rows[position]["error"] == nil, "row \(position): \(rows[position])")
            #expect(rows[position]["anchor"] != nil)
        }
        for position in [1, 3, 4] {
            #expect(rows[position]["selectionId"] == nil, "row \(position): \(rows[position])")
            #expect(rows[position]["error"] == nil, "row \(position): \(rows[position])")
        }
        #expect(await registry.count() == 3, "only the three model picks are registered")
    }

    // MARK: - an entry with no usable identity

    @Test(
        "get_selection: a drawing-entity with no usable entity is that row's error, and the rest still resolve",
        arguments: [
            #"{"bodyId": "6575N383", "kind": "drawing-entity", "index": 0, "entityType": "DIMENSION"}"#,
            #"{"bodyId": "6575N383", "kind": "drawing-entity", "index": 0, "entity": null}"#,
            #"{"bodyId": "6575N383", "kind": "drawing-entity", "index": 0, "entity": ""}"#,
            #"{"bodyId": "6575N383", "kind": "drawing-entity", "index": 0, "entity": "   "}"#,
        ])
    func drawingEntityWithoutIdentityIsAPerEntryError(entry: String) async throws {
        let result = try await hostSelection(
            [entry, modelEntry(kind: "face", index: 0)], bodies: [("box", try box())])
        #expect(!result.isError, "one bad row must not fail the call: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 2)

        let bad = rows[0]
        #expect(bad["bodyId"] as? String == "6575N383", "the row still says which drawing")
        #expect(bad["kind"] as? String == "drawing-entity")
        let message = try #require(bad["error"] as? String, "no error on \(bad)")
        #expect(message.contains("entity"), "the error should name the missing field: \(message)")
        #expect(!message.contains("body not found"), "wrong error: \(message)")
        #expect(bad["selectionId"] == nil)

        #expect(rows[1]["selectionId"] is String, "the face after it must still resolve")
        #expect(rows[1]["error"] == nil)
    }

    @Test("get_selection: a drawing-entity with no index still decodes, so it cannot poison the file")
    func drawingEntityWithoutIndexDecodes() async throws {
        // The schema says `index` is 0 and ignored for this kind; a writer that leaves it out
        // must not turn the whole file into "malformed" and cut the agent off from the model picks.
        let result = try await hostSelection(
            [
                drawingEntry(entity: "8E/31", entityType: "DIMENSION", index: nil),
                modelEntry(kind: "face", index: 0),
            ], bodies: [("box", try box())])
        try #require(!result.isError, "unexpected error: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 2)
        #expect(rows[0]["entity"] as? String == "8E/31")
        #expect(rows[0]["error"] == nil)
        #expect(rows[1]["selectionId"] is String)
    }

    @Test("get_selection: a model entry with no index is still a malformed file")
    func modelEntryWithoutIndexIsStillMalformed() async throws {
        // Pins that the index leniency above is for drawing-entity only.
        let result = try await hostSelection(
            [#"{"bodyId": "box", "kind": "face"}"#], bodies: [("box", try box())])
        #expect(result.isError, "a face with no index names no face: \(result.text)")
        #expect(result.text.contains("is malformed"), "wrong error: \(result.text)")
    }

    // MARK: - what stays as it was

    @Test(
        "get_selection: any other kind is still that row's error, even carrying entity fields",
        arguments: [
            "drawing_entity", "Drawing-Entity", "drawing-entity ", "drawing-entit", "annotation-pin",
            "",
        ])
    func otherKindsStayPerEntryErrors(kind: String) async throws {
        let future = try entryJSON([
            "bodyId": "box", "kind": kind, "index": 0, "entity": "8E/31", "entityType": "DIMENSION",
        ])
        let result = try await hostSelection(
            [future, modelEntry(kind: "face", index: 0)], bodies: [("box", try box())])
        #expect(!result.isError, "an unknown kind must not fail the call: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 2)

        let message = try #require(rows[0]["error"] as? String, "no error on \(rows[0])")
        #expect(message.contains("unknown kind"), "wrong error: \(message)")
        #expect(rows[0]["selectionId"] == nil)
        #expect(rows[0]["entity"] == nil, "only the exact kind drawing-entity is passed through")

        #expect(rows[1]["selectionId"] is String)
    }

    @Test("get_selection: entity fields on a model entry are not echoed on its row")
    func modelRowsDoNotCarryEntityFields() async throws {
        let stray = try entryJSON([
            "bodyId": "box", "kind": "face", "index": 0, "entity": "8E/31", "entityType": "LINE",
        ])
        let result = try await hostSelection([stray], bodies: [("box", try box())])
        try #require(!result.isError, "unexpected error: \(result.text)")
        let rows = try selectionRows(result)
        try #require(rows.count == 1)
        #expect(rows[0]["selectionId"] is String, "a face is still a face")
        #expect(rows[0]["entity"] == nil)
        #expect(rows[0]["entityType"] == nil)
    }

    @Test("highlight_selection: still refuses drawing-entity, and writes nothing")
    func highlightRefusesDrawingEntity() async throws {
        let store = try scene([])
        let dir = dirOf(store)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lock = try #require(HeldLock(path: "\(dir)/host.lock"))
        defer { lock.release() }

        let result = await SelectionBridgeTools.highlightSelection(
            bodyId: "6575N383", kind: "drawing-entity", index: 0, scheme: "replace",
            target: "selection", store: store, timeoutSeconds: 0.2, pollIntervalSeconds: 0.02)
        #expect(result.isError)
        #expect(
            result.text.contains("unknown kind 'drawing-entity'"), "wrong error: \(result.text)")
        #expect(
            !FileManager.default.fileExists(atPath: "\(dir)/highlight_requests"),
            "highlighting a drawing entity is not part of this bridge yet")
    }
}
