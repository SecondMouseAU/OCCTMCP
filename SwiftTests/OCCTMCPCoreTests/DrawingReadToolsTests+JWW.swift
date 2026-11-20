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
        #expect(xs.max() == 100, "the outline is at drawn size: \(xs)")

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
}
