// FaceAdjacency: the one place face adjacency is read off the kernel's AAG and
// converted into `Shape.faces()` index space, shared by graph_select,
// graph_ml and query_topology (#199, #201).

import Foundation
import OCCTSwift

public enum FaceAdjacency {

    /// One neighbouring face, indexed in `Shape.faces()` order.
    public struct Neighbour: Encodable, Equatable {
        public let index: Int
        public let convexity: String
        public let sharedEdgeCount: Int
    }

    /// One adjacent face pair with `lower < upper`, both in `Shape.faces()` order.
    public struct Pair: Equatable {
        public let lower: Int
        public let upper: Int
        public let convexity: String
        public let sharedEdgeCount: Int
    }

    /// Face adjacency for a whole shape, keyed by `Shape.faces()` index.
    public struct Graph {
        /// Number of faces in `Shape.faces()`, the valid range for every index here.
        public let faceCount: Int
        /// Every adjacent pair, sorted by `(lower, upper)`.
        public let pairs: [Pair]
        /// Neighbours per face, sorted by neighbour index.
        ///
        /// Faces with none are absent.
        public let neighbours: [Int: [Neighbour]]
        /// The AAG node of the first occurrence of each face that has one.
        public let nodes: [Int: AAGNode]
    }

    /// Converts a kernel convexity into its wire label.
    public static func convexityLabel(_ convexity: EdgeConvexity) -> String {
        switch convexity {
        case .concave: return "concave"
        case .smooth: return "smooth"
        case .convex: return "convex"
        }
    }

    /// Builds the adjacency of `shape` in `Shape.faces()` index space.
    ///
    /// AAG nodes are `orientedFaces()` occurrences, so a face shared by two solids is
    /// two nodes. Occurrences merge onto `distinctFaceIndex`, shared edge counts add,
    /// and self-edges are dropped.
    public static func faceAdjacency(shape: Shape) -> Graph {
        let aag = AAG(shape: shape)
        var nodes: [Int: AAGNode] = [:]
        for node in aag.nodes where nodes[node.distinctFaceIndex] == nil {
            nodes[node.distinctFaceIndex] = node
        }

        struct Key: Hashable {
            let lower: Int
            let upper: Int
        }
        var merged: [Key: (convexity: String, count: Int, best: Int)] = [:]
        for edge in aag.edges {
            guard edge.face1Index >= 0, edge.face1Index < aag.nodes.count,
                edge.face2Index >= 0, edge.face2Index < aag.nodes.count
            else { continue }
            let first = aag.nodes[edge.face1Index].distinctFaceIndex
            let second = aag.nodes[edge.face2Index].distinctFaceIndex
            guard first != second else { continue }
            let key = Key(lower: min(first, second), upper: max(first, second))
            let label = convexityLabel(edge.convexity)
            if var existing = merged[key] {
                existing.count += edge.sharedEdgeCount
                if edge.sharedEdgeCount > existing.best {
                    existing.best = edge.sharedEdgeCount
                    existing.convexity = label
                }
                merged[key] = existing
            } else {
                merged[key] = (label, edge.sharedEdgeCount, edge.sharedEdgeCount)
            }
        }

        let pairs = merged.map {
            Pair(
                lower: $0.key.lower, upper: $0.key.upper, convexity: $0.value.convexity,
                sharedEdgeCount: $0.value.count)
        }.sorted { ($0.lower, $0.upper) < ($1.lower, $1.upper) }

        var neighbours: [Int: [Neighbour]] = [:]
        for pair in pairs {
            neighbours[pair.lower, default: []].append(
                Neighbour(
                    index: pair.upper, convexity: pair.convexity,
                    sharedEdgeCount: pair.sharedEdgeCount))
            neighbours[pair.upper, default: []].append(
                Neighbour(
                    index: pair.lower, convexity: pair.convexity,
                    sharedEdgeCount: pair.sharedEdgeCount))
        }
        for key in neighbours.keys {
            neighbours[key]?.sort { $0.index < $1.index }
        }
        return Graph(
            faceCount: shape.faces().count, pairs: pairs, neighbours: neighbours, nodes: nodes)
    }
}
