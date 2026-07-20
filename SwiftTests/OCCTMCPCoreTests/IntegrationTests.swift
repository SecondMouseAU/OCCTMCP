// IntegrationTests: spawn the occtmcp-server binary, drive it via
// JSON-RPC over stdio (newline-delimited per the Swift MCP SDK
// StdioTransport contract), assert tool responses against a
// tempdir-redirected scene.
//
// Slow: requires the binary to be built (`swift build` ahead of test
// run). The harness is deliberately minimal; the unit suites already
// cover the deterministic logic; this is the smoke test that proves
// the wired-up server actually serves requests.
//
// `.serialized` because the harness cd's into a tempdir and points
// OCCTMCP_OUTPUT_DIR at it; running multiple instances in parallel
// would fight over the same env var.

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("stdio integration", .serialized)
struct IntegrationTests {

    /// Path to the built binary. Phase 6.3's smoke test requires
    /// `swift build` to have run; absence is treated as a skipped test
    /// rather than a failure so contributors who haven't built yet
    /// don't see a misleading red.
    static var binaryURL: URL? {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        for cfg in ["debug", "release"] {
            let url = URL(fileURLWithPath: "\(cwd)/.build/\(cfg)/occtmcp-server")
            if fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    @Test("server initialises and lists tools")
    func initialisesAndLists() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let harness = try Harness(binary: binary)
        defer { harness.terminate() }

        try harness.send(.init(
            id: 1,
            method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("integration-test"),
                    "version": .string("0.1"),
                ]),
            ])
        ))
        let initResponse = try harness.recv(timeout: 10)
        #expect(initResponse["id"]?.intValue == 1)
        #expect(initResponse["result"] != nil)

        try harness.send(.init(
            method: "notifications/initialized",
            params: .object([:])
        ))

        try harness.send(.init(id: 2, method: "tools/list", params: .object([:])))
        let listResponse = try harness.recv(timeout: 5)
        guard case .object(let result)? = listResponse["result"],
              case .array(let tools)? = result["tools"] else {
            Issue.record("tools/list result missing tools array")
            return
        }
        #expect(tools.count >= 30)
        let names = tools.compactMap { tool -> String? in
            guard case .object(let dict) = tool else { return nil }
            return dict["name"]?.stringValue
        }
        for expected in [
            "ping", "get_scene", "execute_script", "render_preview",
            "pick_surface_point",
            "compute_metrics", "measure_deviation", "boolean_op", "set_assembly_metadata",
            "check_thickness",
            "deviation_histogram", "cross_section_compare",
            "signed_deviation_heatmap", "overlay_render",
        ] {
            #expect(names.contains(expected), "missing tool: \(expected)")
        }
    }

    @Test("history-based remap preserves selectionIds across transform_body")
    func historyRemapPreservesAcrossTransform() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-history-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Synthesize a real cylinder BREP so transform_body /
        // select_topology can actually load it. r=10mm, h=25mm gives
        // 3 faces (lateral + 2 caps), which is enough to verify
        // selection survives a translate.
        guard let cyl = Shape.cylinder(radius: 10, height: 25) else {
            Issue.record("Failed to synthesize cylinder BREP fixture")
            return
        }
        try Exporter.writeBREP(shape: cyl, to: URL(fileURLWithPath: "\(scene)/cyl.brep"))

        let manifest = ScriptManifest(
            description: "History remap test scene",
            bodies: [
                BodyDescriptor(
                    id: "cyl",
                    file: "cyl.brep",
                    color: [0.8, 0.7, 0.3, 1]
                ),
            ]
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // 1. select_topology: pick a face on the cylinder
        try harness.send(.init(
            id: 30, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("cyl"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selectResp = try harness.recv(timeout: 10)
        guard case .object(let result)? = selectResp["result"],
              case .array(let content)? = result["content"],
              case .object(let firstContent)? = content.first,
              let text = firstContent["text"]?.stringValue,
              let selectData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: selectData) as? [String: Any],
              let selections = parsed["selections"] as? [[String: Any]],
              let firstSelection = selections.first,
              let selectionId = firstSelection["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // 2. transform_body: move it
        try harness.send(.init(
            id: 31, method: "tools/call",
            params: .object([
                "name": .string("transform_body"),
                "arguments": .object([
                    "bodyId": .string("cyl"),
                    "translate": .array([.double(20), .double(0), .double(0)]),
                ]),
            ])
        ))
        let transformResp = try harness.recv(timeout: 30)
        #expect(transformResp["error"] == nil)

        // 3. remap_selection: should find the face via history (fate
        //    preserved), not via centroid heuristic
        try harness.send(.init(
            id: 32, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let remapResp = try harness.recv(timeout: 5)
        guard case .object(let remapResult)? = remapResp["result"],
              case .array(let remapContent)? = remapResult["content"],
              case .object(let remapBody)? = remapContent.first,
              let remapText = remapBody["text"]?.stringValue,
              let remapData = remapText.data(using: .utf8),
              let remapParsed = try JSONSerialization.jsonObject(with: remapData) as? [String: Any],
              let remapped = remapParsed["remapped"] as? [[String: Any]],
              let firstEntry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        #expect(firstEntry["fate"] as? String == "preserved",
                "expected history-based remap to preserve, got: \(firstEntry["fate"] ?? "<nil>")")
        if let conf = firstEntry["confidenceMm"] as? Double {
            #expect(conf == 0, "history-based remap should report confidenceMm=0, got \(conf)")
        }
    }

    @Test("render_preview overlays a linear dimension on the rendered PNG")
    func dimensionOverlayRenders() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-dimoverlay-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Cylinder fixture, same shape as historyRemapPreservesAcrossTransform.
        guard let cyl = Shape.cylinder(radius: 10, height: 25) else {
            Issue.record("Failed to synthesise cylinder fixture")
            return
        }
        try Exporter.writeBREP(shape: cyl, to: URL(fileURLWithPath: "\(scene)/cyl.brep"))
        let manifest = ScriptManifest(
            description: "Dimension overlay test scene",
            bodies: [BodyDescriptor(id: "cyl", file: "cyl.brep", color: [0.8, 0.7, 0.3, 1])]
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // Pick two vertices on the cylinder so we have known anchor
        // points for a linear dimension.
        try harness.send(.init(
            id: 40, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("cyl"),
                    "kind": .string("vertex"),
                    "limit": .int(2),
                ]),
            ])
        ))
        let selectResp = try harness.recv(timeout: 10)
        guard case .object(let result)? = selectResp["result"],
              case .array(let content)? = result["content"],
              case .object(let firstContent)? = content.first,
              let text = firstContent["text"]?.stringValue,
              let selData = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: selData) as? [String: Any],
              let selections = parsed["selections"] as? [[String: Any]],
              selections.count >= 2,
              let id1 = selections[0]["selectionId"] as? String,
              let id2 = selections[1]["selectionId"] as? String else {
            Issue.record("select_topology(vertex, limit=2) didn't return two picks")
            return
        }

        // Add a linear dimension between them.
        try harness.send(.init(
            id: 41, method: "tools/call",
            params: .object([
                "name": .string("add_dimension"),
                "arguments": .object([
                    "kind": .string("linear"),
                    "id": .string("test_height"),
                    "anchors": .object([
                        "from": .string(id1),
                        "to": .string(id2),
                    ]),
                ]),
            ])
        ))
        let dimResp = try harness.recv(timeout: 5)
        #expect(dimResp["error"] == nil)

        // Render and assert the PNG was produced + non-trivial.
        let pngPath = "\(scene)/render.png"
        try harness.send(.init(
            id: 42, method: "tools/call",
            params: .object([
                "name": .string("render_preview"),
                "arguments": .object([
                    "outputPath": .string(pngPath),
                    "options": .object([
                        "width": .int(400),
                        "height": .int(300),
                        "renderAnnotations": .bool(true),
                    ]),
                ]),
            ])
        ))
        let renderResp = try harness.recv(timeout: 30)
        #expect(renderResp["error"] == nil)

        let attrs = try FileManager.default.attributesOfItem(atPath: pngPath)
        let size = (attrs[.size] as? Int) ?? 0
        // PNG with a body + dimension overlay should comfortably exceed
        // ~2 KB. A blank 400×300 RGBA PNG is ~700 bytes.
        #expect(size > 2_000, "rendered PNG was \(size) bytes; overlay may not have been drawn")
    }

    @Test("generate_drawing lays out multiple bodies as a general-arrangement sheet")
    func generateDrawingAssembly() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-ga-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Two distinct parts in the scene.
        let plate = try #require(Shape.box(width: 40, height: 30, depth: 8))
        let pin = try #require(Shape.cylinder(radius: 5, height: 25))
        try Exporter.writeBREP(shape: plate, to: URL(fileURLWithPath: "\(scene)/plate.brep"))
        try Exporter.writeBREP(shape: pin, to: URL(fileURLWithPath: "\(scene)/pin.brep"))
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(ScriptManifest(
            description: "GA drawing test scene",
            bodies: [
                BodyDescriptor(id: "plate", file: "plate.brep", name: "Base Plate", color: [0.7, 0.7, 0.7, 1]),
                BodyDescriptor(id: "pin", file: "pin.brep", name: "Dowel Pin", color: [0.6, 0.6, 0.6, 1]),
            ]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        let dxfPath = "\(scene)/ga.dxf"
        try harness.send(.init(
            id: 60, method: "tools/call",
            params: .object([
                "name": .string("generate_drawing"),
                "arguments": .object([
                    "bodyIds": .array([.string("plate"), .string("pin")]),
                    "outputPath": .string(dxfPath),
                    "spec": .object([
                        "sheet": .object([
                            "size": .string("a3"),
                            "orientation": .string("landscape"),
                            "projection": .string("third"),
                            "scale": .string("auto"),
                        ]),
                        "views": .array([
                            .object(["name": .string("front")]),
                            .object(["name": .string("top")]),
                            .object(["name": .string("right")]),
                        ]),
                    ]),
                ]),
            ])
        ))
        let resp = try harness.recv(timeout: 30)
        #expect(resp["error"] == nil)
        guard case .object(let result)? = resp["result"],
              case .array(let content)? = result["content"],
              case .object(let first)? = content.first,
              let text = first["text"]?.stringValue,
              let data = text.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("generate_drawing response shape unexpected")
            return
        }
        #expect(parsed["componentCount"] as? Int == 2)   // two bodies laid out
        #expect(parsed["partCount"] as? Int == 2)         // two parts-list rows
        let fileSize = (parsed["fileSize"] as? Int) ?? 0
        #expect(fileSize > 4_000, "GA DXF was \(fileSize) bytes; views may not have rendered")
    }

    @Test("pick_surface_point hits a body and composes into add_dimension")
    func pickSurfacePointMeasures() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-pick-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // A box: its 8 pick-vertices give an interior centroid, so the
        // centre-pixel ray (which the framing aims at the centroid) crosses two
        // faces and reliably hits. A cylinder's sparse seam vertices would put
        // the framing pivot on the lateral surface → grazing ray.
        guard let box = Shape.box(width: 20, height: 20, depth: 20) else {
            Issue.record("Failed to synthesise box fixture")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/box.brep"))
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(ScriptManifest(
            description: "pick_surface_point test scene",
            bodies: [BodyDescriptor(id: "box", file: "box.brep", color: [0.8, 0.7, 0.3, 1])]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        // The centre pixel ray passes through the framing pivot (bbox centre),
        // which is interior to the solid, so it must hit a boundary face. Two
        // different camera presets give two distinct surface points.
        func pick(id: Int, camera: String) throws -> String {
            try harness.send(.init(
                id: id, method: "tools/call",
                params: .object([
                    "name": .string("pick_surface_point"),
                    "arguments": .object([
                        "screenX": .double(200),
                        "screenY": .double(150),
                        "options": .object([
                            "camera": .string(camera),
                            "width": .int(400),
                            "height": .int(300),
                        ]),
                    ]),
                ])
            ))
            let resp = try harness.recv(timeout: 30)
            guard case .object(let result)? = resp["result"],
                  case .array(let content)? = result["content"],
                  case .object(let first)? = content.first,
                  let text = first["text"]?.stringValue,
                  let data = text.data(using: .utf8) else {
                throw Harness.HarnessError.unexpectedShape("pick_surface_point response envelope")
            }
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                Issue.record("pick_surface_point (\(camera)) returned non-JSON: \(text)")
                throw Harness.HarnessError.unexpectedShape("pick_surface_point body not JSON")
            }
            #expect(parsed["hit"] as? Bool == true, "centre-pixel pick missed the solid (\(camera))")
            #expect(parsed["bodyId"] as? String == "box")
            guard let sel = parsed["selectionId"] as? String else {
                throw Harness.HarnessError.unexpectedShape("pick_surface_point returned no selectionId")
            }
            return sel
        }

        let front = try pick(id: 50, camera: "front")
        let top = try pick(id: 51, camera: "top")

        // The picked points must be usable directly as add_dimension anchors.
        try harness.send(.init(
            id: 52, method: "tools/call",
            params: .object([
                "name": .string("add_dimension"),
                "arguments": .object([
                    "kind": .string("linear"),
                    "id": .string("pick_span"),
                    "anchors": .object(["from": .string(front), "to": .string(top)]),
                ]),
            ])
        ))
        let dimResp = try harness.recv(timeout: 10)
        #expect(dimResp["error"] == nil)
        guard case .object(let dimResult)? = dimResp["result"],
              case .array(let dimContent)? = dimResult["content"],
              case .object(let dimFirst)? = dimContent.first,
              let dimText = dimFirst["text"]?.stringValue,
              let dimData = dimText.data(using: .utf8),
              let dimParsed = try JSONSerialization.jsonObject(with: dimData) as? [String: Any] else {
            Issue.record("add_dimension response shape unexpected")
            return
        }
        // A non-zero span between two distinct surface points.
        let value = (dimParsed["value"] as? Double) ?? 0
        #expect(value > 0, "dimension between two picked points was \(value)")
    }

    @Test("history-based remap survives boolean_op via per-input history")
    func historyRemapAcrossBooleanOp() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-bool-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Two non-overlapping boxes: union should produce one body
        // whose faces include the unmodified faces of both inputs.
        guard let box1 = Shape.box(width: 10, height: 10, depth: 10),
              let box2Raw = Shape.box(width: 10, height: 10, depth: 10),
              let box2 = box2Raw.translated(by: SIMD3(20, 0, 0)) else {
            Issue.record("Failed to synthesise box fixtures")
            return
        }
        try Exporter.writeBREP(shape: box1, to: URL(fileURLWithPath: "\(scene)/a.brep"))
        try Exporter.writeBREP(shape: box2, to: URL(fileURLWithPath: "\(scene)/b.brep"))

        let manifest = ScriptManifest(
            description: "Boolean history test",
            bodies: [
                BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1]),
                BodyDescriptor(id: "b", file: "b.brep", color: [0, 1, 0, 1]),
            ]
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // Pick a face on `a` (any face will do; boxes have 6).
        try harness.send(.init(
            id: 50, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("a"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // Union the two bodies, non-overlapping so faces survive
        // unchanged on both sides.
        try harness.send(.init(
            id: 51, method: "tools/call",
            params: .object([
                "name": .string("boolean_op"),
                "arguments": .object([
                    "op": .string("union"),
                    "aBodyId": .string("a"),
                    "bBodyId": .string("b"),
                    "outputBodyId": .string("merged"),
                ]),
            ])
        ))
        let boolResp = try harness.recv(timeout: 30)
        #expect(boolResp["error"] == nil)

        // remap_selection should resolve the prior face via history.
        try harness.send(.init(
            id: 52, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        #expect(
            fate == "preserved" || fate == "split",
            "boolean_op history should resolve to preserved or split (got \(fate))"
        )
        // confidenceMm: 0 means the history path returned the answer
        // (centroid heuristic always returns a positive distance).
        if let conf = entry["confidenceMm"] as? Double {
            #expect(conf == 0, "history path should report confidenceMm=0, got \(conf)")
        }
    }

    @Test("history-based remap survives apply_feature via FeatureReconstructor.histories")
    func historyRemapAcrossApplyFeature() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-feat-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // 40×40×40 box, drill a hole down the +Z axis offset to one
        // corner so most of the box's six faces survive the operation
        // (we'll select one and assert it remaps).
        guard let box = Shape.box(width: 40, height: 40, depth: 40) else {
            Issue.record("Failed to synthesise box")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/part.brep"))
        let manifest = ScriptManifest(
            description: "apply_feature history test",
            bodies: [BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1])]
        )
        try ManifestStore(path: "\(scene)/manifest.json").write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 60, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // Hole feature with non-nil id: populates BuildResult.histories
        // per OCCTSwift v1.0.3. Drill near a corner so most faces survive.
        try harness.send(.init(
            id: 61, method: "tools/call",
            params: .object([
                "name": .string("apply_feature"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "feature": .object([
                        "id": .string("h1"),
                        "kind": .string("hole"),
                        "axisPoint": .array([.double(5), .double(5), .double(0)]),
                        "axisDirection": .array([.double(0), .double(0), .double(1)]),
                        "diameter": .double(4),
                    ]),
                ]),
            ])
        ))
        let applyResp = try harness.recv(timeout: 30)
        #expect(applyResp["error"] == nil, "apply_feature errored: \(applyResp)")

        try harness.send(.init(
            id: 62, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        #expect(
            fate == "preserved" || fate == "split",
            "apply_feature(hole) history should resolve to preserved or split (got \(fate))"
        )
        if let conf = entry["confidenceMm"] as? Double {
            #expect(conf == 0, "history path should report confidenceMm=0, got \(conf)")
        }
    }

    @Test("history-based remap survives apply_feature(fillet) post-OCCTSwift v1.0.4")
    func historyRemapAcrossFilletFeature() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-fillet-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        guard let box = Shape.box(width: 30, height: 30, depth: 30) else {
            Issue.record("Failed to synthesise box")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/part.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "fillet history test",
            bodies: [BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1])]
        ))

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 70, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // Fillet spec with non-nil id: exercises OCCTSwift v1.0.4's
        // applyFillet → filletedWithFullHistory wiring (closes #166).
        // EdgeSelector defaults to .all in the JSON path.
        try harness.send(.init(
            id: 71, method: "tools/call",
            params: .object([
                "name": .string("apply_feature"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "feature": .object([
                        "id": .string("f1"),
                        "kind": .string("fillet"),
                        "radius": .double(2.0),
                    ]),
                ]),
            ])
        ))
        let applyResp = try harness.recv(timeout: 30)
        #expect(applyResp["error"] == nil, "apply_feature(fillet) errored: \(applyResp)")

        try harness.send(.init(
            id: 72, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        #expect(
            fate == "preserved" || fate == "split",
            "fillet history should resolve to preserved or split (got \(fate))"
        )
        if let conf = entry["confidenceMm"] as? Double {
            #expect(conf == 0, "history path should report confidenceMm=0, got \(conf)")
        }
    }

    @Test("remap_selection resolves cleanly across TWO chained apply_feature hops on the same body (#90/#91/#93)")
    func historyRemapAcrossTwoApplyFeatureHops() async throws {
        // NOTE: this black-box test can't distinguish "hop 2 genuinely
        // absorbed into the retained BRepGraph" from "hop 2 degraded to a
        // generation reset and remap_selection's implicit-identity
        // fallback happened to still resolve the same face index"; both
        // paths report fate=preserved/split with confidenceMm=0 through
        // the public tool surface (see
        // HistoryRegistryLineageTests.retainedLineageSurvivesTwoHops for
        // the in-process test that actually distinguishes them via
        // graph.instanceID / graph.contains(uid:) and confirms genuine
        // continuation, not a lucky fallback: SecondMouseAU/OCCTSwift#336
        // was retracted in v1.15.2 as not-a-bug, the reported "chaining
        // absorbs zero records" was a box-centering mistake in the
        // repro's own geometry, not a real defect in `add(_:absorbing:
        // ...)`). This test still has value as a regression guard: it
        // proves the server doesn't error and remap_selection doesn't
        // silently mis-resolve across a real two-hop sequence.
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built, run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-twohop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        guard let box = Shape.box(width: 40, height: 40, depth: 40) else {
            Issue.record("Failed to synthesise box")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/part.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "two-hop history test",
            bodies: [BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1])]
        ))

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 80, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // Hop 1: drill a hole near a corner, in place.
        try harness.send(.init(
            id: 81, method: "tools/call",
            params: .object([
                "name": .string("apply_feature"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "feature": .object([
                        "id": .string("h1"),
                        "kind": .string("hole"),
                        "axisPoint": .array([.double(5), .double(5), .double(0)]),
                        "axisDirection": .array([.double(0), .double(0), .double(1)]),
                        "diameter": .double(4),
                    ]),
                ]),
            ])
        ))
        let hop1Resp = try harness.recv(timeout: 30)
        #expect(hop1Resp["error"] == nil, "apply_feature(hole) errored: \(hop1Resp)")

        // Hop 2: fillet, in place, on the SAME body. This is the hop that
        // fails pre-#93: hop 2's apply_feature used to reload the body
        // from disk into a fresh Shape/TShape tree, discarding hop 1's
        // retained graph, so add(_:absorbing:...)'s TShape-identity
        // correlation silently absorbed zero records.
        try harness.send(.init(
            id: 82, method: "tools/call",
            params: .object([
                "name": .string("apply_feature"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "feature": .object([
                        "id": .string("f1"),
                        "kind": .string("fillet"),
                        "radius": .double(1.0),
                    ]),
                ]),
            ])
        ))
        let hop2Resp = try harness.recv(timeout: 30)
        #expect(hop2Resp["error"] == nil, "apply_feature(fillet) errored: \(hop2Resp)")

        try harness.send(.init(
            id: 83, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        #expect(
            fate == "preserved" || fate == "split",
            "two-hop chain should resolve to preserved or split via history (got \(fate)); fate=approximate/lost with a nonzero confidenceMm means the retained lineage broke between hops and remap_selection fell back to the centroid heuristic"
        )
        if let conf = entry["confidenceMm"] as? Double {
            #expect(conf == 0, "history path should report confidenceMm=0 (got \(conf)); nonzero means the centroid heuristic answered instead of history")
        }
    }

    @Test("selection survives heal_shape (#93): history path when available, graceful fallback otherwise")
    func remapSurvivesHealShape() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built, run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-heal-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        guard let box = Shape.box(width: 20, height: 20, depth: 20) else {
            Issue.record("Failed to synthesise box")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/part.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "heal_shape history test",
            bodies: [BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1])]
        ))

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 84, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        try harness.send(.init(
            id: 85, method: "tools/call",
            params: .object([
                "name": .string("heal_shape"),
                "arguments": .object([
                    "bodyId": .string("part"),
                ]),
            ])
        ))
        let healResp = try harness.recv(timeout: 30)
        #expect(healResp["error"] == nil, "heal_shape errored: \(healResp)")

        try harness.send(.init(
            id: 86, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object([
                    "selectionIds": .array([.string(selectionId)]),
                ]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        // A pristine box may heal as a total no-op (healedWithFullHistory
        // absorbing zero records), which degrades to a generation reset
        // per the commit() decision tree, so this can't strictly assert
        // confidenceMm == 0 the way the apply_feature/boolean_op history
        // tests do. It can assert the selection wasn't lost or forced
        // onto the (positive-distance) centroid heuristic's "approximate"
        // path, which is the observable contract heal_shape promises
        // regardless of which path served the answer.
        #expect(
            fate == "preserved" || fate == "split",
            "heal_shape should resolve to preserved or split (got \(fate))"
        )
    }

    @Test("out-of-band BREP rewrite (execute_script-style) is detected as stale: HistoryRegistry reloads fresh rather than operating on a cached shape (#93)")
    func staleFingerprintForcesFreshReload() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built, run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-stale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        guard let box1 = Shape.box(width: 10, height: 10, depth: 10) else {
            Issue.record("Failed to synthesise box fixture")
            return
        }
        let partPath = "\(scene)/part.brep"
        try Exporter.writeBREP(shape: box1, to: URL(fileURLWithPath: partPath))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "staleness test",
            bodies: [BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1])]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        // Establish a retained lineage for "part" via an in-place no-op transform.
        try harness.send(.init(
            id: 87, method: "tools/call",
            params: .object([
                "name": .string("transform_body"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "translate": .array([.double(0), .double(0), .double(0)]),
                ]),
            ])
        ))
        let t1 = try harness.recv(timeout: 10)
        #expect(t1["error"] == nil, "first transform_body errored: \(t1)")

        // Out-of-band rewrite: mimics execute_script writing a brand new
        // body file directly, bypassing every tool in this process. A
        // totally different, recognisably-sized box.
        guard let box2 = Shape.box(width: 50, height: 60, depth: 70) else {
            Issue.record("Failed to synthesise replacement box fixture")
            return
        }
        try FileManager.default.removeItem(atPath: partPath)
        try Exporter.writeBREP(shape: box2, to: URL(fileURLWithPath: partPath))

        // Mutate again: if HistoryRegistry served the STALE cached
        // liveShape (the original 10x10x10 box) instead of re-detecting
        // the rewrite via the fingerprint mismatch, this transform would
        // silently apply to the wrong geometry and overwrite part.brep
        // with a corrupted result instead of the expected 50x60x70 box.
        try harness.send(.init(
            id: 88, method: "tools/call",
            params: .object([
                "name": .string("transform_body"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "translate": .array([.double(1), .double(0), .double(0)]),
                ]),
            ])
        ))
        let t2 = try harness.recv(timeout: 10)
        #expect(t2["error"] == nil, "second transform_body errored: \(t2)")

        try harness.send(.init(
            id: 89, method: "tools/call",
            params: .object([
                "name": .string("compute_metrics"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "metrics": .array([.string("boundingBox")]),
                ]),
            ])
        ))
        let metricsResp = try harness.recv(timeout: 10)
        guard case .object(let r)? = metricsResp["result"],
              case .array(let c)? = r["content"],
              case .object(let f)? = c.first,
              let t = f["text"]?.stringValue,
              let d = t.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: d) as? [String: Any],
              let bbox = parsed["boundingBox"] as? [String: Any],
              let minV = bbox["min"] as? [Double], minV.count == 3,
              let maxV = bbox["max"] as? [Double], maxV.count == 3 else {
            Issue.record("compute_metrics response shape unexpected: \(metricsResp)")
            return
        }
        let size = zip(minV, maxV).map { abs($1 - $0) }.sorted()
        #expect(
            abs(size[0] - 50) < 0.5 && abs(size[1] - 60) < 0.5 && abs(size[2] - 70) < 0.5,
            "compute_metrics reports size \(size), expected ~[50,60,70] (box2, the out-of-band rewrite); a stale cached liveShape would report ~[10,10,10] (box1)"
        )
    }

    @Test("find_correspondences maps a face across a mirror_or_pattern mirror")
    func findCorrespondencesAcrossMirror() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-corr-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Place a 20×20×20 box at +X so it doesn't straddle the YZ plane;
        // the mirror produces a clearly-separated copy at -X.
        guard let box = Shape.box(width: 20, height: 20, depth: 20),
              let translated = box.translated(by: SIMD3(20, 0, 0)) else {
            Issue.record("Failed to synthesise box")
            return
        }
        try Exporter.writeBREP(shape: translated, to: URL(fileURLWithPath: "\(scene)/src.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "find_correspondences mirror test",
            bodies: [BodyDescriptor(id: "src", file: "src.brep", color: [1, 0, 0, 1])]
        ))

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // Mirror the source about the YZ plane → produces "mirror-src" body.
        try harness.send(.init(
            id: 80, method: "tools/call",
            params: .object([
                "name": .string("mirror_or_pattern"),
                "arguments": .object([
                    "bodyId": .string("src"),
                    "kind": .string("mirror"),
                    "params": .object([
                        "planeOrigin": .array([.double(0), .double(0), .double(0)]),
                        "planeNormal": .array([.double(1), .double(0), .double(0)]),
                    ]),
                ]),
            ])
        ))
        let mirrorResp = try harness.recv(timeout: 30)
        #expect(mirrorResp["error"] == nil, "mirror_or_pattern errored: \(mirrorResp)")
        if case .object(let mr)? = mirrorResp["result"],
           case .array(let mc)? = mr["content"],
           case .object(let mf)? = mc.first,
           let mt = mf["text"]?.stringValue {
            #expect(mt.contains("→ \"mirror-src\""),
                    "mirror_or_pattern didn't produce mirror-src body: \(mt)")
        }

        // Pick a face on the source. Any face: `find_correspondences` is
        // about transporting the pick, not about which face it is.
        try harness.send(.init(
            id: 81, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("src"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue else {
            Issue.record("select_topology response missing text content: \(selResp)")
            return
        }
        guard let d1 = t1.data(using: .utf8) else {
            Issue.record("select_topology text not utf8: \(t1)")
            return
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: d1),
              let p1 = parsed as? [String: Any] else {
            Issue.record("select_topology text wasn't JSON object: t1=[\(t1)] selResp=\(selResp)")
            return
        }
        guard let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology missing selections array: \(t1)")
            return
        }

        // Same mirror plane the pattern used.
        try harness.send(.init(
            id: 82, method: "tools/call",
            params: .object([
                "name": .string("find_correspondences"),
                "arguments": .object([
                    "sourceSelectionIds": .array([.string(selectionId)]),
                    "targetBodyId": .string("mirror-src"),
                    "transform": .object([
                        "kind": .string("mirror"),
                        "planeOrigin": .array([.double(0), .double(0), .double(0)]),
                        "planeNormal": .array([.double(1), .double(0), .double(0)]),
                    ]),
                ]),
            ])
        ))
        let corrResp = try harness.recv(timeout: 10)
        guard case .object(let r2)? = corrResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue else {
            Issue.record("find_correspondences response missing text content: \(corrResp)")
            return
        }
        guard let d2 = t2.data(using: .utf8),
              let parsedCorr = try? JSONSerialization.jsonObject(with: d2),
              let p2 = parsedCorr as? [String: Any] else {
            Issue.record("find_correspondences text wasn't JSON object: t2=[\(t2)] corrResp=\(corrResp)")
            return
        }
        guard let arr = p2["correspondences"] as? [[String: Any]],
              let entry = arr.first else {
            Issue.record("find_correspondences missing correspondences array: \(t2)")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        #expect(fate == "matched", "expected matched, got \(fate) (entry: \(entry))")
        let target = entry["targetSelectionId"] as? String ?? ""
        #expect(target.hasPrefix("sel:mirror-src#face["),
                "target selectionId should resolve onto the mirror body, got \(target)")
        if let conf = entry["confidenceMm"] as? Double {
            // Mirror is exact for axis-aligned faces; allow a generous
            // floor for OCCT-tessellation centroid noise.
            #expect(conf < 0.01, "expected near-zero match distance, got \(conf)")
        }
    }

    @Test("find_correspondences accepts a compound (translate then mirror) transform")
    func findCorrespondencesCompoundTransform() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-corrcomp-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Source at +X corner, target is the same shape translated +5X
        // then mirrored about the YZ plane → final position at -X-side.
        // We pass the compound transform as one transform argument and
        // expect the target face to resolve to a low-distance match.
        guard let box = Shape.box(width: 20, height: 20, depth: 20),
              let src = box.translated(by: SIMD3(20, 0, 0)) else {
            Issue.record("Failed to synthesise box")
            return
        }
        // Compose the same transform on the test side to construct
        // the target BREP that the server will be asked to match.
        guard let translated = src.translated(by: SIMD3(5, 0, 0)) else {
            Issue.record("translated failed")
            return
        }
        guard let mirrored = translated.mirrored(planeNormal: SIMD3(1, 0, 0), planeOrigin: .zero) else {
            Issue.record("mirrored failed")
            return
        }
        try Exporter.writeBREP(shape: src, to: URL(fileURLWithPath: "\(scene)/src.brep"))
        try Exporter.writeBREP(shape: mirrored, to: URL(fileURLWithPath: "\(scene)/tgt.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "compound transform test",
            bodies: [
                BodyDescriptor(id: "src", file: "src.brep", color: [1, 0, 0, 1]),
                BodyDescriptor(id: "tgt", file: "tgt.brep", color: [0, 1, 0, 1]),
            ]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 100, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("src"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = (try? JSONSerialization.jsonObject(with: d1)) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected: \(selResp)")
            return
        }

        // compound: translate +5X, then mirror about YZ.
        try harness.send(.init(
            id: 101, method: "tools/call",
            params: .object([
                "name": .string("find_correspondences"),
                "arguments": .object([
                    "sourceSelectionIds": .array([.string(selectionId)]),
                    "targetBodyId": .string("tgt"),
                    "transform": .object([
                        "kind": .string("compound"),
                        "steps": .array([
                            .object([
                                "kind": .string("translate"),
                                "offset": .array([.double(5), .double(0), .double(0)]),
                            ]),
                            .object([
                                "kind": .string("mirror"),
                                "planeOrigin": .array([.double(0), .double(0), .double(0)]),
                                "planeNormal": .array([.double(1), .double(0), .double(0)]),
                            ]),
                        ]),
                    ]),
                ]),
            ])
        ))
        let resp = try harness.recv(timeout: 10)
        guard case .object(let r2)? = resp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any],
              let arr = parsed["correspondences"] as? [[String: Any]],
              let entry = arr.first else {
            Issue.record("find_correspondences response unexpected: \(resp)")
            return
        }
        #expect(parsed["transformSource"] as? String == "explicit",
                "compound was caller-supplied; transformSource should be 'explicit'")
        #expect(entry["fate"] as? String == "matched",
                "expected matched, got \(entry)")
        if let conf = entry["confidenceMm"] as? Double {
            #expect(conf < 0.01, "expected near-zero distance, got \(conf)")
        }
    }

    @Test("find_correspondences reads provenance when transform omitted (mirror_or_pattern path)")
    func findCorrespondencesProvenanceFallback() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-corrprov-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        guard let box = Shape.box(width: 20, height: 20, depth: 20),
              let src = box.translated(by: SIMD3(20, 0, 0)) else {
            Issue.record("Failed to synthesise box")
            return
        }
        try Exporter.writeBREP(shape: src, to: URL(fileURLWithPath: "\(scene)/src.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "provenance fallback test",
            bodies: [BodyDescriptor(id: "src", file: "src.brep", color: [1, 0, 0, 1])]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        // Mirror via the tool: this is what writes the provenance entry.
        try harness.send(.init(
            id: 110, method: "tools/call",
            params: .object([
                "name": .string("mirror_or_pattern"),
                "arguments": .object([
                    "bodyId": .string("src"),
                    "kind": .string("mirror"),
                    "params": .object([
                        "planeOrigin": .array([.double(0), .double(0), .double(0)]),
                        "planeNormal": .array([.double(1), .double(0), .double(0)]),
                    ]),
                ]),
            ])
        ))
        _ = try harness.recv(timeout: 30)

        // Pick a face on the source.
        try harness.send(.init(
            id: 111, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("src"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = (try? JSONSerialization.jsonObject(with: d1)) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        // No transform argument: should pick up the provenance record.
        try harness.send(.init(
            id: 112, method: "tools/call",
            params: .object([
                "name": .string("find_correspondences"),
                "arguments": .object([
                    "sourceSelectionIds": .array([.string(selectionId)]),
                    "targetBodyId": .string("mirror-src"),
                ]),
            ])
        ))
        let resp = try harness.recv(timeout: 10)
        guard case .object(let r2)? = resp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any],
              let arr = parsed["correspondences"] as? [[String: Any]],
              let entry = arr.first else {
            Issue.record("find_correspondences response unexpected: \(resp)")
            return
        }
        #expect(parsed["transformSource"] as? String == "provenance",
                "transform should resolve from provenance.json, got transformSource=\(parsed["transformSource"] ?? "nil")")
        #expect(entry["fate"] as? String == "matched",
                "expected matched via provenance default, got \(entry)")
    }

    @Test("find_correspondences infers a translation from bbox alignment when no hint")
    func findCorrespondencesBboxInference() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-corrbbox-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Two boxes of the same size, translated by [30, 0, 0]. No
        // mirror_or_pattern call → no provenance entry → tool falls
        // through to bbox inference.
        guard let box = Shape.box(width: 20, height: 20, depth: 20),
              let tgt = box.translated(by: SIMD3(30, 0, 0)) else {
            Issue.record("Failed to synthesise boxes")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/src.brep"))
        try Exporter.writeBREP(shape: tgt, to: URL(fileURLWithPath: "\(scene)/tgt.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "bbox inference test",
            bodies: [
                BodyDescriptor(id: "src", file: "src.brep", color: [1, 0, 0, 1]),
                BodyDescriptor(id: "tgt", file: "tgt.brep", color: [0, 1, 0, 1]),
            ]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 120, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("src"),
                    "kind": .string("face"),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = (try? JSONSerialization.jsonObject(with: d1)) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        try harness.send(.init(
            id: 121, method: "tools/call",
            params: .object([
                "name": .string("find_correspondences"),
                "arguments": .object([
                    "sourceSelectionIds": .array([.string(selectionId)]),
                    "targetBodyId": .string("tgt"),
                ]),
            ])
        ))
        let resp = try harness.recv(timeout: 10)
        guard case .object(let r2)? = resp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let parsed = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any],
              let arr = parsed["correspondences"] as? [[String: Any]],
              let entry = arr.first else {
            Issue.record("find_correspondences response unexpected: \(resp)")
            return
        }
        #expect(parsed["transformSource"] as? String == "bbox-inference",
                "transform should be inferred from bbox alignment, got transformSource=\(parsed["transformSource"] ?? "nil")")
        #expect(entry["fate"] as? String == "matched",
                "expected matched via bbox inference, got \(entry)")
    }

    @Test("annotation tools round-trip via the sidecar")
    func annotationsRoundTrip() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-anno-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // No BREP needed for these tools; annotations are pure scene
        // sidecar mutation. We do still need a manifest so other tools
        // don't fail; an empty bodies array is fine.
        let manifest = ScriptManifest(
            description: "Annotation round-trip scene",
            bodies: []
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }
        try harness.handshake()

        // add a Trihedron
        try harness.send(.init(
            id: 20, method: "tools/call",
            params: .object([
                "name": .string("add_scene_primitive"),
                "arguments": .object([
                    "kind": .string("trihedron"),
                    "id": .string("test_trihedron"),
                    "params": .object([
                        "origin": .array([.double(0), .double(0), .double(0)]),
                        "axisLength": .double(10),
                    ]),
                ]),
            ])
        ))
        let addResp = try harness.recv(timeout: 5)
        #expect(addResp["error"] == nil)

        // sidecar should now exist with our trihedron
        let sidecarPath = "\(scene)/annotations.json"
        #expect(FileManager.default.fileExists(atPath: sidecarPath))
        let raw = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let decoded = try JSONDecoder().decode(AnnotationsSidecar.self, from: raw)
        #expect(decoded.primitives.contains { $0.id == "test_trihedron" })

        // remove it
        try harness.send(.init(
            id: 21, method: "tools/call",
            params: .object([
                "name": .string("remove_scene_annotation"),
                "arguments": .object([
                    "id": .string("test_trihedron"),
                ]),
            ])
        ))
        let removeResp = try harness.recv(timeout: 5)
        #expect(removeResp["error"] == nil)

        let raw2 = try Data(contentsOf: URL(fileURLWithPath: sidecarPath))
        let decoded2 = try JSONDecoder().decode(AnnotationsSidecar.self, from: raw2)
        #expect(decoded2.primitives.allSatisfy { $0.id != "test_trihedron" })
    }

    @Test("ping responds and the scene tools resolve a tempdir manifest")
    func pingAndScene() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }

        // Seed a fresh scene the server will see when we redirect
        // OCCTMCP_OUTPUT_DIR.
        let scene = NSTemporaryDirectory()
            + "occtmcp-it-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        let manifest = ScriptManifest(
            description: "Integration test scene",
            bodies: [BodyDescriptor(id: "alpha", file: "alpha.brep", color: [1, 0, 0, 1])]
        )
        let store = ManifestStore(path: "\(scene)/manifest.json")
        try store.write(manifest)
        try "DUMMY".write(toFile: "\(scene)/alpha.brep", atomically: true, encoding: .utf8)

        let harness = try Harness(
            binary: binary,
            extraEnv: ["OCCTMCP_OUTPUT_DIR": scene]
        )
        defer { harness.terminate() }

        try harness.handshake()

        // ping
        try harness.send(.init(
            id: 10, method: "tools/call",
            params: .object([
                "name": .string("ping"),
                "arguments": .object([:]),
            ])
        ))
        let pingResp = try harness.recv(timeout: 5)
        #expect(pingResp["error"] == nil)

        // get_scene: should round-trip our seeded manifest
        try harness.send(.init(
            id: 11, method: "tools/call",
            params: .object([
                "name": .string("get_scene"),
                "arguments": .object([:]),
            ])
        ))
        let sceneResp = try harness.recv(timeout: 5)
        guard case .object(let result)? = sceneResp["result"],
              case .array(let content)? = result["content"],
              case .object(let firstContent)? = content.first,
              let text = firstContent["text"]?.stringValue else {
            Issue.record("get_scene response shape unexpected")
            return
        }
        #expect(text.contains("alpha"))
    }

    @Test("history-based remap: a face split by a boolean resolves to both successors (#90/#93)")
    func historyRemapSplitFaceResolvesToTwoSuccessors() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-split-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Shape.box(width:height:depth:) is centred at the origin, so a
        // 20x20x20 box spans x/y/z: -10..10 (top face at z=10). `tool`
        // is a shallow slot cut down from the top face only (z: 0..10
        // vs box z: -10..10, doesn't reach the bottom), off-centre in
        // x (6..8 of -10..10, full y width) so it splits the top face
        // into two unequal, individually-addressable pieces rather than
        // deleting it outright.
        guard let box = Shape.box(width: 20, height: 20, depth: 20),
              let toolRaw = Shape.box(width: 2, height: 20, depth: 10),
              let tool = toolRaw.translated(by: SIMD3(7, 0, 5)) else {
            Issue.record("Failed to synthesise box/tool fixtures")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/part.brep"))
        try Exporter.writeBREP(shape: tool, to: URL(fileURLWithPath: "\(scene)/tool.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "split-face history test",
            bodies: [
                BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1]),
                BodyDescriptor(id: "tool", file: "tool.brep", color: [0, 1, 0, 1]),
            ]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        // Pick the top face specifically (outward normal +Z), the one
        // the slot cut will split into two.
        try harness.send(.init(
            id: 70, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "kind": .string("face"),
                    "filter": .object(["normalDirection": .array([.double(0), .double(0), .double(1)])]),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        try harness.send(.init(
            id: 71, method: "tools/call",
            params: .object([
                "name": .string("boolean_op"),
                "arguments": .object([
                    "op": .string("subtract"),
                    "aBodyId": .string("part"),
                    "bBodyId": .string("tool"),
                    "outputBodyId": .string("slotted"),
                ]),
            ])
        ))
        let boolResp = try harness.recv(timeout: 30)
        #expect(boolResp["error"] == nil, "boolean subtract errored: \(boolResp)")

        try harness.send(.init(
            id: 72, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object(["selectionIds": .array([.string(selectionId)])]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        let newIds = entry["newSelectionIds"] as? [String] ?? []
        #expect(fate == "split", "top face crossed by a slot should split (got \(fate))")
        #expect(newIds.count == 2, "expected 2 successor faces from the slot cut, got \(newIds.count): \(newIds)")
        if let conf = entry["confidenceMm"] as? Double {
            #expect(conf == 0, "history path should report confidenceMm=0, got \(conf)")
        }
    }

    @Test("history-based remap: a face fully consumed by a boolean reports fate=lost, not a false match (#90/#93)")
    func historyRemapDistinguishesDeletedFromModified() async throws {
        guard let binary = Self.binaryURL else {
            Issue.record("Binary not built; run `swift build` first.")
            return
        }
        let scene = NSTemporaryDirectory() + "occtmcp-it-deleted-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }

        // Shape.box(width:height:depth:) is centred at the origin: a
        // 10x10x10 box spans x/y/z: -5..5 (top face at z=5). `tool`
        // engulfs the entire top half (z: 0..5) and then some in x/y
        // too, so the original top face has no image at all in the
        // result: fully consumed, not merely reshaped.
        guard let box = Shape.box(width: 10, height: 10, depth: 10),
              let toolRaw = Shape.box(width: 20, height: 20, depth: 10),
              let tool = toolRaw.translated(by: SIMD3(-5, -5, 5)) else {
            Issue.record("Failed to synthesise box/tool fixtures")
            return
        }
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: "\(scene)/part.brep"))
        try Exporter.writeBREP(shape: tool, to: URL(fileURLWithPath: "\(scene)/tool.brep"))
        try ManifestStore(path: "\(scene)/manifest.json").write(ScriptManifest(
            description: "deleted-face history test",
            bodies: [
                BodyDescriptor(id: "part", file: "part.brep", color: [1, 0, 0, 1]),
                BodyDescriptor(id: "tool", file: "tool.brep", color: [0, 1, 0, 1]),
            ]
        ))

        let harness = try Harness(binary: binary, extraEnv: ["OCCTMCP_OUTPUT_DIR": scene])
        defer { harness.terminate() }
        try harness.handshake()

        try harness.send(.init(
            id: 80, method: "tools/call",
            params: .object([
                "name": .string("select_topology"),
                "arguments": .object([
                    "bodyId": .string("part"),
                    "kind": .string("face"),
                    "filter": .object(["normalDirection": .array([.double(0), .double(0), .double(1)])]),
                    "limit": .int(1),
                ]),
            ])
        ))
        let selResp = try harness.recv(timeout: 10)
        guard case .object(let r1)? = selResp["result"],
              case .array(let c1)? = r1["content"],
              case .object(let f1)? = c1.first,
              let t1 = f1["text"]?.stringValue,
              let d1 = t1.data(using: .utf8),
              let p1 = try JSONSerialization.jsonObject(with: d1) as? [String: Any],
              let sels = p1["selections"] as? [[String: Any]],
              let firstSel = sels.first,
              let selectionId = firstSel["selectionId"] as? String else {
            Issue.record("select_topology response shape unexpected")
            return
        }

        try harness.send(.init(
            id: 81, method: "tools/call",
            params: .object([
                "name": .string("boolean_op"),
                "arguments": .object([
                    "op": .string("subtract"),
                    "aBodyId": .string("part"),
                    "bBodyId": .string("tool"),
                    "outputBodyId": .string("halved"),
                ]),
            ])
        ))
        let boolResp = try harness.recv(timeout: 30)
        #expect(boolResp["error"] == nil, "boolean subtract errored: \(boolResp)")

        try harness.send(.init(
            id: 82, method: "tools/call",
            params: .object([
                "name": .string("remap_selection"),
                "arguments": .object(["selectionIds": .array([.string(selectionId)])]),
            ])
        ))
        let rmResp = try harness.recv(timeout: 5)
        guard case .object(let r2)? = rmResp["result"],
              case .array(let c2)? = r2["content"],
              case .object(let f2)? = c2.first,
              let t2 = f2["text"]?.stringValue,
              let d2 = t2.data(using: .utf8),
              let p2 = try JSONSerialization.jsonObject(with: d2) as? [String: Any],
              let remapped = p2["remapped"] as? [[String: Any]],
              let entry = remapped.first else {
            Issue.record("remap_selection response shape unexpected")
            return
        }
        let fate = entry["fate"] as? String ?? "<missing>"
        let newIds = entry["newSelectionIds"] as? [String] ?? []
        #expect(fate == "lost", "fully-consumed top face should report fate=lost (got \(fate))")
        #expect(newIds.isEmpty, "a deleted face should have no successors, got \(newIds)")
    }
}

// MARK: - Harness

/// JSON-RPC over newline-delimited stdio against a spawned MCP server.
final class Harness {
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private let stderr: FileHandle
    private var pending = Data()

    init(binary: URL, extraEnv: [String: String] = [:]) throws {
        let p = Process()
        p.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = stderrPipe
        try p.run()
        self.process = p
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderr = stderrPipe.fileHandleForReading
    }

    struct Request {
        let id: Int?
        let method: String
        let params: Value
        init(id: Int? = nil, method: String, params: Value) {
            self.id = id
            self.method = method
            self.params = params
        }
    }

    func send(_ request: Request) throws {
        var dict: [String: Value] = [
            "jsonrpc": .string("2.0"),
            "method": .string(request.method),
            "params": request.params,
        ]
        if let id = request.id {
            dict["id"] = .int(id)
        }
        let data = try JSONEncoder().encode(Value.object(dict))
        try stdin.write(contentsOf: data)
        try stdin.write(contentsOf: [UInt8(ascii: "\n")])
    }

    /// Block until a complete JSON object arrives on stdout, or the
    /// timeout elapses. Returns the parsed object (top-level dict).
    func recv(timeout seconds: TimeInterval) throws -> [String: Value] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let line = nextLine() {
                let parsed = try JSONDecoder().decode(Value.self, from: line)
                guard case .object(let dict) = parsed else {
                    throw Harness.HarnessError.unexpectedShape("top-level not an object")
                }
                return dict
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                try? Task.checkCancellation()
                Thread.sleep(forTimeInterval: 0.01)
            } else {
                pending.append(chunk)
            }
        }
        throw HarnessError.timeout(seconds)
    }

    private func nextLine() -> Data? {
        guard let nl = pending.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = pending[..<nl]
        pending.removeSubrange(...nl)
        return Data(line)
    }

    func handshake() throws {
        try send(.init(
            id: 1, method: "initialize",
            params: .object([
                "protocolVersion": .string("2024-11-05"),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("integration-test"),
                    "version": .string("0.1"),
                ]),
            ])
        ))
        _ = try recv(timeout: 10)
        try send(.init(
            method: "notifications/initialized",
            params: .object([:])
        ))
    }

    func terminate() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    enum HarnessError: Error, CustomStringConvertible {
        case timeout(TimeInterval)
        case unexpectedShape(String)
        var description: String {
            switch self {
            case .timeout(let s): return "stdio response timeout after \(s)s"
            case .unexpectedShape(let m): return "unexpected JSON shape: \(m)"
            }
        }
    }
}

// MCP's Value type is in the MCP module; harness needs to encode/decode it.
// Re-import here so this file doesn't depend on @testable internals.
import MCP
