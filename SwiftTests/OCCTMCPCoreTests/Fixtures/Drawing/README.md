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
  because the builder has no one-call form for it.
- `mixed.jww`: a line in layer group 0 at 1:10 and one in group 1 at 1:1 (`mixedScales()`).
- `stored.jww`: a 10 unit line at 1:10 with one stored dimension record, value `100`
  (`storedDimension()`).
- `unstated.jww`: a 10 unit line in a layer group that states a scale of 0 (`unstatedScale()`).
- `unstated-beside-scaled.jww`: a line in group 0 at 1:10 and one in group 1 that states a scale of
  0 (`scaledBesideUnstated()`).
- `block-group.jww`: a block whose one line is in group 1 (at 1:5), placed by a reference in
  group 0 (at 1:10), so group 1 holds no top-level element. Composed from the builder's `block`
  and `insert` items, like `both-dimensions.jww`.
- `solid.jww`: a 100 unit line and a solid fill (`solidFill()`).
- `dimension-in-block.jww`: the width at 1:10 with its dimension kept as loose pieces inside a
  block, placed once. Composed from the builder's `block` and `insert` items and the pieces of
  `dimensionedPlate()`.
- `old-dimension.jww`: the stored dimension record of `stored.jww` in a version 3.51 file, which
  keeps no measured points (`storedDimension(version: 351)`).

They are here so the drawing tools are tested on a DWG and a JWW read through `DrawingLoader`, not
only on DXF text built in the tests. The AutoCAD-written DWG samples in OCCTSwiftIO's tests are not
copied: they are under MPL-2.0 and are only used in a real run of the server.
