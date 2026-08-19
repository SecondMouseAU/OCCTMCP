// Annotations: sidecar JSON next to manifest.json carrying the
// scene-level dimensions and standard scene primitives that the v0.4
// AIS-shaped tools produce. Manifest schema is left untouched so this
// is a contained extension; render_preview reads the sidecar if
// present, OCCTSwiftViewport could later opt-in too.
//
// File layout: <output_dir>/annotations.json
//
// {
//   "version": 1,
//   "dimensions": [
//     { "id": "dim_overall", "kind": "linear",
//       "anchors": { "from": "sel:cyl#vertex[0]", "to": "sel:cyl#vertex[1]" },
//       "value": 50.2, "label": null }
//   ],
//   "primitives": [
//     { "id": "wp_sketch", "kind": "workPlane",
//       "params": { "origin": [0,0,0], "normal": [0,0,1], "size": 100,
//                   "color": [0.5, 0.6, 0.85, 0.25] } }
//   ]
// }

import Foundation

public struct AnnotationsSidecar: Codable, Sendable {
    public var version: Int
    public var dimensions: [DimensionAnnotation]
    public var primitives: [PrimitiveAnnotation]

    public init(
        version: Int = 1,
        dimensions: [DimensionAnnotation] = [],
        primitives: [PrimitiveAnnotation] = []
    ) {
        self.version = version
        self.dimensions = dimensions
        self.primitives = primitives
    }
}

public struct DimensionAnnotation: Codable, Sendable {
    public let id: String
    public let kind: String  // "linear" | "angular" | "radial"
    public let anchors: [String: String]  // role → selectionId
    public var value: Double?  // computed at write-time
    public var label: String?
    public var anchorPoints: [[Double]]?  // resolved at write-time
    public init(
        id: String,
        kind: String,
        anchors: [String: String],
        value: Double? = nil,
        label: String? = nil,
        anchorPoints: [[Double]]? = nil
    ) {
        self.id = id
        self.kind = kind
        self.anchors = anchors
        self.value = value
        self.label = label
        self.anchorPoints = anchorPoints
    }
}

public struct PrimitiveAnnotation: Codable, Sendable {
    public let id: String
    public let kind: String  // "trihedron" | "workPlane" | "axis" | "pointCloud"
    public let params: [String: AnyCodable]
    public init(id: String, kind: String, params: [String: AnyCodable]) {
        self.id = id
        self.kind = kind
        self.params = params
    }
}

/// Tiny JSON value type so PrimitiveAnnotation.params can carry the
/// per-kind shape without proliferating concrete structs.
public enum AnyCodable: Codable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([AnyCodable])
    case object([String: AnyCodable])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let v = try? c.decode(Bool.self) {
            self = .bool(v)
            return
        }
        if let v = try? c.decode(Double.self) {
            self = .number(v)
            return
        }
        if let v = try? c.decode(String.self) {
            self = .string(v)
            return
        }
        if let v = try? c.decode([AnyCodable].self) {
            self = .array(v)
            return
        }
        if let v = try? c.decode([String: AnyCodable].self) {
            self = .object(v)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "Unsupported JSON value"
        )
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

public struct AnnotationsStore: Sendable {
    public let path: String
    public init(outputDir: String = OCCTMCPPaths.outputDir()) {
        self.path = "\(outputDir)/annotations.json"
    }
    public init(path: String) {
        self.path = path
    }

    public func read() -> AnnotationsSidecar {
        guard FileManager.default.fileExists(atPath: path),
            let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
            let decoded = try? JSONDecoder().decode(AnnotationsSidecar.self, from: data)
        else {
            return AnnotationsSidecar()
        }
        return decoded
    }

    public func write(_ sidecar: AnnotationsSidecar) throws {
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
