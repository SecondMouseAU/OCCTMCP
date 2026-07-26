// Tests for fit_edge_chain (#121): segments an ordered 3D point chain into
// line and circular-arc runs. EdgeChainMath is pure geometry (no OCCT), so
// most tests exercise it directly on synthetic point arrays with a known
// ground truth; the last test drives the actual MCP tool + a real facet
// chain sourced through detect_mesh_features(includePoints:true), the
// intended real-world pairing (#120 -> #121).

import Foundation
import Testing
import simd
import OCCTSwift
import ScriptHarness
@testable import OCCTMCPCore

@Suite("fit_edge_chain (#121)")
struct EdgeChainFitToolsTests {

    // MARK: - EdgeChainMath: fitting primitives on synthetic data

    @Test("fitLine: perfect colinear points give near-zero residual and the right direction")
    func fitLineExact() throws {
        let points = (0...10).map { SIMD3<Double>(Double($0), Double($0) * 2, 1.0) }   // line through (0,0,1) dir (1,2,0)
        let fit = try #require(EdgeChainMath.fitLine(points))
        #expect(fit.maxResidual < 1e-9)
        let expectedDir = simd_normalize(SIMD3(1.0, 2.0, 0.0))
        #expect(abs(simd_dot(fit.direction, expectedDir)) > 1 - 1e-9, "direction should be parallel to (1,2,0)")
        // Oriented start -> end.
        #expect(simd_dot(fit.direction, points.last! - points.first!) > 0)
    }

    @Test("fitArc: points sampled exactly on a known circle recover center/radius/axis")
    func fitArcExact() throws {
        let center = SIMD3<Double>(3, -2, 5)
        let radius = 10.0
        let axis = simd_normalize(SIMD3<Double>(0, 0, 1))
        let points = (0...20).map { i -> SIMD3<Double> in
            let theta = Double(i) / 20.0 * (.pi / 2)   // a 90-degree arc
            return center + radius * (cos(theta) * SIMD3(1, 0, 0) + sin(theta) * SIMD3(0, 1, 0))
        }
        let fit = try #require(EdgeChainMath.fitArc(points))
        #expect(fit.maxResidual < 1e-6)
        #expect(abs(fit.radius - radius) < 1e-6)
        #expect(simd_distance(fit.center, center) < 1e-6)
        #expect(abs(abs(simd_dot(fit.axis, axis)) - 1.0) < 1e-6, "fitted plane normal should be parallel to +/-Z")
        #expect(abs((fit.endAngle - fit.startAngle) - .pi / 2) < 1e-6, "swept angle should be ~90 degrees")
    }

    @Test("fitLine on genuine arc points reports a residual proportional to sagitta")
    func fitLineOnArcHasExpectedResidual() throws {
        let radius = 50.0
        let halfAngle = 0.2   // radians
        let points = (-10...10).map { i -> SIMD3<Double> in
            let theta = Double(i) / 10.0 * halfAngle
            return SIMD3(radius * sin(theta), radius * (1 - cos(theta)), 0)
        }
        let fit = try #require(EdgeChainMath.fitLine(points))
        // Sagitta of a chord subtending 2*halfAngle at `radius`: r*(1-cos(halfAngle)).
        let sagitta = radius * (1 - cos(halfAngle))
        #expect(fit.maxResidual > sagitta * 0.4, "a genuinely curved chain should NOT fit a line near-perfectly")
    }

    // MARK: - Segmentation

    @Test("segment: a single straight chain produces exactly one line segment")
    func segmentSingleLine() {
        let points = (0...20).map { SIMD3<Double>(Double($0), 0, 0) }
        let segs = EdgeChainMath.segment(points: points, toleranceMm: 0.01)
        #expect(segs.count == 1)
        guard case .line = segs[0].fit else {
            Issue.record("expected a line segment, got \(segs[0].fit)")
            return
        }
        #expect(segs[0].startIndex == 0)
        #expect(segs[0].endIndex == points.count - 1)
    }

    @Test("segment: a single clean arc produces exactly one arc segment")
    func segmentSingleArc() {
        let radius = 20.0
        let points = (0...30).map { i -> SIMD3<Double> in
            let theta = Double(i) / 30.0 * (.pi / 3)
            return SIMD3(radius * cos(theta), radius * sin(theta), 0)
        }
        let segs = EdgeChainMath.segment(points: points, toleranceMm: 0.01)
        #expect(segs.count == 1)
        guard case .arc(let a) = segs[0].fit else {
            Issue.record("expected an arc segment, got \(segs[0].fit)")
            return
        }
        #expect(abs(a.radius - radius) < 0.1)
    }

    @Test("segment: line -> arc -> line (a filleted corner) produces three segments in the right order")
    func segmentLineArcLine() {
        // Straight run along X, a 90-degree fillet of radius 5 centered at
        // (20,5,0), then a straight run along Y. Built so consecutive
        // segments share an exact tangent point (no artificial kink at the
        // line/arc boundary), which is what a real filleted edge looks like.
        let r = 5.0
        let center = SIMD3<Double>(20, r, 0)
        var points: [SIMD3<Double>] = []
        for i in 0...10 { points.append(SIMD3(Double(i) * 2, 0, 0)) }              // 0 -> 20 along X
        for i in 1...10 {
            let theta = -(.pi / 2) + Double(i) / 10.0 * (.pi / 2)                  // sweep to a +Y tangent
            points.append(center + r * SIMD3(cos(theta), sin(theta), 0))
        }
        // Arc's true endpoint (theta=0) is (center.x + r, center.y, 0) = (25, r, 0),
        // with tangent direction (0,1): continue straight up along Y from THERE.
        for i in 1...10 { points.append(SIMD3(20 + r, r + Double(i) * 2, 0)) }

        let segs = EdgeChainMath.segment(points: points, toleranceMm: 0.05)
        #expect(segs.count == 3, "expected line/arc/line, got \(segs.count) segments")
        guard segs.count == 3 else { return }
        guard case .line = segs[0].fit else { Issue.record("segment 0 should be a line"); return }
        guard case .arc(let a) = segs[1].fit else { Issue.record("segment 1 should be an arc"); return }
        guard case .line = segs[2].fit else { Issue.record("segment 2 should be a line"); return }
        #expect(abs(a.radius - r) < 0.2)
        // Segments must be contiguous (shared endpoint between runs).
        #expect(segs[0].endIndex == segs[1].startIndex)
        #expect(segs[1].endIndex == segs[2].startIndex)
    }

    @Test("segment: two different radii are NOT collapsed into one arc (#121's core ask)")
    func segmentMultiRadiusChain() {
        // Two tangent arcs of different radius, sharing a tangent point at
        // the origin: a small tight radius then a much larger one, the
        // "shank outline with two real blend radii" failure mode #121 cites.
        let r1 = 5.0, r2 = 25.0
        var points: [SIMD3<Double>] = []
        let c1 = SIMD3<Double>(0, r1, 0)
        for i in 0...15 {
            let theta = -(.pi / 2) + Double(i) / 15.0 * (.pi / 3)
            points.append(c1 + r1 * SIMD3(cos(theta), sin(theta), 0))
        }
        let tangentPoint = points.last!
        let tangentDir = simd_normalize(points[points.count - 1] - points[points.count - 2])
        let normalDir = SIMD3<Double>(-tangentDir.y, tangentDir.x, 0)   // perpendicular, toward c2
        let c2 = tangentPoint + r2 * normalDir
        let theta0 = atan2(tangentPoint.y - c2.y, tangentPoint.x - c2.x)
        for i in 1...15 {
            let theta = theta0 + Double(i) / 15.0 * (.pi / 4)
            points.append(c2 + r2 * SIMD3(cos(theta), sin(theta), 0))
        }

        let segs = EdgeChainMath.segment(points: points, toleranceMm: 0.05)
        let arcSegments = segs.compactMap { seg -> Double? in
            if case .arc(let a) = seg.fit { return a.radius }
            return nil
        }
        #expect(segs.count >= 2, "a single-circle-only fit would collapse this into one segment")
        #expect(arcSegments.contains { abs($0 - r1) < 0.5 }, "expected a segment fitting the r=\(r1) blend, got radii \(arcSegments)")
        #expect(arcSegments.contains { abs($0 - r2) < 0.5 }, "expected a segment fitting the r=\(r2) blend, got radii \(arcSegments)")
        #expect(!arcSegments.contains { abs($0 - (r1 + r2) / 2) < 1.0 }, "no segment should have collapsed to a single averaged radius")
    }

    // MARK: - Tool-level: dispatch through the JSON-facing function + a real facet chain

    struct SegmentMirror: Decodable {
        let startIndex, endIndex, pointCount: Int
        let kind: String
        let startPoint, endPoint: [Double]
        let direction: [Double]?
        let center: [Double]?
        let radius: Double?
        let axis: [Double]?
        let startAngle, endAngle: Double?
        let maxResidualMm, rmsResidualMm: Double
    }
    struct ReportMirror: Decodable {
        let pointCount: Int
        let closed: Bool
        let toleranceMm: Double
        let segmentCount: Int
        let segments: [SegmentMirror]
        let warnings: [String]
    }

    @Test("tool: rejects fewer than 2 points and a non-positive toleranceMm")
    func toolValidation() async throws {
        let tooFew = await EdgeChainFitTools.fitEdgeChain(points: [SIMD3(0, 0, 0)])
        #expect(tooFew.isError)

        let badTol = await EdgeChainFitTools.fitEdgeChain(
            points: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)], toleranceMm: -1)
        #expect(badTol.isError)
    }

    @Test("tool: closed:true is reported but not segmented across the wrap")
    func toolClosedWarning() async throws {
        let points = (0..<20).map { i -> SIMD3<Double> in
            let theta = Double(i) / 20.0 * 2 * .pi
            return SIMD3(10 * cos(theta), 10 * sin(theta), 0)
        }
        let result = await EdgeChainFitTools.fitEdgeChain(points: points, closed: true)
        #expect(!result.isError, "unexpected error: \(result.text)")
        let r = try JSONDecoder().decode(ReportMirror.self, from: Data(result.text.utf8))
        #expect(r.closed)
        #expect(r.warnings.contains { $0.contains("wrap") })
    }

    @Test("end to end: detect_mesh_features(includePoints:true) ring feeds fit_edge_chain and recovers the true radius")
    func endToEndWithRealCreaseRing() async throws {
        // A capped cylinder: STL facet approximation of a true circular rim,
        // exactly the "arc exists only as a chain of straight facet edges"
        // case #121 is about. Reuses the tiered-cylinder-style fixture
        // pattern (round, no corner ambiguity) already established in
        // MeshFeatureToolsTests.
        let dir = NSTemporaryDirectory() + "occtmcp-edgechain-e2e-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = ManifestStore(path: "\(dir)/manifest.json")
        try store.write(ScriptManifest(description: "edgechain e2e", bodies: []))
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let radius = 15.0, height = 10.0, segments = 48
        func p(_ i: Int, _ z: Double) -> SIMD3<Double> {
            let theta = 2 * Double.pi * Double(i) / Double(segments)
            return SIMD3(radius * cos(theta), radius * sin(theta), z)
        }
        var out = "solid cyl\n"
        func facet(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) {
            let n = simd_normalize(simd_cross(b - a, c - a))
            out += "  facet normal \(n.x) \(n.y) \(n.z)\n    outer loop\n"
            for v in [a, b, c] { out += "      vertex \(v.x) \(v.y) \(v.z)\n" }
            out += "    endloop\n  endfacet\n"
        }
        for i in 0..<segments {
            let i2 = (i + 1) % segments
            facet(SIMD3(0, 0, 0), p(i, 0), p(i2, 0))          // bottom cap
            facet(p(i, 0), p(i, height), p(i2, height))       // wall (2 tris)
            facet(p(i, 0), p(i2, height), p(i2, 0))
            facet(SIMD3(0, 0, height), p(i2, height), p(i, height))   // top cap
        }
        out += "endsolid cyl\n"
        let stlPath = "\(dir)/cyl.stl"
        try out.write(toFile: stlPath, atomically: true, encoding: .utf8)

        let importResult = await IOTools.importFile(
            inputPath: stlPath, format: .stl, idPrefix: "cyl", store: store, history: SceneHistory())
        #expect(!importResult.isError, "import failed: \(importResult.text)")
        struct ImportReport: Decodable { let addedBodyIds: [String] }
        let imported = try JSONDecoder().decode(ImportReport.self, from: Data(importResult.text.utf8))
        let bodyId = try #require(imported.addedBodyIds.first)

        let featuresResult = await MeshFeatureTools.detectMeshFeatures(
            bodyId: bodyId, includePoints: true, render: false, store: store)
        #expect(!featuresResult.isError, "unexpected error: \(featuresResult.text)")

        struct RingMirror: Decodable { let closed: Bool; let points: [[Double]]? }
        struct FeatureReportMirror: Decodable { let rings: [RingMirror] }
        let features = try JSONDecoder().decode(FeatureReportMirror.self, from: Data(featuresResult.text.utf8))
        let ring = try #require(features.rings.first { $0.points != nil && $0.closed })
        let ringPoints = try #require(ring.points)
        #expect(ringPoints.count >= segments - 1, "expected a full rim ring, got \(ringPoints.count) points")

        let chainPoints = ringPoints.map { SIMD3<Double>($0[0], $0[1], $0[2]) }
        let fitResult = await EdgeChainFitTools.fitEdgeChain(points: chainPoints, closed: false)
        #expect(!fitResult.isError, "unexpected error: \(fitResult.text)")
        let fitReport = try JSONDecoder().decode(ReportMirror.self, from: Data(fitResult.text.utf8))

        // A regular N-gon inscribed in the true circle fits a single arc
        // segment cleanly at a reasonable tolerance, and its recovered
        // radius should closely match the true rim radius.
        let arcs = fitReport.segments.filter { $0.kind == "arc" }
        #expect(!arcs.isEmpty, "expected at least one arc segment for a facet-approximated circular rim")
        #expect(arcs.contains { abs(($0.radius ?? -1) - radius) < 0.5 }, "no arc segment recovered the true rim radius \(radius): \(arcs.map(\.radius))")
    }
}
