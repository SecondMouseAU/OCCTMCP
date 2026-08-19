// Manifest helpers: read / write `manifest.json` under the resolved
// output directory. Re-uses `ScriptManifest` and `BodyDescriptor` from
// ScriptHarness so the on-disk format is identical to whatever
// occtkit / ScriptContext write.

import Foundation
import ScriptHarness

public struct ManifestStore: Sendable {
    public let path: String

    public init(path: String = OCCTMCPPaths.manifestPath()) {
        self.path = path
    }

    /// Load the manifest from disk, or nil if the file does not exist.
    ///
    /// Throws if the file exists but cannot be parsed.
    public func read() throws -> ScriptManifest? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScriptManifest.self, from: data)
    }

    /// Write the manifest to disk with an updated timestamp.
    public func write(_ manifest: ScriptManifest) throws {
        let bumped = manifest.withRefreshedTimestamp()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bumped)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

extension ScriptManifest {
    /// Return a copy with `timestamp` reset to now.
    ///
    /// The struct is value-type and immutable so this is the natural mutation primitive.
    public func withRefreshedTimestamp() -> ScriptManifest {
        return ScriptManifest(
            version: self.version,
            timestamp: Date(),
            description: self.description,
            bodies: self.bodies,
            graphs: self.graphs,
            metadata: self.metadata
        )
    }

    /// Locate a body by its `id`.
    ///
    /// Returns nil when not found.
    public func body(withId id: String) -> BodyDescriptor? {
        return bodies.first { $0.id == id }
    }
}
