# Drawing fixtures

`plate.dxf` and `plate.dwg` are the same 100 x 60 plate (four lines and a circle; the DWG also
carries three dimensions), copied unchanged from `SecondMouseAU/OCCTSwiftIO` at v2.0.0-beta.6,
`Tests/OCCTSwiftIOTests/Fixtures/Drawing/plate.dxf` and `.../Fixtures/DWG/plate.dwg`, where the
drawing loader's own tests read them. `plate.jww` is the same plate (the four lines and the circle,
no dimensions) as a JWW version 700 file. SwiftJWW's tests build it in code; it was written once
from that builder (`Tests/OCCTSwiftIOTests/Support/JWWFixture.swift` in OCCTSwiftIO), and committed as bytes so this
repository does not carry a copy of the JWW layout.

`dimensioned.jww` and `mixed.jww` come from the same builder (`JWWFixture.dimensionedPlate()`,
`JWWFixture.mixedScales()`, `storedDimension()` and `unstatedScale()`, OCCTSwiftIO v2.0.0-beta.10) and are committed as bytes the same way.
`dimensioned.jww` is a 10 x 6 outline drawn at 1:10 (so 100 x 60 at full size) with a dimension kept
as loose pieces (value `100`) and a radius value `R5` that no dimension explains. `mixed.jww` has
a line in layer group 0 at 1:10 and one in group 1 at 1:1. `stored.jww` is a 10 unit line at 1:10
with one stored dimension record (value `100`), the control for a dimension that is not rebuilt.
`unstated.jww` is a 10 unit line in a layer group that states a scale of 0.

They are here so the drawing tools are tested on a DWG and a JWW read through `DrawingLoader`, not
only on DXF text built in the tests. The AutoCAD-written DWG samples in OCCTSwiftIO's tests are not
copied: they are under MPL-2.0 and are only used in a real run of the server.
