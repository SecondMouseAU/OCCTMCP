# Drawing fixtures

`plate.dxf` and `plate.dwg` are the same 100 x 60 plate (four lines and a circle; the DWG also
carries three dimensions), copied unchanged from `SecondMouseAU/OCCTSwiftIO` at v2.0.0-beta.6,
`Tests/OCCTSwiftIOTests/Fixtures/Drawing/plate.dxf` and `.../Fixtures/DWG/plate.dwg`, where the
drawing loader's own tests read them. `plate.jww` is the same plate (the four lines and the circle,
no dimensions) as a JWW version 700 file. SwiftJWW's tests build it in code; it was written once
from that builder (`Tests/OCCTSwiftIOTests/Support/JWWFixture.swift` in OCCTSwiftIO), and committed as bytes so this
repository does not carry a copy of the JWW layout.

The other JWW files come from the same builder (`JWWFixture` in OCCTSwiftIO v2.0.0-beta.10) and are
committed as bytes the same way:

- `dimensioned.jww`: a 10 x 6 outline drawn at 1:10 (so 100 x 60 at full size) with a dimension kept
  as loose pieces (value `100`) and a radius value `R5` that no dimension explains
  (`dimensionedPlate()`).
- `both-dimensions.jww`: the same outline with two dimensions in one file, the width `100` kept as
  loose pieces (rebuilt by the reader) and the height `60` stored as one dimension record. It is the
  control that `rebuilt` follows each dimension and not the file. It is the builder's
  `dimensionedPlate()` pieces and `storedDimension()` record composed with `drawing(_:scales:)`,
  because the builder has no one-call form for it (`bothDimensions()` in the recipe below).
- `mixed.jww`: a line in layer group 0 at 1:10 and one in group 1 at 1:1 (`mixedScales()`).
- `stored.jww`: a 10 unit line at 1:10 with one stored dimension record, value `100`
  (`storedDimension()`).
- `unstated.jww`: a 10 unit line in a layer group that states a scale of 0 (`unstatedScale()`).
- `unstated-beside-scaled.jww`: a line in group 0 at 1:10 and one in group 1 that states a scale of
  0 (`scaledBesideUnstated()`).
- `block-group.jww`: a block whose one line is in group 1 (at 1:5), placed by a reference in
  group 0 (at 1:10), so group 1 holds no top-level element. Composed from the builder's `block`
  and `insert` items, like `both-dimensions.jww` (`blockGroup()` in the recipe below).
- `solid.jww`: a 100 unit line and a solid fill (`solidFill()`).
- `dimension-in-block.jww`: the width at 1:10 with its dimension kept as loose pieces inside a
  block, placed once. Composed from the builder's `block` and `insert` items and the pieces of
  `dimensionedPlate()` (`dimensionInBlock()` in the recipe below).
- `stored-dimension-in-block.jww`: the width at 1:10 with a stored dimension record (value `100`)
  inside a block, placed once. It is the control for `dimension-in-block.jww`: a stored record in a
  block is listed, loose pieces in a block are not rebuilt (`storedDimensionInBlock()` in the recipe
  below).
- `old-dimension.jww`: the stored dimension record of `stored.jww` in a version 3.51 file, which
  keeps no measured points (`storedDimension(version: 351)`).

They are here so the drawing tools are tested on a DWG and a JWW read through `DrawingLoader`, not
only on DXF text built in the tests. The AutoCAD-written DWG samples in OCCTSwiftIO's tests are not
copied: they are under MPL-2.0 and are only used in a real run of the server.

## Rebuilding the JWW fixtures

The JWW files are committed as bytes, so this repository does not carry a copy of the builder. Four
of them are not one call of it: the builder has no one-call form for them, so each is a composition
of its `Item`s, and the program below holds those compositions with every coordinate, layer, flag
and scale. It also calls the builder's own one-call functions for the rest, so one run rebuilds all
of the JWW fixtures except `plate.jww` (see below).

To rebuild them, or to audit them when OCCTSwiftIO's builder changes, take
`Tests/OCCTSwiftIOTests/Support/JWWFixture.swift` from `SecondMouseAU/OCCTSwiftIO` at
v2.0.0-beta.10 and save the program as `main.swift` beside it:

```swift
import Foundation

extension JWWFixture {
    /// The 10 x 6 outline, four lines in group 0, layer 0.
    static var outline: [Item] {
        [(0.0, 0.0, 10.0, 0.0), (10, 0, 10, 6), (10, 6, 0, 6), (0, 6, 0, 0)]
            .map { Item(shape: .line($0.0, $0.1, $0.2, $0.3)) }
    }

    /// The width's loose pieces, which are the pieces of `dimensionedPlate()` without its `R5`
    /// text. All are on layer 0xE with the dimension flags.
    static var widthPieces: [Item] {
        let layer = 0xE
        return [
            Item(shape: .line(0, -2, 10, -2), layer: layer, flags: 0x2000),
            Item(shape: .line(0, -0.5, 0, -2), layer: layer, flags: 0x2000),
            Item(shape: .line(10, -0.5, 10, -2), layer: layer, flags: 0x2000),
            Item(shape: .point(0, -2), layer: layer, flags: 0x40),
            Item(shape: .point(10, -2), layer: layer, flags: 0x40),
            Item(shape: .text("100", at: (4.5, -1.8)), layer: layer, flags: 0x4010),
        ]
    }

    /// The width's stored record, as in `storedDimension()`: its value text is on layer 0xD.
    static var widthRecord: Item {
        Item(
            shape: .dimensionRecord(
                line: (0, -2, 10, -2), value: "100", at: (4.5, -1.8), textLayer: 0xD,
                witness: [(0, 0, 0, -2), (10, 0, 10, -2)], arrows: [(0, -2), (10, -2)],
                measured: [(0, 0), (10, 0)]),
            layer: 0xE)
    }

    /// The outline, the width as loose pieces, then the height as one stored record. Group 0 is
    /// at 1:10.
    static func bothDimensions() -> Data {
        let height = Item(
            shape: .dimensionRecord(
                line: (12, 0, 12, 6), value: "60", at: (12.3, 3), textLayer: 0xD,
                witness: [(10, 0, 12.5, 0), (10, 6, 12.5, 6)], arrows: [(12, 0), (12, 6)],
                measured: [(10, 0), (10, 6)]),
            layer: 0xE)
        return drawing(outline + widthPieces + [height], scales: [0: 10])
    }

    /// Block 1 "B" holds one line in group 1, and a reference in group 0 at (2, 3) places it.
    /// Group 0 is at 1:10 and group 1 at 1:5.
    static func blockGroup() -> Data {
        drawing(
            [
                Item(
                    shape: .block(
                        number: 1, name: "B",
                        members: [Item(shape: .line(0, 0, 1, 0), group: 1)])),
                Item(shape: .insert(number: 1, at: (2, 3))),
            ], scales: [0: 10, 1: 5])
    }

    /// The width line, then block 1 "DIM" holding the loose pieces, then a reference at the origin.
    /// Group 0 is at 1:10.
    static func dimensionInBlock() -> Data {
        drawing(
            [
                Item(shape: .line(0, 0, 10, 0)),
                Item(shape: .block(number: 1, name: "DIM", members: widthPieces)),
                Item(shape: .insert(number: 1, at: (0, 0))),
            ], scales: [0: 10])
    }

    /// The width line, then block 1 "DIM" holding the stored record, then a reference at the
    /// origin. Group 0 is at 1:10.
    static func storedDimensionInBlock() -> Data {
        drawing(
            [
                Item(shape: .line(0, 0, 10, 0)),
                Item(shape: .block(number: 1, name: "DIM", members: [widthRecord])),
                Item(shape: .insert(number: 1, at: (0, 0))),
            ], scales: [0: 10])
    }
}

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let fixtures: [(String, Data)] = [
    ("dimensioned.jww", JWWFixture.dimensionedPlate()),
    ("mixed.jww", JWWFixture.mixedScales()),
    ("stored.jww", JWWFixture.storedDimension()),
    ("old-dimension.jww", JWWFixture.storedDimension(version: 351)),
    ("unstated.jww", JWWFixture.unstatedScale()),
    ("unstated-beside-scaled.jww", JWWFixture.scaledBesideUnstated()),
    ("solid.jww", JWWFixture.solidFill()),
    ("both-dimensions.jww", JWWFixture.bothDimensions()),
    ("block-group.jww", JWWFixture.blockGroup()),
    ("dimension-in-block.jww", JWWFixture.dimensionInBlock()),
    ("stored-dimension-in-block.jww", JWWFixture.storedDimensionInBlock()),
]
for (name, data) in fixtures {
    try data.write(to: directory.appendingPathComponent(name))
}
```

Then build it, run it into a scratch directory, and compare each file with the committed one:

```bash
FIXTURES=/path/to/OCCTMCP/SwiftTests/OCCTMCPCoreTests/Fixtures/Drawing
swiftc -O JWWFixture.swift main.swift -o rebuild && mkdir out && ./rebuild out
for f in out/*.jww; do cmp "$f" "$FIXTURES/$(basename "$f")" && echo "same: $(basename "$f")"; done
```

The writer stamps nothing (no time, no random field), so the same builder gives the same bytes
every time. Rebuilt this way against v2.0.0-beta.10 (commit `d1b7274`), all eleven files are
byte-identical to the committed ones. If a later builder gives different bytes, the files are not
wrong for that reason alone: read each pair through `read_drawing`, `list_drawing_dimensions` and
`list_drawing_entities` and compare the entities, which is what the tests assert.

`plate.jww` is not in the program. It was written from an older revision of the builder, one that
wrote a layer group scale of 0 where `plate()` now writes 1, and it differs from today's `plate()`
only in those sixteen scale fields (32 bytes).
