import Foundation

/// Writes a minimal JWW file (version 700 header, then drawing entities) for tests.
///
/// The header layout mirrors SwiftJWW's reader and its own test builder, from which this is copied.
enum JWWFixture {

    struct Builder {
        var d = Data()
        mutating func u8(_ v: Int) { d.append(UInt8(v & 0xFF)) }
        mutating func u16(_ v: Int) {
            d.append(UInt8(v & 0xFF))
            d.append(UInt8((v >> 8) & 0xFF))
        }
        mutating func u32(_ v: Int) { for k in 0..<4 { d.append(UInt8((v >> (8 * k)) & 0xFF)) } }
        mutating func f64(_ v: Double) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        }
        mutating func emptyStr() { u8(0) }
        mutating func zeros(_ n: Int) { d.append(Data(count: n)) }

        /// Emit a minimal but byte-exact v700 header (all fields zero / empty strings).
        mutating func header() {
            d.append(contentsOf: Array("JwwData.".utf8))
            u32(700)
            emptyStr()  // memo
            u32(0)
            u32(0)  // zumen, writeGLay
            for _ in 0..<16 {
                zeros(4 + 4 + 8 + 4)
                for _ in 0..<16 { zeros(8) }
            }  // layer-groups
            zeros(14 * 4)
            zeros(5 * 4)
            zeros(4)
            zeros(4)  // dummy, sunpou, dummy1, maxDrawWid
            zeros(8 * 2)
            zeros(8)
            zeros(4)
            zeros(4)
            zeros(8)
            zeros(8 * 2)
            zeros(8 * 2)
            for _ in 0..<(16 * 16) { emptyStr() }
            for _ in 0..<16 { emptyStr() }  // names
            zeros(8)
            zeros(8)
            zeros(4)
            zeros(8)  // kage...
            zeros(8)
            zeros(8)  // tenkuu (v>=300)
            zeros(4)
            zeros(8)
            zeros(8 * 2)
            zeros(8)
            zeros(8 * 2)
            for _ in 0..<8 { zeros(8 + 8 + 8 + 4) }  // zoom (v>=300)
            zeros(8 * 3)
            zeros(4)
            zeros(8 * 2)
            zeros(8)
            zeros(4)  // dDm (v>=300)
            zeros(8 * 10)
            zeros(8)  // fukusen, ryo
            for _ in 0..<10 { zeros(8) }
            for _ in 0..<10 { zeros(16) }  // Pen, PrtPen
            for _ in 0..<8 { zeros(16) }
            for _ in 0..<5 { zeros(20) }
            for _ in 0..<4 { zeros(16) }  // LType
            zeros(4 * 11)
            zeros(8)
            zeros(4 * 3)
            zeros(8 * 5)
            zeros(8 * 4)
            zeros(8)  // flags..solid
            for _ in 0..<257 { zeros(8) }  // SXF color display (v>=420)
            for _ in 0..<257 {
                emptyStr()
                zeros(16)
            }  // SXF color print
            for _ in 0..<33 { zeros(16) }  // SXF ltype pattern
            for _ in 0..<33 {
                emptyStr()
                zeros(4 + 80)
            }  // SXF ltype param
            for _ in 0..<10 { zeros(8 * 3 + 4) }  // Moji[1..10]
            zeros(8 * 3)
            zeros(8)
            zeros(8)
            zeros(8)
            zeros(4)
            zeros(8 * 6)  // moji write settings
        }
        mutating func base(penStyle: Int = 1, color: Int = 2, layer: Int = 0) {
            u32(0)
            u8(penStyle)
            u16(color)
            u16(0)
            u16(layer)
            u16(0)
            u16(0)  // v>=351 → penWidth present
        }
        mutating func str(_ s: String) {
            let a = Array(s.utf8)
            u8(a.count)
            d.append(contentsOf: a)
        }
        mutating func classTag(_ name: String) {
            u16(0xFFFF)
            u16(0x2bc)
            u16(name.utf8.count)
            d.append(contentsOf: Array(name.utf8))
        }
        // inline entity field groups (no object tag; used inside CDataSunpou)
        mutating func senFields(
            _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, layer: Int = 0
        ) {
            base(layer: layer)
            f64(x1)
            f64(y1)
            f64(x2)
            f64(y2)
        }
        mutating func mojiFields(_ text: String, layer: Int = 0) {
            base(layer: layer)
            f64(0)
            f64(0)
            f64(0)
            f64(0)
            u32(0)
            f64(2)
            f64(2)
            f64(0)
            f64(0)
            emptyStr()
            str(text)
        }
        mutating func tenFields(_ x: Double, _ y: Double, layer: Int = 0) {
            base(layer: layer)
            f64(x)
            f64(y)
            u32(0)
        }
    }

    /// The 100 x 60 plate of `Fixtures/DWG/plate.dwg` and `Fixtures/Drawing/plate.dxf`.
    ///
    /// Four lines and a circle of radius 5 at (30, 30), all on layer 0. JWW has no equivalent of
    /// the DXF dimension entities used there, so it carries the geometry only.
    static func plate() -> Data {
        var b = Builder()
        b.header()
        b.u16(5)  // array preamble: five objects
        let corners: [((Double, Double), (Double, Double))] = [
            ((0, 0), (100, 0)), ((100, 0), (100, 60)), ((100, 60), (0, 60)), ((0, 60), (0, 0)),
        ]
        for (i, line) in corners.enumerated() {
            if i == 0 {
                b.classTag("CDataSen")
            } else {
                b.u16(0x8001)  // back-reference to the CDataSen class
            }
            b.base(layer: 0)
            b.f64(line.0.0)
            b.f64(line.0.1)
            b.f64(line.1.0)
            b.f64(line.1.1)
        }
        b.classTag("CDataEnko")
        b.base(layer: 0)
        b.f64(30)  // centre x
        b.f64(30)  // centre y
        b.f64(5)  // radius
        b.f64(0)  // start
        b.f64(2 * .pi)  // sweep
        b.f64(0)  // tilt
        b.f64(1)  // ratio: a circle
        b.u32(1)  // full circle
        return b.d
    }
}
