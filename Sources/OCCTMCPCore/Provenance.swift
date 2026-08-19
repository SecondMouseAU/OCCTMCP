// Provenance: `<output_dir>/provenance.json` sidecar that records how
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

/// Actor-isolated (#157): every mutating method used to be a plain
/// read-modify-write cycle against `provenance.json` on a `Sendable`
/// struct constructed fresh per call, which serializes NOTHING; two
/// concurrent calls (e.g. `remove_body` racing a `mirror_or_pattern` call
/// writing a different body's record) could both read the same starting
/// state and silently lose whichever write happened first. Wrapping the
/// struct in an actor alone would NOT have fixed this: a fresh instance
/// per call has no shared isolation domain with any other fresh instance.
/// The fix is the same shape `SelectionRegistry`/`ZoneRegistry` already
/// use for this exact problem: one process-wide `shared` instance that
/// every call site goes through, so the read-modify-write cycle actually
/// serializes.
///
/// Unlike those two, there's no in-memory cache to keep warm across calls:
/// `read()` always re-reads the file fresh (it did before this change too),
/// so the actor's only job is serializing the read-modify-write cycle each
/// mutating method performs, not caching anything. `outputDir` is a
/// PARAMETER to every method rather than baked into the instance via
/// init (mirroring `ZoneRegistry`'s `store:` parameter, not
/// `SelectionRegistry`'s no-parameter shape): a single shared actor now
/// serves every output dir a process ever touches, where the old
/// per-call `ProvenanceStore(outputDir:)` constructed a fresh instance
/// (and thus a fresh, unshared "isolation domain") for each one.
public actor ProvenanceStore {
    public static let shared = ProvenanceStore()

    public init() {}

    private func path(outputDir: String) -> String {
        "\(outputDir)/provenance.json"
    }

    /// Whole-file read.
    ///
    /// Returns an empty dictionary when the sidecar
    /// doesn't exist yet; callers don't need to distinguish "no
    /// provenance recorded for this body" from "no sidecar at all".
    public func read(outputDir: String) -> [String: ProvenanceRecord] {
        let filePath = path(outputDir: outputDir)
        guard FileManager.default.fileExists(atPath: filePath),
            let data = try? Data(contentsOf: URL(fileURLWithPath: filePath))
        else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: ProvenanceRecord].self, from: data)) ?? [:]
    }

    /// Merge `record` for `bodyId` into the sidecar, replacing any
    /// prior entry under the same id.
    ///
    /// Atomic write so partial state
    /// can never be observed; actor isolation is what makes the
    /// read-modify-write cycle around that write atomic too.
    public func upsert(bodyId: String, record: ProvenanceRecord, outputDir: String) {
        var current = read(outputDir: outputDir)
        current[bodyId] = record
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: URL(fileURLWithPath: path(outputDir: outputDir)), options: .atomic)
    }

    /// Drop the record for `bodyId`.
    ///
    /// No-op if not present. Used by the
    /// scene-mutation tools that delete bodies.
    public func remove(bodyId: String, outputDir: String) {
        var current = read(outputDir: outputDir)
        guard current.removeValue(forKey: bodyId) != nil else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(current) else { return }
        try? data.write(to: URL(fileURLWithPath: path(outputDir: outputDir)), options: .atomic)
    }

    /// Wipe every record.
    ///
    /// Used by `clear_scene`, which removes every
    /// body in the scene at once: cheaper than removing each id
    /// individually, and correct since none of them survive.
    public func clear(outputDir: String) {
        try? FileManager.default.removeItem(atPath: path(outputDir: outputDir))
    }
}
