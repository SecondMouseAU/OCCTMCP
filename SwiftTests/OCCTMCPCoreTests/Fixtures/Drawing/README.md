# Drawing fixtures

`plate.dxf` and `plate.dwg` are the same 100 x 60 plate (four lines and a circle; the DWG also
carries three dimensions), copied unchanged from `SecondMouseAU/OCCTSwiftIO` at v2.0.0-beta.6,
`Tests/OCCTSwiftIOTests/Fixtures/Drawing/plate.dxf` and `.../Fixtures/DWG/plate.dwg`, where the
drawing loader's own tests read them. `plate.jww` is the same plate (the four lines and the circle,
no dimensions) as a JWW version 700 file. SwiftJWW's tests build it in code; it was written once
from that builder (`Tests/OCCTSwiftIOTests/Support/JWWFixture.swift` in OCCTSwiftIO), and committed as bytes so this
repository does not carry a copy of the JWW layout.

They are here so the drawing tools are tested on a DWG and a JWW read through `DrawingLoader`, not
only on DXF text built in the tests. The AutoCAD-written DWG samples in OCCTSwiftIO's tests are not
copied: they are under MPL-2.0 and are only used in a real run of the server.
