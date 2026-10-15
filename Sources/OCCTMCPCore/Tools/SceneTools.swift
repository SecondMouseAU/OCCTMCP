// SceneTools: pure-manifest scene-mutation tools (Phase 1 in the Node
// implementation). Each one reads the manifest, mutates an in-memory
// copy, snapshots the prior state into SceneHistory, and writes the
// manifest back. OCCTSwiftViewport's ScriptWatcher reloads on the file
// write: that's the side effect that makes the live preview update.

import Foundation
import MCP
import ScriptHarness

/// Result envelope used by every scene tool.
public struct ToolText: Sendable {
    public let text: String
    public let isError: Bool
    public init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
    /// Result for a failed manifest load or `ManifestStore.update`.
    ///
    /// A `ManifestError` keeps its own message; any other error is a failed write.
    public static func manifestFailure(_ error: Error) -> ToolText {
        if let manifestError = error as? ManifestError {
            return .init(manifestError.localizedDescription, isError: true)
        }
        return .init("Failed to write manifest: \(error.localizedDescription)", isError: true)
    }

    public func asCallToolResult() -> CallTool.Result {
        return .init(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            isError: isError
        )
    }
}

public enum SceneTools {
    // ── remove_body ────────────────────────────────────────────────────────

    public static func removeBody(
        bodyId: String,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        let manifest: ScriptManifest
        do { manifest = try store.requireScene() } catch { return .manifestFailure(error) }
        await history.snapshot(store: store)

        guard let target = manifest.body(withId: bodyId) else {
            return .init("Body not found: \(bodyId)", isError: true)
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let bodyFile = "\(outputDir)/\(target.file)"

        let updated: ScriptManifest
        do {
            updated = try store.update { current in
                let current = try current.requiringScene()
                guard current.body(withId: bodyId) != nil else {
                    throw ManifestError.bodyNotFound(bodyId)
                }
                return current.replacing(bodies: current.bodies.filter { $0.id != bodyId })
            }
        } catch {
            return .manifestFailure(error)
        }
        try? FileManager.default.removeItem(atPath: bodyFile)
        // Best effort by design: the manifest write above is what removed the body, and a stale
        // provenance record for an absent body is harmless. Report it rather than fail (#236).
        var warning = ""
        do {
            try await ProvenanceStore.shared.remove(bodyId: bodyId, outputDir: outputDir)
        } catch {
            warning = " Warning: failed to update provenance.json: \(error.localizedDescription)"
        }
        return .init(
            "Removed body \"\(bodyId)\" (file: \(target.file)). Remaining: \(updated.bodies.count)."
                + warning
        )
    }

    // ── clear_scene ────────────────────────────────────────────────────────

    public static func clearScene(
        keepHistory: Bool = false,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        let manifest: ScriptManifest
        do { manifest = try store.requireScene() } catch { return .manifestFailure(error) }
        await history.snapshot(store: store)

        let outputDir = (store.path as NSString).deletingLastPathComponent
        var removedCount = 0
        var filesToRemove: [String] = []

        do {
            try store.update { current in
                let current = try current.requiringScene()
                removedCount = current.bodies.count
                filesToRemove = current.bodies.map { "\(outputDir)/\($0.file)" }
                return current.replacing(bodies: [], description: "(cleared)")
            }
        } catch {
            return .manifestFailure(error)
        }
        for path in filesToRemove {
            try? FileManager.default.removeItem(atPath: path)
        }
        // Best effort by design, as in remove_body: the scene is already cleared (#236).
        var warning = ""
        do {
            try await ProvenanceStore.shared.clear(outputDir: outputDir)
        } catch {
            warning = " Warning: failed to clear provenance.json: \(error.localizedDescription)"
        }
        if !keepHistory {
            await history.clear()
        }
        return .init(
            "Cleared \(removedCount) bodies from scene." + (keepHistory ? "" : " History reset.")
                + warning
        )
    }

    // ── rename_body ────────────────────────────────────────────────────────

    public static func renameBody(
        bodyId: String,
        newBodyId: String,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        let manifest: ScriptManifest
        do { manifest = try store.requireScene() } catch { return .manifestFailure(error) }
        await history.snapshot(store: store)

        guard manifest.body(withId: bodyId) != nil else {
            return .init("Body not found: \(bodyId)", isError: true)
        }
        if manifest.bodies.contains(where: { $0.id == newBodyId }) {
            return .init(
                "Cannot rename: a body with id \"\(newBodyId)\" already exists.", isError: true)
        }

        do {
            try store.update { current in
                let current = try current.requiringScene()
                guard current.body(withId: bodyId) != nil else {
                    throw ManifestError.bodyNotFound(bodyId)
                }
                if current.bodies.contains(where: { $0.id == newBodyId }) {
                    throw ManifestError.bodyIdTaken(newBodyId)
                }
                return current.replacing(
                    bodies: current.bodies.map { body -> BodyDescriptor in
                        guard body.id == bodyId else { return body }
                        return BodyDescriptor(
                            id: newBodyId,
                            file: body.file,
                            format: body.format,
                            name: body.name,
                            color: body.color,
                            roughness: body.roughness,
                            metallic: body.metallic
                        )
                    })
            }
        } catch {
            return .manifestFailure(error)
        }
        // Re-key the retained lineage (#93) so a body's history survives a
        // rename. selectionIds embed bodyId, so old selection strings
        // still go stale here (unchanged, documented behaviour); this
        // only keeps the GRAPH itself (and any future mutation chained
        // off it) alive under the new id.
        await HistoryRegistry.shared.rename(bodyId: bodyId, to: newBodyId)
        return .init("Renamed \"\(bodyId)\" → \"\(newBodyId)\".")
    }

    // ── set_appearance ─────────────────────────────────────────────────────

    public struct AppearanceUpdate {
        public var color: [Float]?
        public var opacity: Float?
        public var roughness: Float?
        public var metallic: Float?
        public var name: String?
        public init(
            color: [Float]? = nil,
            opacity: Float? = nil,
            roughness: Float? = nil,
            metallic: Float? = nil,
            name: String? = nil
        ) {
            self.color = color
            self.opacity = opacity
            self.roughness = roughness
            self.metallic = metallic
            self.name = name
        }
        var anyFieldSet: Bool {
            color != nil || opacity != nil || roughness != nil || metallic != nil || name != nil
        }
    }

    public static func setAppearance(
        bodyId: String,
        update: AppearanceUpdate,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        if !update.anyFieldSet {
            return .init(
                "No appearance fields provided. Pass at least one of: color, opacity, roughness, metallic, name.",
                isError: true
            )
        }
        if let c = update.color, c.count != 3 && c.count != 4 {
            return .init(
                "color must be [r,g,b] or [r,g,b,a]; got length \(c.count).", isError: true)
        }
        let manifest: ScriptManifest
        do { manifest = try store.requireScene() } catch { return .manifestFailure(error) }
        await history.snapshot(store: store)

        guard manifest.body(withId: bodyId) != nil else {
            return .init("Body not found: \(bodyId)", isError: true)
        }

        // Derived from the body as read under the lock, so a concurrent change to a field this
        // call does not set is kept.
        var applied: [String: String] = [:]
        if let o = update.opacity { applied["opacity"] = "\(o)" }
        if let r = update.roughness { applied["roughness"] = "\(r)" }
        if let m = update.metallic { applied["metallic"] = "\(m)" }
        if let n = update.name { applied["name"] = n }

        do {
            try store.update { current in
                let current = try current.requiringScene()
                guard let target = current.body(withId: bodyId) else {
                    throw ManifestError.bodyNotFound(bodyId)
                }
                var newColor = target.color
                if let c = update.color {
                    let alpha: Float =
                        (c.count == 4) ? c[3] : (target.color?.count == 4 ? target.color![3] : 1)
                    newColor = c.count == 3 ? [c[0], c[1], c[2], alpha] : c
                    applied["color"] = "\(newColor!)"
                }
                if let o = update.opacity {
                    var rgba = newColor ?? [0.7, 0.7, 0.7, 1]
                    if rgba.count == 3 { rgba.append(1) }
                    rgba[3] = o
                    newColor = rgba
                }
                return current.replacing(
                    bodies: current.bodies.map { body -> BodyDescriptor in
                        guard body.id == bodyId else { return body }
                        return BodyDescriptor(
                            id: body.id,
                            file: body.file,
                            format: body.format,
                            name: update.name ?? body.name,
                            color: newColor,
                            roughness: update.roughness ?? body.roughness,
                            metallic: update.metallic ?? body.metallic
                        )
                    })
            }
        } catch {
            return .manifestFailure(error)
        }
        let pretty =
            applied
            .sorted { $0.key < $1.key }
            .map { "  \($0.key): \($0.value)" }
            .joined(separator: "\n")
        return .init("Updated appearance of \"\(bodyId)\":\n\(pretty)")
    }

    // ── compare_versions ───────────────────────────────────────────────────

    public struct DiffReport: Encodable {
        public let since: Int
        public let available: Int
        public let added: [String]
        public let removed: [String]
        public let appearanceChanged: [AppearanceChange]
        public let fileChanged: [String]
        public let unchanged: [String]
    }
    public struct AppearanceChange: Encodable {
        public let id: String
        public let fields: [String]
    }

    public static func compareVersions(
        since: Int = 1,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        let current: ScriptManifest
        do { current = try store.requireScene() } catch { return .manifestFailure(error) }
        let availableCount = await history.count()
        guard let prior = await history.snapshot(since: since) else {
            return .init(
                "Not enough history: requested \(since) runs back, only \(availableCount) snapshots available. Make at least \(since) state changes (execute_script or scene-mutation tools) before comparing.",
                isError: true
            )
        }
        let diff = diffManifests(
            prev: prior, curr: current, since: since, available: availableCount)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(diff)
            return .init(String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            return .init("Failed to encode diff: \(error.localizedDescription)", isError: true)
        }
    }

    static func diffManifests(
        prev: ScriptManifest,
        curr: ScriptManifest,
        since: Int,
        available: Int
    ) -> DiffReport {
        func key(_ b: BodyDescriptor) -> String {
            return b.id ?? "__noid_\(b.file)"
        }
        let prevByKey = Dictionary(uniqueKeysWithValues: prev.bodies.map { (key($0), $0) })
        let currByKey = Dictionary(uniqueKeysWithValues: curr.bodies.map { (key($0), $0) })

        var added: [String] = []
        var removed: [String] = []
        var appearanceChanged: [AppearanceChange] = []
        var fileChanged: [String] = []
        var unchanged: [String] = []

        for (k, currBody) in currByKey {
            guard let prevBody = prevByKey[k] else {
                added.append(k)
                continue
            }
            var fields: [String] = []
            if currBody.color != prevBody.color { fields.append("color") }
            if currBody.name != prevBody.name { fields.append("name") }
            if currBody.roughness != prevBody.roughness { fields.append("roughness") }
            if currBody.metallic != prevBody.metallic { fields.append("metallic") }
            if currBody.file != prevBody.file {
                fileChanged.append(k)
            }
            if !fields.isEmpty {
                appearanceChanged.append(AppearanceChange(id: k, fields: fields))
            }
            if fields.isEmpty && currBody.file == prevBody.file {
                unchanged.append(k)
            }
        }
        for k in prevByKey.keys where currByKey[k] == nil {
            removed.append(k)
        }

        return DiffReport(
            since: since,
            available: available,
            added: added.sorted(),
            removed: removed.sorted(),
            appearanceChanged: appearanceChanged.sorted { $0.id < $1.id },
            fileChanged: fileChanged.sorted(),
            unchanged: unchanged.sorted()
        )
    }
}
