// Body loading by manifest format (#258): a body whose `format` is not `brep` is read by that
// format, the error names the format it failed on, an embedding host can supply the shape, and
// the tools that write a body back refuse one they would corrupt.

import Foundation
import MCP
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("Body loader", .serialized)
struct BodyLoaderTests {

    /// A scene directory holding `part.step` (a 10 x 20 x 30 box, written as STEP) and `solid.brep`.
    func makeScene(stepFormat: String = "step") throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-bodyloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        try Exporter.writeSTEP(shape: box, to: dir.appendingPathComponent("part.step"))
        try Exporter.writeBREP(shape: box, to: dir.appendingPathComponent("solid.brep"))
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "body loader",
                bodies: [
                    BodyDescriptor(id: "part", file: "part.step", format: stepFormat),
                    BodyDescriptor(id: "solid", file: "solid.brep"),
                ]))
        return dir
    }

    func connect(_ dir: URL, provider: BodyShapeProvider? = nil) async throws -> Client {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(outputDirectory: dir, bodyShapeProvider: provider)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        return client
    }

    func call(
        _ client: Client, _ name: String, _ arguments: [String: Value]
    ) async throws -> (text: String, isError: Bool) {
        let (content, isError) = try await client.callTool(name: name, arguments: arguments)
        var text = ""
        if case .text(let t, _, _) = content.first { text = t }
        return (text, isError == true)
    }

    func json(_ text: String) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "not a JSON object: \(text)")
    }

    func faceCount(_ client: Client, _ bodyId: String) async throws -> Int {
        let r = try await call(
            client, "query_topology", ["bodyId": .string(bodyId), "entity": "face"])
        try #require(!r.isError, "query_topology failed: \(r.text)")
        let results = try #require(try json(r.text)["results"] as? [Any], "\(r.text)")
        return results.count
    }

    // ── read by format ──────────────────────────────────────────────────

    @Test("query_topology and compute_metrics read a step body by its format")
    func stepBodyIsRead() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)

        #expect(try await faceCount(client, "part") == 6)

        let metrics = try await call(
            client, "compute_metrics", ["bodyId": "part", "metrics": ["volume"]])
        try #require(!metrics.isError, "compute_metrics failed: \(metrics.text)")
        let volume = try #require(try json(metrics.text)["volume"] as? Double, "\(metrics.text)")
        #expect(abs(volume - 6000) < 1e-3, "volume \(volume)")
    }

    @Test("format is matched case-insensitively and accepts the extension spellings")
    func formatSpellings() async throws {
        for spelling in ["STEP", "stp", "Step"] {
            let dir = try makeScene(stepFormat: spelling)
            defer { try? FileManager.default.removeItem(at: dir) }
            let client = try await connect(dir)
            #expect(try await faceCount(client, "part") == 6, "format \(spelling)")
        }
    }

    @Test("select_topology mints selections on a step body")
    func selectOnStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let r = try await call(
            client, "select_topology", ["bodyId": "part", "kind": "face", "limit": 3])
        try #require(!r.isError, "select_topology failed: \(r.text)")
        #expect(r.text.contains("sel:part#face["))
    }

    @Test("validate_geometry with no bodyId validates a step body too")
    func validateWholeScene() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let r = try await call(client, "validate_geometry", [:])
        try #require(!r.isError, "\(r.text)")
        let bodies = try #require(try json(r.text)["bodies"] as? [[String: Any]], "\(r.text)")
        let part = try #require(bodies.first { $0["id"] as? String == "part" }, "\(r.text)")
        #expect(part["isValid"] as? Bool == true, "\(part)")
        #expect(part["error"] == nil || part["error"] is NSNull, "\(part)")
    }

    // ── errors name the format ──────────────────────────────────────────

    @Test("a step body that does not parse reports step, not BREP")
    func errorNamesStep() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("this is not a STEP file".utf8).write(to: dir.appendingPathComponent("part.step"))
        let client = try await connect(dir)
        let r = try await call(
            client, "query_topology", ["bodyId": "part", "entity": "face"])
        #expect(r.isError)
        #expect(r.text.contains("Failed to read step body"), "\(r.text)")
        #expect(!r.text.contains("BREP"), "\(r.text)")
    }

    @Test("a format the server cannot read is named, with the supported ones")
    func unsupportedFormat() async throws {
        let dir = try makeScene(stepFormat: "glb")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let r = try await call(
            client, "query_topology", ["bodyId": "part", "entity": "face"])
        #expect(r.isError)
        #expect(r.text.contains("has format \"glb\""), "\(r.text)")
        let listed = try #require(r.text.components(separatedBy: "Supported formats: ").last)
        let names = listed.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).components(
            separatedBy: ", ")
        #expect(Set(names) == ["brep", "step", "iges", "stl", "obj"], "\(names)")
    }

    // ── the host's own shape ────────────────────────────────────────────

    @Test("a host provider is consulted first, and nil falls through to the file")
    func providerFirstNilFallsThrough() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sphere = try #require(Shape.sphere(radius: 5))
        let asked = EventLog()
        let client = try await connect(dir) { body, outputDir in
            asked.add(
                "\(body.id ?? "?") \(body.format) \((outputDir as NSString).lastPathComponent)")
            return body.id == "part" ? sphere : nil
        }
        // The host's sphere (1 face), not the 6-face box in part.step.
        #expect(try await faceCount(client, "part") == 1)
        // nil: the file is read, by format.
        #expect(try await faceCount(client, "solid") == 6)
        #expect(asked.all.contains("part step \(dir.lastPathComponent)"), "\(asked.all)")
        #expect(asked.all.contains("solid brep \(dir.lastPathComponent)"), "\(asked.all)")
    }

    @Test("a provider that throws fails the tool call")
    func providerThrows() async throws {
        struct Refused: Error, CustomStringConvertible {
            var description: String { "host refused" }
        }
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir) { _, _ in throw Refused() }
        let r = try await call(client, "query_topology", ["bodyId": "part", "entity": "face"])
        #expect(r.isError)
        #expect(r.text.contains("host refused"), "\(r.text)")
    }

    @Test("the lineage graph is built from the host's shape and rebuilt when the host swaps it")
    func lineageFollowsHostShape() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let manifest = try #require(
            try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).read())
        let body = try #require(manifest.body(withId: "part"))
        let held = try #require(Shape.box(width: 1, height: 2, depth: 3))
        let swapped = try #require(Shape.box(width: 4, height: 5, depth: 6))
        let registry = HistoryRegistry()

        func resolve(_ host: Shape?) async throws -> (shape: Shape, fresh: Bool) {
            try await OCCTMCPContext.$bodyShapeProvider.withValue(
                { _, _ in host },
                operation: {
                    let r = try await registry.currentInput(
                        bodyId: "part", body: body, outputDir: dir.path)
                    return (r.shape, r.isFreshLoad)
                })
        }

        let first = try await resolve(held)
        #expect(first.fresh)
        #expect(first.shape.isSame(as: held), "graph built from a re-read, not the host's shape")

        let repeated = try await resolve(held)
        #expect(!repeated.fresh, "the same host shape reuses the cached lineage")
        #expect(repeated.shape.isSame(as: held))

        // The file on disk did not change, only the shape the host holds.
        let other = try await resolve(swapped)
        #expect(other.fresh, "a different host shape must not be served from the old lineage")
        #expect(other.shape.isSame(as: swapped))

        // An editing tool never asks the provider and never continues a lineage built from the
        // host's shape: it starts from the file, so its input does not depend on which tool ran
        // before it. (The file here is a BREP, since a step body is not editable.)
        let brepBody = try #require(manifest.body(withId: "solid"))
        _ = try await OCCTMCPContext.$bodyShapeProvider.withValue(
            { _, _ in held },
            operation: {
                try await registry.currentInput(
                    bodyId: "solid", body: brepBody, outputDir: dir.path)
            })
        let edit = try await registry.currentEditInput(
            bodyId: "solid", path: dir.appendingPathComponent("solid.brep").path)
        #expect(edit.isFreshLoad, "an edit continued the lineage a host shape built")
        #expect(!edit.shape.isSame(as: held), "an edit ran on the host's shape")
        let again = try await registry.currentEditInput(
            bodyId: "solid", path: dir.appendingPathComponent("solid.brep").path)
        #expect(!again.isFreshLoad, "a file-built lineage is continued across edits")
        #expect(again.graph === edit.graph)

        // A host-backed read after the edit rebuilds from the host's shape, which is not the
        // edit's lineage.
        let reread = try await OCCTMCPContext.$bodyShapeProvider.withValue(
            { _, _ in held },
            operation: {
                try await registry.currentInput(
                    bodyId: "solid", body: brepBody, outputDir: dir.path)
            })
        #expect(reread.isFreshLoad)
        #expect(reread.shape.isSame(as: held))
        #expect(reread.graph !== edit.graph)

        // No provider: read by format, the STEP file.
        let fromFile = try await resolve(nil)
        #expect(fromFile.fresh)
        #expect(!fromFile.shape.isSame(as: swapped))
    }

    // ── get_selection on a step body (the report in #258) ────────────────

    struct PickMirror: Decodable {
        let selectionId: String?
        let error: String?
    }
    struct PicksMirror: Decodable {
        let state: String
        let selections: [PickMirror]?
    }

    /// Plays the viewport host: holds `host.lock` and writes a one-face pick on `part`.
    func withPick<T>(
        _ dir: URL, _ body: (_ registry: SelectionRegistry) async throws -> T
    ) async throws -> T {
        let lock = try #require(HeldLock(path: dir.appendingPathComponent("host.lock").path))
        defer { lock.release() }
        let sidecar = SelectionBridgeTools.SelectionSidecar(
            selections: [.init(bodyId: "part", kind: "face", index: 0, uid: nil)],
            revision: 1, updatedAt: "2026-11-11T00:00:00Z")
        try JSONEncoder().encode(sidecar).write(
            to: dir.appendingPathComponent("selection.json"), options: .atomic)
        return try await body(SelectionRegistry())
    }

    func pick(
        _ dir: URL, registry: SelectionRegistry
    ) async throws -> (pick: PickMirror, area: Double?) {
        let result = await SelectionBridgeTools.getSelection(
            store: ManifestStore(path: dir.appendingPathComponent("manifest.json").path),
            registry: registry)
        try #require(!result.isError, "get_selection failed: \(result.text)")
        let r = try JSONDecoder().decode(PicksMirror.self, from: Data(result.text.utf8))
        let entry = try #require(r.selections?.first, "\(result.text)")
        guard let id = entry.selectionId else { return (entry, nil) }
        return (entry, await registry.snapshot(for: id)?.area)
    }

    @Test("get_selection resolves a pick on a step body, from the file when no host shape is given")
    func getSelectionOnStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await withPick(dir) { registry in
            let (entry, area) = try await pick(dir, registry: registry)
            #expect(entry.error == nil, "\(entry.error ?? "")")
            #expect(entry.selectionId?.hasPrefix("sel:part#face[") == true)
            // A face of the 10 x 20 x 30 box in part.step: 200, 300 or 600.
            let a = try #require(area)
            #expect([200.0, 300.0, 600.0].contains { abs($0 - a) < 1e-6 }, "area \(a)")
        }
    }

    @Test("get_selection resolves a pick against the host's shape, not a re-read of the file")
    func getSelectionUsesHostShape() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let held = try #require(Shape.box(width: 1, height: 2, depth: 3))
        try await withPick(dir) { registry in
            let (entry, area) = try await OCCTMCPContext.$bodyShapeProvider.withValue(
                { body, _ in body.id == "part" ? held : nil },
                operation: { try await pick(dir, registry: registry) })
            #expect(entry.error == nil, "\(entry.error ?? "")")
            // A face of the host's 1 x 2 x 3 box (2, 3 or 6), not of the 10 x 20 x 30 file.
            let a = try #require(area)
            #expect([2.0, 3.0, 6.0].contains { abs($0 - a) < 1e-6 }, "area \(a)")
        }
    }

    // ── every load site reads by format and reports it by name ──────────

    /// `part` is a step body whose file is not STEP, so every tool that reads it fails.
    func corruptStepScene() throws -> URL {
        let dir = try makeScene()
        try Data("this is not a STEP file".utf8).write(to: dir.appendingPathComponent("part.step"))
        return dir
    }

    func expectNamesStep(_ r: (text: String, isError: Bool), _ tool: String) {
        #expect(r.isError, "\(tool) succeeded on a corrupt step body: \(r.text)")
        #expect(r.text.contains("Failed to read step body"), "\(tool): \(r.text)")
        #expect(!r.text.contains("couldn't be completed"), "\(tool) lost the message: \(r.text)")
        #expect(!r.text.contains("BREP"), "\(tool) named the wrong format: \(r.text)")
    }

    @Test("tools that load every body name the step format when one fails to read")
    func everyLoadSiteNamesTheFormat() async throws {
        let dir = try corruptStepScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let out = dir.appendingPathComponent("out").path

        let calls: [(String, [String: Value])] = [
            ("render_preview", ["outputPath": "\(out).png"]),
            ("pick_surface_point", ["screenX": 100, "screenY": 100]),
            ("export_scene", ["format": "brep", "outputPath": "\(out).brep", "bodyIds": ["part"]]),
            ("generate_drawing", ["bodyId": "part", "outputPath": "\(out).dxf", "spec": [:]]),
            ("select_by_feature", ["bodyId": "part"]),
            ("auto_dimension", ["bodyId": "part"]),
            ("select_topology", ["bodyId": "part", "kind": "face"]),
        ]
        for (name, arguments) in calls {
            expectNamesStep(try await call(client, name, arguments), name)
        }

        // validate_geometry reports a per-body error entry rather than failing the call.
        let r = try await call(client, "validate_geometry", [:])
        try #require(!r.isError, "\(r.text)")
        let bodies = try #require(try json(r.text)["bodies"] as? [[String: Any]], "\(r.text)")
        let part = try #require(bodies.first { $0["id"] as? String == "part" }, "\(r.text)")
        let message = try #require(part["error"] as? String, "\(part)")
        #expect(message.contains("Failed to read step body"), "\(message)")
        #expect(!message.contains("couldn't be completed"), "\(message)")
    }

    @Test("a step body works through the tools that read it by lineage, ray, export and drawing")
    func stepBodyThroughMoreTools() async throws {
        let calls: [(String, [String: Value])] = [
            ("select_by_feature", ["bodyId": "part"]),
            ("auto_dimension", ["bodyId": "part"]),
            (
                "measure_distance",
                ["fromBodyId": "part", "toBodyId": "solid", "from": "face[0]", "to": "face[1]"]
            ),
            ("measure_distance", ["fromBodyId": "part", "toBodyId": "solid"]),
            ("pick_surface_point", ["screenX": 100, "screenY": 100]),
            ("export_scene", ["format": "brep", "outputPath": "OUT.brep", "bodyIds": ["part"]]),
            (
                "generate_drawing",
                [
                    "bodyId": "part", "outputPath": "OUT.dxf",
                    "spec": [
                        "sheet": [
                            "size": "a3", "orientation": "landscape", "projection": "third",
                            "scale": "auto",
                        ],
                        "views": [["name": "front"], ["name": "top"]],
                    ],
                ]
            ),
        ]
        for (name, template) in calls {
            // A fresh scene and server per tool. The lineage reads cache what they build, so in a
            // shared scene a tool that still read BREP would pass off an earlier tool's cache.
            let dir = try makeScene()
            defer { try? FileManager.default.removeItem(at: dir) }
            let client = try await connect(dir)
            var arguments = template
            if case .string(let path)? = arguments["outputPath"] {
                arguments["outputPath"] = .string(dir.appendingPathComponent(path).path)
            }
            let r = try await call(client, name, arguments)
            #expect(!r.isError, "\(name) failed on a step body: \(r.text)")
            guard case .string(let path)? = arguments["outputPath"] else { continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            #expect((size ?? 0) > 1_000, "\(name) wrote \(size ?? 0) bytes to \(path)")
            if name == "export_scene" {
                // What was exported is the 10 x 20 x 30 box read from part.step.
                let back = try Shape.loadBREP(fromPath: path)
                #expect(back.faces().count == 6)
                #expect(abs((back.volumeInertia?.volume ?? 0) - 6000) < 1e-3)
            }
        }
    }

    @Test("feature tools find the hole in a step body, so they read its real geometry")
    func holePlateThroughFeatureTools() async throws {
        // A 20 x 20 x 20 box with a radius 4 blind hole, written as STEP. A tool that read an
        // empty or wrong shape would find no hole.
        let box = try #require(
            Shape.box(origin: SIMD3(-10, -10, -10), width: 20, height: 20, depth: 20))
        let tool = try #require(
            Shape.cylinder(at: SIMD3(5, 0, 0), direction: SIMD3(0, 0, 1), radius: 4, height: 20))
        let plate = try #require(box.subtracting(tool))
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-bodyloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Exporter.writeSTEP(shape: plate, to: dir.appendingPathComponent("plate.step"))
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "hole plate",
                bodies: [BodyDescriptor(id: "plate", file: "plate.step", format: "step")]))

        let found = try await call(
            connect(dir), "select_by_feature", ["bodyId": "plate", "kinds": ["hole"]])
        try #require(!found.isError, "\(found.text)")
        let selections = try #require(
            try json(found.text)["selections"] as? [[String: Any]], "\(found.text)")
        let hole = try #require(
            selections.first { $0["kind"] as? String == "hole" }, "\(found.text)")
        let detail = try #require(hole["detail"] as? [String: Any], "\(found.text)")
        #expect((detail["surfaceType"] as? String)?.lowercased().contains("cylind") == true)

        // A fresh server, so auto_dimension does not read what select_by_feature cached.
        let dimensioned = try await call(
            connect(dir), "auto_dimension", ["bodyId": "plate", "showDiameter": true])
        try #require(!dimensioned.isError, "\(dimensioned.text)")
        let added = try #require(
            try json(dimensioned.text)["added"] as? [[String: Any]], "\(dimensioned.text)")
        #expect(!added.isEmpty, "no dimension added for the hole: \(dimensioned.text)")
    }

    @Test("measure_distance resolves selectionIds on a step body through a cold lineage")
    func distanceOnSelectionIds() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let selected = try await call(
            client, "select_topology", ["bodyId": "part", "kind": "face", "limit": 2])
        try #require(!selected.isError, "\(selected.text)")
        let ids = Array(
            Set(
                selected.text.matches(of: /sel:part#face\[\d+\]/).map { String($0.output) }
            )
        ).sorted()
        try #require(ids.count == 2, "expected two selectionIds in \(selected.text)")

        // select_topology cached the lineage. Drop it, so the sub-shape lookup below has to
        // resolve the body itself rather than read what the selection left behind.
        await OCCTMCPPaths.withOutputDirectory(dir) { await HistoryRegistry.shared.clear() }

        let r = try await call(
            client, "measure_distance", ["from": .string(ids[0]), "to": .string(ids[1])])
        #expect(!r.isError, "measure_distance on selectionIds failed: \(r.text)")
    }

    @Test(
        "render_preview draws a step body",
        .enabled(if: metalDeviceAvailable, "needs a Metal device"))
    func renderStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let png = dir.appendingPathComponent("part.png").path
        let r = try await call(
            client, "render_preview", ["outputPath": .string(png), "bodyIds": ["part"]])
        try #require(!r.isError, "\(r.text)")
        try expectPNG(atPath: png)
    }

    @Test("a provider that throws fails the history-aware reads too")
    func providerThrowsOnLineageReads() async throws {
        struct Refused: Error, CustomStringConvertible {
            var description: String { "host refused" }
        }
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir) { _, _ in throw Refused() }
        let calls: [(String, [String: Value])] = [
            ("select_topology", ["bodyId": "solid", "kind": "face"]),
            ("auto_dimension", ["bodyId": "solid"]),
            ("measure_distance", ["fromBodyId": "part", "toBodyId": "solid"]),
        ]
        for (name, arguments) in calls {
            let r = try await call(client, name, arguments)
            #expect(r.isError, "\(name) ignored a throwing provider: \(r.text)")
            #expect(r.text.contains("host refused"), "\(name): \(r.text)")
        }
    }

    // ── the other readable formats, and the lookups that tolerate a failed read ──

    @Test("iges, stl and obj bodies are read by format, and igs and brp are accepted spellings")
    func otherReadableFormats() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-bodyloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        try Exporter.writeIGES(shape: box, to: dir.appendingPathComponent("a.iges"))
        try Exporter.writeIGES(shape: box, to: dir.appendingPathComponent("b.igs"))
        try Exporter.writeSTL(shape: box, to: dir.appendingPathComponent("c.stl"))
        try Exporter.writeOBJ(shape: box, to: dir.appendingPathComponent("d.obj"))
        try Exporter.writeBREP(shape: box, to: dir.appendingPathComponent("e.brp"))
        let bodies = [
            ("a", "a.iges", "iges"), ("b", "b.igs", "igs"), ("c", "c.stl", "stl"),
            ("d", "d.obj", "obj"), ("e", "e.brp", "brp"),
        ]
        try ManifestStore(path: dir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "formats",
                bodies: bodies.map { BodyDescriptor(id: $0.0, file: $0.1, format: $0.2) }))
        let client = try await connect(dir)
        for (id, _, format) in bodies {
            #expect(try await faceCount(client, id) > 0, "\(format) body read no faces")
        }
        #expect(try await faceCount(client, "a") == 6)
        #expect(try await faceCount(client, "e") == 6)

        // A scene-wide validate leaves raw mesh shells out, and validates one that is named.
        let all = try await call(client, "validate_geometry", [:])
        try #require(!all.isError, "\(all.text)")
        let listed = try #require(try json(all.text)["bodies"] as? [[String: Any]], "\(all.text)")
        #expect(Set(listed.compactMap { $0["id"] as? String }) == ["a", "b", "e"], "\(all.text)")
        for id in ["a", "b", "e"] {
            let entry = try #require(listed.first { $0["id"] as? String == id }, "\(all.text)")
            #expect(entry["error"] == nil || entry["error"] is NSNull, "\(id): \(entry)")
        }
        let named = try await call(client, "validate_geometry", ["bodyId": "c"])
        try #require(!named.isError, "\(named.text)")
        let one = try #require(try json(named.text)["bodies"] as? [[String: Any]], "\(named.text)")
        #expect(one.count == 1 && one.first?["id"] as? String == "c", "\(named.text)")
    }

    @Test("a scene-wide validate keeps an unreadable format as an error entry and skips raw meshes")
    func validateUnknownFormatAndMeshOnly() async throws {
        let dir = try makeScene(stepFormat: "glb")
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let all = try await call(client, "validate_geometry", [:])
        try #require(!all.isError, "\(all.text)")
        let bodies = try #require(try json(all.text)["bodies"] as? [[String: Any]], "\(all.text)")
        let part = try #require(bodies.first { $0["id"] as? String == "part" }, "\(all.text)")
        let message = try #require(part["error"] as? String, "\(part)")
        #expect(message.contains("has format \"glb\""), "\(message)")

        // A scene of nothing but raw mesh shells has nothing to validate, and says why.
        let meshDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-bodyloader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: meshDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: meshDir) }
        let box = try #require(Shape.box(width: 1, height: 1, depth: 1))
        try Exporter.writeSTL(shape: box, to: meshDir.appendingPathComponent("m.stl"))
        try ManifestStore(path: meshDir.appendingPathComponent("manifest.json").path).write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "mesh only",
                bodies: [BodyDescriptor(id: "m", file: "m.stl", format: "stl")]))
        let meshClient = try await connect(meshDir)
        let none = try await call(meshClient, "validate_geometry", [:])
        #expect(!none.isError, "\(none.text)")
        #expect(none.text.contains("only raw stl/obj mesh shells"), "\(none.text)")
        #expect(!none.text.contains("No bodies in scene"), "\(none.text)")
    }

    @Test("remap_selection keeps a pick on a step body instead of reporting it lost")
    func remapOnStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let selected = try await call(
            client, "select_topology", ["bodyId": "part", "kind": "face", "limit": 1])
        let id = try #require(
            selected.text.firstMatch(of: /sel:part#face\[\d+\]/).map { String($0.output) },
            "\(selected.text)")
        let r = try await call(client, "remap_selection", ["selectionIds": [.string(id)]])
        try #require(!r.isError, "\(r.text)")
        let entries = try #require(try json(r.text)["remapped"] as? [[String: Any]], "\(r.text)")
        #expect(entries.count == 1, "\(r.text)")
        #expect(entries.first?["fate"] as? String == "preserved", "\(r.text)")
    }

    @Test("diff_overlay marks a changed step body")
    func diffOverlayOnStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let changed = try await call(
            client, "set_appearance", ["bodyId": "part", "opacity": 0.5])
        try #require(!changed.isError, "\(changed.text)")
        let r = try await call(client, "diff_overlay", ["since": 1])
        try #require(!r.isError, "\(r.text)")
        let ids = try #require(try json(r.text)["primitiveIds"] as? [String], "\(r.text)")
        #expect(ids.contains("diff_appchg_part"), "no marker for the step body: \(r.text)")
    }

    @Test("find_correspondences infers the translation from a step source body")
    func correspondencesFromStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let moved = try #require(box.translated(by: SIMD3(5, 0, 0)))
        try Exporter.writeBREP(shape: moved, to: dir.appendingPathComponent("moved.brep"))
        let store = ManifestStore(path: dir.appendingPathComponent("manifest.json").path)
        let scene = try #require(try store.read())
        try store.write(
            scene.replacing(
                bodies: scene.bodies + [BodyDescriptor(id: "moved", file: "moved.brep")]))
        let client = try await connect(dir)
        let selected = try await call(
            client, "select_topology", ["bodyId": "part", "kind": "face", "limit": 1])
        let id = try #require(
            selected.text.firstMatch(of: /sel:part#face\[\d+\]/).map { String($0.output) },
            "\(selected.text)")
        // select_topology cached the source's lineage. Drop it, so the source-side lookups have
        // to resolve the step body themselves instead of reading what the selection left behind.
        await OCCTMCPPaths.withOutputDirectory(dir) { await HistoryRegistry.shared.clear() }
        let r = try await call(
            client, "find_correspondences",
            ["sourceSelectionIds": [.string(id)], "targetBodyId": "moved"])
        try #require(!r.isError, "\(r.text)")
        let report = try json(r.text)
        // The translation comes from comparing the step source's bounds to the target's.
        #expect(report["transformSource"] as? String == "bbox-inference", "\(r.text)")
        let matches = try #require(report["correspondences"] as? [[String: Any]], "\(r.text)")
        #expect(matches.first?["fate"] as? String == "matched", "\(r.text)")
    }

    @Test("find_correspondences recomputes a step source's centroid when its snapshot has none")
    func correspondencesCentroidFallback() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        // An anchor whose snapshot carries no centre, so the centroid has to be read back from the
        // body: the fallback path, which a selection minted by select_topology never takes.
        let anchor = TopologyAnchor.face(bodyId: "part", index: 0)
        await OCCTMCPPaths.withOutputDirectory(dir) {
            await SelectionRegistry.shared.record(
                anchor: anchor, snapshot: AnchorSnapshot(center: []))
        }
        let client = try await connect(dir)
        let r = try await call(
            client, "find_correspondences",
            ["sourceSelectionIds": [.string(anchor.selectionId)], "targetBodyId": "solid"])
        try #require(!r.isError, "\(r.text)")
        let matches = try #require(
            try json(r.text)["correspondences"] as? [[String: Any]], "\(r.text)")
        #expect(matches.first?["fate"] as? String == "matched", "centroid not recovered: \(r.text)")
    }

    @Test("find_correspondences reads a step body as the target")
    func correspondencesToStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let selected = try await call(
            client, "select_topology", ["bodyId": "solid", "kind": "face", "limit": 1])
        let id = try #require(
            selected.text.firstMatch(of: /sel:solid#face\[\d+\]/).map { String($0.output) },
            "\(selected.text)")
        let r = try await call(
            client, "find_correspondences",
            ["sourceSelectionIds": [.string(id)], "targetBodyId": "part"])
        try #require(!r.isError, "\(r.text)")
        let matches = try #require(
            try json(r.text)["correspondences"] as? [[String: Any]], "\(r.text)")
        // solid.brep and part.step are the same box in the same place, so the face matches itself.
        #expect(matches.first?["fate"] as? String == "matched", "\(r.text)")
        #expect(
            (matches.first?["targetSelectionId"] as? String)?.hasPrefix("sel:part#face[") == true)
    }

    @Test("align_bodies dry run reads a step body and apply=true refuses it")
    func alignDryRunOnStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let dry = try await call(
            client, "align_bodies", ["bodyId": "part", "referenceBodyId": "solid"])
        #expect(!dry.isError, "a dry run should only read: \(dry.text)")
        let applied = try await call(
            client, "align_bodies",
            ["bodyId": "part", "referenceBodyId": "solid", "apply": true])
        #expect(applied.isError)
        #expect(applied.text.contains("edits brep bodies only"), "\(applied.text)")
    }

    // ── missing files, and the pre-#258 lookup name ──────────────────────

    @Test("a missing file is reported under its own format, not as BREP")
    func missingFileNamesFormat() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("part.step"))
        let client = try await connect(dir)
        let out = dir.appendingPathComponent("out.dxf").path

        let calls: [(String, [String: Value], String)] = [
            ("query_topology", ["bodyId": "part", "entity": "face"], "STEP file missing"),
            (
                "generate_drawing",
                ["bodyId": "part", "outputPath": .string(out), "spec": [:]],
                "STEP file missing"
            ),
            (
                "find_correspondences",
                ["sourceSelectionIds": ["sel:solid#face[0]"], "targetBodyId": "part"],
                "Target STEP missing or unreadable"
            ),
            ("query_topology", ["bodyId": "ghost", "entity": "face"], "Body not found"),
        ]
        for (name, arguments, expected) in calls {
            let r = try await call(client, name, arguments)
            #expect(r.isError, "\(name): \(r.text)")
            #expect(r.text.contains(expected), "\(name): \(r.text)")
            #expect(!r.text.contains("BREP"), "\(name) named the wrong format: \(r.text)")
        }

        // The same file missing from a brep body still says BREP.
        try FileManager.default.removeItem(at: dir.appendingPathComponent("solid.brep"))
        let brep = try await call(
            client, "query_topology", ["bodyId": "solid", "entity": "face"])
        #expect(brep.text.contains("BREP file missing"), "\(brep.text)")
    }

    @Test("the pre-#258 currentInput(bodyId:path:) still reads BREP and is the edit lookup")
    @available(*, deprecated, message: "exercises the deprecated alias on purpose")
    func deprecatedAlias() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = HistoryRegistry()
        let path = dir.appendingPathComponent("solid.brep").path
        let first = try await registry.currentInput(bodyId: "solid", path: path)
        #expect(first.isFreshLoad)
        let second = try await registry.currentEditInput(bodyId: "solid", path: path)
        #expect(!second.isFreshLoad, "the alias and the edit lookup share one cache")
        #expect(second.graph === first.graph)
    }

    // ── editing tools do not corrupt a body they cannot write back to ───

    @Test("editing tools refuse a step body and leave its file and the scene untouched")
    func editingToolsRefuseStepBody() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stepPath = dir.appendingPathComponent("part.step")
        let manifestPath = dir.appendingPathComponent("manifest.json")
        let stepBefore = try Data(contentsOf: stepPath)
        let manifestBefore = try Data(contentsOf: manifestPath)
        let client = try await connect(dir)

        let calls: [(String, [String: Value])] = [
            ("transform_body", ["bodyId": "part", "translate": [1, 0, 0]]),
            ("heal_shape", ["bodyId": "part"]),
            (
                "boolean_op",
                ["op": "union", "aBodyId": "part", "bBodyId": "solid", "outputBodyId": "m"]
            ),
            (
                "boolean_op",
                ["op": "union", "aBodyId": "solid", "bBodyId": "part", "outputBodyId": "m"]
            ),
            (
                "apply_feature",
                ["bodyId": "part", "feature": ["kind": "fillet", "radius": 1]]
            ),
            ("align_bodies", ["bodyId": "part", "referenceBodyId": "solid", "apply": true]),
            (
                "mirror_or_pattern",
                ["bodyId": "part", "kind": "mirror", "params": ["planeNormal": [1, 0, 0]]]
            ),
        ]
        for (name, arguments) in calls {
            let r = try await call(client, name, arguments)
            #expect(r.isError, "\(name) succeeded on a step body: \(r.text)")
            #expect(r.text.contains("edits brep bodies only"), "\(name): \(r.text)")
        }
        #expect(try Data(contentsOf: stepPath) == stepBefore, "the STEP file was rewritten")
        #expect(try Data(contentsOf: manifestPath) == manifestBefore, "the scene changed")
    }

    @Test("align_bodies reads the file it overwrites, not the host's shape")
    func alignIgnoresProviderForTheBodyItEdits() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let moved = try #require(box.translated(by: SIMD3(3, 0, 0)))
        try Exporter.writeBREP(shape: moved, to: dir.appendingPathComponent("ref.brep"))
        let store = ManifestStore(path: dir.appendingPathComponent("manifest.json").path)
        let scene = try #require(try store.read())
        try store.write(
            scene.replacing(bodies: scene.bodies + [BodyDescriptor(id: "ref", file: "ref.brep")]))
        let sphere = try #require(Shape.sphere(radius: 5))
        let client = try await connect(dir) { body, _ in body.id == "solid" ? sphere : nil }

        let r = try await call(
            client, "align_bodies",
            ["bodyId": "solid", "referenceBodyId": "ref", "apply": true])
        try #require(!r.isError, "\(r.text)")

        let written = try Shape.loadBREP(fromPath: dir.appendingPathComponent("solid.brep").path)
        let volume = try #require(written.volumeInertia?.volume)
        #expect(abs(volume - 6000) < 1, "solid.brep now holds the host's sphere: volume \(volume)")
    }

    @Test("editing tools never take the host's shape, whatever the provider returns")
    func editingToolsIgnoreProvider() async throws {
        // Each tool is handed a sphere (volume about 524) for every body. Reading the host's
        // shape instead of the file would write a sphere, not the 10 x 20 x 30 box (6000).
        let sphere = try #require(Shape.sphere(radius: 5))
        let calls:
            [(
                tool: String, arguments: [String: Value], output: String,
                volume: ClosedRange<Double>
            )] =
                [
                    (
                        "transform_body", ["bodyId": "solid", "translate": [5, 0, 0]], "solid",
                        5999...6001
                    ),
                    ("heal_shape", ["bodyId": "solid"], "solid", 5999...6001),
                    (
                        "apply_feature",
                        ["bodyId": "solid", "feature": ["kind": "fillet", "radius": 1]], "solid",
                        5_000...5_999
                    ),
                    (
                        "boolean_op",
                        [
                            "op": "union", "aBodyId": "solid", "bBodyId": "other",
                            "outputBodyId": "joined",
                        ], "joined", 11_999...12_001
                    ),
                    (
                        "mirror_or_pattern",
                        [
                            "bodyId": "solid", "kind": "mirror", "outputBodyId": "mirrored",
                            "params": ["planeNormal": [1, 0, 0]],
                        ], "mirrored", 5_000...12_001
                    ),
                ]
        for (tool, arguments, output, expected) in calls {
            let dir = try makeScene()
            defer { try? FileManager.default.removeItem(at: dir) }
            let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
            let far = try #require(box.translated(by: SIMD3(100, 0, 0)))
            try Exporter.writeBREP(shape: far, to: dir.appendingPathComponent("other.brep"))
            let store = ManifestStore(path: dir.appendingPathComponent("manifest.json").path)
            let scene = try #require(try store.read())
            try store.write(
                scene.replacing(
                    bodies: scene.bodies + [BodyDescriptor(id: "other", file: "other.brep")]))
            let client = try await connect(dir) { _, _ in sphere }

            let r = try await call(client, tool, arguments)
            try #require(!r.isError, "\(tool) failed: \(r.text)")
            let written = try #require(
                try store.read()?.body(withId: output), "\(tool) left no body \(output)")
            let shape = try Shape.loadBREP(
                fromPath: dir.appendingPathComponent(written.file).path)
            let volume = try #require(shape.volumeInertia?.volume, "\(tool) wrote no volume")
            #expect(expected.contains(volume), "\(tool) wrote volume \(volume), not \(expected)")
        }
    }

    @Test("editing tools accept a brep body under any spelling of its format")
    func editingAcceptsBrepSpellings() async throws {
        for spelling in ["BREP", "brp", "Brep"] {
            let dir = try makeScene()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = ManifestStore(path: dir.appendingPathComponent("manifest.json").path)
            let scene = try #require(try store.read())
            try store.write(
                scene.replacing(
                    bodies: scene.bodies.map {
                        $0.id == "solid"
                            ? BodyDescriptor(id: "solid", file: "solid.brep", format: spelling) : $0
                    }))
            let client = try await connect(dir)
            let r = try await call(
                client, "transform_body", ["bodyId": "solid", "translate": [5, 0, 0]])
            #expect(!r.isError, "a \"\(spelling)\" body was refused: \(r.text)")
        }
    }

    @Test("an editing tool still works on a brep body")
    func editingStillWorksOnBrep() async throws {
        let dir = try makeScene()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = try await connect(dir)
        let r = try await call(
            client, "transform_body", ["bodyId": "solid", "translate": [5, 0, 0]])
        try #require(!r.isError, "\(r.text)")
        // The 10 x 20 x 30 box is centred on the origin, so x runs -5...5 before and 0...10 after.
        let moved = try Shape.loadBREP(fromPath: dir.appendingPathComponent("solid.brep").path)
        let bounds = try #require(moved.bounds)
        #expect(abs(bounds.min.x) < 1e-6 && abs(bounds.max.x - 10) < 1e-6, "\(bounds)")
    }
}
