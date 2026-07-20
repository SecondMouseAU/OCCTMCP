// HistoryRegistryLineageTests (#90/#91/#93): proves "a body keeps ONE
// BRepGraph across successive mutations" directly against
// HistoryRegistry's actor API, in-process, no server binary required.
//
// Uses a fresh `HistoryRegistry()` instance per test rather than `.shared`.
// This suite isn't `.serialized`, and a dedicated instance sidesteps any
// cross-test interference over the actor's `entries` dictionary instead
// of relying on bodyId uniqueness to avoid it.

import Foundation
import Testing
import simd
import MCP
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("HistoryRegistry retained lineage (#90/#91/#93)")
struct HistoryRegistryLineageTests {

    @Test("hop 1 absorbs correctly; hop 2 chaining is a KNOWN issue (OCCTSwift#336) until fixed upstream")
    func retainedLineageSurvivesTwoHops() async throws {
        let registry = HistoryRegistry()
        let scene = NSTemporaryDirectory() + "occtmcp-lineage-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }
        let path = "\(scene)/part.brep"

        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: path))

        // Establish the lineage and mint a UID for face 0 BEFORE any mutation.
        let lineage0 = try await registry.currentInput(bodyId: "part", path: path)
        #expect(lineage0.isFreshLoad, "first currentInput call should be a fresh load, no prior entry")
        let instanceID0 = lineage0.graph.instanceID
        let uid0 = try #require(
            lineage0.graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0)
        )

        // Hop 1: subtract a small tool box, absorbed into the retained graph.
        // Deliberately mutates lineage0.shape (the object currentInput
        // actually loaded from disk), NOT the original in-memory `box`:
        // add(_:absorbing:...) correlates by TShape identity (Finding 1),
        // and `box`/`lineage0.shape` are different TShape trees even
        // though they're geometrically identical.
        let tool1 = try #require(Shape.box(width: 3, height: 3, depth: 3)?.translated(by: SIMD3(-1, -1, -1)))
        let (out1, hist1) = try #require(lineage0.shape.subtractedWithFullHistory(tool1))
        try Exporter.writeBREP(shape: out1, to: URL(fileURLWithPath: path))
        let committed1 = await registry.commit(
            bodyId: "part", path: path, output: out1, ref: hist1,
            from: (lineage0.graph, lineage0.root), operationName: "test-hop1"
        )
        #expect(committed1, "hop 1 should absorb as a continuation, not a generation reset")

        let lineage1 = try await registry.currentInput(bodyId: "part", path: path)
        #expect(!lineage1.isFreshLoad, "currentInput right after commit() should hit the fingerprint cache, not reload")
        #expect(lineage1.graph.instanceID == instanceID0, "graph identity should be retained across hop 1")
        #expect(lineage1.graph.contains(uid: uid0), "pre-hop-1 UID should still resolve after hop 1")

        // Hop 2: a second subtract, chained off hop 1's output. Cuts the
        // OPPOSITE corner (box spans (0,0,0)-(10,20,30)) so it clearly
        // touches/modifies pre-existing outer faces near (10,20,30)
        // rather than landing fully enclosed inside the solid, which
        // wouldn't generate any Modified/Generated record against the
        // tracked root at all.
        //
        // KNOWN ISSUE (SecondMouseAU/OCCTSwift#336): a *WithFullHistory
        // call whose INPUT is the output of a prior *WithFullHistory op
        // (rather than a freshly-loaded Shape) currently produces a
        // ShapeHistoryRef that absorbs zero records, verified independent
        // of HistoryRegistry (reproduces against a brand-new BRepGraph
        // too, and regardless of compound-vs-solid root drilling). Single-
        // hop absorption (hop 1, above) is unaffected. commit()'s decision
        // tree correctly detects this (historyRecordCount doesn't grow)
        // and degrades to a generation reset rather than a false
        // continuation, so this whole block is wrapped in withKnownIssue:
        // it documents today's actual behavior and will flip to reporting
        // an unexpected pass (worth noticing) once #336 ships and this
        // repins.
        let tool2 = try #require(Shape.box(width: 3, height: 3, depth: 3)?.translated(by: SIMD3(8, 18, 28)))
        let (out2, hist2) = try #require(lineage1.shape.subtractedWithFullHistory(tool2))
        try Exporter.writeBREP(shape: out2, to: URL(fileURLWithPath: path))

        await withKnownIssue("SecondMouseAU/OCCTSwift#336: chaining a second *WithFullHistory op onto a prior op's output absorbs zero records") {
            let committed2 = await registry.commit(
                bodyId: "part", path: path, output: out2, ref: hist2,
                from: (lineage1.graph, lineage1.root), operationName: "test-hop2"
            )
            #expect(committed2, "hop 2 should absorb as a continuation, not a generation reset")

            let lineage2 = try await registry.currentInput(bodyId: "part", path: path)
            #expect(!lineage2.isFreshLoad)
            #expect(
                lineage2.graph.instanceID == instanceID0,
                "graph identity should STILL be retained after hop 2: this is 'one graph across mutations'"
            )
            #expect(
                lineage2.graph.contains(uid: uid0),
                "pre-hop-1 UID should STILL resolve after hop 2, proving the retained lineage spans both hops, not just hop 1's own continuation"
            )
            let resolved = try #require(lineage2.graph.node(forUID: uid0))
            #expect(resolved.kind == Int(BRepGraph.NodeKind.face.rawValue))
        }
    }

    @Test("a failed/no-op absorb degrades to a generation reset, not a silent wrong continuation")
    func failedAbsorbDegradesToGenerationReset() async throws {
        let registry = HistoryRegistry()
        let scene = NSTemporaryDirectory() + "occtmcp-lineage-reset-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }
        let path = "\(scene)/part.brep"

        let box = try #require(Shape.box(width: 10, height: 10, depth: 10))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: path))
        let lineage0 = try await registry.currentInput(bodyId: "part", path: path)
        let instanceID0 = lineage0.graph.instanceID

        // ref: nil is always a generation reset by construction (no
        // absorb attempted at all), e.g. transform_body/mirror_or_pattern
        // today, pending SecondMouseAU/OCCTSwift#331.
        let translated = try #require(box.translated(by: SIMD3(5, 0, 0)))
        try Exporter.writeBREP(shape: translated, to: URL(fileURLWithPath: path))
        let committed = await registry.commit(
            bodyId: "part", path: path, output: translated, ref: nil,
            from: (lineage0.graph, lineage0.root), operationName: "test-no-history-op"
        )
        #expect(!committed, "ref: nil should always report a generation reset")

        let lineage1 = try await registry.currentInput(bodyId: "part", path: path)
        #expect(
            lineage1.graph.instanceID != instanceID0,
            "a generation reset should mint a NEW graph instance, not keep mutating the old one"
        )
    }

    @Test("a compound-wrapped output (boolean/FeatureReconstructor results, even single-solid) still yields a trackable root for the NEXT hop")
    func compoundWrappedOutputResolvesToTrackableRoot() async throws {
        let registry = HistoryRegistry()
        let scene = NSTemporaryDirectory() + "occtmcp-lineage-compound-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }
        let path = "\(scene)/part.brep"

        let box = try #require(Shape.box(width: 40, height: 40, depth: 40))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: path))
        let lineage0 = try await registry.currentInput(bodyId: "part", path: path)

        // FeatureReconstructor's hole output registers as .compound even
        // though it wraps a single solid, verified directly against the
        // real FeatureTools.applyFeature dependency, not a synthetic
        // stand-in, since that's the shape that broke the naive
        // "trust add()'s raw returned NodeRef" version of this code.
        let envelope: Value = .object([
            "features": .array([.object([
                "id": .string("h1"),
                "kind": .string("hole"),
                "axis_point": .array([.double(5), .double(5), .double(0)]),
                "axis_direction": .array([.double(0), .double(0), .double(1)]),
                "diameter": .double(4),
            ])]),
        ])
        let data = try JSONEncoder().encode(envelope)
        let result = try FeatureReconstructor.buildJSON(data, inputBody: lineage0.shape)
        let output = try #require(result.shape)
        let ref = try #require(result.histories.values.first)

        try Exporter.writeBREP(shape: output, to: URL(fileURLWithPath: path))
        let committed = await registry.commit(
            bodyId: "part", path: path, output: output, ref: ref,
            from: (lineage0.graph, lineage0.root), operationName: "test-hole"
        )
        #expect(committed, "hole feature should absorb as a continuation")

        let lineage1 = try await registry.currentInput(bodyId: "part", path: path)
        #expect(
            lineage1.root.kind == .solid,
            "the stored root should be drilled down to the wrapped solid, not left as .compound: a .compound root can't be tracked by a LATER add() call"
        )
    }

    @Test("commit() writes a fresh entry even with no prior lineage (first touch)")
    func commitWithoutCurrentInputStillEstablishesLineage() async throws {
        let registry = HistoryRegistry()
        let scene = NSTemporaryDirectory() + "occtmcp-lineage-first-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: scene, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: scene) }
        let path = "\(scene)/part.brep"

        let box = try #require(Shape.box(width: 8, height: 8, depth: 8))
        try Exporter.writeBREP(shape: box, to: URL(fileURLWithPath: path))

        #expect(await registry.graph(for: "part") == nil, "no lineage recorded yet")
        let committed = await registry.commit(
            bodyId: "part", path: path, output: box, ref: nil, from: nil, operationName: "test-first-touch"
        )
        #expect(!committed)
        #expect(await registry.graph(for: "part") != nil, "commit() should establish a lineage entry even with no prior currentInput call")
    }
}
