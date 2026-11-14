// The drawing read tools through OCCTSwiftIO's DrawingLoader (#271): DXF, DWG and JWW read from
// their bytes, block expansion and paper space as options every tool takes, the handle and
// locator of every entity, and hatches and leaders as entities. The fixture and helpers are the
// ones in DrawingReadToolsTests.swift.

import CryptoKit
import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

extension DrawingReadToolsTests {

    /// Where `plate.dxf` and `plate.dwg` are.
    static var plateDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Drawing")
    }

    /// The plate as a JWW, written into `dir`.
    func plateJWW(in dir: URL) throws -> String {
        let url = dir.appendingPathComponent("plate.jww")
        try JWWFixture.plate().write(to: url)
        return url.path
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
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try json(await call("read_drawing", ["inputPath": .string(try plateJWW(in: dir))]))
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
            Self.plateDirectory.appendingPathComponent("plate.dwg").path, try plateJWW(in: dir),
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
            expanded["options"] as? [String: Bool] == [
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
            flat["options"] as? [String: Bool] == ["expandBlocks": false, "skipPaperSpace": false])

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
            modelOnly["options"] as? [String: Bool] == [
                "expandBlocks": true, "skipPaperSpace": true,
            ])
        let listed = try json(
            await call(
                "list_drawing_entities", ["inputPath": .string(path), "skipPaperSpace": true]))
        #expect((listed["entities"] as? [[String: Any]])?.count == 1)
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
