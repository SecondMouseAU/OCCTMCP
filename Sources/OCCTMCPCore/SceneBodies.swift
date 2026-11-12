// The scene operations an embedding host's `ExtraTool` handler needs: put a shape into the scene,
// and find a scene body again by its id. `read_brep` and `import_file` add their bodies through
// `SceneBodies.add`, so a handler and a built-in tool take the same path: a staged file, the
// manifest lock, a history snapshot, and the write observers.

import Foundation
import OCCTSwift
import ScriptHarness

/// Why a body could not be added to the scene.
public enum SceneBodiesError: Error, CustomStringConvertible, Equatable {
    /// The body id is empty, starts with a dot, or contains a path separator.
    case invalidBodyId(String)
    /// The shape could not be written as BREP.
    case writeFailed(underlying: String)
    /// The scene directory does not exist and could not be created.
    case cannotCreateSceneDirectory(path: String, underlying: String)
    /// Another body already has this file name, so writing it would overwrite that body's file.
    case fileInUse(file: String, bodyId: String?)

    public var description: String {
        switch self {
        case .invalidBodyId(let id):
            return
                "Invalid body id \"\(id)\": it names the body's file, so it must not be empty, "
                + "start with a dot, or contain \"/\"."
        case .writeFailed(let underlying):
            return "Failed to write BREP: \(underlying)"
        case .cannotCreateSceneDirectory(let path, let underlying):
            return "Cannot create the scene directory \(path): \(underlying)"
        case .fileInUse(let file, let bodyId):
            let owner = bodyId.map { "body \"\($0)\"" } ?? "another body"
            return
                "\(file) is already the file of \(owner), so it was not overwritten. "
                + "Choose a different body id."
        }
    }
}

extension SceneBodiesError: LocalizedError {
    public var errorDescription: String? { description }
}

/// Add shapes to the scene and resolve scene bodies by id, the way the built-in tools do.
///
/// Every call resolves the scene directory from the task it runs on, so it must run on the tool
/// call's own task: inside an `ExtraTool` handler, or in a child task of one. `Task.detached`
/// drops the scene directory the host passed to `makeOCCTMCPServer(outputDirectory:)`.
public enum SceneBodies {

    /// Write `shape` into the scene as a BREP body and return the id it was given.
    ///
    /// The file is written beside the manifest and moved into place under the manifest lock, so a
    /// concurrent writer that took the id first never has its body file overwritten. The
    /// manifest write reaches the host's `manifestWriteObserver`, and the manifest it replaced is
    /// pushed onto `SceneHistory` once the write succeeds, so `compare_versions` can diff against it.
    ///
    /// ```swift
    /// let id = try await SceneBodies.add(shape: solid, idPrefix: "profile", color: [0.8, 0.2, 0.2, 1])
    /// // `id` is "profile", or "profile_1" if that id was taken; later tools take it as `bodyId`.
    /// ```
    ///
    /// It does not check that the shape has an extent; check `shape.bounds` first when the tool
    /// reports one.
    ///
    /// - Parameters:
    ///   - shape: The shape to write.
    ///   - bodyId: The id to use. Throws `ManifestError.bodyIdTaken` when the scene already has it.
    ///     When nil, the first free id of `idPrefix`, `idPrefix_1`, `idPrefix_2` and so on.
    ///   - idPrefix: The id stem used when `bodyId` is nil.
    ///   - color: The body's `[r, g, b, a]` colour, or nil to leave it to the viewer's default.
    ///   - allowInvalid: Write a shape that fails validation, as a mesh shell does.
    ///   - description: The manifest description when the scene has none yet.
    ///   - store: The manifest to add to. The default is the scene of the current tool call.
    ///   - history: The history to snapshot into. The default is the current scene's.
    /// - Returns: The id the body was given.
    /// - Throws: `SceneBodiesError` for an unusable id, a file name another body already has
    ///   (compared without regard to case, since the scene may sit on a case-insensitive volume), an
    ///   uncreatable scene directory or a failed write; a `ManifestError` for a taken id, a malformed
    ///   manifest, a lock failure or a lock timeout; and whatever a vetoing `manifestWriteObserver`
    ///   throws.
    @discardableResult
    public static func add(
        shape: Shape,
        bodyId: String? = nil,
        idPrefix: String = "body",
        color: [Float]? = nil,
        allowInvalid: Bool = false,
        description: String? = nil,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async throws -> String {
        let fallbackDescription = description ?? "Added by an embedding host"
        // The prefix is the stem of every generated id, so it must be usable as one.
        let requested = bodyId ?? idPrefix
        guard !requested.isEmpty, !requested.hasPrefix("."), !requested.contains("/") else {
            throw SceneBodiesError.invalidBodyId(requested)
        }
        // Fail before anything is written: a malformed manifest, or an id already in the scene.
        let existing = try store.requireSceneOrAbsent()
        if let bodyId, existing?.bodies.contains(where: { $0.id == bodyId }) == true {
            throw ManifestError.bodyIdTaken(bodyId)
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: outputDir, withIntermediateDirectories: true)
        } catch {
            throw SceneBodiesError.cannotCreateSceneDirectory(
                path: outputDir, underlying: error.localizedDescription)
        }
        // The staged file is named for nothing but itself: a generated id is only chosen under
        // the lock, where it cannot collide with a concurrent add.
        let stagedPath = "\(outputDir)/.\(UUID().uuidString).partial"
        defer { try? FileManager.default.removeItem(atPath: stagedPath) }
        do {
            try Exporter.writeBREP(
                shape: shape, to: URL(fileURLWithPath: stagedPath), allowInvalid: allowInvalid)
        } catch {
            throw SceneBodiesError.writeFailed(underlying: error.localizedDescription)
        }

        var publishedPath: String?
        var assignedId = ""
        var replaced: ScriptManifest?
        do {
            try store.update { current in
                replaced = current
                let base = current ?? ScriptManifest(description: fallbackDescription, bodies: [])
                let id = bodyId ?? uniqueId(prefix: idPrefix, in: base)
                if base.bodies.contains(where: { $0.id == id }) {
                    throw ManifestError.bodyIdTaken(id)
                }
                let file = "\(id).brep"
                if let owner = base.bodies.first(where: { sameFile($0.file, file) }) {
                    throw SceneBodiesError.fileInUse(file: file, bodyId: owner.id)
                }
                try publishStaged(stagedPath, as: "\(outputDir)/\(file)")
                publishedPath = "\(outputDir)/\(file)"
                assignedId = id
                return base.replacing(
                    bodies: base.bodies + [BodyDescriptor(id: id, file: file, color: color)],
                    description: base.description ?? fallbackDescription)
            }
        } catch {
            if let publishedPath { try? FileManager.default.removeItem(atPath: publishedPath) }
            throw error
        }
        // Only a write that succeeded is history; a lost race or a vetoed write leaves it alone.
        if let replaced { await history.record(replaced) }
        return assignedId
    }

    /// The manifest entry of the body with this id.
    ///
    /// - Throws: `IntrospectionTools.ToolError` when there is no scene, no such body, or the body's
    ///   file is missing.
    public static func body(
        withId id: String, store: ManifestStore = ManifestStore()
    ) throws -> BodyDescriptor {
        try IntrospectionTools.resolveBody(bodyId: id, store: store).body
    }

    /// The shape of the body with this id, read the way a built-in reading tool reads it.
    ///
    /// The embedding host's own shape when `bodyShapeProvider` supplies one, else the body's file
    /// read by the `format` its manifest entry names; each call without a provider parses the file
    /// afresh. That is right for geometry (measure it, compute from it). It is not how to resolve a
    /// `selectionId` or a `GraphUID`: those resolve through the retained lineage graph, and a
    /// freshly parsed shape is not a node of it. A host that holds the shape its picks index into
    /// returns it from `bodyShapeProvider`, and a handler then reads that same shape here.
    ///
    /// - Throws: `IntrospectionTools.ToolError` as for `body(withId:)`, or `BodyLoadError` when the
    ///   file cannot be read.
    public static func shape(
        ofBody id: String, store: ManifestStore = ManifestStore()
    ) throws -> Shape {
        try IntrospectionTools.loadShape(bodyId: id, store: store).shape
    }

    /// The first of `prefix`, `prefix_1`, `prefix_2` and so on that no body in `manifest` has as its
    /// id or as the stem of its file.
    private static func uniqueId(prefix: String, in manifest: ScriptManifest) -> String {
        var i = 0
        while true {
            let candidate = i == 0 ? prefix : "\(prefix)_\(i)"
            let taken = manifest.bodies.contains {
                $0.id == candidate || sameFile($0.file, "\(candidate).brep")
            }
            if !taken { return candidate }
            i += 1
        }
    }

    /// Whether two manifest file names are one file, allowing for a case-insensitive volume.
    private static func sameFile(_ a: String, _ b: String) -> Bool {
        a.lowercased() == b.lowercased()
    }

    /// Move a staged file to `final`, replacing whatever is there.
    private static func publishStaged(_ staged: String, as final: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: final) { try fm.removeItem(atPath: final) }
        try fm.moveItem(atPath: staged, toPath: final)
    }
}
