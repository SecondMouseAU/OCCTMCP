// ExecuteScriptStage: what happens to an `execute_script` run's output between the child process and
// the scene (#257). The script never writes into the scene directory. It writes into a stage
// directory of its own, outside the scene, named to the child as `OCCTSWIFT_OUTPUT_DIR`; only a run
// that finished cleanly is promoted, and a run that did not leaves the scene exactly as it was.

import Foundation
import ScriptHarness

extension ExecuteScriptTool {

    /// What a finished run left in its stage.
    enum StageOutcome {
        /// The run failed. The text says how, when that is more than the exit code.
        case failed(String?)
        /// The run exited cleanly and wrote no manifest, so it changed nothing.
        case noManifest
        /// A manifest that parses, and every file it lists.
        case staged(ScriptManifest)
    }

    /// What `promoteReplacing` did.
    struct Promotion {
        /// The scene's manifest as the swap saw it under the lock; nil when the scene had none.
        let previous: ScriptManifest?
        /// The housekeeping that failed without failing the run.
        let warnings: [String]
    }

    /// A new stage directory under the system temp directory, outside any scene.
    ///
    /// It is outside the scene so that nothing a script writes there can be mistaken for the
    /// scene's own files, and so a host promoting it can refuse a stage inside its scene.
    static func makeStageDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("occtmcp-stage", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The environment for the script child: the parent's, with the output directory set to `stage`.
    ///
    /// The variable is `OCCTSWIFT_OUTPUT_DIR`, the one `ScriptContext` reads. It is never
    /// `OCCTMCP_OUTPUT_DIR`, which names the scene and which the harness does not read: a child
    /// handed the scene under that name would write into it the day a harness honoured it.
    static func scriptEnvironment(
        stage: URL, base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment[ScriptContext.outputDirectoryEnvironmentKey] = stage.path
        return environment
    }

    // MARK: Reading a stage

    /// The message in the stage's failure marker, nil when there is none.
    static func failureMarker(in stage: URL) -> String? {
        let url = stage.appendingPathComponent(ManifestIO.failureMarkerFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = object["message"] as? String, !message.isEmpty
        {
            return message
        }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        return text.isEmpty ? "The script marked its run as failed." : text
    }

    /// Whether the run failed, wrote nothing, or left a usable stage.
    ///
    /// A non-zero exit fails it. So does a failure marker, even after an exit of zero: a script that
    /// catches its own errors reports them with `ctx.fail(_:)`. A manifest that does not parse, or
    /// that lists a file the run did not write, fails it too, so a half-written stage is never
    /// promoted.
    static func classify(_ run: RunResult, stage: URL) -> StageOutcome {
        let marker = failureMarker(in: stage)
        if run.exitCode != 0 { return .failed(marker) }
        if let marker { return .failed(marker) }

        let manifestURL = stage.appendingPathComponent(ManifestIO.manifestFilename)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return .noManifest }
        let manifest: ScriptManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(ScriptManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return .failed(
                "The script's manifest.json could not be read: \(error.localizedDescription)")
        }
        if let problem = stageProblem(manifest, stage: stage) { return .failed(problem) }
        return .staged(manifest)
    }

    /// Why a manifest cannot be promoted from `stage`, nil when it can.
    static func stageProblem(_ manifest: ScriptManifest, stage: URL) -> String? {
        let listed = manifest.bodies.map(\.file) + (manifest.graphs ?? []).map(\.file)
        for file in listed {
            guard isPlainFileName(file) else {
                return
                    "The script's manifest names \"\(file)\", which is not a plain file name "
                    + "inside its output directory."
            }
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: stage.appendingPathComponent(file).path, isDirectory: &isDirectory)
            guard exists, !isDirectory.boolValue else {
                return "The script's manifest lists \(file), which the run did not write."
            }
        }
        return nil
    }

    /// The files OCCTMCP keeps in the scene directory besides the manifest.
    ///
    /// A stage never replaces them: a script that writes one of these names into its output
    /// directory is not heard.
    static let sceneSidecars: Set<String> = [
        "annotations.json", "zones.json", "provenance.json", "manifest.lock",
    ]

    /// A name with no directory part, not hidden, and not one of the stage's own bookkeeping files.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name == (name as NSString).lastPathComponent && !name.hasPrefix(".")
            && name != ManifestIO.manifestFilename && name != ManifestIO.failureMarkerFilename
    }

    // MARK: Promoting a stage

    /// `file` with `runID` before its extension: `body-0.brep` becomes `body-0.1a2b3c4d.brep`.
    static func uniqueName(_ file: String, runID: String) -> String {
        let name = file as NSString
        let stem = name.deletingPathExtension
        let ext = name.pathExtension
        return ext.isEmpty ? "\(stem).\(runID)" : "\(stem).\(runID).\(ext)"
    }

    /// Replace the scene with the stage's output, the default promotion.
    ///
    /// A script's manifest has always meant "the scene as this script built it", so the stage's
    /// bodies and graphs become the scene's, and the files the previous manifest listed are removed
    /// once the new manifest is in place. Files the new manifest lists are copied in under names
    /// that no earlier file has, before the manifest is swapped under `ManifestStore.update`, so
    /// the scene the old manifest describes is whole until the swap and a failure before it leaves
    /// the scene as it was. Unlisted artefacts of the run (`output.step`, a graph's `.sqlite`)
    /// replace their namesakes. Other files in the scene, sidecars included, are not touched.
    ///
    /// - Returns: the manifest the swap replaced, and warnings for the parts that are best effort.
    static func promoteReplacing(
        stage: URL, manifest staged: ScriptManifest, store: ManifestStore
    ) async throws -> Promotion {
        let fm = FileManager.default
        let sceneDirectory = (store.path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: sceneDirectory, withIntermediateDirectories: true)
        let runID = String(UUID().uuidString.prefix(8)).lowercased()

        // stage file name -> the name it takes in the scene
        var renamed: [String: String] = [:]
        func sceneName(_ file: String) -> String {
            if let name = renamed[file] { return name }
            let name = uniqueName(file, runID: runID)
            renamed[file] = name
            return name
        }
        let bodies = staged.bodies.map {
            BodyDescriptor(
                id: $0.id, file: sceneName($0.file), format: $0.format, name: $0.name,
                color: $0.color, roughness: $0.roughness, metallic: $0.metallic)
        }
        let graphs = staged.graphs?.map {
            GraphDescriptor(
                id: $0.id, file: sceneName($0.file), sourceBodyId: $0.sourceBodyId,
                stats: $0.stats)
        }
        // A graph's SQLite export sits beside its JSON and is not listed.
        for graph in staged.graphs ?? [] {
            let companion = ((graph.file as NSString).deletingPathExtension) + ".sqlite"
            if fm.fileExists(atPath: stage.appendingPathComponent(companion).path) {
                _ = sceneName(companion)
            }
        }

        var copied: [String] = []
        func discardCopies() {
            for path in copied { try? fm.removeItem(atPath: path) }
        }
        do {
            for (file, name) in renamed {
                let destination = "\(sceneDirectory)/\(name)"
                try fm.copyItem(
                    atPath: stage.appendingPathComponent(file).path, toPath: destination)
                copied.append(destination)
            }
        } catch {
            discardCopies()
            throw error
        }

        var previous: ScriptManifest?
        do {
            try store.update { current in
                previous = current
                return ScriptManifest(
                    version: staged.version, timestamp: staged.timestamp,
                    description: staged.description, bodies: bodies, graphs: graphs,
                    metadata: staged.metadata)
            }
        } catch {
            discardCopies()
            throw error
        }

        // The scene is replaced. What remains is housekeeping, and none of it fails the run.
        var warnings: [String] = []
        let contents = (try? fm.contentsOfDirectory(atPath: stage.path)) ?? []
        for name in contents where isPlainFileName(name) && renamed[name] == nil {
            if sceneSidecars.contains(name) {
                warnings.append(
                    "The script wrote \(name) into its output directory; the scene keeps its own.")
                continue
            }
            var isDirectory: ObjCBool = false
            guard
                fm.fileExists(
                    atPath: stage.appendingPathComponent(name).path, isDirectory: &isDirectory),
                !isDirectory.boolValue
            else { continue }
            let destination = "\(sceneDirectory)/\(name)"
            do {
                if fm.fileExists(atPath: destination) { try fm.removeItem(atPath: destination) }
                try fm.copyItem(
                    atPath: stage.appendingPathComponent(name).path, toPath: destination)
            } catch {
                warnings.append(
                    "Could not copy \(name) into the scene: \(error.localizedDescription)")
            }
        }
        let previousFiles =
            (previous?.bodies.map(\.file) ?? [])
            + (previous?.graphs ?? []).flatMap { graph in
                [graph.file, ((graph.file as NSString).deletingPathExtension) + ".sqlite"]
            }
        for file in Set(previousFiles) where isPlainFileName(file) {
            try? fm.removeItem(atPath: "\(sceneDirectory)/\(file)")
        }
        do {
            try await ProvenanceStore.shared.clear(outputDir: sceneDirectory)
        } catch {
            warnings.append("Failed to clear provenance.json: \(error.localizedDescription)")
        }
        return Promotion(previous: previous, warnings: warnings)
    }
}
