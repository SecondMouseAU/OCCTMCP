// inspect_assembly reports each node's transform as 16 floats, column 0 first. OCCTSwift
// 4.0.0-beta.6 changed AssemblyNode.transform from simd_float4x4 to Matrix4x4F, and flatten now
// reads columnMajorElements, so a transposed or reordered result must fail here.

import Testing
import OCCTSwift
@testable import OCCTMCPCore

@Suite("AssemblyTools.flatten keeps the column-major layout")
struct AssemblyFlattenTests {

    /// Sixteen distinct values, so no symmetry can hide a transpose: column c holds
    /// 4c+1 ... 4c+4, which makes the translation column (3) read 13, 14, 15 and 16.
    private let matrix = Matrix4x4F(
        SIMD4<Float>(1, 2, 3, 4),
        SIMD4<Float>(5, 6, 7, 8),
        SIMD4<Float>(9, 10, 11, 12),
        SIMD4<Float>(13, 14, 15, 16))

    @Test("column 0 comes first, then 1, 2 and 3")
    func columnMajorOrder() {
        #expect(AssemblyTools.flatten(matrix) == (1...16).map(Float.init))
    }

    @Test("the translation column lands in elements 12 to 14")
    func translationSlots() {
        let flat = AssemblyTools.flatten(matrix)
        #expect(Array(flat[12...14]) == [13, 14, 15])
        #expect(flat[15] == 16)
    }

    @Test("the identity flattens to the identity transform the tool reports for a node without one")
    func identity() {
        #expect(AssemblyTools.flatten(.identity) == AssemblyTools.identityTransform())
    }
}
