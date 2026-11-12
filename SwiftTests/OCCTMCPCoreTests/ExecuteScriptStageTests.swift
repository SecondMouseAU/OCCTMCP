// execute_script writes into a stage, not the scene (#257): the child is handed a stage directory
// outside the scene, a clean run's output replaces the scene through the manifest lock, and a run
// that failed, left a failure marker, wrote nothing usable or was vetoed leaves the scene as it was.
// A fake script stands in for the SwiftPM workspace: it writes into the stage the way `ScriptContext`
// does, so none of these tests compiles anything or touches the script workspace.

import Foundation
import MCP
@testable import OCCTMCPCore
import OCCTSwift
import ScriptHarness
import Testing

@Suite("execute_script stage", .serialized)
struct ExecuteScriptStageTests {

    /// A scene directory inside its own root, so a file that escapes the scene lands where a test
    /// can look for it and `cleanUp` removes it.
    struct Scene {
        let root: URL
        let dir: URL
        let store: ManifestStore

        var manifestBytes: Data {
            (try? Data(contentsOf: URL(fileURLWithPath: store.path))) ?? Data()
        }
        var files: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        }
    }

    func makeScene(bodies: [String] = []) throws -> Scene {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("occtmcp-stage-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("scene")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: dir.appendingPathComponent("manifest.json").path)
        let scene = Scene(root: root, dir: dir, store: store)
        if !bodies.isEmpty {
            let box = try #require(Shape.box(width: 5, height: 5, depth: 5))
            var descriptors: [BodyDescriptor] = []
            for (index, id) in bodies.enumerated() {
                let file = "body-\(index).brep"
                try Exporter.writeBREP(shape: box, to: dir.appendingPathComponent(file))
                descriptors.append(BodyDescriptor(id: id, file: file))
            }
            try store.write(
                ScriptManifest(
                    version: 1, timestamp: Date(), description: "before", bodies: descriptors))
            // A sidecar and a stray file the script knows nothing about.
            try Data("{\"dimensions\":[]}".utf8).write(
                to: dir.appendingPathComponent("annotations.json"))
            try Data("keep me".utf8).write(to: dir.appendingPathComponent("note.txt"))
        }
        return scene
    }

    func cleanUp(_ scene: Scene) { try? FileManager.default.removeItem(at: scene.root) }

    /// What a script's `ctx.add` and `ctx.emit` leave in the stage.
    func emit(
        _ ids: [String], to stage: URL, description: String? = "after", step: Bool = true
    ) throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        var descriptors: [BodyDescriptor] = []
        for (index, id) in ids.enumerated() {
            let file = "body-\(index).brep"
            try Exporter.writeBREP(shape: box, to: stage.appendingPathComponent(file))
            descriptors.append(BodyDescriptor(id: id, file: file, color: [1, 0, 0, 1]))
        }
        if step {
            try Data("ISO-10303-21;".utf8).write(to: stage.appendingPathComponent("output.step"))
        }
        try ManifestIO.write(
            ScriptManifest(description: description, bodies: descriptors),
            to: stage.appendingPathComponent(ManifestIO.manifestFilename))
    }

    func run(
        _ scene: Scene,
        promoter: ScriptStagePromoter? = nil,
        sceneHistory: SceneHistory = SceneHistory(),
        _ script: @escaping @Sendable (URL) throws -> Int32
    ) async -> ToolText {
        await ExecuteScriptTool.executeStaged(
            code: "// a script", description: nil, history: ScriptHistoryStore(),
            store: scene.store, sceneHistory: sceneHistory, promoter: promoter,
            runner: { _, stage in
                let code = try script(stage)
                return .init(stdout: "script output", stderr: "", exitCode: code)
            })
    }

    func manifest(_ scene: Scene) throws -> ScriptManifest {
        try #require(try scene.store.read())
    }

    // ── what the child is told ──────────────────────────────────────────

    @Test("the child writes to a stage outside the scene, named by OCCTSWIFT_OUTPUT_DIR")
    func childIsGivenAStage() async throws {
        let scene = try makeScene(bodies: ["old"])
        defer { cleanUp(scene) }
        let seen = StageLog()
        let before = (files: scene.files, manifest: scene.manifestBytes)
        let result = await run(scene) { stage in
            seen.record(stage)
            try emit(["new"], to: stage)
            // The script has written everything it will: the scene has not been touched.
            #expect(scene.files == before.files, "the scene directory changed while the script ran")
            #expect(scene.manifestBytes == before.manifest, "the scene manifest changed mid-run")
            return 0
        }
        #expect(!result.isError, "\(result.text)")
        let stage = try #require(seen.stage)
        #expect(!stage.path.hasPrefix(scene.dir.path), "the stage is inside the scene")
        #expect(stage.path != scene.dir.path)
        #expect(!FileManager.default.fileExists(atPath: stage.path), "the stage was not removed")

        let environment = ExecuteScriptTool.scriptEnvironment(stage: stage, base: [:])
        #expect(environment[ScriptContext.outputDirectoryEnvironmentKey] == stage.path)
        #expect(
            environment["OCCTMCP_OUTPUT_DIR"] == nil, "the scene must not be exported to the child")
        // An inherited scene variable is not turned into the stage's.
        let inherited = ExecuteScriptTool.scriptEnvironment(
            stage: stage,
            base: ["OCCTMCP_OUTPUT_DIR": scene.dir.path, "OCCTSWIFT_OUTPUT_DIR": "/elsewhere"])
        #expect(inherited["OCCTSWIFT_OUTPUT_DIR"] == stage.path)
    }

    @Test("the workspace's Scripts floor is the root package's, which carries the stage directory")
    func scriptsPinTracksPackageSwift() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        let line = try #require(
            package.split(separator: "\n").first { $0.contains("occtDep(\"OCCTSwiftScripts\"") })
        let pinned = try #require(
            line.split(separator: "\"").dropFirst(3).first.map(String.init), "no floor in \(line)")
        #expect(ExecuteScriptTool.scriptsPin == pinned)
        // The first release with OCCTSWIFT_OUTPUT_DIR and run-failed.json (OCCTSwiftScripts#145).
        #expect(
            ExecuteScriptTool.scriptsPin.compare("1.7.1-beta.4", options: .numeric)
                != .orderedAscending,
            "\(ExecuteScriptTool.scriptsPin) predates the stage directory")
    }

    @Test(
        "the script workspace is under the home directory unless OCCTMCP_SCRIPT_WORKSPACE says otherwise"
    )
    func workspaceDirectoryOverride() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(
            ExecuteScriptTool.workspaceDirectory(environment: [:]).path
                == home.appendingPathComponent(".occtmcp-cache/workspace").path)
        #expect(
            ExecuteScriptTool.workspaceDirectory(environment: ["OCCTMCP_SCRIPT_WORKSPACE": ""]).path
                == home.appendingPathComponent(".occtmcp-cache/workspace").path,
            "an empty override is no override")
        #expect(
            ExecuteScriptTool.workspaceDirectory(
                environment: ["OCCTMCP_SCRIPT_WORKSPACE": "/var/tmp/scripts-ws"]
            ).path == "/var/tmp/scripts-ws")
    }

    // ── a clean run ─────────────────────────────────────────────────────

    @Test("a clean run replaces the scene's bodies and leaves its sidecars alone")
    func cleanRunReplacesTheScene() async throws {
        let scene = try makeScene(bodies: ["old-a", "old-b"])
        defer { cleanUp(scene) }
        let history = SceneHistory()
        let result = await run(scene, sceneHistory: history) { stage in
            try emit(["new-a"], to: stage)
            return 0
        }
        try #require(!result.isError, "\(result.text)")
        #expect(result.text.contains("Script executed successfully."))
        #expect(result.text.contains("new-a"), "the result echoes the new manifest")

        let after = try manifest(scene)
        #expect(after.bodies.compactMap(\.id) == ["new-a"])
        #expect(after.description == "after")
        let body = try #require(after.bodies.first)
        #expect(body.color == [1, 0, 0, 1])
        // The body file keeps its stem and gains the run id, so no earlier file is overwritten.
        #expect(body.file != "body-0.brep")
        #expect(body.file.hasPrefix("body-0.") && body.file.hasSuffix(".brep"), "\(body.file)")
        let shape = try Shape.loadBREP(
            fromPath: scene.dir.appendingPathComponent(body.file).path)
        #expect(abs((shape.volume ?? 0) - 6000) < 1e-6)

        // The old scene's files are gone; the sidecar and the stray file are not.
        #expect(!scene.files.contains("body-0.brep") && !scene.files.contains("body-1.brep"))
        #expect(scene.files.contains("annotations.json") && scene.files.contains("note.txt"))
        #expect(scene.files.contains("output.step"), "an unlisted artefact of the run is promoted")
        #expect(await history.count() == 1, "the prior scene is pushed onto the history")
        let previous = try #require(await history.snapshot(since: 1))
        #expect(previous.bodies.compactMap(\.id) == ["old-a", "old-b"])
    }

    @Test("a first run into an empty scene directory creates the scene")
    func firstRunCreatesTheScene() async throws {
        let scene = try makeScene()
        defer { cleanUp(scene) }
        let result = await run(scene) { stage in
            try emit(["first"], to: stage)
            return 0
        }
        try #require(!result.isError, "\(result.text)")
        #expect(try manifest(scene).bodies.compactMap(\.id) == ["first"])
    }

    @Test("a second clean run removes the first run's files rather than piling them up")
    func secondRunCleansUp() async throws {
        let scene = try makeScene()
        defer { cleanUp(scene) }
        for ids in [["one", "two"], ["three"]] {
            let result = await run(scene) { stage in
                try emit(ids, to: stage)
                return 0
            }
            try #require(!result.isError, "\(result.text)")
        }
        let brep = scene.files.filter { $0.hasSuffix(".brep") }
        #expect(brep.count == 1, "left \(brep)")
        #expect(try manifest(scene).bodies.map(\.file) == brep)
    }

    @Test("a graph and its SQLite export are promoted under one new name and replaced together")
    func graphsAreRenamedWithTheirSQLite() async throws {
        let scene = try makeScene()
        defer { cleanUp(scene) }
        let script: @Sendable (URL) throws -> Int32 = { stage in
            try emit(["body"], to: stage, step: false)
            try Data("{}".utf8).write(to: stage.appendingPathComponent("graph-0.json"))
            try Data("sqlite".utf8).write(to: stage.appendingPathComponent("graph-0.sqlite"))
            let body = try #require(
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: stage.appendingPathComponent("manifest.json")))
                    as? [String: Any])
            var edited = body
            edited["graphs"] = [["id": "graph-0", "file": "graph-0.json", "sourceBodyId": "body"]]
            try JSONSerialization.data(withJSONObject: edited).write(
                to: stage.appendingPathComponent("manifest.json"))
            return 0
        }
        for _ in 0..<2 {
            let result = await run(scene, script)
            try #require(!result.isError, "\(result.text)")
        }
        let graph = try #require(try manifest(scene).graphs?.first)
        #expect(graph.file.hasPrefix("graph-0.") && graph.file.hasSuffix(".json"), "\(graph.file)")
        let companion = (graph.file as NSString).deletingPathExtension + ".sqlite"
        #expect(
            scene.files.contains(graph.file) && scene.files.contains(companion), "\(scene.files)")
        #expect(scene.files.filter { $0.hasPrefix("graph-0.") }.count == 2, "\(scene.files)")
    }

    // ── a run that must not change the scene ────────────────────────────

    /// Run `script` against a scene with two bodies and require that nothing about the scene moved.
    func requireSceneUntouched(
        expecting needle: String? = nil, isError: Bool,
        _ script: @escaping @Sendable (URL) throws -> Int32
    ) async throws {
        let scene = try makeScene(bodies: ["old-a", "old-b"])
        defer { cleanUp(scene) }
        let history = SceneHistory()
        let before = (files: scene.files, manifest: scene.manifestBytes)
        let bodies = try scene.files.filter { $0.hasSuffix(".brep") }.map {
            try Data(contentsOf: scene.dir.appendingPathComponent($0))
        }
        let result = await run(scene, sceneHistory: history, script)
        #expect(result.isError == isError, "\(result.text)")
        if let needle { #expect(result.text.contains(needle), "\(result.text)") }
        #expect(scene.files == before.files, "the scene's files changed")
        #expect(scene.manifestBytes == before.manifest, "the scene's manifest changed")
        let after = try scene.files.filter { $0.hasSuffix(".brep") }.map {
            try Data(contentsOf: scene.dir.appendingPathComponent($0))
        }
        #expect(after == bodies, "a body file changed")
        #expect(await history.count() == 0, "a run that changed nothing pushed history")
    }

    @Test("a script that exits non-zero fails and leaves the scene as it was")
    func nonZeroExit() async throws {
        try await requireSceneUntouched(expecting: "The scene was left as it was.", isError: true) {
            stage in
            // It got as far as writing a manifest.
            try emit(["half"], to: stage)
            return 1
        }
    }

    @Test("a failure marker fails a run that exited zero, and its message reaches the agent")
    func failureMarker() async throws {
        try await requireSceneUntouched(
            expecting: "Reason: the profile did not close", isError: true
        ) {
            stage in
            try emit(["new"], to: stage)
            try ManifestIO.writeFailureMarker(message: "the profile did not close", in: stage)
            return 0
        }
    }

    @Test("a run that writes no manifest changes nothing and says why")
    func noManifest() async throws {
        try await requireSceneUntouched(expecting: "never called ctx.emit()", isError: false) { _ in
            0
        }
    }

    @Test("a manifest that cannot be read fails the run")
    func unreadableManifest() async throws {
        try await requireSceneUntouched(expecting: "could not be read", isError: true) { stage in
            try Data("{ not json".utf8).write(to: stage.appendingPathComponent("manifest.json"))
            return 0
        }
    }

    @Test("a manifest that lists a file the run did not write fails the run")
    func missingBodyFile() async throws {
        try await requireSceneUntouched(expecting: "which the run did not write", isError: true) {
            stage in
            try emit(["new"], to: stage)
            try ManifestIO.write(
                ScriptManifest(
                    description: "x", bodies: [BodyDescriptor(id: "ghost", file: "body-9.brep")]),
                to: stage.appendingPathComponent("manifest.json"))
            return 0
        }
    }

    @Test("a manifest naming a file outside its stage is refused, and nothing escapes")
    func escapingNamesAreRefused() async throws {
        for bad in [
            "../escape.brep", "sub/body.brep", ".hidden.brep", "manifest.json", "/etc/passwd",
        ] {
            try await requireSceneUntouched(expecting: "plain file name", isError: true) { stage in
                try emit(["new"], to: stage)
                try ManifestIO.write(
                    ScriptManifest(
                        description: "x", bodies: [BodyDescriptor(id: "bad", file: bad)]),
                    to: stage.appendingPathComponent("manifest.json"))
                return 0
            }
        }
    }

    @Test("a manifest write that is vetoed leaves the scene as it was and no copy behind")
    func vetoedManifestWrite() async throws {
        struct Veto: Error {}
        let scene = try makeScene(bodies: ["old"])
        defer { cleanUp(scene) }
        let before = (files: scene.files, manifest: scene.manifestBytes)
        let veto: ManifestWriteObserver = { _, _ in throw Veto() }
        let result = await OCCTMCPContext.$manifestWriteObserver.withValue(veto) {
            await run(scene) { stage in
                try emit(["new"], to: stage, step: false)
                return 0
            }
        }
        #expect(result.isError, "\(result.text)")
        #expect(scene.files == before.files, "a promoted copy was left behind: \(scene.files)")
        #expect(scene.manifestBytes == before.manifest)
    }

    // ── a host that promotes ────────────────────────────────────────────

    @Test(
        "a host's promoter gets the stage and the scene directory, and the scene is its to change")
    func hostPromotes() async throws {
        let scene = try makeScene(bodies: ["old"])
        defer { cleanUp(scene) }
        let calls = StageLog()
        let before = (files: scene.files, manifest: scene.manifestBytes)
        let promoter: ScriptStagePromoter = { stage, sceneDirectory in
            // The stage is still there, with what the script wrote.
            let listed = try String(
                contentsOf: stage.appendingPathComponent("manifest.json"), encoding: .utf8)
            calls.record(stage, sceneDirectory: sceneDirectory, manifest: listed)
        }
        let result = await run(scene, promoter: promoter) { stage in
            try emit(["from-the-script"], to: stage)
            return 0
        }
        #expect(!result.isError, "\(result.text)")
        #expect(calls.count == 1)
        #expect(calls.sceneDirectory == scene.dir.path)
        #expect(calls.manifest?.contains("from-the-script") == true)
        // OCCTMCP did not promote: the scene is as the (here, doing-nothing) host left it.
        #expect(scene.files == before.files && scene.manifestBytes == before.manifest)
        let stage = try #require(calls.stage)
        #expect(!FileManager.default.fileExists(atPath: stage.path), "the stage outlived the call")
    }

    @Test("a host's promoter is not asked about a run that failed")
    func hostIsNotAskedAboutAFailedRun() async throws {
        let scene = try makeScene(bodies: ["old"])
        defer { cleanUp(scene) }
        let calls = StageLog()
        let promoter: ScriptStagePromoter = { stage, directory in
            calls.record(stage, sceneDirectory: directory, manifest: nil)
        }
        let result = await run(scene, promoter: promoter) { stage in
            try emit(["x"], to: stage)
            return 2
        }
        #expect(result.isError)
        #expect(calls.count == 0)
    }

    @Test("a promoter that throws is reported, and the stage is still removed")
    func failingPromoter() async throws {
        struct Refused: Error, CustomStringConvertible {
            var description: String { "inbox is full" }
        }
        let scene = try makeScene(bodies: ["old"])
        defer { cleanUp(scene) }
        let seen = StageLog()
        let promoter: ScriptStagePromoter = { _, _ in throw Refused() }
        let result = await run(scene, promoter: promoter) { stage in
            seen.record(stage)
            try emit(["x"], to: stage)
            return 0
        }
        #expect(result.isError)
        #expect(
            result.text.contains("promoting its output into the scene failed: inbox is full"),
            "\(result.text)")
        let stage = try #require(seen.stage)
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }

    /// Calls a host tool that runs the promoter its call can see, on a server built with `promoter`.
    ///
    /// A host tool runs inside the scope `makeOCCTMCPServer` opens for `execute_script`, so it sees
    /// what `execute_script` would use, without compiling a script. Returns the tool's reply.
    private func probePromoter(through promoter: ScriptStagePromoter?) async throws -> String {
        let probe = ExtraTool(
            tool: Tool(
                name: "probe_promoter", description: "runs the promoter this call can see",
                inputSchema: .object(["type": .string("object")])),
            handler: { _ in
                var reply = "none"
                if let seen = OCCTMCPContext.scriptStagePromoter {
                    try await seen(URL(fileURLWithPath: "/probe-stage"), "/probe-scene")
                    reply = "ran"
                }
                return .init(content: [.text(text: reply, annotations: nil, _meta: nil)])
            })
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = await makeOCCTMCPServer(extraTools: [probe], scriptStagePromoter: promoter)
        try await server.start(transport: serverTransport)
        let client = Client(name: "test", version: "1")
        _ = try await client.connect(transport: clientTransport)
        let (content, isError) = try await client.callTool(name: "probe_promoter", arguments: [:])
        #expect(isError != true)
        guard case .text(let text, _, _) = content.first else { return "no text" }
        return text
    }

    @Test("the promoter given to makeOCCTMCPServer is the one a call sees, and none means none")
    func promoterThroughTheServer() async throws {
        let log = StageLog()
        let promoter: ScriptStagePromoter = { stage, sceneDirectory in
            log.record(stage, sceneDirectory: sceneDirectory)
        }
        let withOne = try await probePromoter(through: promoter)
        #expect(withOne == "ran")
        #expect(log.count == 1, "the promoter handed to the factory is the one that ran")
        #expect(log.stage?.path == "/probe-stage")
        #expect(log.sceneDirectory == "/probe-scene")
        let without = try await probePromoter(through: nil)
        #expect(without == "none", "a server built without one installs none")
        #expect(log.count == 1)
    }
}

/// What a fake script or a promoter was called with.
private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [URL] = []
    private var directories: [String] = []
    private var manifests: [String] = []

    func record(_ stage: URL, sceneDirectory: String? = nil, manifest: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        stages.append(stage)
        if let sceneDirectory { directories.append(sceneDirectory) }
        if let manifest { manifests.append(manifest) }
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stages.count
    }
    var stage: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stages.last
    }
    var sceneDirectory: String? {
        lock.lock()
        defer { lock.unlock() }
        return directories.last
    }
    var manifest: String? {
        lock.lock()
        defer { lock.unlock() }
        return manifests.last
    }
}
