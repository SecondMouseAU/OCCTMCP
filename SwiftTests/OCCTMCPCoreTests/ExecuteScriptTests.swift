// Unit tests for ExecuteScriptTool's pure logic — output filtering and
// workspace scaffolding. The SPM-build-and-run path is exercised by
// the (slow, opt-in) integration suite once Phase 5.4's stdio harness
// lands.

import Foundation
import Testing
@testable import OCCTMCPCore

@Suite("execute_script logic", .serialized)
struct ExecuteScriptTests {

    @Test("filterBuildOutput drops OCCT bridge nullability noise")
    func filtersBridgeNoise() {
        let input = """
        Build complete!
        warning: nullability type specifier 'NSStringEncoding *' missing nullability annotation; insert '_Nullable' if the pointer may be null
        ScriptContext: emitting 1 body
        in file included from <module-includes>:42
        normal log line
        """
        let out = ExecuteScriptTool.filterBuildOutput(input)
        #expect(!out.contains("nullability type specifier"))
        #expect(!out.contains("<module-includes>"))
        #expect(out.contains("ScriptContext"))
        #expect(out.contains("normal log line"))
    }

    @Test("filterBuildOutput collapses runs of blank lines")
    func collapsesBlankRuns() {
        let input = "first\n\n\n\n\nsecond"
        let out = ExecuteScriptTool.filterBuildOutput(input)
        #expect(out == "first\n\nsecond")
    }

    @Test("ensureWorkspace creates Package.swift and Sources/Script directory")
    func ensuresWorkspace() throws {
        // Use a tempdir as the cache root by overriding cacheDir via reflection
        // is awkward; instead, just call against the real cache and clean up
        // any prior state to keep the test deterministic.
        // (The real cache is a shared resource; serial running is fine because
        // swift-testing serialises tests within a single suite by default.)
        let fm = FileManager.default
        let pkg = ExecuteScriptTool.cacheDir.appendingPathComponent("Package.swift")
        let src = ExecuteScriptTool.cacheDir.appendingPathComponent("Sources/Script")

        try? fm.removeItem(at: ExecuteScriptTool.cacheDir)
        try ExecuteScriptTool.ensureWorkspace()
        #expect(fm.fileExists(atPath: pkg.path))
        #expect(fm.fileExists(atPath: src.path))

        let contents = try String(contentsOf: pkg, encoding: .utf8)
        #expect(contents.contains("OCCTMCPUserScript"))
        #expect(contents.contains("ScriptHarness"))
    }

    @Test("writeUserScript writes main.swift verbatim")
    func writesUserScript() throws {
        try ExecuteScriptTool.ensureWorkspace()
        let code = "// hello, world\nprint(\"hi\")\n"
        try ExecuteScriptTool.writeUserScript(code: code)
        let mainURL = ExecuteScriptTool.cacheDir.appendingPathComponent("Sources/Script/main.swift")
        let written = try String(contentsOf: mainURL, encoding: .utf8)
        #expect(written == code)
    }

    @Test(
        "runProcess drains stdout and stderr concurrently so a full pipe buffer can't deadlock it",
        .timeLimit(.minutes(1))
    )
    func drainsLargeOutputWithoutDeadlock() async throws {
        // Regression for #129: runProcess() used to call waitUntilExit()
        // before ever reading either pipe. A typical OS pipe buffer is
        // 64KB, so a synthetic child that writes more than that on BOTH
        // stdout and stderr reproduces the deadlock deterministically,
        // without needing a real swift build/occtkit subprocess.
        let script = "yes | head -c 200000; yes | head -c 200000 1>&2"
        let result = try await ExecuteScriptTool.runProcess(
            executable: "/bin/sh",
            args: ["-c", script]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count >= 200_000)
        #expect(result.stderr.utf8.count >= 200_000)
    }
}
