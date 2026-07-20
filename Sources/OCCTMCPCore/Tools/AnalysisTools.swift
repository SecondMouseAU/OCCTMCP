// AnalysisTools — read-only inspection that goes one level deeper than
// IntrospectionTools: graph validation, feature recognition, pairwise
// clearance, plus the raw-path graph_* / feature_recognize tools that
// match the Node side's lower-level surface.

import Foundation
import OCCTSwift
import ScriptHarness

public enum AnalysisTools {

    // ── validate_geometry ──────────────────────────────────────────────

    public struct ValidateReport: Encodable {
        public let bodies: [BodyRecord]

        public struct BodyRecord: Encodable {
            public let id: String?
            public let file: String
            public let isValid: Bool?
            public let errorCount: Int?
            public let warningCount: Int?
            public let error: String?
        }
    }

    public static func validateGeometry(
        bodyId: String? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        guard let manifest = try? store.read() else {
            return .init("No scene loaded. Run execute_script first.")
        }
        let outputDir = (store.path as NSString).deletingLastPathComponent
        let targets: [BodyDescriptor]
        if let id = bodyId {
            guard let body = manifest.body(withId: id) else {
                return .init("Body not found: \(id)")
            }
            targets = [body]
        } else {
            targets = manifest.bodies.filter { $0.format == "brep" }
        }
        if targets.isEmpty {
            return .init("No BREP bodies in scene.")
        }

        var records: [ValidateReport.BodyRecord] = []
        for body in targets {
            let path = "\(outputDir)/\(body.file)"
            do {
                let shape = try Shape.loadBREP(fromPath: path)
                let graph = try GraphIO.buildGraph(from: shape)
                let report = GraphIO.ValidationReport(graph.validate())
                records.append(.init(
                    id: body.id,
                    file: body.file,
                    isValid: report.isValid,
                    errorCount: report.errorCount,
                    warningCount: report.warningCount,
                    error: nil
                ))
            } catch {
                records.append(.init(
                    id: body.id,
                    file: body.file,
                    isValid: nil,
                    errorCount: nil,
                    warningCount: nil,
                    error: error.localizedDescription
                ))
            }
        }
        return IntrospectionTools.encode(ValidateReport(bodies: records))
    }

    // ── recognize_features ─────────────────────────────────────────────

    public struct FeatureReport: Encodable {
        public let bodyId: String
        public let pockets: [Pocket]
        public let holes: [Hole]

        public struct Pocket: Encodable {
            public let floorFaceIndex: Int
            public let wallFaceIndices: [Int]
            public let zLevel: Double
            public let depth: Double
            public let isOpen: Bool
        }
        public struct Hole: Encodable {
            public let faceIndex: Int
            public let radius: Double
            public let depth: Double
        }
    }

    public static func recognizeFeatures(
        bodyId: String,
        kinds: [String]? = nil,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        let loaded: (manifest: ScriptManifest, body: BodyDescriptor, shape: Shape, path: String)
        do {
            loaded = try IntrospectionTools.loadShape(bodyId: bodyId, store: store)
        } catch {
            return .init("\(error)")
        }
        let aag = AAG(shape: loaded.shape)
        let wantPockets = kinds.map { $0.contains("pocket") } ?? true
        let wantHoles = kinds.map { $0.contains("hole") } ?? true

        let pockets = wantPockets ? aag.detectPockets().map {
            FeatureReport.Pocket(
                floorFaceIndex: $0.floorFaceIndex,
                wallFaceIndices: $0.wallFaceIndices,
                zLevel: $0.zLevel,
                depth: $0.depth,
                isOpen: $0.isOpen
            )
        } : []
        let holes = wantHoles ? aag.detectHoles().map {
            FeatureReport.Hole(faceIndex: $0.faceIndex, radius: $0.radius, depth: $0.depth)
        } : []

        return IntrospectionTools.encode(FeatureReport(
            bodyId: bodyId,
            pockets: pockets,
            holes: holes
        ))
    }

    // ── analyze_clearance ──────────────────────────────────────────────

    public struct ClearanceReport: Encodable {
        public let pairs: [Pair]
        public struct Pair: Encodable {
            public let a: String
            public let b: String
            public let minDistance: Double
            public let intersects: Bool
            public let contacts: [IntrospectionTools.DistanceReport.Contact]
        }
    }

    public static func analyzeClearance(
        bodyIds: [String],
        computeContacts: Bool = true,
        store: ManifestStore = ManifestStore()
    ) async -> ToolText {
        if bodyIds.count < 2 {
            return .init("analyze_clearance needs at least 2 body ids; got \(bodyIds.count).")
        }
        var loaded: [(id: String, shape: Shape)] = []
        for id in bodyIds {
            do {
                let l = try IntrospectionTools.loadShape(bodyId: id, store: store)
                loaded.append((id, l.shape))
            } catch {
                return .init("\(error)")
            }
        }

        var pairs: [ClearanceReport.Pair] = []
        for i in 0..<loaded.count {
            for j in (i + 1)..<loaded.count {
                let a = loaded[i], b = loaded[j]
                if computeContacts {
                    guard let solutions = a.shape.allDistanceSolutions(to: b.shape, maxSolutions: 16) else {
                        continue
                    }
                    let minD = solutions.map(\.distance).min() ?? .infinity
                    let contacts = solutions.map {
                        IntrospectionTools.DistanceReport.Contact(
                            fromPoint: [$0.point1.x, $0.point1.y, $0.point1.z],
                            toPoint: [$0.point2.x, $0.point2.y, $0.point2.z],
                            distance: $0.distance
                        )
                    }
                    pairs.append(.init(
                        a: a.id, b: b.id,
                        minDistance: minD,
                        intersects: minD < 1e-9,
                        contacts: contacts
                    ))
                } else {
                    let minD = a.shape.minDistance(to: b.shape) ?? .infinity
                    pairs.append(.init(
                        a: a.id, b: b.id,
                        minDistance: minD,
                        intersects: minD < 1e-9,
                        contacts: []
                    ))
                }
            }
        }
        return IntrospectionTools.encode(ClearanceReport(pairs: pairs))
    }

    // ── graph_validate / graph_compact / graph_dedup ───────────────────
    // Raw-path counterparts to validate_geometry (and the upstream
    // graph-* occtkit verbs). Take a BREP path directly, return the
    // GraphIO report verbatim.

    public static func graphValidate(brepPath: String) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            let graph = try GraphIO.buildGraph(from: shape)
            let report = GraphIO.ValidationReport(graph.validate())
            return IntrospectionTools.encode(report)
        } catch {
            return .init("graph_validate failed: \(error.localizedDescription)", isError: true)
        }
    }

    public struct GraphCompactPayload: Encodable {
        public let nodesBefore: Int
        public let nodesAfter: Int
        public let removed: Removed
        public let output: String
        public struct Removed: Encodable {
            public let vertices: Int
            public let edges: Int
            public let faces: Int
        }
    }

    public static func graphCompact(brepPath: String, outputPath: String) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            let graph = try GraphIO.buildGraph(from: shape)
            let nodesBefore = graph.stats.totalNodes
            let r = graph.compact()
            guard let rebuilt = GraphIO.rebuildShape(from: graph) else {
                return .init("graph_compact failed: rebuild produced nil shape.", isError: true)
            }
            try GraphIO.writeBREP(rebuilt, to: outputPath)
            return IntrospectionTools.encode(GraphCompactPayload(
                nodesBefore: nodesBefore,
                nodesAfter: r.nodesAfter,
                removed: .init(
                    vertices: r.removedVertices,
                    edges: r.removedEdges,
                    faces: r.removedFaces
                ),
                output: outputPath
            ))
        } catch {
            return .init("graph_compact failed: \(error.localizedDescription)", isError: true)
        }
    }

    public struct GraphDedupPayload: Encodable {
        public let canonicalSurfaces: Int
        public let canonicalCurves: Int
        public let surfaceRewrites: Int
        public let curveRewrites: Int
        public let output: String
    }

    public static func graphDedup(brepPath: String, outputPath: String) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            let graph = try GraphIO.buildGraph(from: shape)
            let r = graph.deduplicate()
            guard let rebuilt = GraphIO.rebuildShape(from: graph) else {
                return .init("graph_dedup failed: rebuild produced nil shape.", isError: true)
            }
            try GraphIO.writeBREP(rebuilt, to: outputPath)
            return IntrospectionTools.encode(GraphDedupPayload(
                canonicalSurfaces: r.canonicalSurfaces,
                canonicalCurves: r.canonicalCurves,
                surfaceRewrites: r.surfaceRewrites,
                curveRewrites: r.curveRewrites,
                output: outputPath
            ))
        } catch {
            return .init("graph_dedup failed: \(error.localizedDescription)", isError: true)
        }
    }

    public static func graphML(
        brepPath: String,
        description: String? = nil
    ) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            let graph = try GraphIO.buildGraph(from: shape)
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("occtmcp-graphml-\(UUID().uuidString).json")
            try BREPGraphJSONExporter.export(graph, to: tempURL, description: description)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            let data = try Data(contentsOf: tempURL)
            // Augment the exporter JSON with a convexity-attributed face-adjacency
            // block (the gAAG edge attribute B-rep GNNs key on), computed
            // kernel-direct from the AAG — same source as graph_select. Closes the
            // graph_ml half of OCCTMCP#38. Face indices follow shape.faces() order.
            guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .init(String(data: data, encoding: .utf8) ?? "{}")
            }
            let aag = AAG(shape: shape)
            obj["faceAdjacency"] = aag.edges.map { e in
                [
                    "face1": e.face1Index,
                    "face2": e.face2Index,
                    "convexity": convexityLabel(e.convexity),
                    "sharedEdgeCount": e.sharedEdgeCount,
                ] as [String: Any]
            }
            let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            return .init(String(decoding: out, as: UTF8.self))
        } catch {
            return .init("graph_ml failed: \(error.localizedDescription)", isError: true)
        }
    }

    // ── graph_select ────────────────────────────────────────────────────
    // Local B-rep graph adjacency / selection queries without dumping the
    // whole graph (graph_ml). Mirrors the OCCTSwiftScripts `graph-select` verb,
    // backed directly by the kernel AAG (face queries + convexity) and
    // BRepGraph (edge/vertex adjacency). Convexity is a dihedral-between-two-
    // faces property, so it is reported on face *adjacencies* (the gAAG edge
    // attribute). Face indices follow shape.faces() order (the `face[N]` scheme
    // query_topology emits); edge/vertex indices are BRepGraph indices.
    // OCCTMCP#38.

    private static func convexityLabel(_ c: EdgeConvexity) -> String {
        switch c {
        case .concave: return "concave"
        case .smooth:  return "smooth"
        case .convex:  return "convex"
        }
    }

    public struct GraphSelectNeighbour: Encodable {
        public let face: Int; public let convexity: String; public let sharedEdgeCount: Int
    }
    public struct GraphSelectFaceNeighbors: Encodable {
        public let query = "face-neighbors"
        public let face: Int
        public let isPlanar: Bool
        public let isVertical: Bool
        public let isHorizontal: Bool
        public let normal: [Double]?
        public let neighbors: [GraphSelectNeighbour]
    }
    public struct GraphSelectEdgeFaces: Encodable {
        public let query = "edge-faces"
        public let edge: Int
        public let faces: [Int]
        public let startVertex: Int?
        public let endVertex: Int?
        public let boundary: Bool
        public let manifold: Bool
    }
    public struct GraphSelectVertexEdges: Encodable {
        public let query = "vertex-edges"
        public let vertex: Int
        public let edges: [Int]
    }
    public struct GraphSelectFaceAdj: Encodable {
        public let face1: Int; public let face2: Int; public let convexity: String; public let sharedEdgeCount: Int
    }
    public struct GraphSelectFaceAdjacency: Encodable {
        public let query = "face-adjacency"
        public let faceCount: Int
        public let adjacencies: [GraphSelectFaceAdj]
    }
    public struct GraphSelectEdgesClass: Encodable {
        public let query = "edges-class"
        public let edgeClass: String
        public let edges: [Int]
    }

    public static func graphSelect(
        brepPath: String,
        query: String,
        face: Int?,
        edge: Int?,
        vertex: Int?,
        edgeClass: String?
    ) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            switch query {
            case "face-neighbors":
                let aag = AAG(shape: shape)
                guard let f = face, f >= 0, f < aag.nodes.count else {
                    return .init("face-neighbors requires `face` in 0..<\(AAG(shape: shape).nodes.count)", isError: true)
                }
                let node = aag.nodes[f]
                let neighbors = aag.neighbors(of: f).sorted().map { nb -> GraphSelectNeighbour in
                    let e = aag.edge(between: f, and: nb)
                    return GraphSelectNeighbour(face: nb,
                                                convexity: convexityLabel(e?.convexity ?? .smooth),
                                                sharedEdgeCount: e?.sharedEdgeCount ?? 0)
                }
                return IntrospectionTools.encode(GraphSelectFaceNeighbors(
                    face: f, isPlanar: node.isPlanar, isVertical: node.isVertical,
                    isHorizontal: node.isHorizontal,
                    normal: node.normal.map { [$0.x, $0.y, $0.z] },
                    neighbors: neighbors))

            case "edge-faces":
                let graph = try GraphIO.buildGraph(from: shape)
                guard let m = edge, m >= 0, m < graph.edgeCount else {
                    return .init("edge-faces requires `edge` in 0..<\(graph.edgeCount)", isError: true)
                }
                return IntrospectionTools.encode(GraphSelectEdgeFaces(
                    edge: m, faces: graph.faces(of: m),
                    startVertex: graph.edgeStartVertex(m), endVertex: graph.edgeEndVertex(m),
                    boundary: graph.isBoundaryEdge(m), manifold: graph.isManifoldEdge(m)))

            case "vertex-edges":
                let graph = try GraphIO.buildGraph(from: shape)
                guard let k = vertex, k >= 0, k < graph.vertexCount else {
                    return .init("vertex-edges requires `vertex` in 0..<\(graph.vertexCount)", isError: true)
                }
                return IntrospectionTools.encode(GraphSelectVertexEdges(vertex: k, edges: graph.edges(of: k)))

            case "face-adjacency":
                let aag = AAG(shape: shape)
                let adjacencies = aag.edges.map {
                    GraphSelectFaceAdj(face1: $0.face1Index, face2: $0.face2Index,
                                       convexity: convexityLabel($0.convexity), sharedEdgeCount: $0.sharedEdgeCount)
                }
                return IntrospectionTools.encode(GraphSelectFaceAdjacency(
                    faceCount: aag.nodes.count, adjacencies: adjacencies))

            case "edges-class":
                let graph = try GraphIO.buildGraph(from: shape)
                let kind = edgeClass ?? "boundary"
                guard ["boundary", "non-manifold", "seam", "degenerate"].contains(kind) else {
                    return .init("`class` must be boundary | non-manifold | seam | degenerate", isError: true)
                }
                let matches: [Int] = (0..<graph.edgeCount).filter { i in
                    switch kind {
                    case "boundary":     return graph.isBoundaryEdge(i)
                    case "non-manifold": return !graph.isManifoldEdge(i)
                    case "seam":         return graph.edgeCoEdges(i).contains { graph.coedgeSeamPair($0) != nil }
                    case "degenerate":   return graph.isEdgeDegenerated(i)
                    default:             return false
                    }
                }
                return IntrospectionTools.encode(GraphSelectEdgesClass(edgeClass: kind, edges: matches))

            default:
                return .init("Unknown query '\(query)'. Use face-neighbors | edge-faces | vertex-edges | face-adjacency | edges-class.", isError: true)
            }
        } catch {
            return .init("graph_select failed: \(error.localizedDescription)", isError: true)
        }
    }

    public static func featureRecognize(brepPath: String) async -> ToolText {
        guard FileManager.default.fileExists(atPath: brepPath) else {
            return .init("BREP file not found: \(brepPath)")
        }
        do {
            let shape = try Shape.loadBREP(fromPath: brepPath)
            let aag = AAG(shape: shape)
            return IntrospectionTools.encode(FeatureReport(
                bodyId: brepPath,
                pockets: aag.detectPockets().map {
                    .init(
                        floorFaceIndex: $0.floorFaceIndex,
                        wallFaceIndices: $0.wallFaceIndices,
                        zLevel: $0.zLevel,
                        depth: $0.depth,
                        isOpen: $0.isOpen
                    )
                },
                holes: aag.detectHoles().map {
                    .init(faceIndex: $0.faceIndex, radius: $0.radius, depth: $0.depth)
                }
            ))
        } catch {
            return .init("feature_recognize failed: \(error.localizedDescription)", isError: true)
        }
    }
}
