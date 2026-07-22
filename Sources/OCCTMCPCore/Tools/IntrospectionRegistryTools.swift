// IntrospectionRegistryTools — list_selections, clear_selections,
// list_annotations, list_zones, clear_zones. Cheap state-introspection tools
// so the LLM can see what's been accumulated in the SelectionRegistry /
// AnnotationsStore / ZoneRegistry without re-running select_topology /
// segment_mesh_zones or re-reading a sidecar by hand.

import Foundation

public enum RegistryIntrospectionTools {

    // MARK: - list_selections

    public struct ListSelectionsResult: Encodable {
        public let count: Int
        public let selections: [SelectionRegistry.Entry]
    }

    public static func listSelections(
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let entries = await registry.listEntries()
        return IntrospectionTools.encode(ListSelectionsResult(
            count: entries.count,
            selections: entries
        ))
    }

    // MARK: - clear_selections

    public struct ClearSelectionsResult: Encodable {
        public let cleared: Int
    }

    public static func clearSelections(
        registry: SelectionRegistry = .shared
    ) async -> ToolText {
        let count = await registry.count()
        await registry.clear()
        return IntrospectionTools.encode(ClearSelectionsResult(cleared: count))
    }

    // MARK: - list_annotations

    public struct ListAnnotationsResult: Encodable {
        public let dimensions: [DimensionAnnotation]
        public let primitives: [PrimitiveAnnotation]
    }

    public static func listAnnotations(
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let sidecar = AnnotationsStore(outputDir: outputDir).read()
        return IntrospectionTools.encode(ListAnnotationsResult(
            dimensions: sidecar.dimensions,
            primitives: sidecar.primitives
        ))
    }

    // MARK: - list_zones

    public struct ListZonesResult: Encodable {
        public let count: Int
        public let zones: [ZoneSummary]

        public struct ZoneSummary: Encodable {
            public let zoneId: String
            public let bodyId: String
            public let index: Int
            public let triangleCount: Int
            public let areaMm2: Double
            public let fitKind: String
            /// `ZoneRecord.slippage?.kind` (#109) — `nil` for a zone minted
            /// before slippage classification landed, or one whose weld
            /// guard failed at segmentation time (see `MeshZoneTools`).
            public let slippageKind: String?
        }
    }

    public static func listZones(
        bodyId: String? = nil,
        registry: ZoneRegistry = .shared,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let zonesStore = ZonesStore(outputDir: outputDir)
        await registry.loadSidecarIfNeeded(store: zonesStore)
        let zones: [ZoneRecord]
        if let id = bodyId {
            zones = await registry.zones(forBody: id)
        } else {
            zones = await registry.all()
        }
        let summaries = zones.map {
            ListZonesResult.ZoneSummary(
                zoneId: $0.zoneId, bodyId: $0.bodyId, index: $0.index,
                triangleCount: $0.triangleIndices.count, areaMm2: $0.areaMm2, fitKind: $0.fit.kind,
                slippageKind: $0.slippage?.kind
            )
        }
        return IntrospectionTools.encode(ListZonesResult(count: summaries.count, zones: summaries))
    }

    // MARK: - clear_zones

    public struct ClearZonesResult: Encodable {
        public let cleared: Int
    }

    public static func clearZones(
        bodyId: String? = nil,
        registry: ZoneRegistry = .shared,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let zonesStore = ZonesStore(outputDir: outputDir)
        await registry.loadSidecarIfNeeded(store: zonesStore)
        let cleared = await registry.clear(bodyId: bodyId, store: zonesStore)
        return IntrospectionTools.encode(ClearZonesResult(cleared: cleared))
    }
}
