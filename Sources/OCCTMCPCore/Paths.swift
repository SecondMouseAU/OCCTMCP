// Paths: output directory and manifest path resolution. Mirrors the
// Node implementation in src/paths.ts: env override > iCloud Drive >
// local fallback. Tests redirect via OCCTMCP_OUTPUT_DIR.

import Foundation

public enum OCCTMCPPaths {
    public static let envOverrideKey = "OCCTMCP_OUTPUT_DIR"

    /// Resolve the output directory for the current process.
    /// Resolution order:
    ///   1. `OCCTMCP_OUTPUT_DIR` env var (used by the test suite).
    ///   2. iCloud Drive container if it exists
    ///      (`~/Library/Mobile Documents/com~apple~CloudDocs/OCCTSwiftScripts/output`).
    ///   3. Local fallback (`~/.occtswift-scripts/output`).
    public static func outputDir(env: [String: String] = ProcessInfo.processInfo.environment)
        -> String
    {
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
