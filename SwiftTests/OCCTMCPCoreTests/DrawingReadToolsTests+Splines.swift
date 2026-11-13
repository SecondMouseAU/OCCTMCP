// The spline half of the drawing read tools (#263, SwiftDXF 0.3.0): a SPLINE is an entity with its
// control data and a box that follows the curve, and measure_drawing gives it an exact NURBS edge
// when its control data defines a curve and chords within a stated tolerance when it does not. The
// fixture and the helpers are the ones in DrawingReadToolsTests.swift.

import Foundation
import MCP
@testable import OCCTMCPCore
import Testing

extension DrawingReadToolsTests {

    @Test("a spline lists its control data, and a box that follows the curve, not its polygon")
    func splineEntity() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)

        let curves = try await entities(["types": ["spline"]], path)
        #expect(curves.ids == [fixture.id("curve")], "\(curves.ids)")
        let record = try #require(curves.all.first)
        #expect(record["type"] as? String == "spline" && record["layer"] as? String == "CURVES")
        #expect(record["degree"] as? Int == 2)
        #expect(near(numbers(record["knots"]), [0, 0, 0, 1, 1, 1]))
        let control = (record["controlPoints"] as? [Any])?.map { numbers($0) }
        #expect(
            control?.count == 3 && near(control?[0], [10, 35, 0]) && near(control?[1], [20, 45, 0])
                && near(control?[2], [30, 35, 0]), "\(String(describing: record["controlPoints"]))")
        #expect(record["closed"] as? Bool == false && record["periodic"] as? Bool == false)
        #expect(record["rational"] as? Bool == false)
        #expect(record["weights"] == nil && record["fitPoints"] == nil)

        // The curve peaks at (20, 40): half way between the ends and the control point at (20, 45).
        let box = try #require(record["bounds"] as? [String: Any])
        // The box is taken from points on the curve, so it can fall short of it by a ten-thousandth
        // of the spline's size (here about 2e-3) and no more.
        #expect(near(numbers(box["min"]), [10, 35, 0], tol: 5e-3), "\(String(describing: box))")
        #expect(near(numbers(box["max"]), [30, 40, 0], tol: 5e-3), "\(String(describing: box))")

        // So a window that clears the curve but not its control point does not touch it, and one
        // that holds the curve but not its control point holds it.
        let above = try await entities(["rect": [0, 41, 100, 50]], path)
        #expect(!above.ids.contains(fixture.id("curve")), "\(above.ids)")
        let holds = try await entities(["rect": [5, 30, 35, 41], "rectMode": "within"], path)
        #expect(holds.ids.contains(fixture.id("curve")), "\(holds.ids)")
        let onLayer = try await entities(["layers": ["CURVES"]], path)
        #expect(onLayer.ids == [fixture.id("curve")])
    }

    @Test("a rational, periodic or fit-point spline says what it is")
    func splineFlags() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        let w = (2.0).squareRoot() / 2
        f.add(
            "rational", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, flags: 12, knots: [0, 0, 0, 1, 1, 1], weights: [1, w, 1],
                control: [(10, 0), (10, 10), (0, 10)]))
        f.add(
            "fit", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 3, flags: 11, fit: [(0, 0), (10, 5), (20, 0)]))
        let all = try await entities([:], try f.write(to: dir)).all
        let rational = try #require(all.first { $0["id"] as? String == f.id("rational") })
        #expect(rational["rational"] as? Bool == true && rational["periodic"] as? Bool == false)
        #expect(near(numbers(rational["weights"]), [1, w, 1]))
        let fit = try #require(all.first { $0["id"] as? String == f.id("fit") })
        #expect(fit["closed"] as? Bool == true && fit["periodic"] as? Bool == true)
        #expect((fit["fitPoints"] as? [Any])?.count == 3)
        #expect(fit["controlPoints"] == nil)
    }

    @Test("a spline's control data defines an exact edge: a rational quarter circle is exact")
    func splineDistanceIsExact() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        let w = (2.0).squareRoot() / 2
        f.add(
            "quarter", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, flags: 12, knots: [0, 0, 0, 1, 1, 1], weights: [1, w, 1],
                control: [(10, 0), (10, 10), (0, 10)]))
        // The arc is the circle of radius 10 about the origin, so the point (20, 20) is 20 sqrt 2 - 10
        // from it, along the diagonal. Without the weights the control polygon makes a parabola
        // whose nearest point is 17.68 away, and chords would fall short of the arc.
        let r = try json(
            await measure(
                try f.write(to: dir), "distance", a: .string(f.id("quarter")), b: [20, 20]))
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - (20 * 2.0.squareRoot() - 10)) < 1e-6, "\(value)")
        let onArc = try #require(numbers(r["pointOnA"]))
        #expect(abs((onArc[0] * onArc[0] + onArc[1] * onArc[1]).squareRoot() - 10) < 1e-6)
        #expect(abs(onArc[0] - onArc[1]) < 1e-6, "the nearest point is on the diagonal: \(onArc)")
        let end = try #require(r["a"] as? [String: Any])
        #expect(end["type"] as? String == "spline")
        let notes = try #require(r["notes"] as? [String])
        #expect(!notes.contains { $0.contains("approximated") }, "\(notes)")
    }

    @Test("a fit-point spline, or one whose knot vector cannot define it, is approximated")
    func splineDistanceApproximated() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Uniform Catmull-Rom through four fit points: between (10, 10) and (20, 10) it rises to
        // (-P0 + 9 P1 + 9 P2 - P3) / 16 = (15, 11.25) at the middle, where the fit polygon stays at 10.
        f.add(
            "fit", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(degree: 3, fit: [(0, 0), (10, 10), (20, 10), (30, 0)]))
        // Three control points and no knots: SwiftDXF repairs it to a clamped uniform curve.
        f.add(
            "noKnots", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(degree: 2, control: [(10, 35), (20, 45), (30, 35)]))
        let path = try f.write(to: dir)

        let fit = try json(await measure(path, "distance", a: .string(f.id("fit")), b: [15, 15]))
        // 15 - 11.25 above the curve, not the 5 above the fit polygon.
        let fitValue = try #require(fit["value"] as? Double)
        #expect(abs(fitValue - 3.75) < 0.01, "\(fitValue)")
        let fitNotes = try #require(fit["notes"] as? [String])
        #expect(
            fitNotes.contains { $0.contains("spline") && $0.contains("approximated") },
            "\(fitNotes)")

        // The repaired curve is the quadratic that peaks at (20, 40): 60 below the point (20, 100).
        let repaired = try json(
            await measure(path, "distance", a: .string(f.id("noKnots")), b: [20, 100]))
        #expect(
            abs((repaired["value"] as? Double ?? 0) - 60) < 0.01,
            "\(String(describing: repaired["value"]))")
        let notes = try #require(repaired["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline") && $0.contains("approximated") }, "\(notes)")
    }

    @Test("an unclamped spline is measured over its valid domain, not over every knot")
    func unclampedSplineDomain() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // A uniform cubic B-spline on four control points: one span, over knots 3 to 4. The curve
        // runs from (10, 8.33) to (20, 8.33) and peaks at (15, 9.583) half way (the point is
        // (P0 + 23 P1 + 23 P2 + P3) / 48), so the point (15, 30) is 30 - 9.583 above it.
        f.add(
            "uniform", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 3, knots: [0, 1, 2, 3, 4, 5, 6, 7],
                control: [(0, 0), (10, 10), (20, 10), (30, 0)]))
        let r = try json(
            await measure(
                try f.write(to: dir), "distance", a: .string(f.id("uniform")), b: [15, 30]))
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - (30 - 460.0 / 48)) < 1e-6, "\(value)")
        let notes = try #require(r["notes"] as? [String])
        #expect(!notes.contains { $0.contains("approximated") }, "\(notes)")
    }

    @Test("a spline whose knots span nothing is refused by OCCT and approximated")
    func emptyKnotDomain() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "flat", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, knots: [0, 0, 0, 0, 0, 0], control: [(10, 35), (20, 45), (30, 35)]))
        let r = try json(
            await measure(try f.write(to: dir), "distance", a: .string(f.id("flat")), b: [20, 100]))
        // SwiftDXF repairs the knot vector to a clamped uniform one: the quadratic peaking at (20, 40).
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - 60) < 0.01, "\(value)")
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline") && $0.contains("approximated") }, "\(notes)")
    }

    @Test("a closed spline is closed by a chord when its curve's ends differ, not its poles'")
    func closedByTheCurveNotThePoles() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Closed, not periodic, uniform (unclamped) knots, and the first and last control points are
        // the same: but an unclamped curve does not end at its poles. It runs over knots 3 to 4, from
        // (P0 + 4 P1 + P2) / 6 = (10, 8.33) to (P1 + 4 P2 + P3) / 6 = (15, 8.33), so SwiftDXF closes
        // it with the chord between them. The point (12.5, 0) is 8.33 from that chord and 8.70 from
        // either end of the open curve.
        f.add(
            "loop", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 3, flags: 9, knots: (0...7).map(Double.init),
                control: [(0, 0), (10, 10), (20, 10), (0, 0)]))
        let r = try json(
            await measure(try f.write(to: dir), "distance", a: .string(f.id("loop")), b: [12.5, 0]))
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - 25.0 / 3) < 1e-3, "\(value)")
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline") && $0.contains("approximated") }, "\(notes)")
    }

    @Test("one note per kind of approximation, even when both ends are approximated alike")
    func approximationNotesAreDeduplicated() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "fitA", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(degree: 3, fit: [(0, 0), (10, 5), (20, 0)]))
        f.add(
            "fitB", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(degree: 3, fit: [(0, 30), (10, 35), (20, 30)]))
        f.add(
            "ellipse", "ELLIPSE", layer: "0",
            [
                (10, "50"), (20, "0"), (30, "0"), (11, "5"), (21, "0"), (31, "0"), (40, "0.5"),
                (41, "0"), (42, "6.283185307179586"),
            ])
        let path = try f.write(to: dir)

        let alike = try json(
            await measure(path, "distance", a: .string(f.id("fitA")), b: .string(f.id("fitB"))))
        let alikeNotes = try #require(alike["notes"] as? [String])
        #expect(alikeNotes.count == 1, "both ends are splines, so one note: \(alikeNotes)")

        let mixed = try json(
            await measure(path, "distance", a: .string(f.id("fitA")), b: .string(f.id("ellipse"))))
        let mixedNotes = try #require(mixed["notes"] as? [String])
        #expect(mixedNotes.count == 2, "\(mixedNotes)")
        #expect(mixedNotes.contains { $0.contains("spline") }, "\(mixedNotes)")
        #expect(mixedNotes.contains { $0.contains("ellipse") }, "\(mixedNotes)")
    }

    @Test("weights that are not one positive number per control point are ignored")
    func unusableSplineWeights() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        let control = [(10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]
        // Two weights for three control points, and a weight of zero: either way the spline is the
        // plain quadratic through (10, 0), (10, 10), (0, 10), not the rational quarter circle.
        f.add(
            "twoWeights", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, flags: 12, knots: [0, 0, 0, 1, 1, 1], weights: [1, 0.7],
                control: control))
        f.add(
            "zeroWeight", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, flags: 12, knots: [0, 0, 0, 1, 1, 1], weights: [1, 0, 1],
                control: control))
        let path = try f.write(to: dir)
        for name in ["twoWeights", "zeroWeight"] {
            let r = try json(await measure(path, "distance", a: .string(f.id(name)), b: [20, 20]))
            // That quadratic is x = 10 (1 - t^2), y = 20 t - 10 t^2: its nearest point to (20, 20) is
            // at t = 0.5, (7.5, 7.5), which is 12.5 sqrt 2 away; the circle would be 18.28.
            let value = try #require(r["value"] as? Double)
            #expect(abs(value - 12.5 * 2.0.squareRoot()) < 1e-6, "\(name): \(value)")
            let notes = try #require(r["notes"] as? [String])
            #expect(!notes.contains { $0.contains("approximated") }, "\(name): \(notes)")
        }
    }

    @Test("a degree outside 32 bits, or that does not fit the control data, is approximated")
    func absurdDegree() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // OCCTSwift narrows the degree to 32 bits, so 3 000 000 000 would trap if it got that far.
        // SwiftDXF clamps a degree into 1...(points - 1): the huge one becomes the quadratic that
        // peaks at (20, 40), 60 below (20, 100); the others become degree 1, the control polygon,
        // whose nearest point to (20, 100) is its corner at (20, 45), 55 below.
        // A degree below -2 147 483 648 traps the same narrowing, so the lower bound is tested too.
        let cases: [(name: String, degree: Int, expected: Double)] = [
            ("huge", 3_000_000_000, 60), ("negative", -5, 55), ("zero", 0, 55),
            ("belowInt32", -2_147_483_649, 55), ("intMin", Int.min, 55),
        ]
        for (name, degree, _) in cases {
            f.add(
                name, "SPLINE", layer: "0",
                DrawingFixture.splineGroups(
                    degree: degree, knots: [0, 0, 0, 1, 1, 1],
                    control: [(10, 35), (20, 45), (30, 35)]))
        }
        let path = try f.write(to: dir)
        for (name, _, expected) in cases {
            let r = try json(await measure(path, "distance", a: .string(f.id(name)), b: [20, 100]))
            let value = try #require(r["value"] as? Double)
            #expect(abs(value - expected) < 0.01, "\(name): \(value)")
            let notes = try #require(r["notes"] as? [String])
            #expect(
                notes.contains { $0.contains("spline") && $0.contains("approximated") },
                "\(name): \(notes)")
        }
    }

    @Test("a knot that is not a number is approximated, not handed to OCCT")
    func nonFiniteKnot() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "nan", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, knots: [0, 0, 0, .nan, 1, 1], control: [(10, 35), (20, 45), (30, 35)]))
        let r = try json(
            await measure(try f.write(to: dir), "distance", a: .string(f.id("nan")), b: [20, 100]))
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - 60) < 0.01, "\(value)")
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline") && $0.contains("approximated") }, "\(notes)")
    }

    @Test("a knot vector shorter than the control data needs is approximated, not indexed past")
    func shortKnotVector() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        f.add(
            "short", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, knots: [0, 0, 1], control: [(10, 35), (20, 45), (30, 35)]))
        let r = try json(
            await measure(
                try f.write(to: dir), "distance", a: .string(f.id("short")), b: [20, 100]))
        let value = try #require(r["value"] as? Double)
        #expect(abs(value - 60) < 0.01, "\(value)")
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline") && $0.contains("approximated") }, "\(notes)")
    }

    @Test("a closed spline whose ends meet is an exact edge, and so is a closed periodic one")
    func closedSplinesThatNeedNoChord() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Closed, clamped, and its first and last control points are the same point: nothing to close.
        f.add(
            "loop", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, flags: 9, knots: [0, 0, 0, 0.5, 1, 1, 1],
                control: [(10, 0), (10, 10), (20, 10), (10, 0)]))
        // Closed and periodic: a uniform cubic B-spline on a square, with the first three control
        // points repeated to wrap it. It runs over knots 3 to 7 and closes itself, so SwiftDXF adds no
        // chord. The curve is a rounded square; its side midpoints are the nearest to the centre, and
        // each is (A + 23 B + 23 C + D) / 48 for the four control points of its span, 9.583 along.
        f.add(
            "square", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 3, flags: 11, knots: (0...10).map(Double.init),
                control: [(0, 0), (10, 0), (10, 10), (0, 10), (0, 0), (10, 0), (10, 10)]))
        let path = try f.write(to: dir)

        let loop = try json(await measure(path, "distance", a: .string(f.id("loop")), b: [10, 0]))
        #expect(abs(loop["value"] as? Double ?? 1) < 1e-6, "\(String(describing: loop["value"]))")
        let loopNotes = try #require(loop["notes"] as? [String])
        #expect(!loopNotes.contains { $0.contains("approximated") }, "\(loopNotes)")

        let square = try json(
            await measure(path, "distance", a: .string(f.id("square")), b: [5, 5]))
        let value = try #require(square["value"] as? Double)
        #expect(abs(value - (460.0 / 48 - 5)) < 1e-6, "\(value)")
        let squareNotes = try #require(square["notes"] as? [String])
        #expect(!squareNotes.contains { $0.contains("approximated") }, "\(squareNotes)")
    }

    @Test("a closed spline whose ends do not meet is measured as drawn: closed by a chord")
    func closedSplineIsClosed() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var f = DrawingFixture()
        // Flag bit 1 (closed) with a clamped quadratic from (0, 0) over (10, 10) to (20, 0): the
        // curve peaks at (10, 5), and SwiftDXF closes it with the chord back along y = 0.
        f.add(
            "closed", "SPLINE", layer: "0",
            DrawingFixture.splineGroups(
                degree: 2, flags: 9, knots: [0, 0, 0, 1, 1, 1],
                control: [(0, 0), (10, 10), (20, 0)]))
        let r = try json(
            await measure(
                try f.write(to: dir), "distance", a: .string(f.id("closed")), b: [10, -5]))
        // The open curve is 10 away (its apex is at y = 5); the closing chord is 5 away.
        #expect(abs((r["value"] as? Double ?? 0) - 5) < 1e-6, "\(String(describing: r["value"]))")
        let notes = try #require(r["notes"] as? [String])
        #expect(notes.contains { $0.contains("spline") && $0.contains("approximated") }, "\(notes)")
    }

    @Test("a spline measured against a line, and the same spline twice")
    func splineAgainstEntities() async throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fixture = DrawingFixture.tSlot()
        let path = try fixture.write(to: dir)
        // The curve's highest point is its apex at y = 40, and the line "top" is at y = 50.
        let r = try json(
            await measure(
                path, "distance", a: .string(fixture.id("curve")), b: .string(fixture.id("top"))))
        #expect(abs((r["value"] as? Double ?? 0) - 10) < 1e-6, "\(String(describing: r["value"]))")
        let same = try json(
            await measure(
                path, "distance", a: .string(fixture.id("curve")), b: .string(fixture.id("curve"))))
        #expect(abs(same["value"] as? Double ?? -1) < 1e-9)
    }
}
