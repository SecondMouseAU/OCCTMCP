// ExecuteScriptTool — runs an arbitrary Swift CAD script via a cached
// SPM workspace. Mirrors `occtkit run` (Sources/occtkit/Commands/Run.swift)
// from OCCTSwiftScripts but lives in-process here so the MCP server
// doesn't need to fork a separate occtkit binary.
//
// Cache layout: ~/.occtmcp-cache/workspace/{Package.swift,Sources/Script/main.swift}.
// First call is slow (SPM builds OCCTSwift transitive). Subsequent calls
// are incremental builds (~1-2s on a hot system).
//
// Side effect: ScriptContext.emit() in the user script writes a fresh
// manifest.json into the resolved output directory. SceneHistory snapshots
// the prior state so compare_versions sees the change.

import Foundation

public enum ExecuteScriptTool {

    public static let cacheDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".occtmcp-cache/workspace")

    public static let buildTimeoutSeconds: TimeInterval = 300

    /// Pin floor for OCCTSwiftScripts (provides ScriptHarness). MUST track
    /// `Package.swift`'s OCCTSwiftScripts pin — they share the OCCTSwift
    /// cohort transitively, so divergence makes execute_script compile
    /// against a different (older) kernel than the server's own tools.
    /// A `from: "0.x"` floor caps below 1.0.0 (SPM "up to next major"),
    /// which stranded scripts on pre-GA OCCTSwift 0.171.0 (#42).
    /// Floored at 1.4.2: 1.4.0/1.4.1 leave OCCTSwiftIO uncapped, which now
    /// floats to the heavy 1.5.0 and makes the script workspace fail to
    /// resolve (SecondMouseAU/OCCTSwiftScripts#69, ecosystem#14). 1.4.2 caps
    /// it to the lean 1.0.x line.
    static let scriptsPin = "1.4.2"

    public static func execute(
        code: String,
        description: String? = nil,
        history: ScriptHistoryStore = .shared,
        store: ManifestStore = ManifestStore(),
        sceneHistory: SceneHistory = .shared
    ) async -> ToolText {
        await sceneHistory.snapshot(store: store)
        await history.set(code)

        do {
            try ensureWorkspace()
            try writeUserScript(code: code)
        } catch {
            return .init("Workspace setup failed: \(error.localizedDescription)", isError: true)
        }

        let runResult: RunResult
        do {
            runResult = try await runWorkspace()
        } catch {
            return .init("Build / run failed: \(error.localizedDescription)", isError: true)
        }

        let filtered = filterBuildOutput(
            [runResult.stdout, runResult.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        )
        var manifestSection = ""
        if let manifest = try? store.read() {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(manifest),
               let str = String(data: data, encoding: .utf8) {
                manifestSection = "\n\nManifest:\n\(str)"
            }
        }
        if runResult.exitCode == 0 {
            let prefix = "Script executed successfully."
                + (description.map { " (\($0))" } ?? "")
            return .init("\(prefix)\n\nOutput:\n\(filtered.isEmpty ? "(no output)" : filtered)\(manifestSection)")
        }
        return .init("Script failed.\n\n\(filtered)", isError: true)
    }

    // MARK: - Workspace management

    static func ensureWorkspace() throws {
        let fm = FileManager.default
        try fm.createDirectory(
            at: cacheDir.appendingPathComponent("Sources/Script"),
            withIntermediateDirectories: true
        )
        let packageURL = cacheDir.appendingPathComponent("Package.swift")
        let packageContent = """
        // swift-tools-version: 6.0
        import PackageDescription

        let package = Package(
            name: "OCCTMCPUserScript",
            platforms: [.macOS(.v15)],
            dependencies: [
                .package(url: "https://github.com/SecondMouseAU/OCCTSwiftScripts.git", from: "\(scriptsPin)"),
            ],
            targets: [
                .executableTarget(
                    name: "Script",
                    dependencies: [
                        .product(name: "ScriptHarness", package: "OCCTSwiftScripts"),
                    ],
                    path: "Sources/Script",
                    swiftSettings: [.swiftLanguageMode(.v6)]
                ),
            ]
        )
        """
        // Only rewrite when the contents change so SPM's mtime-based
        // up-to-date checks aren't invalidated on every call.
        let existing = try? String(contentsOf: packageURL, encoding: .utf8)
        if existing != packageContent {
            try packageContent.write(to: packageURL, atomically: true, encoding: .utf8)
        }
    }

    static func writeUserScript(code: String) throws {
        let mainURL = cacheDir.appendingPathComponent("Sources/Script/main.swift")
        try FileManager.default.createDirectory(
            at: mainURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try code.write(to: mainURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Build & run

    struct RunResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func runWorkspace() async throws -> RunResult {
        // First build (catch compile errors cleanly), then run with
        // --skip-build so script stdout isn't drowned in build noise.
        let build = try runProcess(
            executable: "/usr/bin/swift",
            args: ["build", "-c", "release", "--package-path", cacheDir.path]
        )
        if build.exitCode != 0 {
            return build
        }
        return try runProcess(
            executable: "/usr/bin/swift",
            args: ["run", "-c", "release", "--skip-build",
                   "--package-path", cacheDir.path, "Script"]
        )
    }

    static func runProcess(executable: String, args: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cacheDir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return RunResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    // MARK: - Output filtering (mirrors src/tools.ts filterBuildOutput)

    static func filterBuildOutput(_ raw: String) -> String {
        let kept = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                !line.contains("nullability type specifier")
                    && !line.contains("insert '_Nullable'")
                    && !line.contains("insert '_Nonnull'")
                    && !line.contains("insert '_Null_unspecified'")
                    && !line.contains("<module-includes>:")
                    && !line.contains("in file included from <module-includes>")
                    && !line.contains("#import \"OCCTBridge.h\"")
                    && !isContextLine(line)
            }
        return kept.joined(separator: "\n")
            .replacingOccurrences(
                of: "\n{3,}", with: "\n\n",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isContextLine(_ line: String) -> Bool {
        // Pure line-number context like "  42 |"
        if line.range(of: #"^\s*\d+\s*\|\s*$"#, options: .regularExpression) != nil { return true }
        // Caret/note lines
        if line.range(of: #"^\s*\|.*(?:warning|note):"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"^\s*\|\s*[`|]-"#, options: .regularExpression) != nil { return true }
        return false
    }
}
