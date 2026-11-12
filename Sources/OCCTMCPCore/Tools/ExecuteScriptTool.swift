// ExecuteScriptTool: runs an arbitrary Swift CAD script via a cached
// SPM workspace. Mirrors `occtkit run` (Sources/occtkit/Commands/Run.swift)
// from OCCTSwiftScripts but lives in-process here so the MCP server
// doesn't need to fork a separate occtkit binary.
//
// Cache layout: ~/.occtmcp-cache/workspace/{Package.swift,Sources/Script/main.swift}.
// First call is slow (SPM builds OCCTSwift transitive). Subsequent calls
// are incremental builds (~1-2s on a hot system).
//
// The script writes into a stage directory of its own, outside the scene, never into the scene
// (#257; see ExecuteScriptStage.swift). `ScriptContext.emit()` writes the stage's manifest.json, and
// only a run that finished cleanly is promoted: the scene is replaced with the stage's output,
// through `ManifestStore.update`, which is what the viewport's ScriptWatcher sees and reloads.
// An embedding host can supply the promotion instead (`ScriptStagePromoter`). SceneHistory
// snapshots the prior scene just before a promotion, so compare_versions sees the change.

import Foundation

public enum ExecuteScriptTool {

    /// Where the cached SwiftPM workspace for scripts lives.
    ///
    /// `OCCTMCP_SCRIPT_WORKSPACE` overrides the default, so a host or a CI job that must not write
    /// under the home directory can keep it elsewhere. Read once, when the process starts.
    public static let cacheDir: URL = workspaceDirectory()

    /// The workspace directory for `environment`: the override when set and non-empty, else
    /// `~/.occtmcp-cache/workspace`.
    static func workspaceDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[workspaceEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".occtmcp-cache/workspace")
    }

    public static let workspaceEnvironmentKey = "OCCTMCP_SCRIPT_WORKSPACE"

    public static let buildTimeoutSeconds: TimeInterval = 300

    /// Pin floor for OCCTSwiftScripts (provides ScriptHarness).
    ///
    /// MUST track `Package.swift`'s OCCTSwiftScripts pin (a test holds them equal): they share the
    /// OCCTSwift cohort transitively, so divergence makes execute_script compile against a
    /// different kernel than the server's own tools. A `from:` floor that is a stable version never
    /// selects a prerelease, so this floor was 1.4.2 and resolved to v1.7.0, which empties its
    /// output directory, ignores `OCCTSWIFT_OUTPUT_DIR` and leaves no failure marker (#257).
    /// 1.7.1-beta.4 is the first release with the stage directory and the marker
    /// (OCCTSwiftScripts#143, #145). The prerelease floor admits later 1.x releases.
    static let scriptsPin = "1.7.1-beta.4"

    /// Runs the script in a stage directory and promotes a clean run's output into the scene.
    ///
    /// A failed run, or one that wrote no manifest, leaves the scene as it was.
    ///
    /// `promoter` takes over the promotion: it gets the stage and the scene directory instead of
    /// OCCTMCP replacing the scene. It defaults to the one the embedding host gave
    /// `makeOCCTMCPServer(scriptStagePromoter:)`.
    public static func execute(
        code: String,
        description: String? = nil,
        history: ScriptHistoryStore = .shared,
        store: ManifestStore = ManifestStore(),
        sceneHistory: SceneHistory = .shared,
        promoter: ScriptStagePromoter? = OCCTMCPContext.scriptStagePromoter
    ) async -> ToolText {
        await executeStaged(
            code: code, description: description, history: history, store: store,
            sceneHistory: sceneHistory, promoter: promoter,
            runner: { code, stage in
                do {
                    try ensureWorkspace()
                    try writeUserScript(code: code)
                } catch {
                    throw WorkspaceSetupError(underlying: error)
                }
                return try await runWorkspace(stage: stage)
            })
    }

    /// Prepares the workspace for `code` and runs it as a child that writes into `stage`.
    ///
    /// The seam a test replaces with a fake script, so no test needs the SwiftPM workspace.
    typealias Runner = @Sendable (_ code: String, _ stage: URL) async throws -> RunResult

    /// The workspace could not be prepared, as opposed to the script failing.
    struct WorkspaceSetupError: Error {
        let underlying: Error
    }

    static func executeStaged(
        code: String,
        description: String?,
        history: ScriptHistoryStore,
        store: ManifestStore,
        sceneHistory: SceneHistory,
        promoter: ScriptStagePromoter?,
        runner: Runner
    ) async -> ToolText {
        await history.set(code)

        let stage: URL
        do {
            stage = try makeStageDirectory()
        } catch {
            return .init("Stage setup failed: \(error.localizedDescription)", isError: true)
        }
        defer { try? FileManager.default.removeItem(at: stage) }

        let runResult: RunResult
        do {
            runResult = try await runner(code, stage)
        } catch let error as WorkspaceSetupError {
            return .init(
                "Workspace setup failed: \(error.underlying.localizedDescription)", isError: true)
        } catch {
            return .init("Build / run failed: \(error.localizedDescription)", isError: true)
        }

        let filtered = filterBuildOutput(
            [runResult.stdout, runResult.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        )
        let prefix = "Script executed successfully." + (description.map { " (\($0))" } ?? "")
        let output = "Output:\n\(filtered.isEmpty ? "(no output)" : filtered)"

        switch classify(runResult, stage: stage) {
        case .failed(let reason):
            var text = "Script failed.\n\n\(filtered)"
            if let reason {
                text += (filtered.isEmpty ? "" : "\n\n") + "Reason: \(reason)"
            }
            return .init(text + "\n\nThe scene was left as it was.", isError: true)

        case .noManifest:
            return .init(
                "\(prefix)\n\n\(output)\n\nThe script wrote no manifest (it never called "
                    + "ctx.emit()), so the scene is unchanged.")

        case .staged(let manifest):
            await sceneHistory.snapshot(store: store)
            var warnings: [String] = []
            do {
                if let promoter {
                    let sceneDirectory = (store.path as NSString).deletingLastPathComponent
                    try await promoter(stage, sceneDirectory)
                } else {
                    warnings = try await promoteReplacing(
                        stage: stage, manifest: manifest, store: store)
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                return .init(
                    "Script ran, but promoting its output into the scene failed: \(reason)\n\n"
                        + output,
                    isError: true)
            }

            var manifestSection = ""
            if let manifest = try? store.read() {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                if let data = try? encoder.encode(manifest),
                    let str = String(data: data, encoding: .utf8)
                {
                    manifestSection = "\n\nManifest:\n\(str)"
                }
            }
            let warningSection =
                warnings.isEmpty ? "" : "\n\nWarnings:\n" + warnings.joined(separator: "\n")
            return .init("\(prefix)\n\n\(output)\(warningSection)\(manifestSection)")
        }
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

    static func runWorkspace(stage: URL) async throws -> RunResult {
        // First build (catch compile errors cleanly), then run with
        // --skip-build so script stdout isn't drowned in build noise. The script child, and only
        // it, is told to write into the stage.
        let environment = scriptEnvironment(stage: stage)
        let build = try await runProcess(
            executable: "/usr/bin/swift",
            args: ["build", "-c", "release", "--package-path", cacheDir.path],
            environment: environment
        )
        if build.exitCode != 0 {
            return build
        }
        return try await runProcess(
            executable: "/usr/bin/swift",
            args: [
                "run", "-c", "release", "--skip-build",
                "--package-path", cacheDir.path, "Script",
            ],
            environment: environment
        )
    }

    static func runProcess(
        executable: String, args: [String], environment: [String: String]? = nil,
        currentDirectory: URL = cacheDir
    ) async throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Listen for the exit from before the child exists (#265).
        let exited = ProcessExit(process)
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

        // Not `process.waitUntilExit()`. On a process with no termination handler it waits on the
        // run loop of the thread that called `run()`, and after the awaits above this task can be
        // on another thread, whose run loop never hears of the exit, so the call never returns
        // (#265).
        let exitCode = await exited.status()

        return RunResult(
            stdout: String(data: stdoutBytes, encoding: .utf8) ?? "",
            stderr: String(data: stderrBytes, encoding: .utf8) ?? "",
            exitCode: exitCode
        )
    }

    /// Reference-type accumulator for `drain(_:)`.
    ///
    /// The dispatch source behind
    /// `readabilityHandler` guarantees its event handler is never re-entered
    /// concurrently with itself, so mutating `data` across invocations is
    /// safe; it's boxed in a class (rather than a captured `var`) purely so
    /// the compiler's closure-Sendable check, which can't see that GCD
    /// guarantee, doesn't reject it.
    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    /// Reads a pipe's read end to EOF without blocking a Swift concurrency
    /// cooperative-pool thread for the wait (#147, see the call site comment
    /// in `runProcess`).
    ///
    /// The dispatch source behind `readabilityHandler` only
    /// invokes the closure once the fd is actually readable, so
    /// `availableData` here never blocks waiting on the child; it either
    /// returns already-buffered bytes or (at EOF) empty data, at which point
    /// the handler is torn down and the continuation resumes exactly once.
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
        let kept =
            raw
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
        if line.range(of: #"^\s*\|.*(?:warning|note):"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"^\s*\|\s*[`|]-"#, options: .regularExpression) != nil { return true }
        return false
    }
}
