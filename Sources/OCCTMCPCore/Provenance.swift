// Provenance — `<output_dir>/provenance.json` sidecar that records how
// derived bodies were created from source bodies. Currently populated
// only by `mirror_or_pattern` so `find_correspondences` can default
// `transformHint` from the manifest when the LLM omits it.
//
// Format is a top-level object keyed by body id:
// {
//   "mirror-src": {
//     "sourceBodyId": "src",
//     "transform": { "kind": "mirror", "planeOrigin": [...], "planeNormal": [...] }
//   }
// }
//
// Sibling-not-substitute to the scene manifest. Manifest is owned by
// ScriptHarness and we don't want to fork its schema; provenance is a
// separate file that only OCCTMCP reads/writes.

import Foundation

public struct ProvenanceRecord: Codable, Sendable {
    public let sourceBodyId: String
    public let transform: CorrespondenceTools.TransformHint

    public init(sourceBodyId: String, transform: CorrespondenceTools.TransformHint) {
        self.sourceBodyId = sourceBodyId
        self.transform = transform
    }
}

public struct ProvenanceStore: Sendable {
    public let path: String

    public init(outputDir: String) {
        self.path = "\(outputDir)/provenance.json"
    }

    /// Whole-file read. Returns an empty dictionary when the sidecar
    /// doesn't exist yet — callers don't need to distinguish "no
    /// provenance recorded for this body" from "no sidecar at all".
    public func read() -> [String: ProvenanceRecord] {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: ProvenanceRecord].self, from: data)) ?? [:]
    }

    /// Merge `record` for `bodyId` into the sidecar, replacing any
    /// prior entry under the same id. Atomic write so partial state
    /// can never be observed.
    public func upsert(bodyId: String, record: ProvenanceRecord) {
        var current = read()
        current[bodyId] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Drop `bodyId`'s record. No-op if not present. Used by the
    /// scene-mutation tools that delete bodies.
    public func remove(bodyId: String) {
        var current = read()
        guard current.removeValue(forKey: bodyId) != nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
