import Foundation
import Metal
import Testing

/// Whether this machine has a Metal device, for tests that render.
///
/// A test gated by `.enabled(if: metalDeviceAvailable)` is reported as skipped on a headless
/// runner. The previous shape, an early `return` on a "Metal" error text, recorded a pass
/// with zero expectations run.
let metalDeviceAvailable: Bool = MTLCreateSystemDefaultDevice() != nil

/// Expect `path` to hold a PNG with at least `minBytes` of data.
///
/// `fileExists` alone passes for an empty or garbage file.
func expectPNG(
    atPath path: String, minBytes: Int = 1_000, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let data = try #require(
        FileManager.default.contents(atPath: path), "no file at \(path)",
        sourceLocation: sourceLocation)
    #expect(
        data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
        "\(path) lacks the PNG signature", sourceLocation: sourceLocation)
    #expect(
        data.count >= minBytes, "\(path) is only \(data.count) bytes",
        sourceLocation: sourceLocation)
}
