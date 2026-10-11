// inspect_assembly and set_assembly_metadata read .xbf input with the OCAF reader (#234).

import Foundation
import Testing
import OCCTSwift
@testable import OCCTMCPCore

@Suite("assembly tools accept .xbf input", .serialized)
struct AssemblyXBFInputTests {

    func tempDir() throws -> String {
        let dir = NSTemporaryDirectory() + "occtmcp-xbf-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    func writeBoxStep(in dir: String) throws -> String {
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let doc = try #require(Document.create())
        _ = doc.addShape(box)
        let path = "\(dir)/in.step"
        try doc.writeSTEP(to: URL(fileURLWithPath: path), progress: nil)
        return path
    }

    /// Reads named strings off the main label; the Document must outlive its nodes.
    func namedStrings(ofXBF path: String, keys: [String]) throws -> [String: String] {
        let loaded = Document.loadOCAF(from: path)
        let doc = try #require(loaded.document, "loadOCAF status \(loaded.status)")
        let node = try #require(doc.mainLabel ?? doc.rootNodes.first)
        var out: [String: String] = [:]
        for key in keys { out[key] = node.namedString(key) }
        return out
    }

    @Test("round trip: STEP -> set_assembly_metadata -> inspect_assembly on the .xbf")
    func roundTrip() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let step = try writeBoxStep(in: dir)
        let xbf = "\(dir)/out.xbf"

        let set = await AssemblyTools.setAssemblyMetadata(
            inputPath: step, outputPath: xbf,
            metadata: .init(title: "Bracket", material: "6061"))
        #expect(!set.isError, "\(set.text)")

        let inspect = await AssemblyTools.inspectAssembly(inputPath: xbf)
        #expect(!inspect.isError, "\(inspect.text)")
        #expect(inspect.text.contains("totalComponents"), "\(inspect.text)")

        let read = try namedStrings(ofXBF: xbf, keys: ["title", "material"])
        #expect(read["title"] == "Bracket")
        #expect(read["material"] == "6061")
    }

    @Test("set_assembly_metadata on an .xbf input keeps the earlier metadata and adds the new")
    func xbfInputKeepsMetadata() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let step = try writeBoxStep(in: dir)
        let first = "\(dir)/first.xbf"
        let second = "\(dir)/second.xbf"

        let r1 = await AssemblyTools.setAssemblyMetadata(
            inputPath: step, outputPath: first, metadata: .init(title: "Bracket"))
        #expect(!r1.isError, "\(r1.text)")
        let r2 = await AssemblyTools.setAssemblyMetadata(
            inputPath: first, outputPath: second, metadata: .init(revision: "B"))
        #expect(!r2.isError, "\(r2.text)")

        let read = try namedStrings(ofXBF: second, keys: ["title", "revision"])
        #expect(read["title"] == "Bracket")
        #expect(read["revision"] == "B")
    }

    @Test("an empty or non-OCAF .xbf is refused before the reader sees it")
    func notOCAF() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let text = "\(dir)/text.xbf"
        let empty = "\(dir)/empty.xbf"
        try Data("not an ocaf file".utf8).write(to: URL(fileURLWithPath: text))
        try Data().write(to: URL(fileURLWithPath: empty))
        await expectAllFail([text, empty], dir: dir, containing: "not a binary OCAF file")
    }

    @Test("a truncated or garbage OCAF body is an error naming the reader status")
    func corruptOCAF() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let step = try writeBoxStep(in: dir)
        let real = "\(dir)/real.xbf"
        let set = await AssemblyTools.setAssemblyMetadata(
            inputPath: step, outputPath: real, metadata: .init(title: "t"))
        #expect(!set.isError, "\(set.text)")
        let truncated = "\(dir)/truncated.xbf"
        let garbage = "\(dir)/garbage.xbf"
        let whole = try Data(contentsOf: URL(fileURLWithPath: real))
        try whole.prefix(20).write(to: URL(fileURLWithPath: truncated))
        try Data("BINFILE garbage garbage garbage".utf8).write(to: URL(fileURLWithPath: garbage))
        await expectAllFail([truncated, garbage], dir: dir, containing: "reader status")
    }

    func expectAllFail(_ paths: [String], dir: String, containing needle: String) async {
        let out = "\(dir)/o.xbf"
        var results: [(label: String, result: ToolText)] = []
        for path in paths {
            results.append(("inspect \(path)", await AssemblyTools.inspectAssembly(inputPath: path)))
            results.append(
                (
                    "set \(path)",
                    await AssemblyTools.setAssemblyMetadata(
                        inputPath: path, outputPath: out, metadata: .init(title: "t"))
                ))
        }
        #expect(results.count == paths.count * 2)
        for r in results {
            #expect(r.result.isError, "\(r.label)")
            #expect(r.result.text.contains(needle), "\(r.label): \(r.result.text)")
        }
        #expect(!FileManager.default.fileExists(atPath: out))
    }
}
