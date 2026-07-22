// ZoneRegistry — server-side store of segmented mesh zones, minted by
// `segment_mesh_zones` (#101) and resolved by `zone_continuity_sweep` (#102).
// Mirrors SelectionRegistry's actor-cache-plus-sidecar shape: the LLM gets
// back stable `zone:<bodyId>#<n>` ids, then refers to one from a later call
// without re-segmenting.
//
// File layout: <output_dir>/zones.json
//
// {
//   "version": 1,
//   "zones": [
//     { "zoneId": "zone:box#0", "bodyId": "box", "index": 0,
//       "triangleIndices": [0, 1, 2, ...], "areaMm2": 900.0,
//       "fit": { "kind": "plane", "params": [...], "residualRmsMm": 0.01,
//                "residualMaxMm": 0.02, "inlierRatio": 1.0 },
//       "params": { "maxDihedralDegrees": 20, "mergeRelativeTolerance": 0.004,
//                   "maxMergeAngleDegrees": 50, "minRegionTriangles": 8,
//                   "maxZones": 64, "deflection": 0.5 },
//       "meshSignature": { "triangleCount": 1234, "bboxMin": [...], "bboxMax": [...] },
//       "slippage": { "kind": "plane", "axisPoint": [...], "axisDirection": [...],
//                     "pitchPerRadianMm": null, "confidence": 0.92 } }
//   ]
// }
//
// `slippage` (#109, OCCTSwiftMesh#26/#31) is OPTIONAL: a sidecar written
// before this landed has no such key at all, and Swift's synthesized
// `Decodable` treats a missing key on an `Optional` property as `nil`, not a
// decode error — no version bump needed. See `ZoneSlippage`'s doc comment
// for the field semantics (axis sign arbitrariness, confidence-as-gap, the
// per-kind axis meaning).

import Foundation

public struct ZoneFit: Sendable, Codable {
    public let kind: String
    public let params: [Double]
    public let residualRmsMm: Double
    public let residualMaxMm: Double
    public let inlierRatio: Double
    public init(kind: String, params: [Double], residualRmsMm: Double, residualMaxMm: Double, inlierRatio: Double) {
        self.kind = kind
        self.params = params
        self.residualRmsMm = residualRmsMm
        self.residualMaxMm = residualMaxMm
        self.inlierRatio = inlierRatio
    }
}

/// A zone's surface-kind classification + characteristic axis, by local
/// slippage analysis (Gelfand & Guibas, SGP 2004 — OCCTSwiftMesh#26/#31,
/// `Mesh.slippage(forTriangles:maxSamples:)`, >=1.6.0). Mirrors
/// `SlippageResult` field-for-field, minus `eigenRatios` (an internal
/// diagnostic array, not bounded LLM-facing output — `confidence` is the
/// summary that matters).
///
/// `axisDirection`'s SIGN is arbitrary (inherent to the underlying
/// eigenvector recovery — a flipped axis is still the same axis). Its
/// MEANING depends on `kind`: rotation/screw axis for cylinder/revolution/
/// helix; the extrude direction for extrusion; the surface NORMAL for
/// plane (never a sweep direction); `nil` for sphere (no preferred axis)
/// and freeform.
///
/// `confidence` is a spectral-gap diagnostic in `[0, 1]`, not a
/// probability: a wide gap between the slippable and non-slippable
/// eigenvalues means a confident classification, while a gap barely past
/// the detection floor means the kind boundary itself is close to
/// arbitrary — this is what makes a near-symmetric body (whose true
/// eigen-spectrum has no clean separation to begin with) read as
/// low-confidence rather than confidently wrong.
public struct ZoneSlippage: Sendable, Codable {
    public let kind: String
    public let axisPoint: [Double]?
    public let axisDirection: [Double]?
    public let pitchPerRadianMm: Double?
    public let confidence: Double
    public init(kind: String, axisPoint: [Double]?, axisDirection: [Double]?, pitchPerRadianMm: Double?, confidence: Double) {
        self.kind = kind
        self.axisPoint = axisPoint
        self.axisDirection = axisDirection
        self.pitchPerRadianMm = pitchPerRadianMm
        self.confidence = confidence
    }
}

/// The segmentation parameters that produced a zone table, carried alongside
/// each zone so a later `zone_continuity_sweep` (or a curious LLM) can see
/// exactly how it was cut without re-reading the `segment_mesh_zones` call.
public struct SegmentParamsUsed: Sendable, Codable {
    public let maxDihedralDegrees: Double
    public let mergeRelativeTolerance: Double
    public let maxMergeAngleDegrees: Double
    public let minRegionTriangles: Int
    public let maxZones: Int?
    public let deflection: Double
    public init(
        maxDihedralDegrees: Double, mergeRelativeTolerance: Double, maxMergeAngleDegrees: Double,
        minRegionTriangles: Int, maxZones: Int?, deflection: Double
    ) {
        self.maxDihedralDegrees = maxDihedralDegrees
        self.mergeRelativeTolerance = mergeRelativeTolerance
        self.maxMergeAngleDegrees = maxMergeAngleDegrees
        self.minRegionTriangles = minRegionTriangles
        self.maxZones = maxZones
        self.deflection = deflection
    }
}

/// Cheap fingerprint of the body's mesh at segmentation time: triangle count
/// plus bounding box. Not a content hash (too expensive to store/compare at
/// scan scale) — a body edit that happens to preserve both is the one case
/// this misses, an accepted trade-off for a fast staleness check. Every
/// `ZoneRecord.triangleIndices` is only meaningful against a mesh built with
/// the SAME deflection this signature was captured from (see
/// `ZoneSweepTool`, which re-meshes zone-scoped sweeps at `params.deflection`
/// rather than a caller-supplied one).
public struct MeshSignature: Sendable, Codable, Equatable {
    public let triangleCount: Int
    public let bboxMin: [Double]
    public let bboxMax: [Double]
    public init(triangleCount: Int, bboxMin: [Double], bboxMax: [Double]) {
        self.triangleCount = triangleCount
        self.bboxMin = bboxMin
        self.bboxMax = bboxMax
    }

    public func matches(_ other: MeshSignature, epsilon: Double = 1e-6) -> Bool {
        guard triangleCount == other.triangleCount else { return false }
        guard bboxMin.count == 3, bboxMax.count == 3,
              other.bboxMin.count == 3, other.bboxMax.count == 3 else { return false }
        for i in 0..<3 {
            if abs(bboxMin[i] - other.bboxMin[i]) > epsilon { return false }
            if abs(bboxMax[i] - other.bboxMax[i]) > epsilon { return false }
        }
        return true
    }
}

public struct ZoneRecord: Sendable, Codable {
    public let zoneId: String
    public let bodyId: String
    public let index: Int
    /// Indices into the body's own mesh (built with `params.deflection`)
    /// triangle list, in the SAME order `Mesh.indices` uses (`indices[i*3
    /// ..< i*3+3]` per `i` here) — the `MeshRegion.triangleIndices`
    /// convention this is copied from.
    public let triangleIndices: [Int]
    public let areaMm2: Double
    public let fit: ZoneFit
    public let params: SegmentParamsUsed
    public let meshSignature: MeshSignature
    /// Optional so a `zones.json` sidecar written before #109 (no `slippage`
    /// key at all) still decodes: Swift's synthesized `Decodable` treats a
    /// missing key on an `Optional` stored property as `nil` rather than an
    /// error. `nil` also covers the same-session case where the mesh's own
    /// weld guard failed (see `MeshZoneTools`'s `adjacentZones` comment —
    /// slippage needs the identical welded-mesh correspondence).
    public let slippage: ZoneSlippage?

    public init(
        zoneId: String, bodyId: String, index: Int, triangleIndices: [Int], areaMm2: Double,
        fit: ZoneFit, params: SegmentParamsUsed, meshSignature: MeshSignature, slippage: ZoneSlippage? = nil
    ) {
        self.zoneId = zoneId
        self.bodyId = bodyId
        self.index = index
        self.triangleIndices = triangleIndices
        self.areaMm2 = areaMm2
        self.fit = fit
        self.params = params
        self.meshSignature = meshSignature
        self.slippage = slippage
    }
}

public struct ZonesSidecar: Codable, Sendable {
    public var version: Int
    public var zones: [ZoneRecord]
    public init(version: Int = 1, zones: [ZoneRecord] = []) {
        self.version = version
        self.zones = zones
    }
}

public struct ZonesStore: Sendable {
    public let path: String
    public init(outputDir: String) {
        self.path = "\(outputDir)/zones.json"
    }
    public init(path: String) {
        self.path = path
    }

    public func read() -> ZonesSidecar {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode(ZonesSidecar.self, from: data) else {
            return ZonesSidecar()
        }
        return decoded
    }

    public func write(_ sidecar: ZonesSidecar) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sidecar)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}

/// In-memory zone cache, write-through to `<output_dir>/zones.json` on every
/// mutation. `records` and the sidecar are kept in sync by every mutating
/// call, so the ONLY case a fresh actor instance needs to catch up from disk
/// is its very first touch of a given output dir (a process restart, or the
/// first call in a session) — `loadSidecarIfNeeded` handles exactly that,
/// gated on a one-shot `hasSynced` flag. This mirrors
/// SelectionRegistry's shape (actor cache + parseable ids) plus Annotations'
/// disk-sidecar persistence, one level up: SelectionRegistry never persists
/// (a session's picks are meant to be ephemeral); zones are meant to survive
/// a restart so a later `zone_continuity_sweep` call can resolve one minted
/// in an earlier process.
public actor ZoneRegistry {
    public static let shared = ZoneRegistry()

    private var records: [String: ZoneRecord] = [:]
    private var hasSynced = false

    public init() {}

    /// Pull in whatever the sidecar for `store` already has, once per actor
    /// instance. Safe to call before every operation; only does work the
    /// first time.
    public func loadSidecarIfNeeded(store: ZonesStore) {
        guard !hasSynced else { return }
        hasSynced = true
        for z in store.read().zones { records[z.zoneId] = z }
    }

    public func nextIndex(bodyId: String) -> Int {
        (records.values.filter { $0.bodyId == bodyId }.map(\.index).max() ?? -1) + 1
    }

    public func zone(_ zoneId: String) -> ZoneRecord? {
        records[zoneId]
    }

    public func zones(forBody bodyId: String) -> [ZoneRecord] {
        records.values.filter { $0.bodyId == bodyId }.sorted { $0.index < $1.index }
    }

    public func all() -> [ZoneRecord] {
        records.values.sorted { $0.zoneId < $1.zoneId }
    }

    /// Record a batch of zones (one `segment_mesh_zones` call mints several),
    /// SUPERSEDING every existing zone for each `bodyId` present in the
    /// batch, and persist once, not once per zone.
    ///
    /// A body's zone table has to reflect exactly ONE segmentation at a
    /// time. Without the supersede, re-running `segment_mesh_zones` on a
    /// body with params that yield FEWER zones than a prior run would leave
    /// the prior run's stale higher-numbered `zone:<body>#<k>` records
    /// resolvable — the underlying mesh didn't change, only the
    /// segmentation did, so `MeshSignature` still matches — and `list_zones`
    /// would show a mix of two different segmentations for that body.
    /// Superseding first (remove every record whose `bodyId` is in the
    /// batch, THEN insert the batch) guarantees a body's zones always come
    /// from a single `segment_mesh_zones` call. Other bodies' zones are
    /// untouched.
    public func recordBatch(_ recs: [ZoneRecord], store: ZonesStore) {
        let bodyIds = Set(recs.map(\.bodyId))
        let stale = records.values.filter { bodyIds.contains($0.bodyId) }.map(\.zoneId)
        for k in stale { records.removeValue(forKey: k) }
        for r in recs { records[r.zoneId] = r }
        persist(store: store)
    }

    /// Drop zones for `bodyId`, or every zone when `bodyId` is nil. Returns
    /// the count cleared.
    @discardableResult
    public func clear(bodyId: String?, store: ZonesStore) -> Int {
        let toRemove = bodyId == nil
            ? Array(records.keys)
            : records.values.filter { $0.bodyId == bodyId }.map(\.zoneId)
        for k in toRemove { records.removeValue(forKey: k) }
        persist(store: store)
        return toRemove.count
    }

    private func persist(store: ZonesStore) {
        try? store.write(ZonesSidecar(zones: all()))
    }
}
