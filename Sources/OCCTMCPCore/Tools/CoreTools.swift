// CoreTools: get_scene, get_script, export_model, get_api_reference.
// Pure file-system / process-state operations that don't need OCCTSwift.
//
// get_api_reference's `mcp_tools` category is supplied by Server.swift
// (it needs the live tool registry); the OCCT API categories will be
// regenerated from OCCTSwift sources in a follow-up: for v1 the tool
// returns a pointer to the OCCTSwift docs.

import Foundation
import ScriptHarness

/// Holds the source of the most recent script run in this MCP session.
/// Updated by the (yet-to-be-ported) execute_script handler in Phase 5.4.
public actor ScriptHistoryStore {
    public static let shared = ScriptHistoryStore()
    private var lastSource: String?
    public func set(_ source: String) { self.lastSource = source }
    public func get() -> String? { return lastSource }
}

public enum CoreTools {

    // ── get_scene ──────────────────────────────────────────────────────

    public static func getScene(
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard FileManager.default.fileExists(atPath: store.path) else {
            return .init("No scene loaded. Run execute_script first.")
        }
        guard let manifest = try? store.read() else {
            return .init("Failed to parse manifest at \(store.path).", isError: true)
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let files = (try? FileManager.default.contentsOfDirectory(atPath: outputDir)) ?? []
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let summary: String
        if let data = try? encoder.encode(manifest), let str = String(data: data, encoding: .utf8) {
            summary = str
        } else {
            summary = "{}"
        }
        return .init(
            "Current scene:\n\(summary)\n\nOutput files: \(files.sorted().joined(separator: ", "))")
    }

    // ── get_script ─────────────────────────────────────────────────────

    public static func getScript(history: ScriptHistoryStore = .shared) async -> ToolText {
        if let src = await history.get() {
            return .init(src)
        }
        return .init("No script has been executed in this session. Call execute_script first.")
    }

    // ── export_model ───────────────────────────────────────────────────

    public static func exportModel(
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: outputDir) else {
            return .init("No output directory found. Run execute_script first.")
        }
        let allFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDir)) ?? []
        let exts: Set<String> = [
            "step", "stp", "brep", "stl", "obj", "json", "iges", "igs", "gltf", "glb",
        ]
        let modelFiles =
            allFiles
            .filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
        if modelFiles.isEmpty {
            return .init("No model files found in output.")
        }
        let paths = modelFiles.map { "\(outputDir)/\($0)" }
        return .init("Exported model files:\n\(paths.joined(separator: "\n"))")
    }
}
