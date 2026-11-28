// The entity types SwiftDXF 0.6 reads (#300): a SOLID, a 3DFACE, a WIPEOUT and a TOLERANCE are
// entities with a layer, a colour, a box and their geometry, where they were skipped records
// before, and an angular dimension's computed angle is no length to scale into millimetres. The
// fixture and the helpers are the ones in DrawingReadToolsTests.swift.

import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

extension DrawingReadToolsTests {

    /// One of each of the four types, written as the groups a CAD program writes.
    private func solidTypesFixture() -> DrawingFixture {
        var f = DrawingFixture()
        // The file lists a SOLID's corners 1, 2, 4, 3 (groups 10 to 13); the reader puts them in
        // outline order, so the third and fourth swap.
        f.add(
            "fill", "SOLID", layer: "FILL",
            [
                (62, "3"), (10, "0"), (20, "0"), (30, "0"), (11, "4"), (21, "0"), (31, "0"),
                (12, "0"), (22, "5"), (32, "0"), (13, "4"), (23, "5"), (33, "0"),
            ])
        f.add(
            "mesh", "3DFACE", layer: "MESH",
            [
                (10, "0"), (20, "0"), (30, "-2"), (11, "1"), (21, "0"), (31, "0"), (12, "1"),
                (22, "1"), (32, "7"), (13, "0"), (23, "1"), (33, "0"),
            ])
        // A WIPEOUT is stored as an image: an insertion point, the two pixel vectors, the image
        // size and a clip boundary in pixels. A rectangular clip is two opposite corners.
        f.add(
            "mask", "WIPEOUT", layer: "MASK",
            [
                (10, "-3"), (20, "0"), (30, "0"), (11, "2"), (21, "0"), (31, "0"), (12, "0"),
                (22, "2"), (32, "0"), (13, "1"), (23, "1"), (14, "-0.5"), (24, "-0.5"),
                (14, "0.5"), (24, "0.5"),
            ])
        f.add(
            "frame", "TOLERANCE", layer: "GDT",
            [(3, "ISO"), (10, "9"), (20, "-6"), (30, "0"), (1, "{\\Fgdt;c}%%v0.1")])
        return f
    }

    @Test("a SOLID, a 3DFACE, a WIPEOUT and a TOLERANCE are entities with layer, colour and geometry")
    func solidWipeoutFaceAndTolerance() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = solidTypesFixture()
        let path = try fixture.write(to: dir)

        let all = try await entities([:], path)
        #expect(all.total == 4, "\(all.ids)")
        func record(_ name: String) throws -> [String: Any] {
            try #require(all.all.first { $0["id"] as? String == fixture.id(name) })
        }
        func box(_ record: [String: Any]) throws -> ([Double]?, [Double]?) {
            let box = try #require(record["bounds"] as? [String: Any])
            return (numbers(box["min"]), numbers(box["max"]))
        }

        let fill = try record("fill")
        #expect(fill["type"] as? String == "solid" && fill["layer"] as? String == "FILL")
        #expect(fill["color"] as? Int == 3)
        let fillVertices = (fill["vertices"] as? [Any])?.map { numbers($0) }
        #expect(
            fillVertices?.count == 4 && near(fillVertices?[0], [0, 0, 0])
                && near(fillVertices?[1], [4, 0, 0]) && near(fillVertices?[2], [4, 5, 0])
                && near(fillVertices?[3], [0, 5, 0]), "\(String(describing: fill["vertices"]))")
        #expect(fill["closed"] as? Bool == true)
        let fillBox = try box(fill)
        #expect(near(fillBox.0, [0, 0, 0]) && near(fillBox.1, [4, 5, 0]))

        let mesh = try record("mesh")
        #expect(mesh["type"] as? String == "face3d" && mesh["layer"] as? String == "MESH")
        let meshVertices = (mesh["vertices"] as? [Any])?.map { numbers($0) }
        #expect(
            meshVertices?.count == 4 && near(meshVertices?[0], [0, 0, -2])
                && near(meshVertices?[2], [1, 1, 7]), "\(String(describing: mesh["vertices"]))")
        let meshBox = try box(mesh)
        #expect(near(meshBox.0, [0, 0, -2]) && near(meshBox.1, [1, 1, 7]), "z is kept")

        // The clip's two corners are (-0.5, -0.5) and (0.5, 0.5) pixels of a 1 by 1 image placed at
        // (-3, 0) with pixel vectors (2, 0) and (0, 2): a 2 by 2 square, (-3, 0) to (-1, 2).
        let mask = try record("mask")
        #expect(mask["type"] as? String == "wipeout" && mask["layer"] as? String == "MASK")
        let maskVertices = (mask["vertices"] as? [Any])?.map { numbers($0) }
        #expect(maskVertices?.count == 4, "\(String(describing: mask["vertices"]))")
        let maskBox = try box(mask)
        #expect(
            near(maskBox.0, [-3, 0, 0]) && near(maskBox.1, [-1, 2, 0]), "\(maskBox)")

        let frame = try record("frame")
        #expect(frame["type"] as? String == "tolerance" && frame["layer"] as? String == "GDT")
        #expect(near(numbers(frame["at"]), [9, -6, 0]))
        #expect(frame["text"] as? String == "{\\Fgdt;c}%%v0.1", "the frame string, as written")
        #expect(frame["styleName"] as? String == "ISO")
        #expect(frame["rotationDeg"] as? Double == 0)
        let frameBox = try box(frame)
        #expect(
            near(frameBox.0, [9, -6, 0]) && near(frameBox.1, [9, -6, 0]),
            "its box is its insertion point: the frame's size comes from a style the reader lacks")

        // They are entities, so the types are a filter, and read_drawing counts them and does not
        // list them as skipped.
        let solids = try await entities(["types": ["solid", "wipeout"]], path)
        #expect(solids.ids == [fixture.id("fill"), fixture.id("mask")], "\(solids.ids)")
        let summary = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(summary["entityCount"] as? Int == 4)
        #expect(
            summary["byType"] as? [String: Int] == [
                "solid": 1, "face3d": 1, "wipeout": 1, "tolerance": 1,
            ])
        let warnings = try #require(summary["warnings"] as? [String])
        #expect(!warnings.contains { $0.contains("no mapping") }, "\(warnings)")
    }

    @Test("measuring a solid fill, a wipeout, a 3D face or a tolerance says what to do instead")
    func measuringTheNewTypes() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = solidTypesFixture()
        let path = try fixture.write(to: dir)
        for (name, needle) in [
            ("fill", "`vertices`"), ("mask", "`vertices`"), ("mesh", "`vertices`"),
            ("frame", "`at`"),
        ] {
            let r = await measure(path, "distance", a: .string(fixture.id(name)), b: [0, 0])
            #expect(r.isError && r.text.contains(needle), "\(name): \(r.text)")
        }
    }

    @Test("an angular dimension's computed angle is degrees, so it has no millimetre figure")
    func angularComputedValueIsNotScaled() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Inches, so a length scales by 25.4 and a wrongly scaled angle would show as 2286.
        var f = DrawingFixture()
        f.insUnits = 1
        // Two lines from the origin, along +x and +y, and an arc between them: a quarter turn.
        f.add(
            "angle", "DIMENSION", layer: "DIMS",
            [
                (70, "2"), (42, "1.5707963"), (11, "5"), (21, "5"), (31, "0"), (10, "0"),
                (20, "10"), (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "10"), (24, "0"),
                (34, "0"), (15, "0"), (25, "0"), (35, "0"), (16, "5"), (26, "5"), (36, "0"),
            ])
        // A linear dimension of the same drawing: ten inches along x.
        f.add(
            "length", "DIMENSION", layer: "DIMS",
            [
                (70, "0"), (42, "10"), (11, "5"), (21, "-2"), (31, "0"), (10, "0"), (20, "-2"),
                (30, "0"), (13, "0"), (23, "0"), (33, "0"), (14, "10"), (24, "0"), (34, "0"),
            ])
        let path = try f.write(to: dir)
        let r = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let list = try #require(r["dimensions"] as? [[String: Any]])
        let angle = try #require(list.first { $0["kind"] as? String == "angular" })
        let length = try #require(list.first { $0["kind"] as? String == "linear" })

        let computed = try #require(angle["valueFromPoints"] as? Double)
        #expect(abs(computed - 90) < 1e-9, "the angle the points give, in degrees: \(computed)")
        #expect(angle["valueFromPointsMm"] == nil, "an angle is not a length to scale: \(angle)")
        #expect(angle["valueMm"] == nil)

        #expect(length["valueFromPoints"] as? Double == 10)
        #expect(length["valueFromPointsMm"] as? Double == 254, "a length is scaled by 25.4")
    }
}
