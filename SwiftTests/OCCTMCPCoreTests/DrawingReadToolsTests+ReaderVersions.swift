// The release line of each reader a drawing went through (#281): what the source record says for a
// DXF, a DWG and a JWW, which tools carry it, and that each recorded line is the one
// `Package.resolved` pins, so a bump of any one reader without the record fails here. The fixtures
// and helpers are the ones in DrawingReadToolsTests.swift and its DrawingLoader extension.

import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

extension DrawingReadToolsTests {

    /// The version `Package.resolved` pins for the package with this identity.
    static func pinnedVersion(of identity: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Package.resolved"))
        let resolved = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pins = try #require(resolved["pins"] as? [[String: Any]])
        let pin = try #require(
            pins.first { $0["identity"] as? String == identity },
            "Package.resolved has no pin for \(identity)")
        let state = try #require(pin["state"] as? [String: Any])
        return try #require(state["version"] as? String)
    }

    /// The release line of a version: major and minor, so `0.5.0` is `0.5`.
    static func releaseLine(of version: String) -> String {
        version.split(separator: ".").prefix(2).joined(separator: ".")
    }

    /// Expects `line` to be the release line `Package.resolved` pins for `identity`.
    func expectLine(_ line: String, isPinnedFor identity: String) throws {
        let pinned = try Self.pinnedVersion(of: identity)
        #expect(
            Self.releaseLine(of: pinned) == line,
            "Package.resolved pins \(identity) \(pinned), but the recorded line is \(line)")
    }

    // ── Each recorded line is held to its pin ───────────────────────────

    @Test("the recorded SwiftDXF line is the release line Package.resolved pins")
    func swiftDXFLineIsPinned() throws {
        try expectLine(DrawingFile.readerVersion, isPinnedFor: "swiftdxf")
    }

    @Test("the recorded SwiftDWG line is the release line Package.resolved pins")
    func swiftDWGLineIsPinned() throws {
        try expectLine(DrawingFile.dwgReaderVersion, isPinnedFor: "swiftdwg")
    }

    @Test("the recorded SwiftJWW line is the release line Package.resolved pins")
    func swiftJWWLineIsPinned() throws {
        try expectLine(DrawingFile.jwwReaderVersion, isPinnedFor: "swiftjww")
    }

    // ── What the source record says for each format ─────────────────────

    /// `source` of `read_drawing` for a fixture file.
    func plateSource(_ name: String) async throws -> [String: Any] {
        let path = Self.plateDirectory.appendingPathComponent(name).path
        let r = try json(await call("read_drawing", ["inputPath": .string(path)]))
        return try #require(r["source"] as? [String: Any])
    }

    @Test("a DXF is read by SwiftDXF alone")
    func dxfRecordsSwiftDXF() async throws {
        let source = try await plateSource("plate.dxf")
        #expect(source["format"] as? String == "dxf")
        #expect(
            source["readerVersions"] as? [String: String]
                == ["SwiftDXF": DrawingFile.readerVersion],
            "\(source["readerVersions"] ?? "none")")
        #expect(source["readerVersion"] as? String == DrawingFile.readerVersion)
    }

    @Test("a DWG is read by SwiftDWG and then SwiftDXF")
    func dwgRecordsSwiftDWGAndSwiftDXF() async throws {
        let source = try await plateSource("plate.dwg")
        #expect(source["format"] as? String == "dwg")
        #expect(
            source["readerVersions"] as? [String: String]
                == [
                    "SwiftDXF": DrawingFile.readerVersion, "SwiftDWG": DrawingFile.dwgReaderVersion,
                ],
            "\(source["readerVersions"] ?? "none")")
        #expect(source["readerVersion"] as? String == DrawingFile.readerVersion)
    }

    @Test("a JWW is read by SwiftJWW and then SwiftDXF")
    func jwwRecordsSwiftJWWAndSwiftDXF() async throws {
        let source = try await plateSource("plate.jww")
        #expect(source["format"] as? String == "jww")
        #expect(
            source["readerVersions"] as? [String: String]
                == [
                    "SwiftDXF": DrawingFile.readerVersion, "SwiftJWW": DrawingFile.jwwReaderVersion,
                ],
            "\(source["readerVersions"] ?? "none")")
        #expect(source["readerVersion"] as? String == DrawingFile.readerVersion)
    }

    @Test(
        "every tool that returns ids carries the release line of each reader, for a DWG and a JWW")
    func everyToolCarriesReaderVersions() async throws {
        let files: [(name: String, expected: [String: String])] = [
            (
                "plate.dwg",
                ["SwiftDXF": DrawingFile.readerVersion, "SwiftDWG": DrawingFile.dwgReaderVersion]
            ),
            (
                "plate.jww",
                ["SwiftDXF": DrawingFile.readerVersion, "SwiftJWW": DrawingFile.jwwReaderVersion]
            ),
        ]
        #expect(files.count == 2)
        for (name, expected) in files {
            let path = Self.plateDirectory.appendingPathComponent(name).path
            let listed = try await entities(["types": ["line"]], path)
            let ids = listed.ids
            try #require(ids.count >= 2, "\(name) has fewer than two lines")
            let input: [String: Value] = ["inputPath": .string(path)]
            let dimensions = try json(await call("list_drawing_dimensions", input))
            let measured = try json(
                await measure(path, "distance", a: .string(ids[0]), b: .string(ids[1])))
            let results: [(String, [String: Any])] = [
                ("list_drawing_entities", listed.raw), ("list_drawing_dimensions", dimensions),
                ("measure_drawing", measured),
            ]
            for (tool, result) in results {
                let carried = (result["source"] as? [String: Any])?["readerVersions"]
                #expect(
                    carried as? [String: String] == expected,
                    "\(name) \(tool): \(carried ?? "none")")
            }
        }
    }
}
