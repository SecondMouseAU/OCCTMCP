// GapFillerTools — show_bounding_box, diff_overlay, select_by_feature.
// Three small wins layered on the SelectionRegistry + AnnotationsStore
// + recognize_features primitives we already have.
//
// All three are compositions over existing tools rather than fresh
// OCCT calls — they make common LLM idioms one tool call instead of
// several.

import Foundation
import simd
import OCCTSwift
import ScriptHarness

public enum GapFillerTools {

    // MARK: - show_bounding_box

    public struct BoundingBoxResult: Encodable {
        public let primitiveId: String
        public let bodyId: String
        public let min: [Double]
        public let max: [Double]
        public let extent: [Double]
        public let center: [Double]
    }

    /// Compute a body's axis-aligned bounding box and register it as a
    /// `boundingBox` scene primitive. The renderer can draw the
    /// 12-edge wireframe later; for now the value is also returned
    /// inline so the LLM can reason about it.
    public static func showBoundingBox(
        bodyId: String,
        primitiveId: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let bb = loaded.shape.bounds
        let minP = [bb.min.x, bb.min.y, bb.min.z]
        let maxP = [bb.max.x, bb.max.y, bb.max.z]
        let extent = [
            bb.max.x - bb.min.x,
            bb.max.y - bb.min.y,
            bb.max.z - bb.min.z,
        ]
        let center = [
            (bb.min.x + bb.max.x) * 0.5,
            (bb.min.y + bb.max.y) * 0.5,
            (bb.min.z + bb.max.z) * 0.5,
        ]
        let id = primitiveId ?? "bbox_\(bodyId)"
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir)
        var doc = sidecar.read()
        doc.primitives.removeAll { $0.id == id }
        doc.primitives.append(.init(
            id: id, kind: "boundingBox",
            params: [
                "bodyId": .string(bodyId),
                "min": .array(minP.map { .number($0) }),
                "max": .array(maxP.map { .number($0) }),
            ]
        ))
        try? sidecar.write(doc)
        return IntrospectionTools.encode(BoundingBoxResult(
            primitiveId: id,
            bodyId: bodyId,
            min: minP,
            max: maxP,
            extent: extent,
            center: center
        ))
    }

    // MARK: - diff_overlay

    public struct DiffOverlayResult: Encodable {
        public let added: [String]
        public let removed: [String]
        public let appearanceChanged: [String]
        public let fileChanged: [String]
        public let primitiveIds: [String]
    }

    /// Visualise a recent scene change. Reads compare_versions data,
    /// drops a tinted scene primitive at each affected body's bbox so
    /// the LLM (and a future viewport) can see what moved at a glance.
    /// Added → green, removed → red, appearance/file changed → yellow.
    public static func diffOverlay(
        since: Int = 1,
        store: ManifestStore = ManifestStore(),
        history: SceneHistory = .shared
    ) async -> ToolText {
        guard let current = try? store.read() else {
            return .init("No scene loaded.")
        }
        let availableCount = await history.count()
        guard let prior = await history.snapshot(since: since) else {
            return .init("Not enough history: requested \(since), have \(availableCount).")
        }
        let diff = SceneTools.diffManifests(
            prev: prior, curr: current,
            since: since, available: availableCount
        )
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir)
        var doc = sidecar.read()
        var primitiveIds: [String] = []

        func registerOverlay(bodyId: String, color: [Double], suffix: String) {
            // Look up the body's bbox from the live manifest — for
            // removed bodies we don't have a current shape, so the
            // prior manifest's body is used to position a marker.
            let manifest = (current.body(withId: bodyId) != nil) ? current : prior
            guard let body = manifest.body(withId: bodyId) else { return }
            let path = "\(outputDir)/\(body.file)"
            guard FileManager.default.fileExists(atPath: path),
                  let shape = try? Shape.loadBREP(fromPath: path) else { return }
            let bb = shape.bounds
            let centre = [
                (bb.min.x + bb.max.x) * 0.5,
                (bb.min.y + bb.max.y) * 0.5,
                (bb.min.z + bb.max.z) * 0.5,
            ]
            let extent = [
                bb.max.x - bb.min.x,
                bb.max.y - bb.min.y,
                bb.max.z - bb.min.z,
            ]
            let id = "diff_\(suffix)_\(bodyId)"
            doc.primitives.removeAll { $0.id == id }
            doc.primitives.append(.init(
                id: id, kind: "diffMarker",
                params: [
                    "bodyId": .string(bodyId),
                    "fate": .string(suffix),
                    "center": .array(centre.map { .number($0) }),
                    "extent": .array(extent.map { .number($0) }),
                    "color": .array(color.map { .number($0) }),
                ]
            ))
            primitiveIds.append(id)
        }

        let green: [Double] = [0.2, 0.85, 0.2, 0.5]
        let red: [Double] = [0.85, 0.2, 0.2, 0.5]
        let yellow: [Double] = [0.95, 0.85, 0.1, 0.5]
        for id in diff.added { registerOverlay(bodyId: id, color: green, suffix: "added") }
        for id in diff.removed { registerOverlay(bodyId: id, color: red, suffix: "removed") }
        for entry in diff.appearanceChanged { registerOverlay(bodyId: entry.id, color: yellow, suffix: "appchg") }
        for id in diff.fileChanged { registerOverlay(bodyId: id, color: yellow, suffix: "filechg") }

        try? sidecar.write(doc)
        return IntrospectionTools.encode(DiffOverlayResult(
            added: diff.added,
            removed: diff.removed,
            appearanceChanged: diff.appearanceChanged.map(\.id),
            fileChanged: diff.fileChanged,
            primitiveIds: primitiveIds
        ))
    }

    // MARK: - select_by_feature

    public struct FeatureSelection: Encodable {
        public let kind: String              // "hole" | "pocket"
        public let selectionId: String
        public let detail: AnchorSnapshot
    }
    public struct FeatureSelectionsResult: Encodable {
        public let bodyId: String
        public let selections: [FeatureSelection]
    }

    /// Run AAG feature recognition, then turn each detected hole / pocket
    /// into a selectionId pointing at the relevant face (hole faceIndex,
    /// or pocket floorFaceIndex). The LLM can then dimension or refer
    /// to those features without re-running query_topology.
    public static func selectByFeature(
        bodyId: String,
        kinds: [String]? = nil,
        store: ManifestStore = ManifestStore(),
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        // #91/#93: resolve through the retained lineage graph rather than
        // trusting AAG's floorFaceIndex/faceIndex; those address
        // shape.faces() enumeration order, which the graph's own node
        // index doesn't always match (true for faces only by coincidence,
        // see TopologyIdentityTests).
        let lineage: (shape: Shape, graph: BRepGraph, root: BRepGraph.NodeRef, isFreshLoad: Bool)
        do {
            lineage = try await HistoryRegistry.shared.currentInput(bodyId: bodyId, path: loaded.path)
        } catch {
            return .init("\(error)")
        }
        let shape = lineage.shape
        let graph = lineage.graph
        let aag = AAG(shape: shape)
        let wantPockets = kinds.map { $0.contains("pocket") } ?? true
        let wantHoles = kinds.map { $0.contains("hole") } ?? true

        let allFaces = shape.faces()
        var results: [FeatureSelection] = []

        func mintFaceSelection(kind: String, faceIndex: Int) async {
            guard faceIndex < allFaces.count else { return }
            let face = allFaces[faceIndex]
            let (centre, normal) = SelectionTools.faceCenterAndNormal(face: face)
            let snap = AnchorSnapshot(
                center: [centre.x, centre.y, centre.z],
                normal: normal.map { [$0.x, $0.y, $0.z] },
                area: face.area(),
                surfaceType: String(describing: face.surfaceType)
            )
            let resolvedIndex = SelectionTools.graphIndex(
                for: Shape.fromFace(face), kind: .face, in: graph, fallback: faceIndex
            )
            let anchor = TopologyAnchor.face(bodyId: bodyId, index: resolvedIndex)
            await registry.record(anchor: anchor, snapshot: snap)
            if let uid = graph.uid(ofNodeKind: Int(BRepGraph.NodeKind.face.rawValue), index: resolvedIndex) {
                await registry.recordGraphUID(selectionId: anchor.selectionId, uid: uid)
            }
            results.append(.init(kind: kind, selectionId: anchor.selectionId, detail: snap))
        }

        if wantPockets {
            for pocket in aag.detectPockets() {
                await mintFaceSelection(kind: "pocket", faceIndex: pocket.floorFaceIndex)
            }
        }
        if wantHoles {
            for hole in aag.detectHoles() {
                await mintFaceSelection(kind: "hole", faceIndex: hole.faceIndex)
            }
        }
        return IntrospectionTools.encode(FeatureSelectionsResult(
            bodyId: bodyId,
            selections: results
        ))
    }
}
