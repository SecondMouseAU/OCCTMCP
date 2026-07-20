// SceneTools — pure-manifest scene-mutation tools (Phase 1 in the Node
// implementation). Each one reads the manifest, mutates an in-memory
// copy, snapshots the prior state into SceneHistory, and writes the
// manifest back. OCCTSwiftViewport's ScriptWatcher reloads on the file
// write — that's the side effect that makes the live preview update.

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
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        await history.snapshot(store: store)

        guard let target = manifest.body(withId: bodyId) else {
            return .init("Body not found: \(bodyId)")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let bodyFile = "\(outputDir)/\(target.file)"

        let updated = ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description,
            bodies: manifest.bodies.filter { $0.id != bodyId },
            graphs: manifest.graphs,
            metadata: manifest.metadata
        )
        do {
            try store.write(updated)
        } catch {
            return .init("Failed to write manifest: \(error.localizedDescription)", isError: true)
        }
        try? FileManager.default.removeItem(atPath: bodyFile)
        return .init(
            "Removed body \"\(bodyId)\" (file: \(target.file)). Remaining: \(updated.bodies.count)."
        )
    }

    // ── clear_scene ────────────────────────────────────────────────────────

    public static func clearScene(
        keepHistory: Bool = false,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        await history.snapshot(store: store)

        let outputDir = (store.path as NSString).deletingLastPathComponent
        let removedCount = manifest.bodies.count
        let filesToRemove = manifest.bodies.map { "\(outputDir)/\($0.file)" }

        let updated = ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: "(cleared)",
            bodies: [],
            graphs: manifest.graphs,
            metadata: manifest.metadata
        )
        do {
            try store.write(updated)
        } catch {
            return .init("Failed to write manifest: \(error.localizedDescription)", isError: true)
        }
        for path in filesToRemove {
            try? FileManager.default.removeItem(atPath: path)
        }
        if !keepHistory {
            await history.clear()
        }
        return .init(
            "Cleared \(removedCount) bodies from scene." + (keepHistory ? "" : " History reset.")
        )
    }

    // ── rename_body ────────────────────────────────────────────────────────

    public static func renameBody(
        bodyId: String,
        newBodyId: String,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        await history.snapshot(store: store)

        guard let target = manifest.body(withId: bodyId) else {
            return .init("Body not found: \(bodyId)")
        }
        if manifest.bodies.contains(where: { $0.id == newBodyId }) {
            return .init("Cannot rename: a body with id \"\(newBodyId)\" already exists.")
        }

        let updatedBodies = manifest.bodies.map { body -> BodyDescriptor in
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
        }
        let updated = ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description,
            bodies: updatedBodies,
            graphs: manifest.graphs,
            metadata: manifest.metadata
        )
        do {
            try store.write(updated)
        } catch {
            return .init("Failed to write manifest: \(error.localizedDescription)", isError: true)
        }
        _ = target
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
                "No appearance fields provided. Pass at least one of: color, opacity, roughness, metallic, name."
            )
        }
        if let c = update.color, c.count != 3 && c.count != 4 {
            return .init("color must be [r,g,b] or [r,g,b,a]; got length \(c.count).")
        }
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        await history.snapshot(store: store)

        guard let target = manifest.body(withId: bodyId) else {
            return .init("Body not found: \(bodyId)")
        }

        var newColor = target.color
        var applied: [String: String] = [:]
        if let c = update.color {
            let alpha: Float = (c.count == 4) ? c[3] : (target.color?.count == 4 ? target.color![3] : 1)
            newColor = c.count == 3 ? [c[0], c[1], c[2], alpha] : c
            applied["color"] = "\(newColor!)"
        }
        if let o = update.opacity {
            var current = newColor ?? [0.7, 0.7, 0.7, 1]
            if current.count == 3 { current.append(1) }
            current[3] = o
            newColor = current
            applied["opacity"] = "\(o)"
        }
        let newRoughness = update.roughness ?? target.roughness
        if let r = update.roughness { applied["roughness"] = "\(r)" }
        let newMetallic = update.metallic ?? target.metallic
        if let m = update.metallic { applied["metallic"] = "\(m)" }
        let newName = update.name ?? target.name
        if let n = update.name { applied["name"] = n }

        let updatedBodies = manifest.bodies.map { body -> BodyDescriptor in
            guard body.id == bodyId else { return body }
            return BodyDescriptor(
                id: body.id,
                file: body.file,
                format: body.format,
                name: newName,
                color: newColor,
                roughness: newRoughness,
                metallic: newMetallic
            )
        }
        let updated = ScriptManifest(
            version: manifest.version,
            timestamp: Date(),
            description: manifest.description,
            bodies: updatedBodies,
            graphs: manifest.graphs,
            metadata: manifest.metadata
        )
        do {
            try store.write(updated)
        } catch {
            return .init("Failed to write manifest: \(error.localizedDescription)", isError: true)
        }
        let pretty = applied
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
        guard let current = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        let availableCount = await history.count()
        guard let prior = await history.snapshot(since: since) else {
            return .init(
                "Not enough history: requested \(since) runs back, only \(availableCount) snapshots available. Make at least \(since) state changes (execute_script or scene-mutation tools) before comparing."
            )
        }
        let diff = diffManifests(prev: prior, curr: current, since: since, available: availableCount)
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
