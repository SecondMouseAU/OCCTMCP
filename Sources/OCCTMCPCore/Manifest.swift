// Manifest helpers: read / write `manifest.json` under the resolved
// output directory. Re-uses `ScriptManifest` and `BodyDescriptor` from
// ScriptHarness so the on-disk format is identical to whatever
// occtkit / ScriptContext write.

import Foundation
import ScriptHarness

public struct ManifestStore: Sendable {
    public let path: String

    /// How long `update` and `write` wait for another writer's lock before throwing.
    public let lockTimeout: TimeInterval

    public init(path: String = OCCTMCPPaths.manifestPath(), lockTimeout: TimeInterval = 30) {
        self.path = path
        self.lockTimeout = lockTimeout
    }

    /// Path of the advisory lock file, next to the manifest.
    ///
    /// It is a separate file because the atomic write replaces the manifest's inode, which would
    /// drop a lock held on the manifest itself.
    public var lockPath: String {
        (path as NSString).deletingLastPathComponent + "/manifest.lock"
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

    /// Load the manifest, throwing a `ManifestError` that tells an absent file from a malformed one.
    public func requireScene() throws -> ScriptManifest {
        do {
            if let manifest = try read() { return manifest }
        } catch {
            throw ManifestError.malformed(path: path, reason: error.localizedDescription)
        }
        throw ManifestError.noScene
    }

    /// Load the manifest, nil when the file is absent, throwing `ManifestError.malformed` when it
    /// exists but cannot be parsed.
    public func requireSceneOrAbsent() throws -> ScriptManifest? {
        do {
            return try read()
        } catch {
            throw ManifestError.malformed(path: path, reason: error.localizedDescription)
        }
    }

    /// Write the manifest to disk with an updated timestamp, under the manifest lock.
    public func write(_ manifest: ScriptManifest) throws {
        try withLock {
            _ = try commit(manifest, willWrite: nil)
        }
    }

    /// Read, transform and atomically rewrite the manifest while holding the manifest lock.
    ///
    /// `transform` receives the current manifest (nil when the file is absent) and returns the
    /// manifest to write. `willWrite` receives the exact bytes about to be written, under the
    /// lock and before the atomic rename; throwing from either closure aborts without writing.
    /// A malformed existing manifest throws `ManifestError.malformed` and is never overwritten.
    ///
    /// Not re-entrant: calling `update` or `write` on the same path from inside a closure
    /// waits for the lock and throws `ManifestError.lockTimeout`.
    ///
    /// - Returns: the manifest that was written, with its refreshed timestamp.
    @discardableResult
    public func update(
        willWrite: ((_ data: Data) throws -> Void)? = nil,
        _ transform: (_ current: ScriptManifest?) throws -> ScriptManifest
    ) throws -> ScriptManifest {
        try withLock {
            let current: ScriptManifest?
            do {
                current = try read()
            } catch {
                throw ManifestError.malformed(path: path, reason: error.localizedDescription)
            }
            return try commit(try transform(current), willWrite: willWrite)
        }
    }

    private func commit(
        _ manifest: ScriptManifest,
        willWrite: ((Data) throws -> Void)?
    ) throws -> ScriptManifest {
        let bumped = manifest.withRefreshedTimestamp()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bumped)
        try willWrite?(data)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return bumped
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw ManifestError.lockFailed(path: lockPath, errno: errno)
        }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw ManifestError.lockFailed(path: lockPath, errno: errno)
            }
            guard Date() < deadline else {
                throw ManifestError.lockTimeout(path: lockPath)
            }
            usleep(2_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

/// Why a manifest could not be loaded or locked.
public enum ManifestError: Error, LocalizedError, CustomStringConvertible, Equatable {
    case noScene
    case malformed(path: String, reason: String)
    case lockTimeout(path: String)
    case lockFailed(path: String, errno: Int32)
    case bodyNotFound(String)
    case bodyIdTaken(String)

    public var description: String { errorDescription ?? "Manifest error." }

    public var errorDescription: String? {
        switch self {
        case .noScene:
            return "No scene loaded. Run execute_script first."
        case .malformed(let path, let reason):
            return "Manifest \(path) exists but could not be parsed (\(reason)). "
                + "It was not modified."
        case .lockTimeout(let path):
            return "Timed out waiting for the manifest lock \(path)."
        case .lockFailed(let path, let code):
            return "Could not lock \(path): \(String(cString: strerror(code)))."
        case .bodyNotFound(let id):
            return "Body not found: \(id)"
        case .bodyIdTaken(let id):
            return "A body with id \"\(id)\" already exists."
        }
    }
}

extension ScriptManifest {
    /// Return a copy with `bodies` replaced and `graphs` and `metadata` carried over.
    ///
    /// `description` keeps the existing value when nil.
    public func replacing(bodies: [BodyDescriptor], description: String? = nil) -> ScriptManifest {
        return ScriptManifest(
            version: self.version,
            timestamp: self.timestamp,
            description: description ?? self.description,
            bodies: bodies,
            graphs: self.graphs,
            metadata: self.metadata
        )
    }

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

extension Optional where Wrapped == ScriptManifest {
    /// The manifest, or `ManifestError.noScene` when the file was absent.
    public func requiringScene() throws -> ScriptManifest {
        guard let manifest = self else { throw ManifestError.noScene }
        return manifest
    }
}
