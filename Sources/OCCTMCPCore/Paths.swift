// Paths: output directory and manifest path resolution. Mirrors the
// Node implementation in src/paths.ts: env override > iCloud Drive >
// local fallback. Tests redirect via OCCTMCP_OUTPUT_DIR. An embedding host
// can instead pass `outputDirectory` to `makeOCCTMCPServer`, which scopes a
// task-local override around each tool call (#195).

import Foundation

public enum OCCTMCPPaths {
    public static let envOverrideKey = "OCCTMCP_OUTPUT_DIR"

    /// The output directory an embedding host asked for, scoped to the current task.
    ///
    /// Set only through `withOutputDirectory(_:operation:)`. Child tasks and
    /// `async let` inherit it; `Task.detached` does not. Code in this package MUST NOT
    /// use `Task.detached` on a tool path, or the override silently stops applying.
    @TaskLocal public static var outputDirectoryOverride: String?

    /// Run `operation` with `directory` as the output directory for every path
    /// lookup made inside it.
    ///
    /// A `nil` directory leaves resolution untouched, so the environment and
    /// fallback rules below apply as before.
    public static func withOutputDirectory<T>(
        _ directory: URL?,
        operation: () async throws -> T
    ) async rethrows -> T {
        guard let directory else { return try await operation() }
        return try await $outputDirectoryOverride.withValue(
            directory.standardizedFileURL.path,
            operation: operation
        )
    }

    /// Resolve the output directory for the current task.
    ///
    /// Resolution order:
    ///   0. The task-local host override (`makeOCCTMCPServer(outputDirectory:)`).
    ///   1. `OCCTMCP_OUTPUT_DIR` env var (used by the test suite).
    ///   2. iCloud Drive container if it exists
    ///      (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output`).
    ///   3. Local fallback (`~/.occtswift-scripts/output`).
    public static func outputDir(env: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        if let hostOverride = outputDirectoryOverride {
            return hostOverride
        }
        if let override = env[envOverrideKey], !override.isEmpty {
            return override
        }
        let home = NSString(string: "~").expandingTildeInPath
        let icloudParent = "\(home)/Library/Mobile Documents/com~apple~CloudDocs"
        let icloud = "\(icloudParent)/OCCTSwiftScripts/output"
        if FileManager.default.fileExists(atPath: icloudParent) {
            return icloud
        }
        return "\(home)/.occtswift-scripts/output"
    }

    /// Path to manifest.json inside the resolved output directory.
    public static func manifestPath(env: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
        return outputDir(env: env) + "/manifest.json"
    }
}

/// Hands out one instance of a process-global actor per host-supplied output directory.
///
/// With no host override (stdio server, tests) it returns the single legacy instance, so
/// behaviour is unchanged. With an override, each directory gets its own instance, so two
/// embedded servers never share selections, zones, history or scene snapshots.
///
/// Instances are kept for the life of the process, one per distinct directory. That suits
/// a host with a small number of long-lived servers; a host that creates a server per
/// request with a fresh directory each time would grow this table without bound.
final class DirectoryScoped<Instance: Sendable>: @unchecked Sendable {
    private var legacy: Instance?
    private let make: @Sendable () -> Instance
    private let lock = NSLock()
    private var byDirectory: [String: Instance] = [:]

    init(make: @escaping @Sendable () -> Instance) {
        self.make = make
    }

    var current: Instance {
        lock.lock()
        defer { lock.unlock() }
        guard let directory = OCCTMCPPaths.outputDirectoryOverride else {
            if let existing = legacy { return existing }
            let created = make()
            legacy = created
            return created
        }
        if let existing = byDirectory[directory] { return existing }
        let created = make()
        byDirectory[directory] = created
        return created
    }
}
