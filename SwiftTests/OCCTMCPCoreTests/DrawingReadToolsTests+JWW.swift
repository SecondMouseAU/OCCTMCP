// What a JWW read through OCCTSwiftIO's DrawingLoader says about itself (#274): the scale each
// layer group was drawn at, which dimensions were rebuilt from loose pieces, and what no dimension
// explains. The fixtures are in Fixtures/Drawing (see its README).

import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

extension DrawingReadToolsTests {

    /// A 100 x 60 outline drawn 10 x 6 at 1:10, with a dimension kept as loose pieces (value `100`)
    /// and a radius value `R5` that no dimension explains.
    static var dimensionedJWW: String {
        plateDirectory.appendingPathComponent("dimensioned.jww").path
    }

    /// A line in layer group 0 at 1:10 and one in group 1 at 1:1.
    static var mixedScalesJWW: String {
        plateDirectory.appendingPathComponent("mixed.jww").path
    }

    /// A line at 1:10 with one stored dimension record (value `100`).
    static var storedDimensionJWW: String {
        plateDirectory.appendingPathComponent("stored.jww").path
    }

    /// A 10 x 6 outline at 1:10 with its width `100` kept as loose pieces (rebuilt) and its height
    /// `60` stored as a dimension record.
    static var bothDimensionsJWW: String {
        plateDirectory.appendingPathComponent("both-dimensions.jww").path
    }

    /// A line in group 0 at 1:10 and one in group 1, which states a scale of 0.
    static var unstatedBesideScaledJWW: String {
        plateDirectory.appendingPathComponent("unstated-beside-scaled.jww").path
    }

    /// A line in group 1 (at 1:5) inside a block placed by a reference in group 0 (at 1:10).
    static var blockGroupJWW: String {
        plateDirectory.appendingPathComponent("block-group.jww").path
    }

    /// A 100 unit line and a solid fill.
    static var solidFillJWW: String {
        plateDirectory.appendingPathComponent("solid.jww").path
    }

    /// A line in a layer group that states a scale of 0.
    static var unstatedScaleJWW: String {
        plateDirectory.appendingPathComponent("unstated.jww").path
    }

    @Test("a JWW is read at full size, and the scale applied to each layer group is stated")
    func jwwFullSizeAndScales() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.dimensionedJWW)]))
        let source = try #require(r["source"] as? [String: Any])
        #expect(source["format"] as? String == "jww")

        // Drawn 10 x 6 at 1:10: the entities are 100 x 60, not the drawn size.
        let outline = try await entities(["types": ["line"]], Self.dimensionedJWW).all
        #expect(outline.count == 4, "\(outline.count) lines")
        let xs =
            outline.flatMap { numbers($0["start"]) ?? [] }
            + outline.flatMap { numbers($0["end"]) ?? [] }
        #expect(xs.max() == 100, "the outline is not at full size: \(xs)")

        let scales = try #require(r["layerGroupScales"] as? [[String: Any]])
        #expect(scales.count == 1, "\(scales)")
        #expect(scales.first?["group"] as? Int == 0)
        #expect(scales.first?["layerNamePrefix"] as? String == "0-")
        #expect(scales.first?["scale"] as? Double == 10)
        let warnings = try #require(r["warnings"] as? [String])
        // The controls for this are below: the mixed-scales and unstated-scale tests have each one.
        #expect(
            !warnings.contains {
                $0.contains("different scales") || $0.contains("states no scale")
            },
            "one stated scale is not a warning: \(warnings)")
    }

    @Test("a dimension a JWW keeps as loose pieces is a dimension, marked as rebuilt")
    func jwwRebuiltDimension() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.dimensionedJWW)]))
        #expect(r["rebuiltDimensions"] as? Int == 1)
        #expect((r["byType"] as? [String: Int])?["dimension"] == 1)

        let listing = try json(
            await call("list_drawing_dimensions", ["inputPath": .string(Self.dimensionedJWW)]))
        let rows = try #require(listing["dimensions"] as? [[String: Any]])
        #expect(rows.count == 1, "\(rows)")
        let row = try #require(rows.first)
        #expect(row["rebuilt"] as? Bool == true)
        #expect(row["text"] as? String == "100")
        #expect(row["layer"] as? String == "0-E")
        #expect(abs((row["valueFromPoints"] as? Double ?? 0) - 100) < 1e-9, "\(row)")

        // The same flag on the entity listing.
        let all = try await entities(["types": ["dimension"]], Self.dimensionedJWW).all
        let dimension = try #require(all.first?["dimension"] as? [String: Any])
        #expect(dimension["rebuilt"] as? Bool == true)
    }

    @Test("a dimension a file stores is not marked as rebuilt, and a DXF or DWG has no JWW fields")
    func storedDimensionIsNotRebuilt() async throws {
        // plate.dwg carries three stored dimensions: the control for the rebuilt flag above.
        let dwg = Self.plateDirectory.appendingPathComponent("plate.dwg").path
        let listing = try json(await call("list_drawing_dimensions", ["inputPath": .string(dwg)]))
        let rows = try #require(listing["dimensions"] as? [[String: Any]])
        #expect(rows.count == 3, "\(rows.count) dimensions")
        #expect(rows.allSatisfy { $0["rebuilt"] == nil }, "a stored dimension was marked rebuilt")

        for name in ["plate.dxf", "plate.dwg"] {
            let path = Self.plateDirectory.appendingPathComponent(name).path
            let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
            #expect(r["layerGroupScales"] == nil, "\(name)")
            #expect(r["rebuiltDimensions"] == nil, "\(name)")
        }
    }

    @Test("a value no dimension explains is a warning that names it, not a silent loss")
    func jwwUnexplainedValue() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.dimensionedJWW)]))
        let warnings = try #require(r["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("R5") }, "\(warnings)")

        // The value is not dropped: it stays in the drawing as a loose text at full size.
        let texts = try await entities(["types": ["text"]], Self.dimensionedJWW).all
        let loose = try #require(
            texts.first { $0["text"] as? String == "R5" },
            "the R5 text is not in the entity list: \(texts)")
        // Drawn at (3, 3) at 1:10, so (30, 30) at full size.
        #expect(near(numbers(loose["at"]), [30, 30, 0]), "\(loose["at"] ?? "?")")
    }

    @Test("groups drawn at different scales are each stated, with the loader's warning")
    func jwwMixedScales() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.mixedScalesJWW)]))
        let scales = try #require(r["layerGroupScales"] as? [[String: Any]])
        #expect(scales.map { $0["group"] as? Int } == [0, 1], "\(scales)")
        #expect(scales.map { $0["scale"] as? Double } == [10, 1], "\(scales)")
        #expect(scales.map { $0["layerNamePrefix"] as? String } == ["0-", "1-"], "\(scales)")
        let warnings = try #require(r["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("different scales") }, "\(warnings)")
        #expect(warnings.contains { $0.contains("1:10 for group 0") }, "\(warnings)")

        // Each group is at full size: 10 drawn units at 1:10 is 100, and 5 at 1:1 stays 5.
        let lines = try await entities(["types": ["line"]], Self.mixedScalesJWW).all
        #expect(
            lines.compactMap { $0["length"] as? Double }.sorted() == [5, 100],
            "\(lines.map { $0["length"] ?? "?" })")
    }

    @Test("a group that states no scale is read at drawn size, and the warning says so")
    func jwwUnstatedScale() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.unstatedScaleJWW)]))
        let scales = try #require(r["layerGroupScales"] as? [[String: Any]])
        #expect(scales.count == 1, "\(scales)")
        #expect(scales.first?["group"] as? Int == 0)
        #expect(scales.first?["scale"] as? Double == 1, "scale 1 is drawn size")
        let warnings = try #require(r["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("states no scale") }, "\(warnings)")
        #expect(
            !warnings.contains { $0.contains("different scales") },
            "one group is not a mixed scale: \(warnings)")

        // Drawn size: the 10 unit line is 10, not multiplied by anything.
        let lines = try await entities(["types": ["line"]], Self.unstatedScaleJWW).all
        #expect(
            lines.compactMap { $0["length"] as? Double } == [10],
            "\(lines.map { $0["length"] ?? "?" })")
    }

    @Test("a dimension record a JWW stores is a dimension and is not marked as rebuilt")
    func jwwStoredDimensionIsNotRebuilt() async throws {
        // The same format as the rebuilt dimension above, so this is the control that the flag
        // follows how the reader got the dimension and not the file's format.
        let stored = Self.storedDimensionJWW
        let read = try json(await call("read_drawing", ["inputPath": .string(stored)]))
        #expect((read["byType"] as? [String: Int])?["dimension"] == 1, "\(read["byType"] ?? "")")
        #expect(read["rebuiltDimensions"] == nil)

        let listing = try json(
            await call("list_drawing_dimensions", ["inputPath": .string(stored)]))
        let rows = try #require(listing["dimensions"] as? [[String: Any]])
        #expect(rows.count == 1, "\(rows)")
        let row = try #require(rows.first)
        #expect(row["rebuilt"] == nil, "a stored dimension was marked rebuilt")
        #expect(row["text"] as? String == "100")
        #expect(abs((row["valueFromPoints"] as? Double ?? 0) - 100) < 1e-9, "\(row)")

        let all = try await entities(["types": ["dimension"]], stored).all
        let dimension = try #require(all.first?["dimension"] as? [String: Any])
        #expect(dimension["rebuilt"] == nil, "the entity listing marked a stored dimension rebuilt")
    }

    @Test(
        "the rebuilt flag follows each dimension, in a file that has a rebuilt one and a stored one"
    )
    func jwwRebuiltFlagFollowsTheDimension() async throws {
        let path = Self.bothDimensionsJWW
        let listing = try json(await call("list_drawing_dimensions", ["inputPath": .string(path)]))
        let rows = try #require(listing["dimensions"] as? [[String: Any]])
        #expect(rows.count == 2, "\(rows)")
        let flags = Dictionary(
            rows.compactMap { row -> (String, Bool?)? in
                guard let text = row["text"] as? String else { return nil }
                return (text, row["rebuilt"] as? Bool)
            }, uniquingKeysWith: { first, _ in first })
        #expect(flags["100"] == .some(true), "the loose-piece dimension: \(flags)")
        #expect(flags["60"] == .some(nil), "the stored dimension was marked: \(flags)")

        // Both paths, and the count in read_drawing, agree.
        let all = try await entities(["types": ["dimension"]], path).all
        #expect(all.count == 2, "\(all.count) dimension entities")
        let byText = Dictionary(
            all.compactMap { entity -> (String, Bool?)? in
                guard let record = entity["dimension"] as? [String: Any],
                    let text = record["text"] as? String
                else { return nil }
                return (text, record["rebuilt"] as? Bool)
            }, uniquingKeysWith: { first, _ in first })
        #expect(byText["100"] == .some(true) && byText["60"] == .some(nil), "\(byText)")
        let read = try json(await call("read_drawing", ["inputPath": .string(path)]))
        #expect(read["rebuiltDimensions"] as? Int == 1, "one of two dimensions was rebuilt")
    }

    @Test("a distance across layer groups at different scales says it is not the sheet distance")
    func jwwMeasureAcrossScales() async throws {
        let measured = try json(
            await measure(
                Self.mixedScalesJWW, "distance", a: .string("e0"), b: .string("e1")))
        let notes = try #require(measured["notes"] as? [String])
        #expect(
            notes.contains {
                $0.contains("not the sheet distance") && $0.contains("different scales")
            },
            "\(notes)")

        // An angle is the same at any scale, so the note is for a distance only.
        let angle = try json(
            await measure(Self.mixedScalesJWW, "angle", a: .string("e0"), b: .string("e1")))
        let angleNotes = try #require(angle["notes"] as? [String])
        #expect(
            !angleNotes.contains { $0.contains("not the sheet distance") }, "\(angleNotes)")

        // The note is the drawing's, as the reference says: a distance from one entity to a point
        // carries it too, whichever groups are involved.
        let toPoint = try json(
            await measure(
                Self.mixedScalesJWW, "distance", a: .string("e0"),
                b: .array([.double(0), .double(0)])
            ))
        let pointNotes = try #require(toPoint["notes"] as? [String])
        #expect(pointNotes.contains { $0.contains("not the sheet distance") }, "\(pointNotes)")

        // The control: a JWW with one scale has no such note, so the note is not always there.
        let single = try json(
            await measure(
                Self.dimensionedJWW, "distance", a: .string("e0"), b: .string("e2")))
        let singleNotes = try #require(single["notes"] as? [String])
        #expect(
            !singleNotes.contains { $0.contains("not the sheet distance") }, "\(singleNotes)")
    }

    @Test("a group that states no scale beside a scaled one is a mixed scale, at drawn size")
    func jwwUnstatedBesideScaled() async throws {
        let path = Self.unstatedBesideScaledJWW
        let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
        let scales = try #require(r["layerGroupScales"] as? [[String: Any]])
        #expect(scales.map { $0["group"] as? Int } == [0, 1], "\(scales)")
        #expect(scales.map { $0["scale"] as? Double } == [10, 1], "\(scales)")
        let warnings = try #require(r["warnings"] as? [String])
        #expect(warnings.contains { $0.contains("states no scale") }, "\(warnings)")
        #expect(warnings.contains { $0.contains("drawn size for group 1") }, "\(warnings)")
        let lines = try await entities(["types": ["line"]], path).all
        #expect(lines.compactMap { $0["length"] as? Double } == [100, 5], "\(lines)")
    }

    @Test(
        "a block member takes the scale of the group that places it, and its own group is not listed"
    )
    func jwwBlockMemberScale() async throws {
        let path = Self.blockGroupJWW
        let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
        // The member is drawn in group 1 (1:5) and placed by a reference in group 0 (1:10).
        let scales = try #require(r["layerGroupScales"] as? [[String: Any]])
        #expect(scales.map { $0["group"] as? Int } == [0], "\(scales)")
        let lines = try await entities(["types": ["line"]], path).all
        #expect(lines.compactMap { $0["length"] as? Double } == [10], "\(lines)")
    }

    @Test("a JWW solid fill is skipped by type with no layer, as the loader counts it")
    func jwwSolidFillIsSkipped() async throws {
        let r = try json(await call("read_drawing", ["inputPath": .string(Self.solidFillJWW)]))
        let skipped = try #require(r["skipped"] as? [String: Any])
        #expect(skipped["total"] as? Int == 1, "\(skipped)")
        #expect(skipped["byType"] as? [String: Int] == ["SOLID": 1], "\(skipped)")
        let byLayer = try #require(skipped["byLayer"] as? [String: Any])
        #expect(byLayer.isEmpty, "a JWW solid fill carries no layer: \(byLayer)")
    }
}
