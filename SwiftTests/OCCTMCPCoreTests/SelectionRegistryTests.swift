// Unit tests for SelectionRegistry.clear(): the return value must be the
// count actually removed, computed in the SAME actor call as the removal
// (#135). A prior version split this into a separate `count()` read
// followed by `clear()`, which let another task's concurrent record/clear
// land on the actor in between, so the reported count could diverge from
// what was truly cleared.
//
// Also covers #150: `count()`/`clear()`'s basis must be the union of
// `anchors.keys` and `snapshots.keys`, not `anchors.count` alone, so a
// point-snapshot-only entry (`pick_surface_point`, which has no
// `TopologyAnchor`) is neither invisible to `count()` nor silently
// uncounted when `clear()` wipes it.
//
// #182 re-keyed the registry on GraphUID: `uid` is now a field on
// `TopologyAnchor` itself (written by the same `record` call as the rest
// of the anchor) rather than a separate `graphUIDs` side-table written by
// its own `recordGraphUID` call. The pre-#182 regression test here
// (`countAndClearIncludeGraphUIDOnlyEntries`) simulated a uid recorded for
// a selectionId that was never `record()`-ed, a real gap two call sites
// (`RemapTools.refreshAfterHistoryRemap`, `CorrespondenceTools.mintUID`)
// could actually produce, since the old `recordGraphUID` call ran
// independently of whether `record` had. That specific violation is no
// longer expressible through this actor's public API at all (there is no
// `recordGraphUID` any more; a uid can only ever arrive attached to an
// anchor passed to `record`), so the test below is replaced by
// `uidTravelsWithItsAnchorNotSeparately`, which proves the new invariant
// directly instead of a violation of the old one.

import Foundation
import Testing
import OCCTSwift
@testable import OCCTMCPCore

@Suite("SelectionRegistry")
struct SelectionRegistryTests {

    func snapshot(_ x: Double = 0) -> AnchorSnapshot {
        AnchorSnapshot(center: [x, 0, 0])
    }

    @Test("clear() returns the exact count of entries removed, and empties the registry")
    func clearReturnsCountRemoved() async throws {
        let registry = SelectionRegistry()

        #expect(await registry.clear() == 0)

        await registry.record(anchor: .face(bodyId: "box", index: 0), snapshot: snapshot())
        await registry.record(anchor: .face(bodyId: "box", index: 1), snapshot: snapshot(1))
        await registry.record(anchor: .body(bodyId: "cyl"), snapshot: snapshot())

        #expect(await registry.count() == 3)

        let cleared = await registry.clear()
        #expect(cleared == 3)
        #expect(await registry.count() == 0)
        #expect(await registry.listEntries().isEmpty)
    }

    /// #150: `recordPointSnapshot` (used by `pick_surface_point`) populates
    /// only `snapshots`, never `anchors` — there's no `TopologyAnchor` for a
    /// free surface point. Before the fix, `count()`/`clear()` were
    /// `anchors.count`-based, so a point-snapshot-only entry was invisible to
    /// `count()` yet still silently wiped by `clear()`, understating the
    /// `cleared` figure `clear_selections` reports to the LLM. Both must
    /// count the union of `anchors.keys` and `snapshots.keys`.
    @Test("count() and clear() include point-snapshot-only entries, not just anchor-based ones")
    func countAndClearIncludePointSnapshots() async throws {
        let registry = SelectionRegistry()

        await registry.record(anchor: .face(bodyId: "box", index: 0), snapshot: snapshot())
        await registry.recordPointSnapshot(selectionId: "pick:box#abcd1234", snapshot: snapshot(1))

        #expect(await registry.count() == 2)

        let cleared = await registry.clear()
        #expect(cleared == 2)
        #expect(await registry.count() == 0)
    }

    /// The `clear()` primitive's count matches its removal under concurrent record calls.
    ///
    /// Every recorded selection is either still live at the end or counted by exactly one
    /// `clear()` return value.
    ///
    /// This guards only the `clear()` primitive (for example a future `await` in its body). It
    /// cannot detect #135, whose race lived in the caller (`clearSelections` calling `count()` and
    /// then `clear()`). A tool-layer version of this test was tried against that split and never
    /// went red (see #212), so no test here claims to cover it.
    @Test("clear() stays atomic with its own count under concurrent record/clear calls")
    func clearIsAtomicUnderConcurrency() async throws {
        let registry = SelectionRegistry()
        let totalRecords = 200

        let clearedCounts: [Int] = await withTaskGroup(of: Int?.self) { group in
            for i in 0..<totalRecords {
                group.addTask {
                    let anchor = TopologyAnchor.face(bodyId: "body\(i)", index: i)
                    await registry.record(anchor: anchor, snapshot: AnchorSnapshot(center: [Double(i), 0, 0]))
                    return nil
                }
            }
            for _ in 0..<20 {
                group.addTask {
                    await registry.clear()
                }
            }
            var results: [Int] = []
            for await value in group {
                if let cleared = value { results.append(cleared) }
            }
            return results
        }

        let finalCount = await registry.count()
        #expect(clearedCounts.reduce(0, +) + finalCount == totalRecords)

        // #151 (2): the aggregate count invariant above can't catch a
        // regression that decouples `anchors`/`snapshots` under concurrency
        // (e.g. a survivor whose anchor lives but whose snapshot doesn't, or
        // vice versa) — only their totals would still add up. Every entry
        // `listEntries()` reports as still live must have a non-nil
        // `snapshot`, since `record(anchor:snapshot:)` always writes both
        // dictionaries together and nothing else touches `anchors` here.
        let survivors = await registry.listEntries()
        #expect(survivors.count == finalCount)
        for entry in survivors {
            #expect(entry.snapshot != nil, "\(entry.selectionId) survived without a matching snapshot")
        }
    }

    /// #182: `uid` travels as a field on the recorded `TopologyAnchor`
    /// itself, written by the SAME `record` call as `bodyId`/`index`/the
    /// snapshot, never by a separate call the way the retired
    /// `recordGraphUID` worked. Three things this proves together: (1) a
    /// uid-carrying anchor is counted exactly once by `count()`/`clear()`,
    /// same as a uid-less one (no double-counting introduced by folding
    /// uid into the anchor value); (2) `graphUID(for:)` reads back the
    /// SAME uid that was attached at record time, straight off the stored
    /// anchor; (3) an anchor recorded with a uid, then re-recorded without
    /// one (a plain `.face(bodyId:index:)` construction, `uid` defaulting
    /// to nil), clears the previously-cached uid rather than leaving a
    /// stale one behind, the same "record replaces the whole entry"
    /// semantics `record`'s doc comment already promised for the snapshot,
    /// extended to uid now that it lives on the same value.
    @Test("a recorded anchor's uid travels with it, not through a separate table")
    func uidTravelsWithItsAnchorNotSeparately() async throws {
        let registry = SelectionRegistry()

        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let graph = try #require(BRepGraph(shape: box))
        let uid = try #require(graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0))

        let anchor = TopologyAnchor.face(bodyId: "box", index: 0, uid: uid)
        #expect(anchor.selectionId == "sel:box#face[0]")
        await registry.record(anchor: anchor, snapshot: snapshot())

        // A second, uid-less selection: count()/clear() must not treat the
        // presence of a uid on one entry as adding a phantom extra entry.
        await registry.record(anchor: .edge(bodyId: "box", index: 1), snapshot: snapshot(1))

        #expect(await registry.count() == 2)
        #expect(await registry.graphUID(for: "sel:box#face[0]") == uid)
        #expect(await registry.graphUID(for: "sel:box#edge[1]") == nil)

        // Re-recording the same selectionId with a uid-less anchor (the
        // default `uid: nil`) must clear the previously-cached uid, not
        // leave it stranded: `record` replaces the whole stored value.
        await registry.record(anchor: .face(bodyId: "box", index: 0), snapshot: snapshot())
        #expect(await registry.graphUID(for: "sel:box#face[0]") == nil)
        #expect(await registry.count() == 2, "re-recording the same id must not grow the count")

        let cleared = await registry.clear()
        #expect(cleared == 2)
        #expect(await registry.count() == 0)
    }

    /// `TopologyAnchor.withUID` (#182): the ergonomic path for a caller
    /// that resolves an anchor's index first (e.g. via
    /// `SelectionTools.graphIndex`) and only later has a graph in hand to
    /// look up its uid (`CorrespondenceTools.withGraphUID`,
    /// `RemapTools.refreshAfterHistoryRemap`). Must attach on every
    /// face/edge/vertex case, and must be a documented no-op on `.body`
    /// (never a graph node, so there is nothing to attach a uid to).
    @Test("TopologyAnchor.withUID attaches on face/edge/vertex, no-ops on body")
    func withUIDAttachesPerCase() async throws {
        let box = try #require(Shape.box(width: 10, height: 20, depth: 30))
        let graph = try #require(BRepGraph(shape: box))
        let uid = try #require(graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: 0))

        let face = TopologyAnchor.face(bodyId: "box", index: 0).withUID(uid)
        #expect(face.uid == uid)
        #expect(face.nodeKind == .face)

        let edge = TopologyAnchor.edge(bodyId: "box", index: 2).withUID(uid)
        #expect(edge.uid == uid)

        let vertex = TopologyAnchor.vertex(bodyId: "box", index: 5).withUID(uid)
        #expect(vertex.uid == uid)

        let body = TopologyAnchor.body(bodyId: "box").withUID(uid)
        #expect(body.uid == nil, "a body anchor is never a graph node; withUID must be a no-op")
        #expect(body.nodeKind == nil)
    }
}
