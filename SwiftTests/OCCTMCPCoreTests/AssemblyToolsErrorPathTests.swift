// inspect_assembly and set_assembly_metadata must report their failures as error results
// (isError true), not as a successful call with an apology in the text (#218).

import Foundation
import Testing
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("inspect_assembly / set_assembly_metadata report failures as errors", .serialized)
struct AssemblyToolsErrorPathTests {

    /// A scene with a single body "a" (a dummy BREP file is enough: every case here fails before
    /// the file is parsed).
    func freshScene() throws -> ManifestStore {
        let dir = NSTemporaryDirectory() + "occtmcp-assembly-err-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(
            ScriptManifest(
                version: 1, timestamp: Date(), description: "assembly errors",
                bodies: [BodyDescriptor(id: "a", file: "a.brep", color: [1, 0, 0, 1])]))
        return store
    }

    func dirOf(_ store: ManifestStore) -> String {
        (store.path as NSString).deletingLastPathComponent
    }

    func bytes(_ store: ManifestStore) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: store.path))
    }

    @Test("inspect_assembly: missing file, no scene, unknown body, no input, bad extension")
    func inspectErrors() async throws {
        let store = try freshScene()
        defer { try? FileManager.default.removeItem(atPath: dirOf(store)) }
        let before = try bytes(store)
        let txt = "\(dirOf(store))/notes.txt"
        try "x".write(toFile: txt, atomically: true, encoding: .utf8)
        let noScene = ManifestStore(path: NSTemporaryDirectory() + "occtmcp-none-\(UUID())/m.json")

        let cases: [(label: String, result: ToolText, text: String)] = [
            (
                "missing file",
                await AssemblyTools.inspectAssembly(inputPath: "\(dirOf(store))/nope.step"),
                "File not found"
            ),
            (
                "no scene",
                await AssemblyTools.inspectAssembly(bodyId: "a", store: noScene),
                "No scene loaded"
            ),
            (
                "unknown body",
                await AssemblyTools.inspectAssembly(bodyId: "nope", store: store),
                "Body not found: nope"
            ),
            (
                "no input",
                await AssemblyTools.inspectAssembly(store: store),
                "requires either bodyId or inputPath"
            ),
            (
                "bad extension",
                await AssemblyTools.inspectAssembly(inputPath: txt),
                "Unsupported extension 'txt'"
            ),
        ]
        #expect(cases.count == 5)
        for c in cases {
            #expect(c.result.text.contains(c.text), "\(c.label): \(c.result.text)")
            #expect(c.result.isError, "\(c.label)")
        }
        #expect(try bytes(store) == before)
    }

    @Test("set_assembly_metadata: missing file, bad extension, component scope without a usable id")
    func metadataErrors() async throws {
        let dir = NSTemporaryDirectory() + "occtmcp-assembly-meta-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let txt = "\(dir)/notes.txt"
        try "x".write(toFile: txt, atomically: true, encoding: .utf8)

        // A real STEP document so the component-scope checks are reached. (The tool's `.xbf`
        // branch calls `Document.load`, which reads STEP, so an `.xbf` input cannot get there.)
        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        let doc = try #require(Document.create())
        _ = doc.addShape(box)
        let xbf = "\(dir)/in.step"
        try doc.writeSTEP(to: URL(fileURLWithPath: xbf), progress: nil)
        let out = "\(dir)/out.xbf"
        let meta = AssemblyTools.AssemblyMetadata(title: "t")

        let cases: [(label: String, result: ToolText, text: String)] = [
            (
                "missing file",
                await AssemblyTools.setAssemblyMetadata(
                    inputPath: "\(dir)/nope.step", outputPath: out, metadata: meta),
                "File not found"
            ),
            (
                "bad extension",
                await AssemblyTools.setAssemblyMetadata(
                    inputPath: txt, outputPath: out, metadata: meta),
                "Unsupported extension '.txt'"
            ),
            (
                "component without id",
                await AssemblyTools.setAssemblyMetadata(
                    inputPath: xbf, outputPath: out, scope: .component, metadata: meta),
                "componentId is required"
            ),
            (
                "component with unknown id",
                await AssemblyTools.setAssemblyMetadata(
                    inputPath: xbf, outputPath: out, scope: .component, componentId: 987_654,
                    metadata: meta),
                "No component with labelId 987654"
            ),
        ]
        #expect(cases.count == 4)
        for c in cases {
            #expect(c.result.text.contains(c.text), "\(c.label): \(c.result.text)")
            #expect(c.result.isError, "\(c.label)")
        }
        #expect(!FileManager.default.fileExists(atPath: out))
    }
}
