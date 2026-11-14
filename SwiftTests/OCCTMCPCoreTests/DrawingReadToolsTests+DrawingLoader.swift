// The drawing read tools through OCCTSwiftIO's DrawingLoader (#271): DXF, DWG and JWW read from
// their bytes, block expansion and paper space as options every tool takes, the handle and
// locator of every entity, and hatches and leaders as entities. The fixture and helpers are the
// ones in DrawingReadToolsTests.swift.

import CryptoKit
import Foundation
import MCP
@testable import OCCTMCPCore
import OCCTSwiftIO
import Testing

extension DrawingReadToolsTests {

    /// Where `plate.dxf`, `plate.dwg` and `plate.jww` are.
    static var plateDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Drawing")
    }

    /// The plate as a JWW: the same 100 x 60 plate as `plate.dxf`, without the dimensions.
    static var plateJWW: String {
        plateDirectory.appendingPathComponent("plate.jww").path
    }

    // ── DWG and JWW ─────────────────────────────────────────────────────

    @Test("a DWG is read, with its own version and the hash of its bytes")
    func dwgIsRead() async throws {
        let path = Self.plateDirectory.appendingPathComponent("plate.dwg").path
        let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
        let source = try #require(r["source"] as? [String: Any])
        #expect(source["format"] as? String == "dwg")
        #expect(source["formatVersion"] as? String == "AC1032")
        #expect(source["dxfVersion"] == nil, "a DWG has no $ACADVER of a DXF")
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(
            source["sha256"] as? String
                == SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        #expect((source["reader"] as? String)?.contains("DrawingLoader") == true)
        let byType = try #require(r["byType"] as? [String: Int])
        #expect(byType == ["line": 4, "circle": 1, "dimension": 3], "\(byType)")
    }

    @Test("a JWW is read, and its missing units are said rather than assumed")
    func jwwIsRead() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.plateJWW)]))
        let source = try #require(r["source"] as? [String: Any])
        #expect(source["format"] as? String == "jww" && source["formatVersion"] as? String == "700")
        #expect(r["byType"] as? [String: Int] == ["line": 4, "circle": 1])
        let warnings = try #require(r["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("no usable units") }, "\(warnings)")
    }

    @Test("the same plate from a DXF, a DWG and a JWW has the same lines and circle")
    func samePlateThreeFormats() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let paths = [
            Self.plateDirectory.appendingPathComponent("plate.dxf").path,
            Self.plateDirectory.appendingPathComponent("plate.dwg").path, Self.plateJWW,
        ]
        var geometries: [[String]] = []
        for path in paths {
            let all = try await entities(["types": ["line", "circle"]], path).all
            geometries.append(
                all.map { e in
                    let type = e["type"] as? String ?? "?"
                    if type == "circle" {
                        return "circle \(numbers(e["center"]) ?? []) \(e["radius"] ?? "?")"
                    }
                    return "line \(numbers(e["start"]) ?? []) \(numbers(e["end"]) ?? [])"
                }.sorted())
        }
        #expect(geometries[0].count == 5, "\(geometries[0])")
        #expect(geometries[1] == geometries[0], "the DWG differs from the DXF")
        #expect(geometries[2] == geometries[0], "the JWW differs from the DXF")
    }

    @Test("a truncated DWG says it is a DWG that ended, not that it is unsupported")
    func truncatedDWG() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let whole = try Data(
            contentsOf: Self.plateDirectory.appendingPathComponent("plate.dwg"))
        let path = dir.appendingPathComponent("cut.dwg")
        try whole.prefix(200).write(to: path)
        let r = await call("read_drawing", ["inputPath": .string(path.path)])
        #expect(r.isError && r.text.contains("DWG"), "\(r.text)")
        #expect(!r.text.contains("supported formats"), "\(r.text)")
    }

    @Test("the format is told from the bytes, not the file name")
    func formatFromTheBytes() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plate = try Data(contentsOf: Self.plateDirectory.appendingPathComponent("plate.dxf"))
        for name in ["plot.txt", "no-extension", "mislabelled.dwg"] {
            let url = dir.appendingPathComponent(name)
            try plate.write(to: url)
            let r = try json(await call("read_drawing", ["inputPath": .string(url.path)]))
            let source = try #require(r["source"] as? [String: Any])
            #expect(source["format"] as? String == "dxf", "\(name)")
            #expect(r["entityCount"] as? Int == 5, "\(name)")
        }
    }

    @Test(
        "a file that cannot be opened says why, in words",
        .enabled(if: getuid() != 0, "a superuser can read a file with no permissions"))
    func unreadableFile() async throws {
        let dir = try makeDirectory()
        let url = dir.appendingPathComponent("locked.dxf")
        try Data("0\nEOF\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let r = await call("read_drawing", ["inputPath": .string(url.path)])
        #expect(r.isError && r.text.contains("permission"), "\(r.text)")
        #expect(!r.text.contains("NSCocoaErrorDomain"), "a raw error dump: \(r.text)")
    }

    @Test("what a reader skips without saying which layer is counted by type alone")
    func skippedWithoutLayers() {
        // A DWG's skipped entities have no layer (SwiftDWG writes them as bare records).
        let warnings = [
            DrawingWarning(kind: .skippedEntities, type: "ATTDEF", count: 5, message: "attdef"),
            DrawingWarning(
                kind: .skippedEntities, type: "SOLID", layer: "FILL", count: 2, message: "solid"),
            DrawingWarning(kind: .missingBlock, type: "X", count: 9, message: "not skipped"),
        ]
        let skipped = DrawingFile.skipped(from: warnings)
        #expect(skipped.total == 7)
        #expect(skipped.byType == ["ATTDEF": 5, "SOLID": 2])
        #expect(skipped.byLayer == ["FILL": ["SOLID": 2]], "ATTDEF has no layer to be under")
    }

    // ── handles ─────────────────────────────────────────────────────────

    @Test("an entity carries its DXF handle and its place in the file, in a DXF and in a DWG")
    func handlesAndLocators() async throws {
        let dxf = try await entities(
            [:], Self.plateDirectory.appendingPathComponent("plate.dxf").path
        ).all
        #expect(dxf.first?["handle"] as? String == "31")
        #expect(dxf.first?["locator"] as? String == "ENTITIES:0")
        #expect(dxf.allSatisfy { $0["via"] == nil }, "nothing was expanded")
        let dwg = try await entities(
            [:], Self.plateDirectory.appendingPathComponent("plate.dwg").path
        ).all
        #expect(dwg.allSatisfy { $0["handle"] is String }, "a DWG keeps its handles")
        // The DWG was made from the DXF, so its first entities have the DXF's handles.
        #expect(
            dwg.prefix(5).map { $0["handle"] as? String }
                == dxf.prefix(5).map { $0["handle"] as? String })
    }

    // ── blocks and paper space ──────────────────────────────────────────

    /// A line, and two inserts of a block holding a circle with its own handle.
    private func blockFixture() -> DrawingFixture {
        var f = DrawingFixture()
        f.blocks = [
            (0, "BLOCK"), (8, "0"), (2, "FASTENER"), (70, "0"), (10, "0"), (20, "0"), (30, "0"),
            (3, "FASTENER"),
            (0, "CIRCLE"), (5, "31"), (8, "0"), (10, "0"), (20, "0"), (30, "0"), (40, "2"),
            (0, "ENDBLK"), (8, "0"),
        ]
        f.add(
            "base", "LINE", layer: "L",
            [(5, "A0"), (10, "0"), (20, "0"), (30, "0"), (11, "5"), (21, "0"), (31, "0")])
        f.add(
            nil, "INSERT", layer: "BLOCKS",
            [(5, "8E"), (2, "FASTENER"), (10, "10"), (20, "10"), (30, "0")])
        f.add(
            nil, "INSERT", layer: "BLOCKS",
            [(5, "8F"), (2, "FASTENER"), (10, "70"), (20, "10"), (30, "0")])
        return f
    }

    @Test("blocks are expanded unless asked not to, and every result says which it was")
    func blockExpansion() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try blockFixture().write(to: dir)

        // The default expands: the line and a circle for each INSERT.
        let expanded = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(expanded["entityCount"] as? Int == 3, "\(expanded)")
        #expect(expanded["byType"] as? [String: Int] == ["line": 1, "circle": 2])
        let skipped = try #require(expanded["skipped"] as? [String: Any])
        #expect(skipped["total"] as? Int == 0, "an expanded INSERT is not skipped: \(skipped)")
        #expect(
            (expanded["source"] as? [String: Any])?["options"] as? [String: Bool] == [
                "expandBlocks": true, "skipPaperSpace": false,
            ])
        let circles = try await entities(["types": ["circle"]], path).all
        #expect(circles.count == 2)
        let first = try #require(circles.first { ($0["via"] as? [String]) == ["8E"] })
        #expect(first["blocks"] as? [String] == ["FASTENER"])
        #expect(first["handle"] as? String == "31", "the circle's own handle, inside the block")
        #expect(near(numbers(first["center"]), [10, 10, 0]), "placed at the insert")
        let second = try #require(circles.first { ($0["via"] as? [String]) == ["8F"] })
        #expect(near(numbers(second["center"]), [70, 10, 0]))
        let base = try #require(try await entities(["types": ["line"]], path).all.first)
        #expect(base["via"] == nil && base["handle"] as? String == "A0")

        // Asked not to, the inserts stay references: skipped, and warned about.
        let flat = try json(
            await call("read_drawing", ["inputPath": .string(path), "expandBlocks": false]))
        #expect(flat["entityCount"] as? Int == 1)
        let flatSkipped = try #require(flat["skipped"] as? [String: Any])
        #expect(flatSkipped["byType"] as? [String: Int] == ["INSERT": 2])
        let flatWarnings = try #require(flat["warnings"] as? [String])
        #expect(flatWarnings.contains { $0.contains("not expanded") }, "\(flatWarnings)")
        #expect(
            (flat["source"] as? [String: Any])?["options"] as? [String: Bool] == [
                "expandBlocks": false, "skipPaperSpace": false,
            ])

        // Every tool's source reference carries the options the ids were made under.
        let listed = try json(
            await call(
                "list_drawing_entities", ["inputPath": .string(path), "expandBlocks": false]))
        let ref = try #require(listed["source"] as? [String: Any])
        #expect(
            ref["options"] as? [String: Bool] == ["expandBlocks": false, "skipPaperSpace": false])

        // The two reads of one file do not answer each other from the cache.
        let again = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(again["entityCount"] as? Int == 3)
        let flatAgain = try json(
            await call("read_drawing", ["inputPath": .string(path), "expandBlocks": false]))
        #expect(flatAgain["entityCount"] as? Int == 1)
    }

    @Test("paper space is read unless asked to leave it out, and said so")
    func paperSpace() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "model", "LINE", layer: "M",
            [(10, "0"), (20, "0"), (30, "0"), (11, "5"), (21, "0"), (31, "0")])
        f.add(
            "paper", "LINE", layer: "P",
            [(67, "1"), (10, "0"), (20, "9"), (30, "0"), (11, "5"), (21, "9"), (31, "0")])
        let path = try f.write(to: dir)

        let both = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(both["entityCount"] as? Int == 2)
        let warnings = try #require(both["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("paper space") }, "\(warnings)")

        let modelOnly = try json(
            await call("read_drawing", ["inputPath": .string(path), "skipPaperSpace": true]))
        #expect(modelOnly["entityCount"] as? Int == 1)
        #expect(
            (modelOnly["source"] as? [String: Any])?["options"] as? [String: Bool] == [
                "expandBlocks": true, "skipPaperSpace": true,
            ])
        let listed = try json(
            await call(
                "list_drawing_entities", ["inputPath": .string(path), "skipPaperSpace": true]))
        #expect((listed["entities"] as? [[String: Any]])?.count == 1)
    }

    @Test("all four tools honour both read settings, and null means the default")
    func everyToolHonoursTheReadSettings() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // A block holding a circle and a dimension; a model line, one insert of the block, then a
        // paper-space line and a paper-space dimension.
        f.blocks = [
            (0, "BLOCK"), (8, "0"), (2, "FASTENER"), (70, "0"), (10, "0"), (20, "0"), (30, "0"),
            (3, "FASTENER"),
            (0, "CIRCLE"), (5, "31"), (8, "0"), (10, "0"), (20, "0"), (30, "0"), (40, "2"),
            (0, "DIMENSION"), (5, "B7"), (8, "0"), (70, "1"), (11, "5"), (21, "-2"), (31, "0"),
            (10, "0"), (20, "-2"), (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "10"),
            (24, "0"), (34, "0"),
            (0, "ENDBLK"), (8, "0"),
        ]
        f.add(
            nil, "LINE", layer: "M",
            [(10, "0"), (20, "0"), (30, "0"), (11, "5"), (21, "0"), (31, "0")])
        f.add(nil, "INSERT", layer: "B", [(5, "8E"), (2, "FASTENER"), (10, "10"), (20, "10")])
        f.add(
            nil, "LINE", layer: "P",
            [(67, "1"), (10, "0"), (20, "9"), (30, "0"), (11, "5"), (21, "9"), (31, "0")])
        f.add(
            nil, "DIMENSION", layer: "D",
            [
                (67, "1"), (70, "1"), (11, "5"), (21, "-2"), (31, "0"), (10, "0"), (20, "-2"),
                (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "10"), (24, "0"), (34, "0"),
            ])
        let path = try f.write(to: dir)
        func args(_ extra: [String: Value]) -> [String: Value] {
            var all: [String: Value] = ["inputPath": .string(path)]
            all.merge(extra) { $1 }
            return all
        }
        let both: [String: Value] = ["expandBlocks": false, "skipPaperSpace": true]
        let nulls: [String: Value] = ["expandBlocks": .null, "skipPaperSpace": .null]

        // list_drawing_dimensions: the block's dimension and the paper-space one.
        func dimensions(_ extra: [String: Value]) async throws -> Int? {
            try json(await call("list_drawing_dimensions", args(extra)))["total"] as? Int
        }
        #expect(try await dimensions([:]) == 2)
        #expect(try await dimensions(["expandBlocks": false]) == 1, "the block's is not expanded")
        #expect(try await dimensions(["skipPaperSpace": true]) == 1, "the paper-space one is out")
        #expect(try await dimensions(both) == 0)
        #expect(try await dimensions(nulls) == 2, "null is the default")

        // list_drawing_entities: the block's circle, and the model and paper lines.
        func total(_ type: String, _ extra: [String: Value]) async throws -> Int? {
            var all = args(extra)
            all["types"] = [.string(type)]
            return try json(await call("list_drawing_entities", all))["total"] as? Int
        }
        #expect(try await total("circle", [:]) == 1)
        #expect(try await total("circle", ["expandBlocks": false]) == 0)
        #expect(try await total("line", [:]) == 2)
        #expect(try await total("line", ["skipPaperSpace": true]) == 1)
        #expect(try await total("circle", nulls) == 1)
        #expect(try await total("line", nulls) == 2)

        // read_drawing: the same, as counts.
        let read = try json(await call("read_drawing", args([:])))
        #expect(read["byType"] as? [String: Int] == ["line": 2, "circle": 1, "dimension": 2])
        let readNull = try json(await call("read_drawing", args(nulls)))
        #expect(readNull["entityCount"] as? Int == read["entityCount"] as? Int)

        // measure_drawing: ids from the default read, then the settings take the entities away.
        let lines = try await entities(["types": ["line"]], path).all
        let model = try #require(lines.first { $0["layer"] as? String == "M" }?["id"] as? String)
        let paper = try #require(lines.first { $0["layer"] as? String == "P" }?["id"] as? String)
        let circle = try #require(
            try await entities(["types": ["circle"]], path).all.first?["id"] as? String)
        let distance: [String: Value] = [
            "measure": "distance", "a": .string(model), "b": .string(paper),
        ]
        let radius: [String: Value] = ["measure": "radius", "a": .string(circle)]
        // The model line is (0, 0) to (5, 0) and the paper line (0, 9) to (5, 9): 9 apart.
        let measured = try json(await call("measure_drawing", args(distance)))
        #expect(measured["value"] as? Double == 9, "\(measured)")
        #expect(!(await call("measure_drawing", args(radius))).isError)
        let measuredNull = try json(
            await call("measure_drawing", args(distance.merging(nulls) { $1 })))
        #expect(measuredNull["value"] as? Double == 9, "null is the default")
        // Skipping paper space takes the line away and renumbers the rest, so the same two ids are
        // no longer two lines 9 apart.
        let noPaper = await call(
            "measure_drawing", args(distance.merging(["skipPaperSpace": true]) { $1 }))
        let noPaperValue = noPaper.isError ? nil : try json(noPaper)["value"] as? Double
        #expect(noPaperValue != 9, "the paper-space line is not there to measure: \(noPaper.text)")
        let noBlocks = await call(
            "measure_drawing", args(radius.merging(["expandBlocks": false]) { $1 }))
        #expect(noBlocks.isError, "the block's circle is not there to measure: \(noBlocks.text)")
    }

    @Test("a clockwise hatch arc is boxed by the stretch it runs along")
    func clockwiseHatchArc() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Centre (5, 0), radius 5, clockwise from 180 degrees to 0: over the top, through (5, 5).
        f.add(
            "arc", "HATCH", layer: "H",
            [
                (2, "X"), (70, "0"), (91, "1"), (92, "1"), (93, "1"), (72, "2"), (10, "5"),
                (20, "0"), (40, "5"), (50, "180"), (51, "0"), (73, "0"), (97, "0"),
            ])
        let all = try await entities([:], try f.write(to: dir)).all
        let hatch = try #require(all.first { $0["id"] as? String == f.id("arc") })
        let box = try #require(hatch["bounds"] as? [String: Any])
        #expect(near(numbers(box["min"]), [0, 0, 0], tol: 1e-9), "\(box)")
        #expect(near(numbers(box["max"]), [10, 5, 0], tol: 1e-9), "\(box)")
    }

    @Test("every tool takes the read settings, a wrong type is refused, and null means the default")
    func readSettingsAreArguments() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = Value.string(try fixture.write(to: dir))
        let calls: [(String, [String: Value])] = [
            ("read_drawing", [:]), ("list_drawing_entities", [:]), ("list_drawing_dimensions", [:]),
            (
                "measure_drawing",
                [
                    "measure": "distance", "a": .string(fixture.id("slotLeft")),
                    "b": .string(fixture.id("slotRight")),
                ]
            ),
        ]
        for (tool, extra) in calls {
            var args: [String: Value] = ["inputPath": path]
            args.merge(extra) { $1 }
            for setting in ["expandBlocks", "skipPaperSpace"] {
                var good = args
                good[setting] = .bool(false)
                let ok = await call(tool, good)
                #expect(!ok.isError, "\(tool) \(setting): \(ok.text)")
                var null = args
                null[setting] = .null
                let defaulted = await call(tool, null)
                #expect(!defaulted.isError, "\(tool) \(setting) null: \(defaulted.text)")
                var bad = args
                bad[setting] = .string("yes")
                let refused = await call(tool, bad)
                #expect(
                    refused.isError && refused.text.contains("`\(setting)` must be true or false"),
                    "\(tool) \(setting): \(refused.text)")
            }
        }
    }

    @Test("the catalog offers the read settings on all four tools, and nowhere else")
    func catalogOffersTheReadSettings() throws {
        let tools = catalogTools()
        for name in [
            "read_drawing", "list_drawing_entities", "list_drawing_dimensions", "measure_drawing",
        ] {
            let tool = try #require(tools.first { $0.name == name }, "\(name)")
            let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
            for setting in ["expandBlocks", "skipPaperSpace"] {
                let schema = try #require(properties[setting]?.objectValue, "\(name) \(setting)")
                #expect(schema["type"]?.stringValue == "boolean", "\(name) \(setting)")
            }
        }
        let other = try #require(tools.first { $0.name == "get_scene" })
        let properties = try #require(other.inputSchema.objectValue?["properties"]?.objectValue)
        #expect(properties["expandBlocks"] == nil, "a tool that reads no drawing")
    }

    @Test("the catalog's entity types cover every type a drawing produces")
    func catalogTypesCoverEveryEntity() async throws {
        // A client that checks arguments against the advertised schema must be able to ask for each.
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tools = catalogTools()
        let tool = try #require(tools.first(where: { $0.name == "list_drawing_entities" }))
        let properties = try #require(tool.inputSchema.objectValue?["properties"]?.objectValue)
        let items = try #require(properties["types"]?.objectValue?["items"]?.objectValue)
        let advertised = try #require(items["enum"]?.arrayValue).compactMap { $0.stringValue }
        let all = try await entities([:], try DrawingFixture.tSlot().write(to: dir)).all
        let produced = Set(all.compactMap { $0["type"] as? String })
        #expect(produced.isSuperset(of: ["hatch", "leader", "spline", "dimension", "line"]))
        #expect(produced.subtracting(advertised).isEmpty, "\(produced.subtracting(advertised))")
    }

    @Test("a dimension reports its oblique angle, its style and its rotation")
    func dimensionStyleAndAngles() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "styled", "DIMENSION", layer: "D",
            [
                (70, "0"), (42, "10"), (11, "5"), (21, "-2"), (31, "0"), (10, "0"), (20, "-2"),
                (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "10"), (24, "0"), (34, "0"),
                (50, "0"), (52, "15"), (3, "ISO-25"),
            ])
        let r = try json(
            await call("list_drawing_dimensions", ["inputPath": .string(try f.write(to: dir))]))
        let record = try #require((r["dimensions"] as? [[String: Any]])?.first)
        #expect(record["styleName"] as? String == "ISO-25")
        #expect(record["obliqueAngleDeg"] as? Double == 15)
        #expect(record["rotationDeg"] as? Double == 0, "a stated rotation of 0 is stated")
    }

    // ── hatches and leaders ─────────────────────────────────────────────

    @Test("a hatch lists its pattern, its fill and its boundary, with bounds that follow it")
    func hatchEntity() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let hatches = try await entities(["types": ["hatch"]], path)
        #expect(hatches.ids == [fixture.id("hatch")], "\(hatches.ids)")
        let record = try #require(hatches.all.first)
        #expect(record["layer"] as? String == "HATCH")
        #expect(record["patternName"] as? String == "SOLID" && record["solid"] as? Bool == true)
        let paths = try #require(record["boundaryPaths"] as? [[String: Any]])
        #expect(paths.count == 1)
        #expect(paths[0]["external"] as? Bool == true && paths[0]["kind"] as? String == "polyline")
        #expect((paths[0]["vertices"] as? [Any])?.count == 4 && paths[0]["closed"] as? Bool == true)
        let box = try #require(record["bounds"] as? [String: Any])
        #expect(near(numbers(box["min"]), [80, 40, 0]) && near(numbers(box["max"]), [90, 50, 0]))
    }

    @Test("an edge-type hatch lists its lines and arcs, and its box is tight to the arc")
    func hatchWithEdges() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // A half disk: the line from (0, 0) to (10, 0) and the arc over it, centre (5, 0), radius 5.
        f.add(
            "half", "HATCH", layer: "H",
            [
                (2, "ANSI31"), (70, "0"), (91, "1"), (92, "1"), (93, "2"), (72, "1"), (10, "0"),
                (20, "0"), (11, "10"), (21, "0"), (72, "2"), (10, "5"), (20, "0"), (40, "5"),
                (50, "0"), (51, "180"), (73, "1"), (97, "0"),
            ])
        let record = try #require(try await entities([:], try f.write(to: dir)).all.first)
        #expect(record["patternName"] as? String == "ANSI31" && record["solid"] as? Bool == false)
        let path = try #require((record["boundaryPaths"] as? [[String: Any]])?.first)
        #expect(path["kind"] as? String == "edges" && path["external"] as? Bool == true)
        let edges = try #require(path["edges"] as? [[String: Any]])
        #expect(edges.compactMap { $0["type"] as? String } == ["line", "arc"])
        #expect(near(numbers(edges[0]["end"]), [10, 0, 0]))
        #expect(near(numbers(edges[1]["center"]), [5, 0, 0]) && edges[1]["radius"] as? Double == 5)
        #expect(
            edges[1]["startAngleDeg"] as? Double == 0 && edges[1]["endAngleDeg"] as? Double == 180)
        #expect(edges[1]["counterClockwise"] as? Bool == true)
        // The arc spans the top half only: the box is 5 high, not the circle's 10.
        let box = try #require(record["bounds"] as? [String: Any])
        #expect(near(numbers(box["min"]), [0, 0, 0], tol: 1e-9), "\(String(describing: box))")
        #expect(near(numbers(box["max"]), [10, 5, 0], tol: 1e-9), "\(String(describing: box))")
    }

    @Test(
        "a hatch lists a bulged polyline path, an ellipse edge and a spline edge, with their bounds"
    )
    func hatchEdgeKinds() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // A two-vertex path whose first segment has bulge 1: the semicircle below (0, 0) to (10, 0).
        f.add(
            "bulged", "HATCH", layer: "H",
            [
                (2, "X"), (70, "0"), (91, "1"), (92, "3"), (72, "1"), (73, "1"), (93, "2"),
                (10, "0"), (20, "0"), (42, "1"), (10, "10"), (20, "0"), (42, "0"), (97, "0"),
            ])
        // An ellipse edge: centre (5, 0), major axis (4, 0), ratio 0.25, a full turn.
        f.add(
            "ellipse", "HATCH", layer: "H",
            [
                (2, "X"), (70, "0"), (91, "1"), (92, "1"), (93, "1"), (72, "3"), (10, "5"),
                (20, "0"), (11, "4"), (21, "0"), (40, "0.25"), (50, "0"), (51, "360"), (73, "1"),
                (97, "0"),
            ])
        // A cubic Bezier spline edge from (0, 0) over (3, 4) and (7, 4) to (10, 0): it peaks at y = 3.
        f.add(
            "spline", "HATCH", layer: "H",
            [
                (2, "X"), (70, "0"), (91, "1"), (92, "1"), (93, "1"), (72, "4"), (94, "3"),
                (73, "0"), (74, "0"), (95, "8"), (96, "4"),
            ]
                + [0, 0, 0, 0, 1, 1, 1, 1].map { (40, "\($0)") }
                + [
                    (10, "0"), (20, "0"), (10, "3"), (20, "4"), (10, "7"), (20, "4"), (10, "10"),
                    (20, "0"), (97, "0"),
                ])
        let all = try await entities([:], try f.write(to: dir)).all
        func record(_ name: String) throws -> [String: Any] {
            try #require(all.first { $0["id"] as? String == f.id(name) }, "no \(name)")
        }
        func path(_ record: [String: Any]) throws -> [String: Any] {
            try #require((record["boundaryPaths"] as? [[String: Any]])?.first)
        }

        let bulged = try record("bulged")
        let bulgedPath = try path(bulged)
        #expect(
            bulgedPath["kind"] as? String == "polyline" && bulgedPath["closed"] as? Bool == true)
        #expect(numbers(bulgedPath["bulges"]) == [1, 0], "\(String(describing: bulgedPath))")
        let bulgedBox = try #require(bulged["bounds"] as? [String: Any])
        #expect(near(numbers(bulgedBox["min"]), [0, -5, 0], tol: 1e-9), "\(bulgedBox)")
        #expect(near(numbers(bulgedBox["max"]), [10, 0, 0], tol: 1e-9), "\(bulgedBox)")

        let ellipse = try record("ellipse")
        let edge = try #require((try path(ellipse)["edges"] as? [[String: Any]])?.first)
        #expect(edge["type"] as? String == "ellipse" && edge["ratio"] as? Double == 0.25)
        #expect(
            near(numbers(edge["center"]), [5, 0, 0]) && near(numbers(edge["majorAxis"]), [4, 0, 0]))
        let ellipseBox = try #require(ellipse["bounds"] as? [String: Any])
        #expect(near(numbers(ellipseBox["min"]), [1, -1, 0]), "\(ellipseBox)")
        #expect(near(numbers(ellipseBox["max"]), [9, 1, 0]), "\(ellipseBox)")

        let spline = try record("spline")
        let splineEdge = try #require((try path(spline)["edges"] as? [[String: Any]])?.first)
        #expect(splineEdge["type"] as? String == "spline" && splineEdge["degree"] as? Int == 3)
        #expect(numbers(splineEdge["knots"]) == [0, 0, 0, 0, 1, 1, 1, 1])
        #expect((splineEdge["controlPoints"] as? [Any])?.count == 4)
        let splineBox = try #require(spline["bounds"] as? [String: Any])
        #expect(near(numbers(splineBox["min"]), [0, 0, 0], tol: 5e-3), "\(splineBox)")
        #expect(near(numbers(splineBox["max"]), [10, 3, 0], tol: 5e-3), "\(splineBox)")
    }

    @Test("a dimension that came out of a block names its reference and block")
    func dimensionInABlock() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.blocks = [
            (0, "BLOCK"), (8, "0"), (2, "FASTENER"), (70, "0"), (10, "0"), (20, "0"), (30, "0"),
            (3, "FASTENER"),
            (0, "DIMENSION"), (5, "B7"), (8, "0"), (70, "1"), (42, "-1"), (11, "5"), (21, "-2"),
            (31, "0"), (10, "0"), (20, "-2"), (30, "0"), (13, "0"), (23, "0"), (33, "0"),
            (14, "10"), (24, "0"), (34, "0"),
            (0, "ENDBLK"), (8, "0"),
        ]
        f.add(
            nil, "INSERT", layer: "BLOCKS",
            [(5, "8E"), (2, "FASTENER"), (10, "0"), (20, "50"), (30, "0")])
        let r = try json(
            await call("list_drawing_dimensions", ["inputPath": .string(try f.write(to: dir))]))
        let record = try #require((r["dimensions"] as? [[String: Any]])?.first)
        #expect(
            record["via"] as? [String] == ["8E"] && record["blocks"] as? [String] == ["FASTENER"])
        #expect(record["handle"] as? String == "B7", "its own handle, inside the block")
        #expect(record["valueFromPoints"] as? Double == 10, "a translation keeps the length")
    }

    @Test("a hatch's island is not its external boundary, whichever way the path is written")
    func hatchIslands() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Three paths: an external polyline (flags 3), a polyline island (flags 2) and an edge
        // island (flags 0, no external bit).
        f.add(
            "ring", "HATCH", layer: "H",
            [
                (2, "X"), (70, "0"), (91, "3"),
                (92, "3"), (72, "0"), (73, "1"), (93, "3"), (10, "0"), (20, "0"), (10, "10"),
                (20, "0"), (10, "10"), (20, "10"), (97, "0"),
                (92, "2"), (72, "0"), (73, "1"), (93, "3"), (10, "2"), (20, "2"), (10, "4"),
                (20, "2"), (10, "4"), (20, "4"), (97, "0"),
                (92, "0"), (93, "2"), (72, "1"), (10, "6"), (20, "6"), (11, "8"), (21, "6"),
                (72, "1"), (10, "8"), (20, "6"), (11, "8"), (21, "8"), (97, "0"),
            ])
        let all = try await entities([:], try f.write(to: dir)).all
        let hatch = try #require(all.first { $0["id"] as? String == f.id("ring") })
        let paths = try #require(hatch["boundaryPaths"] as? [[String: Any]])
        #expect(paths.map { $0["external"] as? Bool } == [true, false, false], "\(paths)")
        #expect(paths.map { $0["kind"] as? String } == ["polyline", "polyline", "edges"])
    }

    @Test("a leader lists its path and arrowhead, and is measured along its segments")
    func leaderEntity() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let leaders = try await entities(["types": ["leader"]], path)
        #expect(leaders.ids == [fixture.id("leader")], "\(leaders.ids)")
        let record = try #require(leaders.all.first)
        #expect(record["layer"] as? String == "NOTES")
        let vertices = (record["vertices"] as? [Any])?.map { numbers($0) }
        #expect(
            vertices?.count == 2 && near(vertices?[0], [5, 40, 0])
                && near(vertices?[1], [50, 25, 0]))
        #expect(record["arrowhead"] as? Bool == true && record["splinePath"] as? Bool == false)
        let box = try #require(record["bounds"] as? [String: Any])
        #expect(near(numbers(box["min"]), [5, 25, 0]) && near(numbers(box["max"]), [50, 40, 0]))

        // The point (50, 0) is nearest the leader's end at (50, 25).
        let r = try json(
            await measure(path, "distance", a: .string(fixture.id("leader")), b: [50, 0]))
        #expect(abs((r["value"] as? Double ?? 0) - 25) < 1e-9, "\(String(describing: r["value"]))")
        #expect((r["notes"] as? [String])?.isEmpty == true)
    }

    @Test(
        "a spline leader is measured along its vertices and says so; a leader names its annotation")
    func splineLeader() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "curved", "LEADER", layer: "0",
            [
                (71, "0"), (72, "1"), (340, "AB"), (3, "Standard"), (10, "0"), (20, "0"), (30, "0"),
                (10, "10"), (20, "0"), (30, "0"),
            ])
        let path = try f.write(to: dir)
        let record = try #require(try await entities([:], path).all.first)
        #expect(record["arrowhead"] as? Bool == false && record["splinePath"] as? Bool == true)
        #expect(record["annotationHandle"] as? String == "AB")
        #expect(record["styleName"] as? String == "Standard")
        let r = try json(await measure(path, "distance", a: .string(f.id("curved")), b: [5, 7]))
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline leader") }, "\(notes)")
    }

    @Test("a hatch is refused as a measure end, with where to look instead")
    func hatchIsNotMeasurable() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let r = await measure(
            try fixture.write(to: dir), "distance", a: .string(fixture.id("hatch")), b: [0, 0])
        #expect(r.isError && r.text.contains("hatch"), "\(r.text)")
        #expect(r.text.contains("boundary"), "\(r.text)")
    }
}
