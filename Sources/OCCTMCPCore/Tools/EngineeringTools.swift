// EngineeringTools: wall-thickness analysis and other engineering
// inspection algorithms that need to live in OCCTMCP itself rather than
// in OCCTSwift's primitives. Each tool is a direct port of the
// equivalent occtkit verb.

import Foundation
import OCCTSwift
import ScriptHarness
import simd

public enum EngineeringTools {

    // ── check_thickness ────────────────────────────────────────────────

    public enum SamplingDensity: String {
        case coarse, medium, fine
        var grid: Int {
            switch self {
            case .coarse: return 4
            case .medium: return 8
            case .fine: return 16
            }
        }
    }

    public struct ThicknessReport: Encodable {
        public let minThickness: Double?
        public let maxThickness: Double?
        public let meanThickness: Double?
        public let thinRegions: [ThinRegion]
        public let samples: Int

        public struct ThinRegion: Encodable {
            public let centerPoint: [Double]
            public let thickness: Double
            public let faceRefs: [String]
        }
    }

    /// Wall-thickness analysis.
    ///
    /// For each face, sample on a UV grid; for
    /// each sample cast a ray inward (along -normal) and record the
    /// distance to the nearest opposite-side hit. Aggregate min / max /
    /// mean and surface samples below `minAcceptable` as `thinRegions`.
    public static func checkThickness(
        bodyId: String,
        minAcceptable: Double? = nil,
        samplingDensity: SamplingDensity = .medium,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let shape = loaded.shape
        let faces = shape.faces()

        let resolution = samplingDensity.grid
        let eps = 1e-4
        var minT: Double = .infinity
        var maxT: Double = 0
        var sum: Double = 0
        var sampled = 0
        var thinRegions: [ThicknessReport.ThinRegion] = []

        for (faceIndex, face) in faces.enumerated() {
            guard let uv = face.uvBounds else { continue }
            let denom = Double(max(1, resolution - 1))
            for i in 0..<resolution {
                for j in 0..<resolution {
                    let u = uv.uMin + (uv.uMax - uv.uMin) * Double(i) / denom
                    let v = uv.vMin + (uv.vMax - uv.vMin) * Double(j) / denom
                    guard let point = face.point(atU: u, v: v),
                        let normal = face.normal(atU: u, v: v)
                    else { continue }
                    let n = simd_normalize(normal)
                    let inward = -n
                    let rayOrigin = point + eps * inward
                    let hits = shape.intersectLine(origin: rayOrigin, direction: inward)
                    guard
                        let nearest =
                            hits
                            .map(\.parameter)
                            .filter({ $0 > 0 })
                            .min()
                    else { continue }
                    let thickness = nearest
                    sampled += 1
                    sum += thickness
                    if thickness < minT { minT = thickness }
                    if thickness > maxT { maxT = thickness }
                    if let limit = minAcceptable, thickness < limit {
                        thinRegions.append(
                            .init(
                                centerPoint: [point.x, point.y, point.z],
                                thickness: thickness,
                                faceRefs: ["face[\(faceIndex)]"]
                            ))
                    }
                }
            }
        }

        return IntrospectionTools.encode(
            ThicknessReport(
                minThickness: sampled > 0 ? minT : nil,
                maxThickness: sampled > 0 ? maxT : nil,
                meanThickness: sampled > 0 ? sum / Double(sampled) : nil,
                thinRegions: thinRegions,
                samples: sampled
            ))
    }
}
