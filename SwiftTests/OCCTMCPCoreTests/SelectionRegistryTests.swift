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

import Foundation
import Testing
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

    /// Interleaves many concurrent `record` calls with several concurrent
    /// `clear` calls on the same actor instance. Because Swift actors only
    /// serialize the body of a single call, this reproduces the exact
    /// window #135 was about: a task can land on the actor between what
    /// used to be a separate `count()` read and the following `clear()`.
    ///
    /// The invariant checked: every recorded selection is either still live
    /// at the end, or was counted by exactly one `clear()` call's return
    /// value; none can be lost in between. That only holds when `clear()`
    /// computes its count and performs the removal in one atomic actor hop
    /// (the fix); a split count()-then-clear() can let a just-added
    /// selection be swept up by the removal without ever being reflected in
    /// any reported `cleared` value, breaking the invariant.
    ///
    /// #151 note: this test validates the NEW `Int`-returning `clear()`
    /// primitive's atomicity going forward (a regression guard against, e.g.,
    /// a future `await` sneaking into `clear()`'s body and breaking its
    /// single-hop guarantee). It does NOT literally reproduce the original
    /// #135 bug: that race lived in the CALLER-level composition
    /// (`IntrospectionRegistryTools.clearSelections` doing a separate
    /// `count()` then a separate `clear()`), and the pre-fix `clear()`
    /// returned `Void`, so this test — written against the current `Int`
    /// signature — can't even compile against that code to demonstrate it
    /// failing there. Don't read a future untouched pass here as evidence
    /// some hypothetical reverted caller-level version would also pass.
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
}
