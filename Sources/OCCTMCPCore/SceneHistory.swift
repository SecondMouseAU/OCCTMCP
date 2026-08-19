// SceneHistory: in-memory ring buffer of recent manifest snapshots.
// `compare_versions` reads from it; every scene-mutating tool (and
// execute_script once it's ported) calls `snapshot()` *before*
// mutating so the next compare can diff current vs prior.
//
// Singleton wrapped in an actor so it's safe to call from any
// concurrent tool handler.

import Foundation
import ScriptHarness

public actor SceneHistory {
    public static let shared = SceneHistory()

    public static let maxSnapshots = 10

    public init() {}

    private var snapshots: [ScriptManifest] = []

    /// Capture the current manifest into the ring.
    ///
    /// No-op if the
    /// manifest doesn't exist or fails to parse.
    public func snapshot(store: ManifestStore = ManifestStore()) async {
        guard let manifest = try? store.read() else { return }
        snapshots.append(manifest)
        if snapshots.count > Self.maxSnapshots {
            snapshots.removeFirst()
        }
    }

    public func count() -> Int { snapshots.count }

    public func clear() { snapshots.removeAll() }

    /// Return the snapshot from `since` runs back, or nil when the
    /// history is shallower than that.
    public func snapshot(since: Int) -> ScriptManifest? {
        let idx = snapshots.count - since
        guard idx >= 0, idx < snapshots.count else { return nil }
        return snapshots[idx]
    }
}
