// The drawing read tools (#260): read_drawing, list_drawing_entities, list_drawing_dimensions and
// measure_drawing, against a synthetic DXF shaped like the Drawings Toolbox's T-slot example: an
// outline, a slot between two named lines, holes, a bulged polyline, an ellipse, text, seven
// dimensions of six kinds, a spline, and records the reader skips (block inserts, a hatch).

import CryptoKit
import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

/// Builds an ASCII DXF and remembers the id each named modelled entity will have.
struct DrawingFixture {
    var insUnits: Int? = 4
    var lineEnding = "\n"
    private var records: [(name: String?, modelled: Bool, groups: [(Int, String)])] = []

    mutating func add(_ name: String?, _ type: String, layer: String, _ groups: [(Int, String)]) {
        let modelled = [
            "LINE", "CIRCLE", "ARC", "ELLIPSE", "POINT", "TEXT", "MTEXT", "LWPOLYLINE", "POLYLINE",
            "DIMENSION", "SPLINE",
        ].contains(type)
        records.append((name, modelled, [(0, type), (8, layer)] + groups))
    }

    /// The id `list_drawing_entities` gives the entity added as `name`.
    func id(_ name: String) -> String {
        var index = 0
        for record in records {
            if record.name == name { return "e\(index)" }
            if record.modelled { index += 1 }
        }
        preconditionFailure("no entity named \(name)")
    }

    func text() -> String {
        var groups: [(Int, String)] = [
            (0, "SECTION"), (2, "HEADER"), (9, "$ACADVER"), (1, "AC1027"),
        ]
        if let insUnits { groups += [(9, "$INSUNITS"), (70, "\(insUnits)")] }
        groups += [(9, "$EXTMIN"), (10, "0"), (20, "0"), (30, "0")]
        groups += [(9, "$EXTMAX"), (10, "100"), (20, "50"), (30, "0")]
        groups += [(0, "ENDSEC"), (0, "SECTION"), (2, "ENTITIES")]
        for record in records { groups += record.groups }
        groups += [(0, "ENDSEC"), (0, "EOF")]
        return groups.map { "\($0.0)\(lineEnding)\($0.1)\(lineEnding)" }.joined()
    }

    func write(to directory: URL, name: String = "tslot.dxf") throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(text().utf8).write(to: url)
        return url.path
    }

    /// The group codes of a `SPLINE` record: flags, degree, counts, knots, weights, points.
    static func splineGroups(
        degree: Int, flags: Int = 8, knots: [Double] = [], weights: [Double] = [],
        control: [(Double, Double)] = [], fit: [(Double, Double)] = []
    ) -> [(Int, String)] {
        var g: [(Int, String)] = [
            (70, "\(flags)"), (71, "\(degree)"), (72, "\(knots.count)"),
            (73, "\(control.count)"), (74, "\(fit.count)"),
        ]
        g += knots.map { (40, "\($0)") }
        g += weights.map { (41, "\($0)") }
        for p in control { g += [(10, "\(p.0)"), (20, "\(p.1)"), (30, "0")] }
        for p in fit { g += [(11, "\(p.0)"), (21, "\(p.1)"), (31, "0")] }
        return g
    }

    /// The T-slot sheet.
    ///
    /// Indices below are those of the modelled entities, in order.
    static func tSlot(insUnits: Int? = 4) -> DrawingFixture {
        var f = DrawingFixture()
        f.insUnits = insUnits
        func line(_ name: String, _ layer: String, _ a: (Double, Double), _ b: (Double, Double)) {
            f.add(
                name, "LINE", layer: layer,
                [
                    (10, "\(a.0)"), (20, "\(a.1)"), (30, "0"), (11, "\(b.0)"), (21, "\(b.1)"),
                    (31, "0"),
                ])
        }
        line("bottom", "OUTLINE", (0, 0), (100, 0))
        line("right", "OUTLINE", (100, 0), (100, 50))
        line("top", "OUTLINE", (100, 50), (0, 50))
        line("left", "OUTLINE", (0, 50), (0, 0))
        // A block insert between modelled entities: it must not shift any id.
        f.add(nil, "INSERT", layer: "BLOCKS", [(2, "FASTENER"), (10, "10"), (20, "10")])
        line("slotLeft", "SLOT", (46, 0), (46, 20))
        line("slotRight", "SLOT", (54, 0), (54, 20))
        f.add(
            "hole", "CIRCLE", layer: "HOLES",
            [(10, "20"), (20, "25"), (30, "0"), (40, "5")])
        f.add(
            "arc", "ARC", layer: "HOLES",
            [(10, "80"), (20, "25"), (30, "0"), (40, "6"), (50, "20"), (51, "70")])
        f.add(
            "polyline", "LWPOLYLINE", layer: "OUTLINE",
            [
                (90, "3"), (70, "0"), (10, "10"), (20, "10"), (10, "30"), (20, "10"), (42, "1"),
                (10, "30"), (20, "20"),
            ])
        f.add(
            "note", "TEXT", layer: "NOTES",
            [(10, "5"), (20, "45"), (30, "0"), (40, "2.5"), (1, "T-SLOT 8"), (50, "0")])
        f.add("datum", "POINT", layer: "NOTES", [(10, "50"), (20, "25"), (30, "0")])
        f.add(
            "ellipse", "ELLIPSE", layer: "HOLES",
            [
                (10, "50"), (20, "35"), (30, "0"), (11, "5"), (21, "0"), (31, "0"), (40, "0.5"),
                (41, "0"), (42, "6.283185307179586"),
            ])
        func dim(
            _ name: String, type: Int, value: Double, text: String? = nil, textAt: (Double, Double),
            def: (Double, Double), p13: (Double, Double)? = nil, p14: (Double, Double)? = nil,
            p15: (Double, Double)? = nil, p16: (Double, Double)? = nil
        ) {
            var g: [(Int, String)] = [
                (70, "\(type)"), (42, "\(value)"), (11, "\(textAt.0)"), (21, "\(textAt.1)"),
                (31, "0"), (10, "\(def.0)"), (20, "\(def.1)"), (30, "0"),
            ]
            if let text { g.append((1, text)) }
            for (base, p) in [(13, p13), (14, p14), (15, p15), (16, p16)] {
                if let p { g += [(base, "\(p.0)"), (base + 10, "\(p.1)"), (base + 20, "0")] }
            }
            f.add(name, "DIMENSION", layer: "DIMS", g)
        }
        dim(
            "dimWidth", type: 0, value: 100, textAt: (50, -10), def: (0, -10), p13: (0, 0),
            p14: (100, 0))
        dim(
            "dimHeight", type: 0, value: 50, textAt: (110, 25), def: (110, 0), p13: (100, 0),
            p14: (100, 50))
        dim(
            "dimSlot", type: 1, value: 8, text: "8 H7", textAt: (50, -5), def: (46, -5),
            p13: (46, 0), p14: (54, 0))
        dim("dimRadius", type: 4, value: 5, textAt: (22, 27), def: (20, 25), p15: (25, 25))
        dim("dimDiameter", type: 3, value: 12, textAt: (80, 33), def: (74, 25), p15: (86, 25))
        dim(
            "dimAngle", type: 2, value: 90, textAt: (90, 40), def: (80, 25), p13: (80, 25),
            p14: (86, 25), p15: (80, 25), p16: (84, 29))
        dim("dimOrdinate", type: 6, value: 12.5, textAt: (12, 60), def: (10, 60), p13: (12.5, 10))
        // An arc that runs counter-clockwise through 0 degrees: its sweep wraps past 360.
        f.add(
            "wrapArc", "ARC", layer: "HOLES",
            [(10, "60"), (20, "25"), (30, "0"), (40, "3"), (50, "270"), (51, "90")])
        f.add(nil, "HATCH", layer: "HATCH", [(2, "SOLID")])
        // A quadratic Bezier-form spline: it peaks at (20, 40), the midpoint of its curve.
        f.add(
            "curve", "SPLINE", layer: "CURVES",
            splineGroups(
                degree: 2, knots: [0, 0, 0, 1, 1, 1], control: [(10, 35), (20, 45), (30, 35)]))
        f.add(nil, "INSERT", layer: "BLOCKS", [(2, "FASTENER"), (10, "70"), (20, "10")])
        return f
    }
}

@Suite("Drawing read tools", .serialized)
struct DrawingReadToolsTests {

    func makeDirectory() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-drawing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func call(_ name: String, _ arguments: [String: Value]) async -> (text: String, isError: Bool) {
        let result = await dispatch(callName: name, arguments: arguments)
        var text = ""
        if case .text(let t, _, _) = result.content.first { text = t }
        return (text, result.isError == true)
    }

    func json(_ call: (text: String, isError: Bool)) throws -> [String: Any] {
        try #require(!call.isError, "\(call.text)")
        return try #require(
            try JSONSerialization.jsonObject(with: Data(call.text.utf8)) as? [String: Any],
            "not a JSON object: \(call.text)")
    }

    func numbers(_ any: Any?) -> [Double]? {
        (any as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue }
    }

    func near(_ a: [Double]?, _ b: [Double], tol: Double = 1e-9) -> Bool {
        guard let a, a.count == b.count else { return false }
        return zip(a, b).allSatisfy { abs($0 - $1) <= tol }
    }

    // ── read_drawing ────────────────────────────────────────────────────

    @Test("read_drawing summarises counts, layers, units, extents, source and what was skipped")
    func readDrawingSummary() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)

        let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(r["entityCount"] as? Int == 21)
        let byType = try #require(r["byType"] as? [String: Int])
        #expect(
            byType == [
                "line": 6, "circle": 1, "arc": 2, "polyline": 1, "text": 1, "point": 1,
                "ellipse": 1, "dimension": 7, "spline": 1,
            ])

        let layers = try #require(r["layers"] as? [[String: Any]])
        #expect(
            layers.compactMap { $0["name"] as? String } == [
                "CURVES", "DIMS", "HOLES", "NOTES", "OUTLINE", "SLOT",
            ])
        let dims = try #require(layers.first { $0["name"] as? String == "DIMS" })
        #expect(dims["total"] as? Int == 7)

        let units = try #require(r["units"] as? [String: Any])
        #expect(units["insUnits"] as? Int == 4)
        #expect(units["name"] as? String == "millimetres")
        #expect(units["mmPerUnit"] as? Double == 1)

        let extents = try #require(r["extents"] as? [String: Any])
        let declared = try #require(extents["declared"] as? [String: Any])
        #expect(
            near(numbers(declared["min"]), [0, 0, 0])
                && near(numbers(declared["max"]), [100, 50, 0]))
        let computed = try #require(extents["computed"] as? [String: Any])
        // The dimensions reach past the declared box: -10 below, 110 to the right, 60 above.
        #expect(
            near(numbers(computed["min"]), [0, -10, 0]), "\(String(describing: computed["min"]))")
        #expect(
            near(numbers(computed["max"]), [110, 60, 0]), "\(String(describing: computed["max"]))")

        let skipped = try #require(r["skipped"] as? [String: Any])
        #expect(skipped["total"] as? Int == 3)
        #expect(skipped["byType"] as? [String: Int] == ["INSERT": 2, "HATCH": 1])
        let skippedByLayer = try #require(skipped["byLayer"] as? [String: [String: Int]])
        #expect(skippedByLayer["BLOCKS"] == ["INSERT": 2])
        #expect(skippedByLayer["HATCH"] == ["HATCH": 1])
        let warnings = try #require(r["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("2 block insert") }, "\(warnings)")

        let source = try #require(r["source"] as? [String: Any])
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(source["sha256"] as? String == expected)
        #expect(source["bytes"] as? Int == bytes.count)
        #expect(source["format"] as? String == "dxf")
        #expect(source["dxfVersion"] as? String == "AC1027")
        #expect(source["fileName"] as? String == "tslot.dxf")
    }

    @Test("a SPLINE is an entity and is not also reported as skipped (SwiftDXF 0.3.0)")
    func splineIsNotSkipped() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try json(
            await call(
                "read_drawing", ["inputPath": .string(try DrawingFixture.tSlot().write(to: dir))]))
        let skipped = try #require(r["skipped"] as? [String: Any])
        let byType = try #require(skipped["byType"] as? [String: Int])
        #expect(byType["SPLINE"] == nil, "a modelled SPLINE was counted as skipped too: \(byType)")
        let byLayer = try #require(skipped["byLayer"] as? [String: [String: Int]])
        #expect(byLayer["CURVES"] == nil, "\(byLayer)")
        let warnings = try #require(r["warnings"] as? [String])
        #expect(!warnings.contains { $0.contains("no mapping") }, "\(warnings)")
    }

    @Test("the source record names the SwiftDXF release line this build is pinned to")
    func readerVersion() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try json(
            await call(
                "read_drawing", ["inputPath": .string(try DrawingFixture.tSlot().write(to: dir))]))
        let source = try #require(r["source"] as? [String: Any])
        #expect(source["readerVersion"] as? String == DrawingFile.readerVersion)

        // The tools that take and return ids carry it too, since it is what tells a caller the ids
        // may no longer mean what they did.
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let input: [String: Value] = ["inputPath": .string(path)]
        let entities = try json(await call("list_drawing_entities", input))
        let dimensions = try json(await call("list_drawing_dimensions", input))
        let measured = try json(
            await measure(
                path, "distance", a: .string(fixture.id("slotLeft")),
                b: .string(fixture.id("slotRight"))))
        let results: [(String, [String: Any])] = [
            ("list_drawing_entities", entities), ("list_drawing_dimensions", dimensions),
            ("measure_drawing", measured),
        ]
        for (tool, result) in results {
            let carried = result["source"] as? [String: Any]
            #expect(carried?["readerVersion"] as? String == DrawingFile.readerVersion, "\(tool)")
        }

        // The constant cannot drift from what Package.resolved pins: a bump that forgets it fails.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let resolved = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(resolved["pins"] as? [[String: Any]])
        let pin = try #require(pins.first { $0["identity"] as? String == "swiftdxf" })
        let state = try #require(pin["state"] as? [String: Any])
        let resolvedVersion = try #require(state["version"] as? String)
        let line = DrawingFile.readerVersion
        #expect(
            resolvedVersion.hasPrefix(line + "."),
            "Package.resolved pins SwiftDXF \(resolvedVersion), but the reader line is \(line)")
    }

    @Test("a CRLF file reads the same as an LF one")
    func crlf() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fixture = DrawingFixture.tSlot()
        fixture.lineEnding = "\r\n"
        let r = try json(
            await call("read_drawing", ["inputPath": .string(try fixture.write(to: dir))]))
        #expect(r["entityCount"] as? Int == 21)
        let skipped = try #require(r["skipped"] as? [String: Any])
        #expect(skipped["byType"] as? [String: Int] == ["INSERT": 2, "HATCH": 1])
        let layers = try #require(r["layers"] as? [[String: Any]])
        #expect(
            layers.compactMap { $0["name"] as? String }.contains("OUTLINE"), "layer names kept a CR"
        )
    }

    @Test("units: inches convert to millimetres, a unitless drawing gives none and says so")
    func units() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inches = try json(
            await call(
                "read_drawing",
                [
                    "inputPath": .string(
                        try DrawingFixture.tSlot(insUnits: 1).write(to: dir, name: "in.dxf"))
                ]))
        let inchUnits = try #require(inches["units"] as? [String: Any])
        #expect(
            inchUnits["name"] as? String == "inches" && inchUnits["mmPerUnit"] as? Double == 25.4)

        let unitless = try json(
            await call(
                "read_drawing",
                [
                    "inputPath": .string(
                        try DrawingFixture.tSlot(insUnits: nil).write(to: dir, name: "none.dxf"))
                ]))
        let noUnits = try #require(unitless["units"] as? [String: Any])
        #expect(noUnits["name"] as? String == "undeclared" && noUnits["mmPerUnit"] == nil)
        let warnings = try #require(unitless["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("no usable units") }, "\(warnings)")

        let zero = try json(
            await call(
                "read_drawing",
                [
                    "inputPath": .string(
                        try DrawingFixture.tSlot(insUnits: 0).write(to: dir, name: "zero.dxf"))
                ]))
        let zeroUnits = try #require(zero["units"] as? [String: Any])
        #expect(zeroUnits["name"] as? String == "unitless" && zeroUnits["mmPerUnit"] == nil)
    }

    @Test("files that cannot be read say why, naming the format")
    func unreadable() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = await call("read_drawing", ["inputPath": .string(dir.path + "/nope.dxf")])
        #expect(missing.isError && missing.text.contains("not found"), "\(missing.text)")

        for (name, needle) in [
            ("plate.dwg", "DWGLoader"), ("plate.jww", "JWW"),
            ("plate.pdf", "supported formats: dxf"),
        ] {
            let path = dir.appendingPathComponent(name).path
            try Data("x".utf8).write(to: URL(fileURLWithPath: path))
            let r = await call("read_drawing", ["inputPath": .string(path)])
            #expect(r.isError && r.text.contains(needle), "\(name): \(r.text)")
        }

        let binary = dir.appendingPathComponent("bin.dxf").path
        try Data("AutoCAD Binary DXF\r\n\u{1a}\u{0}rest".utf8).write(
            to: URL(fileURLWithPath: binary))
        let b = await call("read_drawing", ["inputPath": .string(binary)])
        #expect(b.isError && b.text.contains("binary DXF"), "\(b.text)")

        let notDXF = dir.appendingPathComponent("junk.dxf").path
        try Data("hello world\nthis is not a drawing\n".utf8).write(
            to: URL(fileURLWithPath: notDXF))
        let n = await call("read_drawing", ["inputPath": .string(notDXF)])
        #expect(n.isError && n.text.contains("not a DXF"), "\(n.text)")

        let empty = dir.appendingPathComponent("empty.dxf").path
        try Data().write(to: URL(fileURLWithPath: empty))
        let e = await call("read_drawing", ["inputPath": .string(empty)])
        #expect(e.isError && e.text.contains("empty"), "\(e.text)")
    }

    @Test("a changed file is read again, not answered from the cache")
    func changedFileIsReread() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await DrawingCache.shared.clear()
        let path = try DrawingFixture.tSlot().write(to: dir, name: "changing.dxf")
        let before = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(before["entityCount"] as? Int == 21)

        var smaller = DrawingFixture()
        smaller.add(
            "only", "LINE", layer: "0",
            [(10, "0"), (20, "0"), (30, "0"), (11, "1"), (21, "1"), (31, "0")])
        _ = try smaller.write(to: dir, name: "changing.dxf")
        let after = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(after["entityCount"] as? Int == 1, "served the old file")
        let sourceBefore = try #require(before["source"] as? [String: Any])
        let sourceAfter = try #require(after["source"] as? [String: Any])
        #expect(sourceBefore["sha256"] as? String != sourceAfter["sha256"] as? String)
    }

    // ── list_drawing_entities ───────────────────────────────────────────

    func entities(_ arguments: [String: Value], _ path: String) async throws -> (
        total: Int, ids: [String], all: [[String: Any]], raw: [String: Any]
    ) {
        var args = arguments
        args["inputPath"] = .string(path)
        let r = try json(await call("list_drawing_entities", args))
        let list = try #require(r["entities"] as? [[String: Any]])
        return (r["total"] as? Int ?? -1, list.compactMap { $0["id"] as? String }, list, r)
    }

    @Test("filters by type, by layer and by a rectangle on the sheet")
    func entityFilters() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)

        let lines = try await entities(["types": ["line"]], path)
        #expect(lines.total == 6)
        let slot = try await entities(["layers": ["SLOT"]], path)
        #expect(slot.ids == [fixture.id("slotLeft"), fixture.id("slotRight")])
        let both = try await entities(
            ["types": ["line", "circle"], "layers": ["HOLES", "SLOT"]], path)
        #expect(both.ids == [fixture.id("slotLeft"), fixture.id("slotRight"), fixture.id("hole")])

        // Overlap with a window over the slot: the two slot walls and nothing else.
        let window = try await entities(["rect": [40, 5, 60, 15]], path)
        #expect(window.ids == [fixture.id("slotLeft"), fixture.id("slotRight")], "\(window.ids)")
        // `within` keeps the walls (46 and 54, 0 to 20) and drops the outline that only crosses it.
        let crossing = try await entities(
            ["rect": [40, -1, 60, 21], "rectMode": "intersects"], path)
        #expect(crossing.ids.contains(fixture.id("bottom")), "\(crossing.ids)")
        let inside = try await entities(["rect": [40, -1, 60, 21], "rectMode": "within"], path)
        #expect(inside.ids == [fixture.id("slotLeft"), fixture.id("slotRight")], "\(inside.ids)")
    }

    @Test("paging reports the total, what it returned and whether it stopped short")
    func paging() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try DrawingFixture.tSlot().write(to: dir)
        let page = try await entities(["limit": 3, "offset": 2], path)
        #expect(page.total == 21 && page.ids == ["e2", "e3", "e4"])
        #expect(page.raw["returned"] as? Int == 3 && page.raw["truncated"] as? Bool == true)
        let last = try await entities(["limit": 3, "offset": 18], path)
        #expect(last.ids == ["e18", "e19", "e20"] && last.raw["truncated"] as? Bool == false)
        let beyond = try await entities(["offset": 100], path)
        #expect(beyond.ids.isEmpty && beyond.total == 21)
    }

    @Test("each entity carries its geometry as numbers, in drawing units")
    func entityGeometry() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let all = try await entities([:], try fixture.write(to: dir))
        func entity(_ name: String) throws -> [String: Any] {
            try #require(all.all.first { $0["id"] as? String == fixture.id(name) }, "no \(name)")
        }

        let wall = try entity("slotLeft")
        #expect(wall["type"] as? String == "line" && wall["layer"] as? String == "SLOT")
        #expect(
            near(numbers(wall["start"]), [46, 0, 0]) && near(numbers(wall["end"]), [46, 20, 0]))
        #expect(wall["length"] as? Double == 20)

        let hole = try entity("hole")
        #expect(near(numbers(hole["center"]), [20, 25, 0]) && hole["radius"] as? Double == 5)

        // 20 to 70 degrees on r = 6 about (80, 25). The centre is outside this arc's box, so a
        // box seeded from the centre would be wrong.
        let arc = try entity("arc")
        let rad = Double.pi / 180
        let arcStart = [80 + 6 * cos(20 * rad), 25 + 6 * sin(20 * rad), 0]
        let arcEnd = [80 + 6 * cos(70 * rad), 25 + 6 * sin(70 * rad), 0]
        #expect(abs((arc["sweepDeg"] as? Double ?? 0) - 50) < 1e-9)
        #expect(abs((arc["length"] as? Double ?? 0) - 6 * 50 * rad) < 1e-9)
        #expect(near(numbers(arc["start"]), arcStart, tol: 1e-9))
        #expect(near(numbers(arc["end"]), arcEnd, tol: 1e-9))
        let arcBounds = try #require(arc["bounds"] as? [String: Any])
        #expect(
            near(numbers(arcBounds["min"]), [arcEnd[0], arcStart[1], 0], tol: 1e-9), "\(arcBounds)")
        #expect(
            near(numbers(arcBounds["max"]), [arcStart[0], arcEnd[1], 0], tol: 1e-9), "\(arcBounds)")

        // 270 to 90 degrees is a half turn through 0: sweep 180, and it reaches x = 63 at 0 degrees.
        let wrap = try entity("wrapArc")
        #expect(abs((wrap["sweepDeg"] as? Double ?? 0) - 180) < 1e-9, "\(wrap)")
        #expect(abs((wrap["length"] as? Double ?? 0) - 3 * Double.pi) < 1e-9)
        #expect(near(numbers(wrap["start"]), [60, 22, 0], tol: 1e-9))
        #expect(near(numbers(wrap["end"]), [60, 28, 0], tol: 1e-9))
        let wrapBounds = try #require(wrap["bounds"] as? [String: Any])
        #expect(near(numbers(wrapBounds["min"]), [60, 22, 0], tol: 1e-9), "\(wrapBounds)")
        #expect(near(numbers(wrapBounds["max"]), [63, 28, 0], tol: 1e-9), "\(wrapBounds)")

        let poly = try entity("polyline")
        #expect(poly["closed"] as? Bool == false)
        #expect((poly["vertices"] as? [Any])?.count == 3)
        #expect(numbers(poly["bulges"]) == [0, 1, 0])
        #expect(abs((poly["length"] as? Double ?? 0) - (20 + 5 * Double.pi)) < 1e-9)
        // The semicircle from (30,10) to (30,20) bulges out to x = 35.
        let polyBounds = try #require(poly["bounds"] as? [String: Any])
        #expect(abs((numbers(polyBounds["max"])?[0] ?? 0) - 35) < 1e-9, "\(polyBounds)")

        // Every entity kind has bounds; a polyline's include its vertices, not just its arcs.
        func bounds(_ entity: [String: Any]) throws -> ([Double], [Double]) {
            let box = try #require(entity["bounds"] as? [String: Any], "\(entity)")
            return (try #require(numbers(box["min"])), try #require(numbers(box["max"])))
        }
        let circleBox = try bounds(try entity("hole"))
        #expect(near(circleBox.0, [15, 20, 0]) && near(circleBox.1, [25, 30, 0]), "\(circleBox)")
        let polyBox = try bounds(poly)
        #expect(
            near(polyBox.0, [10, 10, 0]) && near(polyBox.1, [35, 20, 0], tol: 1e-9), "\(polyBox)")
        let pointBox = try bounds(try entity("datum"))
        #expect(near(pointBox.0, [50, 25, 0]) && near(pointBox.1, [50, 25, 0]))
        let textBox = try bounds(try entity("note"))
        #expect(near(textBox.0, [5, 45, 0]) && near(textBox.1, [5, 45, 0]), "\(textBox)")

        let note = try entity("note")
        #expect(note["text"] as? String == "T-SLOT 8" && note["height"] as? Double == 2.5)
        #expect(near(numbers(try entity("datum")["at"]), [50, 25, 0]))
        let ellipse = try entity("ellipse")
        #expect(
            ellipse["ratio"] as? Double == 0.5 && near(numbers(ellipse["majorAxis"]), [5, 0, 0]))
        let ellipseBounds = try #require(ellipse["bounds"] as? [String: Any])
        #expect(near(numbers(ellipseBounds["min"]), [45, 32.5, 0]), "\(ellipseBounds)")
        #expect(near(numbers(ellipseBounds["max"]), [55, 37.5, 0]), "\(ellipseBounds)")

        let dimension = try entity("dimSlot")
        let record = try #require(dimension["dimension"] as? [String: Any])
        #expect(record["kind"] as? String == "aligned" && record["value"] as? Double == 8)
    }

    @Test("bad filters are refused with the reason")
    func entityFilterErrors() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = Value.string(try DrawingFixture.tSlot().write(to: dir))
        let cases: [([String: Value], String)] = [
            (["types": ["hatch"]], "Unknown entity type"),
            (["rect": [1, 2, 3]], "`rect` must be"),
            (["rect": [5, 0, 1, 10]], "`rect` must be"),
            (["rect": "nope"], "`rect` must be"),
            (["rect": [1, 2, "x", 4]], "`rect` must be"),
            (["rect": [0, 0, 1, 1], "rectMode": "touching"], "rectMode"),
        ]
        for (extra, needle) in cases {
            var args: [String: Value] = ["inputPath": path]
            args.merge(extra) { $1 }
            let r = await call("list_drawing_entities", args)
            #expect(r.isError && r.text.contains(needle), "\(extra): \(r.text)")
        }
        let none = await call("list_drawing_entities", [:])
        #expect(none.isError && none.text.contains("requires `inputPath`"))
    }

    // ── list_drawing_dimensions ─────────────────────────────────────────

    @Test("every dimension comes back with its kind, value, text, points and layer")
    func dimensions() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let r = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        #expect(
            r["total"] as? Int == 7 && r["returned"] as? Int == 7
                && r["truncated"] as? Bool == false)
        let list = try #require(r["dimensions"] as? [[String: Any]])
        #expect(
            list.compactMap { $0["kind"] as? String }
                == ["linear", "linear", "aligned", "radius", "diameter", "angular", "ordinate"])
        #expect(list.compactMap { $0["value"] as? Double } == [100, 50, 8, 5, 12, 90, 12.5])
        #expect(
            list.compactMap { $0["valueMm"] as? Double } == [100, 50, 8, 5, 12, 12.5],
            "angular has no mm")
        #expect(list.allSatisfy { $0["layer"] as? String == "DIMS" })
        // Aligned, radius and diameter dimensions also report the length between their own points.
        #expect(list.compactMap { $0["valueFromPoints"] as? Double } == [8, 5, 12])
        #expect(list.compactMap { $0["valueFromPointsMm"] as? Double } == [8, 5, 12])

        let slot = try #require(list.first { $0["id"] as? String == fixture.id("dimSlot") })
        #expect(slot["text"] as? String == "8 H7")
        #expect(
            list.filter { $0["text"] != nil }.count == 1,
            "only the slot dimension overrides its text")
        #expect(near(numbers(slot["textPosition"]), [50, -5, 0]))
        let points = try #require(slot["definitionPoints"] as? [[String: Any]])
        #expect(points.compactMap { $0["group"] as? Int } == [10, 13, 14])
        #expect(
            points.compactMap { $0["role"] as? String }
                == ["dimensionLine", "extensionLine1Origin", "extensionLine2Origin"])
        #expect(
            near(numbers(points[1]["point"]), [46, 0, 0])
                && near(numbers(points[2]["point"]), [54, 0, 0]))

        let radius = try #require(list.first { $0["kind"] as? String == "radius" })
        let radiusPoints = try #require(radius["definitionPoints"] as? [[String: Any]])
        #expect(
            radiusPoints.compactMap { $0["role"] as? String } == ["measuredFrom", "measuredTo"])
        let angular = try #require(list.first { $0["kind"] as? String == "angular" })
        #expect(angular["valueKind"] as? String == "angle" && angular["valueMm"] == nil)
        let angularPoints = try #require(angular["definitionPoints"] as? [[String: Any]])
        #expect(angularPoints.last?["group"] as? Int == 16)
        #expect(angularPoints.last?["role"] as? String == "dimensionArcLocation")
        let ordinate = try #require(list.first { $0["kind"] as? String == "ordinate" })
        #expect(
            (ordinate["definitionPoints"] as? [[String: Any]])?.allSatisfy { $0["role"] == nil }
                == true)
        let units = try #require(r["units"] as? [String: Any])
        #expect(units["mmPerUnit"] as? Double == 1)

        let radial = try json(
            await call(
                "list_drawing_dimensions",
                ["inputPath": .string(path), "kinds": ["radius", "diameter"]]))
        #expect(radial["total"] as? Int == 2)
        let none = try json(
            await call(
                "list_drawing_dimensions", ["inputPath": .string(path), "layers": ["NOPE"]]))
        #expect(none["total"] as? Int == 0)
        let paged = try json(
            await call(
                "list_drawing_dimensions", ["inputPath": .string(path), "limit": 2, "offset": 6]))
        #expect(paged["returned"] as? Int == 1 && paged["truncated"] as? Bool == false)
    }

    @Test("an inch drawing reports dimension values in millimetres too")
    func dimensionsInInches() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try DrawingFixture.tSlot(insUnits: 1).write(to: dir)
        let r = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let list = try #require(r["dimensions"] as? [[String: Any]])
        let width = try #require(list.first)
        #expect(width["value"] as? Double == 100)
        #expect(abs((width["valueMm"] as? Double ?? 0) - 2540) < 1e-9)
    }

    // ── measure_drawing ─────────────────────────────────────────────────

    func measure(
        _ path: String, _ measure: String, a: Value? = nil, b: Value? = nil, vertex: Value? = nil,
        mmPerUnit: Double? = nil
    ) async -> (text: String, isError: Bool) {
        var args: [String: Value] = ["inputPath": .string(path), "measure": .string(measure)]
        if let a { args["a"] = a }
        if let b { args["b"] = b }
        if let vertex { args["vertex"] = vertex }
        if let mmPerUnit { args["mmPerUnit"] = .double(mmPerUnit) }
        return await call("measure_drawing", args)
    }

    @Test("the slot width between two named lines is the gap between them, in mm")
    func slotWidth() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let r = try json(
            await measure(
                path, "distance", a: .string(fixture.id("slotLeft")),
                b: .string(fixture.id("slotRight"))))
        #expect(abs((r["value"] as? Double ?? 0) - 8) < 1e-9)
        #expect(r["unit"] as? String == "drawing units")
        #expect(abs((r["valueMm"] as? Double ?? 0) - 8) < 1e-9)
        let a = try #require(numbers(r["pointOnA"]))
        let b = try #require(numbers(r["pointOnB"]))
        #expect(abs(a[0] - 46) < 1e-9 && abs(b[0] - 54) < 1e-9, "\(a) \(b)")
        let endA = try #require(r["a"] as? [String: Any])
        #expect(
            endA["kind"] as? String == "entity" && endA["id"] as? String == fixture.id("slotLeft"))
        #expect(endA["type"] as? String == "line")
        #expect((r["source"] as? [String: Any])?["fileName"] as? String == "tslot.dxf")

        // The measured width is the stored value of the slot's own dimension.
        let dims = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let slotDim = try #require(
            (dims["dimensions"] as? [[String: Any]])?.first {
                $0["id"] as? String == fixture.id("dimSlot")
            })
        #expect(abs((slotDim["value"] as? Double ?? 0) - (r["value"] as? Double ?? -1)) < 1e-9)
    }

    @Test("distance between entities of different kinds, and between points")
    func distances() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        func value(_ r: (text: String, isError: Bool)) throws -> Double {
            try #require(try json(r)["value"] as? Double)
        }
        // Point to point.
        #expect(abs(try value(await measure(path, "distance", a: [0, 0], b: [3, 4])) - 5) < 1e-9)
        // Point to a line: (50, 10) is 4 from the left slot wall, which runs x = 46, y = 0 to 20.
        let toWall = try value(
            await measure(path, "distance", a: [50, 10], b: .string(fixture.id("slotLeft"))))
        #expect(abs(toWall - 4) < 1e-9)
        // Circle (center (20,25), r 5) to the left outline x = 0: 20 - 5 = 15.
        let circleToLeft = try value(
            await measure(
                path, "distance", a: .string(fixture.id("hole")), b: .string(fixture.id("left"))))
        #expect(abs(circleToLeft - 15) < 1e-9)
        // A polyline is measured along its segments and its arc: the semicircle reaches x = 35.
        let polyToWall = try value(
            await measure(
                path, "distance", a: .string(fixture.id("polyline")),
                b: .string(fixture.id("slotLeft"))))
        #expect(abs(polyToWall - 11) < 1e-6, "\(polyToWall)")
        // Two crossing lines are 0 apart.
        let crossing = try value(
            await measure(
                path, "distance", a: .string(fixture.id("bottom")), b: .string(fixture.id("right")))
        )
        #expect(abs(crossing) < 1e-9)
        // The wrapped arc (270 to 90 through 0, centre (60, 25), r = 3) covers the right half of its
        // circle. (70, 25) is 7 from the point at 0 degrees; (50, 25) is on the uncovered side, so
        // the nearest arc points are its ends, (60, 22) and (60, 28), not the circle's (57, 25).
        let wrapRight = try value(
            await measure(path, "distance", a: [70, 25], b: .string(fixture.id("wrapArc"))))
        #expect(abs(wrapRight - 7) < 1e-9, "\(wrapRight)")
        let wrapLeft = try value(
            await measure(path, "distance", a: [50, 25], b: .string(fixture.id("wrapArc"))))
        #expect(abs(wrapLeft - (100.0 + 9.0).squareRoot()) < 1e-9, "\(wrapLeft)")
        // The 20 to 70 degree arc about (80, 25): a point on its bisector is 4 from it, and one
        // outside its sweep is nearest an end.
        let rad = Double.pi / 180
        let onBisector = [80 + 10 * cos(45 * rad), 25 + 10 * sin(45 * rad)]
        let toBisector = try value(
            await measure(
                path, "distance", a: .array(onBisector.map { .double($0) }),
                b: .string(fixture.id("arc"))))
        #expect(abs(toBisector - 4) < 1e-9, "\(toBisector)")
        let outside = [80 + 10 * cos(135 * rad), 25 + 10 * sin(135 * rad)]
        let end70 = [80 + 6 * cos(70 * rad), 25 + 6 * sin(70 * rad)]
        let toOutside = try value(
            await measure(
                path, "distance", a: .array(outside.map { .double($0) }),
                b: .string(fixture.id("arc"))))
        let expectedOutside =
            ((outside[0] - end70[0]) * (outside[0] - end70[0])
            + (outside[1] - end70[1]) * (outside[1] - end70[1])).squareRoot()
        #expect(abs(toOutside - expectedOutside) < 1e-9, "\(toOutside) vs \(expectedOutside)")
        // A 3-component point works too.
        #expect(
            abs(try value(await measure(path, "distance", a: [0, 0, 0], b: [0, 0, 2])) - 2) < 1e-9)
    }

    @Test("an ellipse end is approximated and the result says so")
    func ellipseDistance() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let r = try json(
            await measure(path, "distance", a: .string(fixture.id("ellipse")), b: [50, 10]))
        // The ellipse's lowest point is (50, 32.5), 22.5 above the point; 48 chords cut that a little.
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - 22.5) < 0.02, "\(value)")
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("48 chords") }, "\(notes)")
    }

    @Test("a tilted ellipse is measured along its tilt, and a partial one only over its sweep")
    func tiltedEllipses() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Major axis (4, 3), so 5 long and tilted; minor 2.5, along (-1.5, 2).
        let common: [(Int, String)] = [
            (10, "0"), (20, "0"), (30, "0"), (11, "4"), (21, "3"), (31, "0"), (40, "0.5"),
        ]
        f.add("full", "ELLIPSE", layer: "0", common + [(41, "0"), (42, "6.283185307179586")])
        f.add("upper", "ELLIPSE", layer: "0", common + [(41, "0"), (42, "3.141592653589793")])
        let path = try f.write(to: dir)
        func distance(_ name: String, to point: [Double]) async throws -> Double {
            let r = try json(
                await measure(
                    path, "distance", a: .string(f.id(name)), b: .array(point.map { .double($0) })))
            return try #require(r["value"] as? Double)
        }
        // On the major axis, 10 from the centre: the vertex (4, 3) is 5 away, whichever way it is tilted.
        #expect(abs(try await distance("full", to: [8, 6]) - 5) < 1e-9)
        #expect(abs(try await distance("upper", to: [8, 6]) - 5) < 1e-9)
        // On the minor axis' far side, 10 from the centre: the full ellipse's vertex (1.5, -2) is 7.5
        // away. The upper half (t = 0 to pi) does not reach that side, so its nearest points are its
        // ends (4, 3) and (-4, -3), both sqrt(125) from (6, -8).
        #expect(abs(try await distance("full", to: [6, -8]) - 7.5) < 1e-9)
        #expect(abs(try await distance("upper", to: [6, -8]) - 125.0.squareRoot()) < 1e-9)
    }

    @Test("millimetres follow the drawing's units; a unitless drawing needs mmPerUnit")
    func millimetres() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let inches = DrawingFixture.tSlot(insUnits: 1)
        let inchPath = try inches.write(to: dir, name: "in.dxf")
        let a = Value.string(inches.id("slotLeft"))
        let b = Value.string(inches.id("slotRight"))
        let inchResult = try json(await measure(inchPath, "distance", a: a, b: b))
        #expect(abs((inchResult["value"] as? Double ?? 0) - 8) < 1e-9)
        #expect(abs((inchResult["valueMm"] as? Double ?? 0) - 203.2) < 1e-9)
        #expect(inchResult["mmPerUnit"] as? Double == 25.4)

        let none = DrawingFixture.tSlot(insUnits: nil)
        let nonePath = try none.write(to: dir, name: "none.dxf")
        let bare = try json(await measure(nonePath, "distance", a: a, b: b))
        #expect(bare["valueMm"] == nil && bare["mmPerUnit"] == nil)
        let notes = try #require(bare["notes"] as? [String])
        #expect(notes.contains { $0.contains("mmPerUnit") }, "\(notes)")
        let supplied = try json(await measure(nonePath, "distance", a: a, b: b, mmPerUnit: 2))
        #expect(abs((supplied["valueMm"] as? Double ?? 0) - 16) < 1e-9)
        // An override of a declared unit is allowed and says it overrode.
        let overridden = try json(await measure(inchPath, "distance", a: a, b: b, mmPerUnit: 1))
        #expect(abs((overridden["valueMm"] as? Double ?? 0) - 8) < 1e-9)
        #expect((overridden["notes"] as? [String])?.contains { $0.contains("overrides") } == true)

        let bad = await measure(nonePath, "distance", a: a, b: b, mmPerUnit: -1)
        #expect(bad.isError && bad.text.contains("`mmPerUnit`"), "\(bad.text)")
    }

    @Test("angle: between two lines, and at a vertex between two points")
    func angles() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let right = try json(
            await measure(
                path, "angle", a: .string(fixture.id("bottom")), b: .string(fixture.id("right"))))
        #expect(
            abs((right["value"] as? Double ?? 0) - 90) < 1e-9
                && right["unit"] as? String == "degrees")
        #expect(right["valueMm"] == nil)

        // `top` runs 100 to 0, against `bottom`'s 0 to 100: 180 between directions, 0 between lines.
        let opposed = try json(
            await measure(
                path, "angle", a: .string(fixture.id("bottom")), b: .string(fixture.id("top"))))
        #expect(abs((opposed["value"] as? Double ?? 0) - 180) < 1e-9)
        #expect(abs(opposed["acuteAngleDeg"] as? Double ?? -1) < 1e-9)

        let vertex = try json(
            await measure(path, "angle", a: [1, 0], b: [0, 1], vertex: [0, 0]))
        #expect(abs((vertex["value"] as? Double ?? 0) - 90) < 1e-9)
        let forty5 = try json(
            await measure(path, "angle", a: [10, 0], b: [10, 10], vertex: [0, 0]))
        #expect(abs((forty5["value"] as? Double ?? 0) - 45) < 1e-9)

        let notLines = await measure(
            path, "angle", a: .string(fixture.id("hole")), b: .string(fixture.id("right")))
        #expect(notLines.isError && notLines.text.contains("two line entities"), "\(notLines.text)")
        let degenerate = await measure(path, "angle", a: [0, 0], b: [1, 1], vertex: [0, 0])
        #expect(
            degenerate.isError && degenerate.text.contains("no direction"), "\(degenerate.text)")
    }

    @Test("radius of a circle or an arc, with the diameter and millimetres")
    func radius() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot(insUnits: 1)
        let path = try fixture.write(to: dir)
        let hole = try json(await measure(path, "radius", a: .string(fixture.id("hole"))))
        #expect(hole["value"] as? Double == 5 && hole["diameter"] as? Double == 10)
        #expect(abs((hole["valueMm"] as? Double ?? 0) - 127) < 1e-9)
        let arc = try json(await measure(path, "radius", a: .string(fixture.id("arc"))))
        #expect(arc["value"] as? Double == 6)
        let line = await measure(path, "radius", a: .string(fixture.id("bottom")))
        #expect(line.isError && line.text.contains("circle or arc"), "\(line.text)")
    }

    @Test("measurement errors name what was wrong")
    func measureErrors() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let cases: [(String, Value?, Value?, String)] = [
            ("distance", nil, [1, 2], "`a` is required"),
            ("distance", .string("slotLeft"), [1, 2], "not an entity id"),
            ("distance", .string("e999"), [1, 2], "out of range"),
            ("distance", [1], [1, 2], "entity id or a point"),
            ("distance", [1, 2, 3, 4], [1, 2], "entity id or a point"),
            ("distance", .string(fixture.id("note")), [1, 2], "text entity"),
            ("distance", .string(fixture.id("dimSlot")), [1, 2], "dimension entity"),
            ("slope", [1, 2], [3, 4], "`measure` must be"),
        ]
        for (measureName, a, b, needle) in cases {
            let r = await measure(path, measureName, a: a, b: b)
            #expect(
                r.isError && r.text.contains(needle),
                "\(measureName) \(String(describing: a)): \(r.text)")
        }
        let missing = await call("measure_drawing", ["inputPath": .string(path)])
        #expect(missing.isError && missing.text.contains("requires"), "\(missing.text)")
    }

    @Test("dimensions without a stored value are measured from their definition points")
    func dimensionsWithoutAStoredValue() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        func dim(_ name: String, type: Int, value: String?, _ points: [(Int, String)]) {
            var g: [(Int, String)] = [(70, "\(type)"), (11, "0"), (21, "0"), (31, "0")]
            if let value { g.append((42, value)) }
            f.add(name, "DIMENSION", layer: "DIMS", g + points)
        }
        // A 3-4-5 triangle between the extension origins: 50 apart.
        dim(
            "aligned", type: 1, value: nil,
            [
                (10, "0"), (20, "-5"), (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "30"),
                (24, "40"), (34, "0"),
            ])
        dim(
            "radius", type: 4, value: nil,
            [(10, "0"), (20, "0"), (30, "0"), (15, "3"), (25, "4"), (35, "0")])
        dim(
            "diameter", type: 3, value: nil,
            [(10, "-3"), (20, "-4"), (30, "0"), (15, "3"), (25, "4"), (35, "0")])
        // The angle of a linear dimension is not modelled, so its length cannot be derived.
        dim(
            "linear", type: 0, value: nil,
            [
                (10, "0"), (20, "-5"), (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "30"),
                (24, "40"), (34, "0"),
            ])
        // Stored 7, but the extension origins are 8 apart: the disagreement is visible.
        dim(
            "stale", type: 1, value: "7",
            [
                (10, "0"), (20, "-5"), (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "8"),
                (24, "0"), (34, "0"),
            ])
        let path = try f.write(to: dir)
        let r = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let list = try #require(r["dimensions"] as? [[String: Any]])
        func record(_ name: String) throws -> [String: Any] {
            try #require(list.first { $0["id"] as? String == f.id(name) }, "no \(name)")
        }
        for name in ["aligned", "radius", "diameter", "linear"] {
            #expect(try record(name)["value"] == nil, "\(name) has no stored value")
        }
        #expect(try record("aligned")["valueFromPoints"] as? Double == 50)
        #expect(try record("radius")["valueFromPoints"] as? Double == 5)
        #expect(try record("diameter")["valueFromPoints"] as? Double == 10)
        #expect(try record("linear")["valueFromPoints"] == nil)
        // Millimetres follow the drawing's units; this drawing declares millimetres.
        #expect(try record("aligned")["valueFromPointsMm"] as? Double == 50)
        let stale = try record("stale")
        #expect(stale["value"] as? Double == 7 && stale["valueFromPoints"] as? Double == 8)
    }

    @Test(
        "an old-style POLYLINE is one entity, and an INSERT's ATTRIB records are counted as SwiftDXF counts them"
    )
    func childRecordsAreNotEntities() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add("old", "POLYLINE", layer: "0", [(66, "1"), (70, "1")])
        for (x, y) in [(0, 0), (10, 0), (10, 10)] {
            f.add(nil, "VERTEX", layer: "0", [(10, "\(x)"), (20, "\(y)"), (30, "0")])
        }
        f.add(nil, "SEQEND", layer: "0", [])
        f.add(nil, "INSERT", layer: "BLOCKS", [(2, "TITLE"), (66, "1"), (10, "0"), (20, "0")])
        f.add(nil, "ATTRIB", layer: "BLOCKS", [(2, "REV"), (1, "A")])
        f.add(nil, "ATTRIB", layer: "BLOCKS", [(2, "DATE"), (1, "today")])
        f.add(nil, "SEQEND", layer: "BLOCKS", [])
        let path = try f.write(to: dir)
        let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(r["entityCount"] as? Int == 1)
        // SwiftDXF 0.3.0 reports `Drawing.skipped` itself, and counts an INSERT's ATTRIB records as
        // skipped entities of their own; the raw scan this replaced counted only the INSERT.
        let skipped = try #require(r["skipped"] as? [String: Any])
        #expect(skipped["total"] as? Int == 3, "\(skipped)")
        #expect(skipped["byType"] as? [String: Int] == ["INSERT": 1, "ATTRIB": 2], "\(skipped)")
        let entity = try #require(
            try await entities([:], path).all.first)
        #expect((entity["vertices"] as? [Any])?.count == 3 && entity["closed"] as? Bool == true)
    }

    @Test("a file with lone CR line endings reads the same as an LF one")
    func carriageReturnOnly() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var fixture = DrawingFixture.tSlot()
        fixture.lineEnding = "\r"
        let r = try json(
            await call("read_drawing", ["inputPath": .string(try fixture.write(to: dir))]))
        #expect(r["entityCount"] as? Int == 21)
        let skipped = try #require(r["skipped"] as? [String: Any])
        #expect(skipped["byType"] as? [String: Int] == ["INSERT": 2, "HATCH": 1])
    }

    @Test("filter arguments that are the wrong shape are refused, not ignored")
    func argumentShapes() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = Value.string(try DrawingFixture.tSlot().write(to: dir))
        let bad: [(String, [String: Value], String)] = [
            ("list_drawing_entities", ["types": [1]], "`types` must be an array of strings"),
            ("list_drawing_entities", ["layers": "SLOT"], "`layers` must be an array of strings"),
            ("list_drawing_dimensions", ["layers": [true]], "`layers` must be an array of strings"),
            ("list_drawing_dimensions", ["kinds": "radius"], "`kinds` must be an array of strings"),
            ("list_drawing_dimensions", ["kinds": ["radiuss"]], "Unknown dimension kind"),
        ]
        for (name, extra, needle) in bad {
            var args: [String: Value] = ["inputPath": path]
            args.merge(extra) { $1 }
            let r = await call(name, args)
            #expect(r.isError && r.text.contains(needle), "\(name) \(extra): \(r.text)")
        }
        // JSON null means absent, for every optional argument.
        let nulls = try json(
            await call(
                "list_drawing_entities",
                [
                    "inputPath": path, "types": .null, "layers": .null, "rect": .null,
                    "rectMode": .null,
                ]))
        #expect(nulls["total"] as? Int == 21)
        let kinds = try json(
            await call("list_drawing_dimensions", ["inputPath": path, "kinds": .null]))
        #expect(kinds["total"] as? Int == 7)
        let fixture = DrawingFixture.tSlot()
        let lines = try json(
            await call(
                "measure_drawing",
                [
                    "inputPath": path, "measure": "angle", "vertex": .null,
                    "a": .string(fixture.id("bottom")), "b": .string(fixture.id("right")),
                ]))
        #expect(abs((lines["value"] as? Double ?? 0) - 90) < 1e-9)
    }

    @Test("an entity id has one spelling, and any other is refused")
    func idSpellings() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try DrawingFixture.tSlot().write(to: dir)
        for bad in ["e-1", "e+5", "e007", "E5", "e", "e5.0", " e5"] {
            let r = await measure(path, "distance", a: .string(bad), b: [0, 0])
            #expect(r.isError && r.text.contains("not an entity id"), "\(bad): \(r.text)")
        }
        let ok = await measure(path, "distance", a: "e0", b: [0, 0])
        #expect(!ok.isError, "\(ok.text)")
    }

    @Test("a closed polyline's closing segment counts, bulge and all")
    func closedPolylineClosingSegment() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // A 10 x 10 square whose closing segment, (0, 10) back to (0, 0), is a semicircle bulging out
        // to x = -5: bulge 1 on the last vertex.
        f.add(
            "loop", "LWPOLYLINE", layer: "0",
            [
                (90, "4"), (70, "1"), (10, "0"), (20, "0"), (10, "10"), (20, "0"), (10, "10"),
                (20, "10"), (10, "0"), (20, "10"), (42, "1"),
            ])
        let path = try f.write(to: dir)
        let all = try await entities([:], path)
        let loop = try #require(all.all.first)
        #expect(abs((loop["length"] as? Double ?? 0) - (30 + 5 * Double.pi)) < 1e-9, "\(loop)")
        let box = try #require(loop["bounds"] as? [String: Any])
        #expect(near(numbers(box["min"]), [-5, 0, 0], tol: 1e-9), "\(box)")
        #expect(near(numbers(box["max"]), [10, 10, 0], tol: 1e-9), "\(box)")
        // (-10, 5) is 5 from the arc's apex (-5, 5); without the closing segment it would be
        // sqrt(125) from the nearest corner.
        let r = try json(await measure(path, "distance", a: .string(f.id("loop")), b: [-10, 5]))
        #expect(abs((r["value"] as? Double ?? 0) - 5) < 1e-9, "\(r)")
    }

    @Test(
        "whole-turn arcs and degenerate entities are read, and refused where they cannot be measured"
    )
    func degenerateEntities() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "full", "ARC", layer: "0",
            [(10, "0"), (20, "0"), (30, "0"), (40, "2"), (50, "0"), (51, "360")])
        f.add(
            "zeroLine", "LINE", layer: "0",
            [(10, "1"), (20, "1"), (30, "0"), (11, "1"), (21, "1"), (31, "0")])
        f.add("zeroCircle", "CIRCLE", layer: "0", [(10, "3"), (20, "3"), (30, "0"), (40, "0")])
        f.add("onePoint", "LWPOLYLINE", layer: "0", [(90, "1"), (70, "0"), (10, "5"), (20, "5")])
        f.add("empty", "LWPOLYLINE", layer: "0", [(90, "0"), (70, "0")])
        let path = try f.write(to: dir)
        let all = try await entities([:], path)
        #expect(all.total == 5)
        func entity(_ name: String) throws -> [String: Any] {
            try #require(all.all.first { $0["id"] as? String == f.id(name) }, "no \(name)")
        }
        // An ARC from 0 to 360 is a whole turn, not an empty sweep.
        let full = try entity("full")
        #expect(abs((full["sweepDeg"] as? Double ?? 0) - 360) < 1e-9, "\(full)")
        #expect(abs((full["length"] as? Double ?? 0) - 4 * Double.pi) < 1e-9)
        #expect(try entity("empty")["bounds"] == nil, "an empty polyline has no position")

        for name in ["zeroLine", "zeroCircle", "empty"] {
            let r = await measure(path, "distance", a: .string(f.id(name)), b: [0, 0])
            #expect(r.isError && r.text.contains("no measurable geometry"), "\(name): \(r.text)")
        }
        let one = try json(
            await measure(path, "distance", a: .string(f.id("onePoint")), b: [0, 0]))
        #expect(abs((one["value"] as? Double ?? 0) - 50.0.squareRoot()) < 1e-9, "\(one)")
    }

    @Test("an ellipse whose end parameter is below its start runs through zero")
    func wrappedEllipse() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Major axis (4, 3), minor 2.5; parameters 3 pi / 2 up through 2 pi to pi / 2: the half that
        // holds the vertex (4, 3) and not the vertex (-4, -3).
        f.add(
            "wrapped", "ELLIPSE", layer: "0",
            [
                (10, "0"), (20, "0"), (30, "0"), (11, "4"), (21, "3"), (31, "0"), (40, "0.5"),
                (41, "4.71238898038469"), (42, "1.5707963267948966"),
            ])
        let path = try f.write(to: dir)
        func distance(to point: [Double]) async throws -> Double {
            let r = try json(
                await measure(
                    path, "distance", a: .string(f.id("wrapped")),
                    b: .array(point.map { .double($0) })))
            return try #require(r["value"] as? Double)
        }
        #expect(abs(try await distance(to: [8, 6]) - 5) < 1e-9)
        // The far vertex is not on it: the nearest points are the ends (1.5, -2) and (-1.5, 2).
        #expect(abs(try await distance(to: [-8, -6]) - 106.25.squareRoot()) < 1e-9)
    }

    @Test("an edit that keeps the file size is read again once its modification time moves")
    func sameSizeEditIsReread() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        await DrawingCache.shared.clear()
        func line(to x: String) -> DrawingFixture {
            var f = DrawingFixture()
            f.add(
                "l", "LINE", layer: "0",
                [(10, "0"), (20, "0"), (30, "0"), (11, x), (21, "0"), (31, "0")])
            return f
        }
        let path = try line(to: "1").write(to: dir)
        let before = try await entities([:], path).all.first
        #expect(before?["length"] as? Double == 1)
        let sizeBefore = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        _ = try line(to: "2").write(to: dir)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: path)
        let sizeAfter = try FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
        try #require(
            sizeBefore == sizeAfter, "the edit must keep the size for this test to mean anything")
        let after = try await entities([:], path).all.first
        #expect(after?["length"] as? Double == 2, "served the old file")
    }

    @Test("every $INSUNITS code maps to the unit ezdxf lists, in the right number of millimetres")
    func unitsTable() {
        // The ezdxf InsUnits list, with each unit in millimetres from its own definition.
        let expected: [(Int, String, Double?)] = [
            (0, "unitless", nil), (1, "inches", 25.4), (2, "feet", 304.8), (3, "miles", 1_609_344),
            (4, "millimetres", 1), (5, "centimetres", 10), (6, "metres", 1000),
            (7, "kilometres", 1_000_000), (8, "microinches", 25.4e-6), (9, "mils", 0.0254),
            (10, "yards", 914.4), (11, "angstroms", 1e-7), (12, "nanometres", 1e-6),
            (13, "microns", 1e-3), (14, "decimetres", 100), (15, "decametres", 1e4),
            (16, "hectometres", 1e5), (17, "gigametres", 1e12),
            (18, "astronomical units", 1.495978707e14), (19, "light years", 9.4607304725808e18),
            (20, "parsecs", 3.0856775814913673e19), (21, "US survey feet", 304.8006096012192),
            (22, "US survey inches", 25.4000508001016), (23, "US survey yards", 914.4018288036576),
            (24, "US survey miles", 1_609_347.2186944374),
        ]
        for (code, name, mm) in expected {
            #expect(DrawingUnits.name(insUnits: code) == name, "code \(code)")
            let got = DrawingUnits.mmPerUnit(insUnits: code)
            switch (got, mm) {
            case (nil, nil): break
            case (let got?, let mm?):
                #expect(abs(got - mm) <= mm * 1e-12, "code \(code): \(got) vs \(mm)")
            default:
                Issue.record(
                    "code \(code): \(String(describing: got)) vs \(String(describing: mm))")
            }
        }
        #expect(DrawingUnits.name(insUnits: 99) == "unknown code 99")
        #expect(DrawingUnits.mmPerUnit(insUnits: 99) == nil)
        #expect(DrawingUnits.name(insUnits: nil) == "undeclared")
    }

    @Test("an angle carries no millimetre note, even on a unitless drawing")
    func angleHasNoUnitNote() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot(insUnits: nil)
        let path = try fixture.write(to: dir)
        let lines = try json(
            await measure(
                path, "angle", a: .string(fixture.id("bottom")), b: .string(fixture.id("right"))))
        #expect(
            (lines["notes"] as? [String])?.contains { $0.contains("mmPerUnit") } == false,
            "\(lines)")
        let points = try json(await measure(path, "angle", a: [1, 0], b: [0, 1], vertex: [0, 0]))
        #expect((points["notes"] as? [String])?.isEmpty == true, "\(points)")
        // A distance on the same drawing does explain the missing millimetres.
        let distance = try json(
            await measure(path, "distance", a: [0, 0], b: [3, 4]))
        #expect((distance["notes"] as? [String])?.contains { $0.contains("mmPerUnit") } == true)
    }

    @Test("a dimension text of exactly <> is no override, and any other text is kept")
    func textOverrides() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        func dim(_ name: String, text: String) {
            f.add(
                name, "DIMENSION", layer: "DIMS",
                [
                    (70, "1"), (42, "8"), (1, text), (11, "0"), (21, "0"), (31, "0"), (10, "0"),
                    (20, "0"), (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "8"), (24, "0"),
                    (34, "0"),
                ])
        }
        dim("default", text: "<>")
        dim("suffixed", text: "<> H7")
        dim("typed", text: "8 +0.1")
        let path = try f.write(to: dir)
        let r = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let list = try #require(r["dimensions"] as? [[String: Any]])
        func text(_ name: String) throws -> String? {
            try #require(list.first { $0["id"] as? String == f.id(name) }, "no \(name)")["text"]
                as? String
        }
        #expect(try text("default") == nil)
        #expect(try text("suffixed") == "<> H7")
        #expect(try text("typed") == "8 +0.1")
    }

    @Test("a scalar argument of the wrong type is refused, not ignored")
    func scalarArgumentTypes() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = Value.string(try fixture.write(to: dir))
        let bad: [(String, [String: Value], String)] = [
            ("list_drawing_entities", ["limit": "ten"], "`limit` must be an integer"),
            ("list_drawing_entities", ["offset": "two"], "`offset` must be an integer"),
            ("list_drawing_entities", ["rectMode": 5], "`rectMode` must be a string"),
            ("list_drawing_dimensions", ["limit": true], "`limit` must be an integer"),
            (
                "measure_drawing",
                ["measure": "distance", "a": [0, 0], "b": [1, 1], "mmPerUnit": "25.4"],
                "`mmPerUnit` must be a number"
            ),
        ]
        for (name, extra, needle) in bad {
            var args: [String: Value] = ["inputPath": path]
            args.merge(extra) { $1 }
            let r = await call(name, args)
            #expect(r.isError && r.text.contains(needle), "\(name) \(extra): \(r.text)")
        }
        // null is absent, as everywhere else.
        let ok = try json(
            await call(
                "measure_drawing",
                [
                    "inputPath": path, "measure": "distance", "a": [0, 0], "b": [3, 4],
                    "mmPerUnit": .null,
                ]))
        #expect(abs((ok["value"] as? Double ?? 0) - 5) < 1e-9)
    }

    @Test("an argument the tool does not take is refused, and a page size outside its range")
    func unknownArgumentsAndRanges() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = Value.string(try DrawingFixture.tSlot().write(to: dir))
        let bad: [(String, [String: Value], String)] = [
            ("list_drawing_entities", ["layer": ["SLOT"]], "takes no argument named `layer`"),
            ("list_drawing_entities", ["type": ["line"], "layers": ["SLOT"]], "`type`"),
            ("list_drawing_dimensions", ["kind": ["radius"]], "takes no argument named `kind`"),
            ("read_drawing", ["layers": ["SLOT"]], "takes no argument named `layers`"),
            ("measure_drawing", ["measure": "radius", "a": "e5", "b": "e6", "unit": 1], "`unit`"),
            ("list_drawing_entities", ["limit": 0], "`limit` must be from 1 to 5000"),
            ("list_drawing_entities", ["limit": 5001], "`limit` must be from 1 to 5000"),
            ("list_drawing_dimensions", ["limit": -3], "`limit` must be from 1 to 5000"),
            ("list_drawing_entities", ["offset": -1], "`offset` must be at least 0"),
        ]
        for (name, extra, needle) in bad {
            var args: [String: Value] = ["inputPath": path]
            args.merge(extra) { $1 }
            let r = await call(name, args)
            #expect(r.isError && r.text.contains(needle), "\(name) \(extra): \(r.text)")
        }
        let edge = try json(
            await call("list_drawing_entities", ["inputPath": path, "limit": 1, "offset": 0]))
        #expect(edge["returned"] as? Int == 1)
    }

    @Test("a coordinate that is not finite does not fail the result; it is written as a string")
    func nonFiniteNumbers() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "good", "LINE", layer: "0",
            [(10, "0"), (20, "0"), (30, "0"), (11, "3"), (21, "4"), (31, "0")])
        f.add(
            "bad", "LINE", layer: "0",
            [(10, "0"), (20, "0"), (30, "0"), (11, "1e999"), (21, "0"), (31, "0")])
        let path = try f.write(to: dir)
        let summary = await call("read_drawing", ["inputPath": .string(path)])
        #expect(!summary.isError, "\(summary.text)")
        let listed = try await entities([:], path)
        let bad = try #require(listed.all.first { $0["id"] as? String == f.id("bad") })
        #expect((bad["end"] as? [Any])?.first as? String == "inf", "\(bad)")
        #expect(bad["length"] as? String == "inf")
        let good = try #require(listed.all.first { $0["id"] as? String == f.id("good") })
        #expect(good["length"] as? Double == 5)
    }

    @Test("polyline bulges of either sign and any size follow their own geometry")
    func bulgeSignsAndSizes() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // A chord (0, 0) to (10, 0). Bulge b makes an arc of included angle 4 atan(|b|): radius
        // c / (2 sin(theta / 2)), sagitta r (1 - cos(theta / 2)). A positive bulge runs counter-
        // clockwise, so it dips below the chord; a negative one rises above it.
        for (name, bulge) in [("ccw", "0.5"), ("cw", "-0.5"), ("shallow", "0.1")] {
            f.add(
                name, "LWPOLYLINE", layer: "0",
                [(90, "2"), (70, "0"), (10, "0"), (20, "0"), (42, bulge), (10, "10"), (20, "0")])
        }
        let path = try f.write(to: dir)
        let listed = try await entities([:], path)
        for (name, b) in [("ccw", 0.5), ("cw", -0.5), ("shallow", 0.1)] {
            let theta = 4 * atan(abs(b))
            let radius = 10 / (2 * sin(theta / 2))
            let sagitta = radius * (1 - cos(theta / 2))
            let entity = try #require(listed.all.first { $0["id"] as? String == f.id(name) })
            #expect(abs((entity["length"] as? Double ?? 0) - radius * theta) < 1e-9, "\(name)")
            let box = try #require(entity["bounds"] as? [String: Any], "\(entity)")
            let lo = try #require(numbers(box["min"]))
            let hi = try #require(numbers(box["max"]))
            #expect(abs(lo[0]) < 1e-9 && abs(hi[0] - 10) < 1e-9, "\(name) x \(lo) \(hi)")
            if b > 0 {
                #expect(
                    abs(lo[1] + sagitta) < 1e-9 && abs(hi[1]) < 1e-9, "\(name) dips \(lo) \(hi)")
            } else {
                #expect(
                    abs(hi[1] - sagitta) < 1e-9 && abs(lo[1]) < 1e-9, "\(name) rises \(lo) \(hi)")
            }
        }
        // From (5, -6): the counter-clockwise arc's lowest point is 3.5 away; the clockwise one rises
        // away from it, so the nearest points are its ends, sqrt(25 + 36).
        func distance(_ name: String) async throws -> Double {
            let r = try json(
                await measure(path, "distance", a: .string(f.id(name)), b: [5, -6]))
            return try #require(r["value"] as? Double)
        }
        #expect(abs(try await distance("ccw") - 3.5) < 1e-9)
        #expect(abs(try await distance("cw") - 61.0.squareRoot()) < 1e-9)
    }

    @Test(
        "three-point angular and unrecognised dimension kinds are named, and carry no millimetres")
    func otherDimensionKinds() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        for (name, type) in [("three", 5), ("odd", 7)] {
            f.add(
                name, "DIMENSION", layer: "DIMS",
                [
                    (70, "\(type)"), (42, "1.5"), (11, "0"), (21, "0"), (31, "0"), (10, "0"),
                    (20, "0"), (30, "0"),
                ])
        }
        let path = try f.write(to: dir)
        let r = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let list = try #require(r["dimensions"] as? [[String: Any]])
        let three = try #require(list.first { $0["id"] as? String == f.id("three") })
        #expect(three["kind"] as? String == "angular3Point")
        #expect(three["valueKind"] as? String == "angle" && three["valueMm"] == nil)
        let odd = try #require(list.first { $0["id"] as? String == f.id("odd") })
        #expect(odd["kind"] as? String == "unknown(7)")
        // `unknown(n)` can be filtered on too.
        let filtered = try json(
            await call(
                "list_drawing_dimensions",
                ["inputPath": .string(path), "kinds": ["unknown(7)"]]))
        #expect(filtered["total"] as? Int == 1)
    }

    @Test("the cache keeps four drawings and drops an older entry for a path that changed")
    func cacheEvictionAndStaleEntries() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let loaded = try await DrawingFile.load(path: try DrawingFixture.tSlot().write(to: dir))
        let cache = DrawingCache()
        let keys = (0..<5).map { DrawingCache.Key(path: "/drawing\($0).dxf", size: 1, modified: 0) }
        for key in keys { await cache.store(loaded, for: key) }
        #expect(await cache.entry(for: keys[0]) == nil, "the oldest of five is evicted")
        for key in keys.dropFirst() {
            #expect(await cache.entry(for: key) != nil, "\(key.path)")
        }
        let changed = DrawingCache.Key(path: "/drawing4.dxf", size: 2, modified: 0)
        await cache.store(loaded, for: changed)
        #expect(await cache.entry(for: keys[4]) == nil, "the entry for the old bytes is dropped")
        #expect(await cache.entry(for: changed) != nil)
    }

    // ── registration ────────────────────────────────────────────────────

    @Test("the four tools are in the catalog with their required arguments")
    func catalog() {
        let tools = catalogTools()
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        for (name, required) in [
            ("read_drawing", ["inputPath"]), ("list_drawing_entities", ["inputPath"]),
            ("list_drawing_dimensions", ["inputPath"]),
            ("measure_drawing", ["inputPath", "measure", "a"]),
        ] {
            let tool = byName[name]
            #expect(tool != nil, "\(name) is not registered")
            let schema = tool?.inputSchema.objectValue
            #expect(
                schema?["required"]?.arrayValue?.compactMap { $0.stringValue } == required,
                "\(name) requires \(String(describing: schema?["required"]))")
        }
    }

    @Test("a client reaches the tools over a real session, arrays and all")
    func overASession() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(outputDirectory: dir)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)

        let (content, isError) = try await client.callTool(
            name: "list_drawing_entities",
            arguments: [
                "inputPath": .string(path), "types": ["line"], "layers": ["SLOT"],
                "rect": [40, 5, 60, 15],
            ])
        #expect(isError != true)
        var text = ""
        if case .text(let t, _, _) = content.first { text = t }
        let result = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(result["total"] as? Int == 2, "\(text)")

        let (measured, measuredError) = try await client.callTool(
            name: "measure_drawing",
            arguments: [
                "inputPath": .string(path), "measure": "distance",
                "a": .string(fixture.id("slotLeft")), "b": .string(fixture.id("slotRight")),
            ])
        #expect(measuredError != true)
        let block = try #require(measured.first, "measure_drawing returned no content")
        guard case .text(let t, _, _) = block else {
            Issue.record("measure_drawing returned a non-text block")
            return
        }
        let r = try #require(try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any])
        #expect(abs((r["value"] as? Double ?? 0) - 8) < 1e-9, "\(t)")
    }
}
