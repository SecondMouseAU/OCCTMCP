// Concurrency regression tests for #157: ProvenanceStore's mutating
// methods used to do an unsynchronized read-modify-write cycle against
// `provenance.json` on a `Sendable` struct constructed fresh per call.
// Two concurrent calls touching DIFFERENT bodyIds (the exact shape of
// `remove_body` racing a `mirror_or_pattern` call writing a different
// body's record) could each read the same starting dictionary, and
// whichever wrote last would silently discard the other's change.
//
// Routing every mutation through a single actor instance serializes the
// read-modify-write cycle so no update is lost, the same fix shape (and
// the same style of concurrency test) as
// SelectionRegistryTests.clearIsAtomicUnderConcurrency (#135/#150/#151).

import Foundation
import Testing
@testable import OCCTMCPCore

private func provenanceRecord(source: String) -> ProvenanceRecord {
    ProvenanceRecord(sourceBodyId: source, transform: .translate(offset: .zero))
}

@Suite("ProvenanceStore concurrency (#157)")
struct ProvenanceStoreTests {

    func tempOutputDir() throws -> String {
        let dir = NSTemporaryDirectory() + "occtmcp-provenance-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("concurrent upserts of distinct bodies all persist, none lost")
    func concurrentUpsertsAllPersist() async throws {
        let outputDir = try tempOutputDir()
        defer { try? FileManager.default.removeItem(atPath: outputDir) }
        let store = ProvenanceStore()
        let total = 200

        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask {
                    try await store.upsert(
                        bodyId: "body\(i)",
                        record: provenanceRecord(source: "src\(i)"),
                        outputDir: outputDir
                    )
                }
            }
        }

        let final = await store.read(outputDir: outputDir)
        #expect(final.count == total)
        for i in 0..<total {
            #expect(final["body\(i)"]?.sourceBodyId == "src\(i)", "body\(i) should have persisted")
        }
    }

    @Test("concurrent removes don't lose unrelated concurrent upserts (#157)")
    func concurrentRemovesDontLoseUnrelatedWrites() async throws {
        let outputDir = try tempOutputDir()
        defer { try? FileManager.default.removeItem(atPath: outputDir) }
        let store = ProvenanceStore()
        let removeCount = 100
        let keepCount = 100

        // Seed sequentially (setup itself isn't the thing under test):
        // `removeN` bodies will be concurrently removed below, `keepN`
        // bodies are never touched and must survive untouched.
        for i in 0..<removeCount {
            try await store.upsert(
                bodyId: "remove\(i)", record: provenanceRecord(source: "old\(i)"), outputDir: outputDir
            )
        }
        for i in 0..<keepCount {
            try await store.upsert(
                bodyId: "keep\(i)", record: provenanceRecord(source: "keep-src\(i)"), outputDir: outputDir
            )
        }

        // Mirrors the reported failure shape exactly: `remove_body`
        // dropping one body's record races `mirror_or_pattern` upserting
        // a DIFFERENT body's record, both against the same sidecar file,
        // concurrently.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<removeCount {
                group.addTask {
                    try await store.remove(bodyId: "remove\(i)", outputDir: outputDir)
                }
            }
            for i in 0..<keepCount {
                group.addTask {
                    try await store.upsert(
                        bodyId: "new\(i)", record: provenanceRecord(source: "new-src\(i)"), outputDir: outputDir
                    )
                }
            }
        }

        let final = await store.read(outputDir: outputDir)
        #expect(final.count == keepCount * 2, "expected \(keepCount) untouched + \(keepCount) new, got \(final.count)")
        for i in 0..<removeCount {
            #expect(final["remove\(i)"] == nil, "remove\(i) should have been dropped by its concurrent remove()")
        }
        for i in 0..<keepCount {
            #expect(final["keep\(i)"] != nil, "keep\(i) should have survived untouched by the concurrent removes")
            #expect(final["new\(i)"] != nil, "new\(i)'s concurrent upsert should not have been lost to a race")
        }
    }

    @Test("clear wipes the sidecar even with concurrent upserts in flight")
    func clearUnderConcurrency() async throws {
        let outputDir = try tempOutputDir()
        defer { try? FileManager.default.removeItem(atPath: outputDir) }
        let store = ProvenanceStore()

        for i in 0..<50 {
            try await store.upsert(
                bodyId: "pre\(i)", record: provenanceRecord(source: "pre-src\(i)"), outputDir: outputDir
            )
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await store.clear(outputDir: outputDir) }
            for i in 0..<50 {
                group.addTask {
                    try await store.upsert(
                        bodyId: "post\(i)", record: provenanceRecord(source: "post-src\(i)"), outputDir: outputDir
                    )
                }
            }
        }

        // Whichever interleaving actually happened, the file must be a valid decode (not a torn
        // write): every `pre*` id is gone (clear supersedes it), and what remains is only `post*`
        // upserts that landed after the clear. The file is decoded directly, because
        // `store.read` maps an undecodable file to an empty dictionary.
        let sidecar = URL(fileURLWithPath: "\(outputDir)/provenance.json")
        if FileManager.default.fileExists(atPath: sidecar.path) {
            let decoded = try JSONDecoder().decode(
                [String: ProvenanceRecord].self, from: Data(contentsOf: sidecar))
            #expect(decoded.keys.allSatisfy { $0.hasPrefix("post") }, "only post* may survive")
        }
        let final = await store.read(outputDir: outputDir)
        for i in 0..<50 {
            #expect(final["pre\(i)"] == nil, "pre\(i) should not survive a clear()")
        }
        for (key, record) in final {
            #expect(key.hasPrefix("post"), "unexpected surviving key \(key)")
            #expect(record.sourceBodyId.hasPrefix("post-src"))
        }

        // A clear must leave the store usable: an upsert after it persists, and exactly the
        // post* survivors plus the new id are in the file. An empty final state above would
        // pass without this.
        try await store.upsert(
            bodyId: "after-clear", record: provenanceRecord(source: "after-src"), outputDir: outputDir)
        try #require(
            FileManager.default.fileExists(atPath: sidecar.path),
            "provenance.json is missing after an upsert that followed clear()")
        let afterwards = try JSONDecoder().decode(
            [String: ProvenanceRecord].self, from: Data(contentsOf: sidecar))
        let record = try #require(afterwards["after-clear"], "an upsert after clear() was lost")
        #expect(record.sourceBodyId == "after-src")
        #expect(Set(afterwards.keys) == Set(final.keys).union(["after-clear"]))
    }
}
