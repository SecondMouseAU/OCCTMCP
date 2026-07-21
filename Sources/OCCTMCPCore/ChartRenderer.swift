// ChartRenderer — pure-Swift Core Graphics 2D rendering for the deviation
// diagnostics (#61 / #62 / #63). No Python / matplotlib: histograms, cross-
// section profile overlays, and the colorbar legend are drawn with CoreGraphics
// + CoreText into PNGs. Headless-safe (no AppKit, no run loop): a bitmap
// CGContext + CGImageDestination.
//
// The diverging colormap here is shared with the surface heatmap so a band's
// fill colour and the legend agree exactly.

import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import simd

enum ChartRenderer {

    enum ChartError: Error, CustomStringConvertible {
        case contextFailed
        case imageFailed
        case writeFailed(String)
        var description: String {
            switch self {
            case .contextFailed: return "Failed to create CoreGraphics bitmap context."
            case .imageFailed:   return "Failed to snapshot CGImage."
            case .writeFailed(let p): return "Failed to write PNG to \(p)."
            }
        }
    }

    // MARK: - Colormap

    /// Diverging "coolwarm" colormap for a signed, normalized value `t ∈ [-1, 1]`.
    /// Blue = shy (under-build, t < 0), near-white = on-target, red = proud
    /// (over-build, t > 0).
    static func divergingColor(_ tIn: Double) -> SIMD4<Float> {
        let t = max(-1.0, min(1.0, tIn))
        let blue  = SIMD3<Float>(0.23, 0.30, 0.75)
        let white = SIMD3<Float>(0.96, 0.96, 0.96)
        let red   = SIMD3<Float>(0.71, 0.02, 0.15)
        let c: SIMD3<Float>
        if t < 0 {
            c = simd_mix(white, blue, SIMD3<Float>(repeating: Float(-t)))
        } else {
            c = simd_mix(white, red, SIMD3<Float>(repeating: Float(t)))
        }
        return SIMD4<Float>(c.x, c.y, c.z, 1)
    }

    // MARK: - Categorical palette (#101)

    /// A dozen colourblind-distinguishable hues for coloring an unbounded set
    /// of discrete groups (zones, verdict buckets), where the diverging
    /// colormap above (which encodes a signed SCALAR) doesn't apply. The
    /// first 8 are the Okabe-Ito set (with pure black swapped for a mid grey,
    /// which reads better against both the white legend background and a
    /// dark viewport); the last 4 extend it with non-overlapping hues from
    /// Paul Tol's "bright" qualitative palette, chosen to stay distinguishable
    /// from the first 8 and from each other.
    static let categoricalPalette: [SIMD3<Float>] = [
        hex(0xE6, 0x9F, 0x00),   // orange
        hex(0x56, 0xB4, 0xE9),   // sky blue
        hex(0x00, 0x9E, 0x73),   // bluish green
        hex(0xF0, 0xE4, 0x42),   // yellow
        hex(0x00, 0x72, 0xB2),   // blue
        hex(0xD5, 0x5E, 0x00),   // vermillion
        hex(0xCC, 0x79, 0xA7),   // reddish purple
        hex(0x99, 0x99, 0x99),   // grey (replaces Okabe-Ito's black)
        hex(0x66, 0xCC, 0xEE),   // cyan (Tol bright)
        hex(0xEE, 0x66, 0x77),   // red (Tol bright)
        hex(0xAA, 0x33, 0x77),   // purple (Tol bright)
        hex(0x22, 0x88, 0x33),   // green (Tol bright)
    ]

    /// Deterministic per-index color: cycles past the palette's length rather
    /// than erroring, so a caller with more groups than colors still gets a
    /// (repeating, non-distinct-beyond-the-palette) render instead of a
    /// crash. Callers are responsible for warning when `index >=
    /// categoricalPalette.count` (repeats start).
    static func categoricalColor(_ index: Int) -> SIMD4<Float> {
        guard !categoricalPalette.isEmpty else { return SIMD4(0.6, 0.6, 0.6, 1) }
        let c = categoricalPalette[index % categoricalPalette.count]
        return SIMD4(c.x, c.y, c.z, 1)
    }

    private static func hex(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> SIMD3<Float> {
        SIMD3(Float(r) / 255, Float(g) / 255, Float(b) / 255)
    }

    // MARK: - Low-level

    static func makeContext(width: Int, height: Int, background: SIMD4<Float>) -> CGContext? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.setFillColor(cg(background))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.textMatrix = .identity
        ctx.setLineJoin(.round)
        return ctx
    }

    static func finalize(_ ctx: CGContext, to url: URL) throws {
        guard let image = ctx.makeImage() else { throw ChartError.imageFailed }
        try write(image, to: url)
    }

    static func write(_ image: CGImage, to url: URL) throws {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw ChartError.writeFailed(url.path) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ChartError.writeFailed(url.path) }
    }

    static func cg(_ c: SIMD4<Float>) -> CGColor {
        CGColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: CGFloat(c.w))
    }

    /// Draw a text label. `anchor` controls horizontal alignment around `at`.
    static func drawText(
        _ text: String, at p: CGPoint, fontSize: CGFloat,
        color: SIMD4<Float>, in ctx: CGContext, anchor: TextAnchor = .left
    ) {
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attrs = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cg(color),
        ] as CFDictionary
        guard let attr = CFAttributedStringCreate(nil, text as CFString, attrs) else { return }
        let line = CTLineCreateWithAttributedString(attr)
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        var x = p.x
        switch anchor {
        case .left:   break
        case .center: x = p.x - CGFloat(w) / 2
        case .right:  x = p.x - CGFloat(w)
        }
        ctx.textPosition = CGPoint(x: x, y: p.y)
        CTLineDraw(line, ctx)
    }

    enum TextAnchor { case left, center, right }

    // MARK: - Histogram (#62)

    /// Histogram of signed deviation values with an optional ±tolerance band.
    static func histogram(
        values: [Double], tolerance: Double?, bins: Int,
        title: String, width: Int = 800, height: Int = 480, to url: URL
    ) throws {
        guard let ctx = makeContext(width: width, height: height, background: SIMD4(1, 1, 1, 1)) else {
            throw ChartError.contextFailed
        }
        let ink = SIMD4<Float>(0.12, 0.12, 0.14, 1)
        let grid = SIMD4<Float>(0.85, 0.85, 0.87, 1)
        let bar = SIMD4<Float>(0.30, 0.45, 0.78, 1)
        let band = SIMD4<Float>(0.55, 0.80, 0.45, 0.30)

        let margin = CGRect(x: 56, y: 44, width: CGFloat(width) - 80, height: CGFloat(height) - 80)

        drawText(title, at: CGPoint(x: 12, y: CGFloat(height) - 26), fontSize: 15, color: ink, in: ctx)

        guard !values.isEmpty else {
            drawText("no samples", at: CGPoint(x: margin.midX, y: margin.midY), fontSize: 13, color: ink, in: ctx, anchor: .center)
            try finalize(ctx, to: url)
            return
        }

        var lo = values.min()!, hi = values.max()!
        if hi - lo < 1e-9 { lo -= 0.5; hi += 0.5 }
        let n = max(2, bins)
        let bw = (hi - lo) / Double(n)
        var counts = [Int](repeating: 0, count: n)
        for v in values {
            var b = Int((v - lo) / bw)
            if b >= n { b = n - 1 }
            if b < 0 { b = 0 }
            counts[b] += 1
        }
        let maxCount = max(1, counts.max()!)

        // value → x pixel, count → y pixel
        func px(_ v: Double) -> CGFloat { margin.minX + CGFloat((v - lo) / (hi - lo)) * margin.width }
        func py(_ c: Int) -> CGFloat { margin.minY + CGFloat(Double(c) / Double(maxCount)) * margin.height }

        // ±tolerance band
        if let tol = tolerance, tol > 0 {
            let x0 = px(max(lo, -tol)), x1 = px(min(hi, tol))
            ctx.setFillColor(cg(band))
            ctx.fill(CGRect(x: x0, y: margin.minY, width: max(0, x1 - x0), height: margin.height))
        }

        // axes
        ctx.setStrokeColor(cg(grid)); ctx.setLineWidth(1)
        ctx.stroke(margin)

        // zero line
        if lo < 0 && hi > 0 {
            ctx.setStrokeColor(cg(SIMD4(0.5, 0.5, 0.5, 1))); ctx.setLineWidth(1.2)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: px(0), y: margin.minY))
            ctx.addLine(to: CGPoint(x: px(0), y: margin.maxY))
            ctx.strokePath()
        }

        // bars
        ctx.setFillColor(cg(bar))
        for b in 0..<n where counts[b] > 0 {
            let x0 = px(lo + Double(b) * bw)
            let x1 = px(lo + Double(b + 1) * bw)
            let h = py(counts[b]) - margin.minY
            ctx.fill(CGRect(x: x0 + 0.5, y: margin.minY, width: max(0, x1 - x0 - 1), height: h))
        }

        // x tick labels: lo, 0, hi
        let fmt = "%.3g"
        drawText(String(format: fmt, lo), at: CGPoint(x: margin.minX, y: margin.minY - 16), fontSize: 11, color: ink, in: ctx, anchor: .center)
        drawText(String(format: fmt, hi), at: CGPoint(x: margin.maxX, y: margin.minY - 16), fontSize: 11, color: ink, in: ctx, anchor: .center)
        if lo < 0 && hi > 0 {
            drawText("0", at: CGPoint(x: px(0), y: margin.minY - 16), fontSize: 11, color: ink, in: ctx, anchor: .center)
        }
        drawText("count (peak \(maxCount))", at: CGPoint(x: margin.minX, y: margin.maxY + 6), fontSize: 11, color: ink, in: ctx)

        try finalize(ctx, to: url)
    }

    // MARK: - Cross-section profile overlay (#61)

    struct ProfileLayer {
        let loops: [[SIMD2<Double>]]
        /// Open polylines (e.g. slicing an open shell) — drawn WITHOUT a closing
        /// segment, unlike `loops`.
        let openPaths: [[SIMD2<Double>]]
        let color: SIMD4<Float>
        let label: String

        init(loops: [[SIMD2<Double>]], openPaths: [[SIMD2<Double>]] = [],
             color: SIMD4<Float>, label: String) {
            self.loops = loops
            self.openPaths = openPaths
            self.color = color
            self.label = label
        }
    }

    /// Overlay two (or more) sets of 2D loops in a shared plane frame.
    static func profileOverlay(
        layers: [ProfileLayer], title: String,
        width: Int = 640, height: Int = 640, to url: URL
    ) throws {
        guard let ctx = makeContext(width: width, height: height, background: SIMD4(1, 1, 1, 1)) else {
            throw ChartError.contextFailed
        }
        let ink = SIMD4<Float>(0.12, 0.12, 0.14, 1)
        drawText(title, at: CGPoint(x: 12, y: CGFloat(height) - 24), fontSize: 14, color: ink, in: ctx)

        // combined bounds
        var lo = SIMD2<Double>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = SIMD2<Double>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
        var any = false
        for layer in layers {
            for loop in layer.loops {
                for p in loop { any = true; lo = simd_min(lo, p); hi = simd_max(hi, p) }
            }
            for path in layer.openPaths {
                for p in path { any = true; lo = simd_min(lo, p); hi = simd_max(hi, p) }
            }
        }
        guard any else {
            drawText("no contours at this station", at: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height) / 2), fontSize: 13, color: ink, in: ctx, anchor: .center)
            try finalize(ctx, to: url)
            return
        }
        var size = hi - lo
        if size.x < 1e-9 { size.x = 1 }
        if size.y < 1e-9 { size.y = 1 }

        let pad: CGFloat = 48
        let plot = CGRect(x: pad, y: pad, width: CGFloat(width) - 2 * pad, height: CGFloat(height) - 2 * pad)
        // uniform scale preserving aspect
        let scale = min(plot.width / CGFloat(size.x), plot.height / CGFloat(size.y))
        let centre = (lo + hi) * 0.5
        func map(_ p: SIMD2<Double>) -> CGPoint {
            CGPoint(
                x: plot.midX + CGFloat(p.x - centre.x) * scale,
                y: plot.midY + CGFloat(p.y - centre.y) * scale
            )
        }

        ctx.setLineWidth(1.6)
        for layer in layers {
            ctx.setStrokeColor(cg(layer.color))
            for loop in layer.loops where loop.count >= 2 {
                ctx.beginPath()
                ctx.move(to: map(loop[0]))
                for p in loop.dropFirst() { ctx.addLine(to: map(p)) }
                ctx.closePath()
                ctx.strokePath()
            }
            for path in layer.openPaths where path.count >= 2 {
                ctx.beginPath()
                ctx.move(to: map(path[0]))
                for p in path.dropFirst() { ctx.addLine(to: map(p)) }
                ctx.strokePath()   // open: no closePath
            }
        }

        // legend (top-right)
        var ly = CGFloat(height) - 28
        for layer in layers {
            let sw = CGRect(x: CGFloat(width) - 150, y: ly, width: 16, height: 8)
            ctx.setFillColor(cg(layer.color)); ctx.fill(sw)
            drawText(layer.label, at: CGPoint(x: CGFloat(width) - 128, y: ly), fontSize: 12, color: ink, in: ctx)
            ly -= 18
        }
        // scale note
        drawText(String(format: "%.3g × %.3g mm", size.x, size.y),
                 at: CGPoint(x: plot.minX, y: 12), fontSize: 11, color: ink, in: ctx)

        try finalize(ctx, to: url)
    }

    // MARK: - Colorbar legend composited onto an existing render (#63)

    /// Load `pngURL`, draw a vertical diverging colorbar with min/0/max labels in
    /// the top-right, and rewrite the file in place.
    static func overlayColorbar(on pngURL: URL, minValue: Double, maxValue: Double, label: String) throws {
        guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ChartError.imageFailed
        }
        let w = base.width, h = base.height
        guard let ctx = makeContext(width: w, height: h, background: SIMD4(0, 0, 0, 0)) else {
            throw ChartError.contextFailed
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        let ink = SIMD4<Float>(0.10, 0.10, 0.12, 1)
        let barW: CGFloat = 18
        let barH: CGFloat = min(CGFloat(h) * 0.5, 220)
        let barX = CGFloat(w) - 96
        let barY = CGFloat(h) - 40 - barH

        // gradient strip, drawn as horizontal slabs bottom(neg)→top(pos)
        let slabs = 64
        let absMax = max(abs(minValue), abs(maxValue), 1e-9)
        for i in 0..<slabs {
            let frac = Double(i) / Double(slabs - 1)             // 0..1 bottom→top
            let value = minValue + frac * (maxValue - minValue)
            let t = value / absMax
            ctx.setFillColor(cg(divergingColor(t)))
            let y = barY + CGFloat(frac) * barH
            ctx.fill(CGRect(x: barX, y: y, width: barW, height: barH / CGFloat(slabs) + 1))
        }
        ctx.setStrokeColor(cg(ink)); ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: barX, y: barY, width: barW, height: barH))

        let lx = barX + barW + 6
        drawText(String(format: "%+.3g", maxValue), at: CGPoint(x: lx, y: barY + barH - 6), fontSize: 11, color: ink, in: ctx)
        drawText(String(format: "%+.3g", minValue), at: CGPoint(x: lx, y: barY), fontSize: 11, color: ink, in: ctx)
        if minValue < 0 && maxValue > 0 {
            let zy = barY + CGFloat(-minValue / (maxValue - minValue)) * barH
            drawText("0", at: CGPoint(x: lx, y: zy - 4), fontSize: 11, color: ink, in: ctx)
        }
        // Right-anchored at the image margin, not left-anchored at the bar: the
        // caption can be wider than the 96px the bar leaves, and left-anchoring
        // ran it off the edge — a mostly-grey #72 heatmap lost the very legend
        // that explains what its grey means. Growing leftward spends empty
        // background instead.
        drawText(label, at: CGPoint(x: CGFloat(w) - 8, y: barY + barH + 6),
                 fontSize: 11, color: ink, in: ctx, anchor: .right)

        try finalize(ctx, to: pngURL)
    }

    // MARK: - Zone legend composited onto an existing render (#101)

    /// Load `pngURL`, draw a top-left legend column (swatch + label per
    /// entry) and rewrite the file in place. Mirrors `overlayColorbar`'s
    /// load/draw/rewrite shape for a categorical (rather than scalar) key.
    /// Rows are capped to what the image height allows; anything past that
    /// collapses into a final "+N more" line rather than running off the
    /// bottom or silently dropping entries with no trace.
    static func overlayZoneLegend(on pngURL: URL, entries: [(label: String, color: SIMD4<Float>)]) throws {
        guard !entries.isEmpty else { return }
        guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ChartError.imageFailed
        }
        let w = base.width, h = base.height
        guard let ctx = makeContext(width: w, height: h, background: SIMD4(0, 0, 0, 0)) else {
            throw ChartError.contextFailed
        }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        let ink = SIMD4<Float>(0.10, 0.10, 0.12, 1)
        let rowH: CGFloat = 16
        let top = CGFloat(h) - 12
        let maxRows = max(1, Int((top - 20) / rowH))
        let shown = min(entries.count, maxRows)
        let swatchX: CGFloat = 10
        let labelX: CGFloat = swatchX + 18

        for i in 0..<shown {
            let y = top - CGFloat(i) * rowH
            let (label, color) = entries[i]
            ctx.setFillColor(cg(color))
            ctx.fill(CGRect(x: swatchX, y: y - 9, width: 12, height: 9))
            drawText(label, at: CGPoint(x: labelX, y: y - 9), fontSize: 10, color: ink, in: ctx)
        }
        if entries.count > shown {
            let y = top - CGFloat(shown) * rowH
            drawText("+\(entries.count - shown) more", at: CGPoint(x: labelX, y: y - 9), fontSize: 10, color: ink, in: ctx)
        }

        try finalize(ctx, to: pngURL)
    }

    // MARK: - Per-station strip chart (#102)

    /// Simple line + dot chart of a per-station scalar against its world
    /// axis coordinate, with an optional horizontal tolerance line. Reuses
    /// `histogram`'s axis/margin/text conventions rather than inventing a
    /// second chart grammar.
    static func stripChart(
        stations: [(axisCoord: Double, value: Double)], tolerance: Double?,
        title: String, yLabel: String = "value",
        width: Int = 800, height: Int = 320, to url: URL
    ) throws {
        guard let ctx = makeContext(width: width, height: height, background: SIMD4(1, 1, 1, 1)) else {
            throw ChartError.contextFailed
        }
        let ink = SIMD4<Float>(0.12, 0.12, 0.14, 1)
        let grid = SIMD4<Float>(0.85, 0.85, 0.87, 1)
        let line = SIMD4<Float>(0.30, 0.45, 0.78, 1)
        let band = SIMD4<Float>(0.55, 0.80, 0.45, 0.30)

        let margin = CGRect(x: 60, y: 44, width: CGFloat(width) - 84, height: CGFloat(height) - 84)
        drawText(title, at: CGPoint(x: 12, y: CGFloat(height) - 26), fontSize: 15, color: ink, in: ctx)

        guard !stations.isEmpty else {
            drawText("no stations", at: CGPoint(x: margin.midX, y: margin.midY), fontSize: 13, color: ink, in: ctx, anchor: .center)
            try finalize(ctx, to: url)
            return
        }

        let xs = stations.map(\.axisCoord)
        var ys = stations.map(\.value)
        if let tol = tolerance { ys.append(tol) }   // the tolerance line must fit on-scale too
        var xlo = xs.min()!, xhi = xs.max()!
        if xhi - xlo < 1e-9 { xlo -= 0.5; xhi += 0.5 }
        var ylo = min(0, ys.min()!), yhi = ys.max()!
        if yhi - ylo < 1e-9 { yhi += 0.5 }

        func px(_ v: Double) -> CGFloat { margin.minX + CGFloat((v - xlo) / (xhi - xlo)) * margin.width }
        func py(_ v: Double) -> CGFloat { margin.minY + CGFloat((v - ylo) / (yhi - ylo)) * margin.height }

        ctx.setStrokeColor(cg(grid)); ctx.setLineWidth(1)
        ctx.stroke(margin)

        if let tol = tolerance, tol >= ylo, tol <= yhi {
            ctx.setFillColor(cg(band))
            let y0 = py(max(ylo, -tol)), y1 = py(min(yhi, tol))
            ctx.fill(CGRect(x: margin.minX, y: min(y0, y1), width: margin.width, height: abs(y1 - y0)))
            ctx.setStrokeColor(cg(SIMD4(0.35, 0.6, 0.3, 1))); ctx.setLineWidth(1)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: margin.minX, y: py(tol)))
            ctx.addLine(to: CGPoint(x: margin.maxX, y: py(tol)))
            ctx.strokePath()
        }

        let sorted = stations.sorted { $0.axisCoord < $1.axisCoord }
        ctx.setStrokeColor(cg(line)); ctx.setLineWidth(1.6)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: px(sorted[0].axisCoord), y: py(sorted[0].value)))
        for s in sorted.dropFirst() { ctx.addLine(to: CGPoint(x: px(s.axisCoord), y: py(s.value))) }
        ctx.strokePath()
        ctx.setFillColor(cg(line))
        for s in sorted {
            ctx.fillEllipse(in: CGRect(x: px(s.axisCoord) - 2, y: py(s.value) - 2, width: 4, height: 4))
        }

        let fmt = "%.3g"
        drawText(String(format: fmt, xlo), at: CGPoint(x: margin.minX, y: margin.minY - 16), fontSize: 11, color: ink, in: ctx, anchor: .center)
        drawText(String(format: fmt, xhi), at: CGPoint(x: margin.maxX, y: margin.minY - 16), fontSize: 11, color: ink, in: ctx, anchor: .center)
        drawText(String(format: fmt, ylo), at: CGPoint(x: margin.minX - 8, y: margin.minY), fontSize: 11, color: ink, in: ctx, anchor: .right)
        drawText(String(format: fmt, yhi), at: CGPoint(x: margin.minX - 8, y: margin.maxY - 10), fontSize: 11, color: ink, in: ctx, anchor: .right)
        drawText(yLabel, at: CGPoint(x: margin.minX, y: margin.maxY + 6), fontSize: 11, color: ink, in: ctx)
        drawText("axisCoord (mm)", at: CGPoint(x: margin.maxX, y: margin.minY - 32), fontSize: 11, color: ink, in: ctx, anchor: .right)

        try finalize(ctx, to: url)
    }
}
