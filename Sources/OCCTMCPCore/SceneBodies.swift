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

    public var description: String {
        switch self {
        case .invalidBodyId(let id):
            return
                "Invalid body id \"\(id)\": it names the body's file, so it must not be empty, "
                + "start with a dot, or contain \"/\"."
        case .writeFailed(let underlying):
            return "Failed to write BREP: \(underlying)"
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
    /// manifest write reaches the host's `manifestWriteObserver`, and the previous manifest is
    /// pushed onto `SceneHistory` first, so `compare_versions` can diff against it.
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
    /// - Throws: `SceneBodiesError`, or a `ManifestError` for a taken id, a malformed manifest or a
    ///   lock timeout.
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
        let seed =
            try store.requireSceneOrAbsent()
            ?? ScriptManifest(description: fallbackDescription, bodies: [])
        if let bodyId, seed.bodies.contains(where: { $0.id == bodyId }) {
            throw ManifestError.bodyIdTaken(bodyId)
        }
        let id = bodyId ?? IOTools.uniqueBodyId(prefix: idPrefix, manifest: seed)
        guard !id.isEmpty, !id.hasPrefix("."), !id.contains("/") else {
            throw SceneBodiesError.invalidBodyId(id)
        }

        let outputDir = (store.path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true)
        let file = "\(id).brep"
        let finalPath = "\(outputDir)/\(file)"
        let stagedPath = "\(outputDir)/.\(id).\(UUID().uuidString).partial"
        do {
            try Exporter.writeBREP(
                shape: shape, to: URL(fileURLWithPath: stagedPath), allowInvalid: allowInvalid)
        } catch {
            throw SceneBodiesError.writeFailed(underlying: error.localizedDescription)
        }

        await history.snapshot(store: store)
        var published = false
        defer { try? FileManager.default.removeItem(atPath: stagedPath) }
        let body = BodyDescriptor(id: id, file: file, color: color)
        do {
            try store.update { current in
                let base = current ?? ScriptManifest(description: fallbackDescription, bodies: [])
                if base.bodies.contains(where: { $0.id == id }) {
                    throw ManifestError.bodyIdTaken(id)
                }
                try publishStaged(stagedPath, as: finalPath)
                published = true
                return base.replacing(
                    bodies: base.bodies + [body],
                    description: base.description ?? fallbackDescription)
            }
        } catch {
            if published { try? FileManager.default.removeItem(atPath: finalPath) }
            throw error
        }
        return id
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
    /// read by the `format` its manifest entry names. This is the shape a `selectionId` on the body
    /// indexes into, so a handler that measures or inspects a pick should read it here and not
    /// load the file itself.
    ///
    /// - Throws: `IntrospectionTools.ToolError` as for `body(withId:)`, or `BodyLoadError` when the
    ///   file cannot be read.
    public static func shape(
        ofBody id: String, store: ManifestStore = ManifestStore()
    ) throws -> Shape {
        try IntrospectionTools.loadShape(bodyId: id, store: store).shape
    }

    /// Move a staged file to `final`, replacing whatever is there.
    private static func publishStaged(_ staged: String, as final: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: final) { try fm.removeItem(atPath: final) }
        try fm.moveItem(atPath: staged, toPath: final)
    }
}
