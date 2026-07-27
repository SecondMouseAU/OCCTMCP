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

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<total {
                group.addTask {
                    await store.upsert(
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
            await store.upsert(
                bodyId: "remove\(i)", record: provenanceRecord(source: "old\(i)"), outputDir: outputDir
            )
        }
        for i in 0..<keepCount {
            await store.upsert(
                bodyId: "keep\(i)", record: provenanceRecord(source: "keep-src\(i)"), outputDir: outputDir
            )
        }

        // Mirrors the reported failure shape exactly: `remove_body`
        // dropping one body's record races `mirror_or_pattern` upserting
        // a DIFFERENT body's record, both against the same sidecar file,
        // concurrently.
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<removeCount {
                group.addTask {
                    await store.remove(bodyId: "remove\(i)", outputDir: outputDir)
                }
            }
            for i in 0..<keepCount {
                group.addTask {
                    await store.upsert(
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
            await store.upsert(
                bodyId: "pre\(i)", record: provenanceRecord(source: "pre-src\(i)"), outputDir: outputDir
            )
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.clear(outputDir: outputDir) }
            for i in 0..<50 {
                group.addTask {
                    await store.upsert(
                        bodyId: "post\(i)", record: provenanceRecord(source: "post-src\(i)"), outputDir: outputDir
                    )
                }
            }
        }

        // Whichever interleaving actually happened, the file must be
        // internally consistent (a valid decode, not a torn write): every
        // `pre*` id is gone (clear supersedes it), and the final state is
        // exactly whatever set of `post*` upserts landed after the clear.
        let final = await store.read(outputDir: outputDir)
        for i in 0..<50 {
            #expect(final["pre\(i)"] == nil, "pre\(i) should not survive a clear()")
        }
        for (key, record) in final {
            #expect(key.hasPrefix("post"), "unexpected surviving key \(key)")
            #expect(record.sourceBodyId.hasPrefix("post-src"))
        }
    }
}
