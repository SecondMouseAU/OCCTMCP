// ExecuteScriptTool: runs an arbitrary Swift CAD script via a cached
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
    /// `Package.swift`'s OCCTSwiftScripts pin: they share the OCCTSwift
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
        let build = try await runProcess(
            executable: "/usr/bin/swift",
            args: ["build", "-c", "release", "--package-path", cacheDir.path]
        )
        if build.exitCode != 0 {
            return build
        }
        return try await runProcess(
            executable: "/usr/bin/swift",
            args: ["run", "-c", "release", "--skip-build",
                   "--package-path", cacheDir.path, "Script"]
        )
    }

    static func runProcess(executable: String, args: [String]) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = cacheDir

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        // Drain both pipes concurrently with the child still running, each in
        // its own child task. Reading only after waitUntilExit() (the naive
        // order) deadlocks as soon as either pipe's OS buffer fills before the
        // child exits: the child blocks inside its own write() with nothing on
        // the other end to drain it, and the parent is stuck inside
        // waitUntilExit() forever since nothing can ever unblock it (#129).
        //
        // `drain(_:)` uses `readabilityHandler` rather than
        // `readDataToEndOfFile()` (#147): the latter is a blocking syscall
        // that, even inside `async let`, parks a real Swift concurrency
        // cooperative-pool thread for the whole subprocess lifetime (up to
        // 60+s for a cold `swift build`), two such threads per
        // `execute_script` call, enough to starve the pool's other
        // concurrently-running async work on a small-core machine.
        // `readabilityHandler`'s callback fires on a libdispatch queue only
        // when the fd is already known-readable (kqueue-driven), so no pool
        // thread ever blocks waiting on the child; the awaiting task just
        // suspends until the continuation resumes.
        async let stdoutData = drain(stdoutPipe.fileHandleForReading)
        async let stderrData = drain(stderrPipe.fileHandleForReading)
        let (stdoutBytes, stderrBytes) = await (stdoutData, stderrData)

        process.waitUntilExit()

        return RunResult(
            stdout: String(data: stdoutBytes, encoding: .utf8) ?? "",
            stderr: String(data: stderrBytes, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Reference-type accumulator for `drain(_:)`. `readabilityHandler`'s
    /// dispatch source guarantees its event handler is never re-entered
    /// concurrently with itself, so mutating `data` across invocations is
    /// safe; it's boxed in a class (rather than a captured `var`) purely so
    /// the compiler's closure-Sendable check, which can't see that GCD
    /// guarantee, doesn't reject it.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Reads a pipe's read end to EOF without blocking a Swift concurrency
    /// cooperative-pool thread for the wait (#147, see the call site comment
    /// in `runProcess`). `readabilityHandler`'s dispatch source only invokes
    /// the closure once the fd is actually readable, so `availableData` here
    /// never blocks waiting on the child; it either returns already-buffered
    /// bytes or (at EOF) empty data, at which point the handler is torn down
    /// and the continuation resumes exactly once.
    static func drain(_ handle: FileHandle) async -> Data {
        let box = DataBox()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            handle.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    fh.readabilityHandler = nil
                    continuation.resume(returning: box.data)
                } else {
                    box.data.append(chunk)
                }
            }
        }
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
