// OCCTMCPCore — server factory + tool registration for the OCCTMCP MCP
// server. Tools are registered against a single Server instance via the
// MCP SDK's withMethodHandler API.
//
// The Swift port grows tool by tool, mirroring the existing Node
// implementation under src/. Once the Swift side reaches feature parity
// the Node code under src/ can be retired.

import Foundation
import MCP
import OCCTSwiftViewport

public enum OCCTMCPVersion {
    public static let serverName = "occtmcp"
    /// Keep in step with the release tag: clients report this string, and a
    /// stale value makes version triage ambiguous (noted in #75).
    public static let serverVersion = "1.26.0"
}

/// Shared by the three tools that share DeviationTools' signed-distance engine
/// (#72), so the LLM reads one consistent account of what the sign means.
let signModeDescription = """
How each sample picks WHICH reference triangle it corresponds to. This steers \
the SIGNED figures only (signedMean/signedMin/signedMax, per-section sweeps, \
histogram buckets, heatmap colours). The unsigned ones (max/rms/mean/p95/\
worstPoint/symmetricHausdorff/maxAbs/withinTolerance) always measure to the \
NEAREST reference surface and mean the same in every mode. \
"robust" (default) rejects reference triangles whose outward normal opposes the \
sample's own before the nearest survivor wins. That matters against an OPEN, \
thin-walled reference (a raw scan / STL skin): a candidate flank sitting 4.5mm \
inside a 2mm wall is only 2.5mm from the wall's INNER surface, so under \
"nearest" that surface wins on proximity and reports +2.5 proud when the truth \
is −4.5 shy — inverted sign, with nothing tying to flag it. So against such a \
reference expect max/mean to report 2.5 while signedMin reports −4.5: both are \
true, they measure to different surfaces, and the gap between them is itself \
the tell that the reference is thin-walled. Samples with no compatible surface \
in reach are reported ambiguous and excluded from the signed figures rather \
than guessed; if EVERY sample is (ambiguousFraction ≈ 1.0) the signed figures \
come back null — do not read that as zero bias, it means the sign channel is \
unavailable and the reference's winding is likely inverted relative to the \
sampled body. "nearest" takes the nearest triangle whatever it is — the \
pre-1.17 behaviour, correct only against a watertight / single-surface reference.
"""

/// Build a fully-configured MCP server with every OCCTMCP tool registered.
/// Caller is responsible for `start(transport:)` and `waitUntilCompleted()`.
public func makeOCCTMCPServer() async -> Server {
    let server = Server(
        name: OCCTMCPVersion.serverName,
        version: OCCTMCPVersion.serverVersion,
        capabilities: .init(
            tools: .init(listChanged: false)
        )
    )
    await registerTools(on: server)
    return server
}

func registerTools(on server: Server) async {
    let tools = catalogTools()

    await server.withMethodHandler(ListTools.self) { _ in
        return .init(tools: tools)
    }

    await server.withMethodHandler(CallTool.self) { params in
        return await dispatch(callName: params.name, arguments: params.arguments ?? [:])
    }
}

func catalogTools() -> [Tool] {
    return [
        Tool(
            name: "get_scene",
            description: "Read the current scene manifest (bodies, colors, materials).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "get_script",
            description: "Return the source of the most recent Swift CAD script executed in this session.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "export_model",
            description: "List exported model files (BREP, STEP, STL, OBJ, IGES, glTF, JSON) from the current output directory.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "validate_geometry",
            description: "Per-body topology validation. Wraps GraphIO + BRepGraph.validate() in-process.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object([
                        "type": .string("string"),
                        "description": .string("Specific body to validate. If omitted, validates every BREP body."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "recognize_features",
            description: "Detect pockets and holes via OCCTSwift's AAG heuristics.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "kinds": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array([.string("pocket"), .string("hole")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "analyze_clearance",
            description: "Pairwise interference / minimum-clearance check between 2+ bodies. Each pair gets minDistance + (optionally) up to 16 contacts.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyIds": .object([
                        "type": .string("array"),
                        "minItems": .int(2),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "computeContacts": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("bodyIds")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "graph_validate",
            description: "Raw-path topology validation. Pass an absolute BREP path; use validate_geometry for the scene-aware version.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "brep_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("brep_path")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "graph_compact",
            description: "Compact a BREP's topology graph (drops unreferenced nodes); writes the rebuilt shape to output_path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "brep_path": .object(["type": .string("string")]),
                    "output_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("brep_path"), .string("output_path")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "graph_dedup",
            description: "Deduplicate shared surface/curve geometry in a BREP's topology graph; writes the rebuilt shape to output_path.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "brep_path": .object(["type": .string("string")]),
                    "output_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("brep_path"), .string("output_path")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "graph_ml",
            description: "Export a BREP's topology graph as ML-friendly JSON. Pass an absolute BREP path and optionally a description. Wraps ScriptHarness BREPGraphJSONExporter, augmented with a `faceAdjacency` block ({face1,face2,convexity,sharedEdgeCount}) — the convexity-attributed gAAG edge attribute, face indices in shape.faces() order.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "brep_path": .object(["type": .string("string")]),
                    "description": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("brep_path")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "graph_select",
            description: "Local B-rep graph adjacency / selection query (no full-graph dump). query=face-neighbors needs `face` (returns adjacent faces + convexity + shared-edge count); edge-faces needs `edge`; vertex-edges needs `vertex`; face-adjacency returns the full attributed face-adjacency graph (gAAG); edges-class needs `class` (boundary|non-manifold|seam|degenerate). Face indices follow shape.faces() order (the face[N] scheme query_topology emits); edge/vertex indices are BRepGraph indices.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "brep_path": .object(["type": .string("string")]),
                    "query": .object([
                        "type": .string("string"),
                        "enum": .array([.string("face-neighbors"), .string("edge-faces"), .string("vertex-edges"), .string("face-adjacency"), .string("edges-class")]),
                    ]),
                    "face": .object(["type": .string("integer")]),
                    "edge": .object(["type": .string("integer")]),
                    "vertex": .object(["type": .string("integer")]),
                    "class": .object(["type": .string("string"), "enum": .array([.string("boundary"), .string("non-manifold"), .string("seam"), .string("degenerate")])]),
                ]),
                "required": .array([.string("brep_path"), .string("query")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "feature_recognize",
            description: "Detect pockets and holes via AAG heuristics. Pass an absolute BREP path; recognize_features is the scene-aware variant.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "brep_path": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("brep_path")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "get_api_reference",
            description: "Returns a catalog of every MCP tool this server exposes (category=mcp_tools), or a pointer to OCCTSwift docs for the OCCT API categories. Use mcp_tools for LLM auto-discovery.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "category": .object([
                        "type": .string("string"),
                        "description": .string("'mcp_tools' for the live tool catalog; any other value returns a pointer to the OCCTSwift sources / docs."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "apply_feature",
            description: "Apply a single feature spec (drill / fillet / chamfer / extrude / revolve / thread / boolean) to a scene body via OCCTSwift's FeatureReconstructor. Without outputBodyId, replaces in place; with outputBodyId, adds a new body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "feature": .object([
                        "type": .string("object"),
                        "description": .string("FeatureSpec object with a 'kind' discriminator. See OCCTSwift/Sources/OCCTSwift/FeatureReconstructor.swift for the schema."),
                    ]),
                    "outputBodyId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId"), .string("feature")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "inspect_assembly",
            description: "Walk an XCAF assembly hierarchy. Pass either a scene bodyId (BREP — degenerate single-node response) or an inputPath (STEP / IGES / XBF for the full tree).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "inputPath": .object(["type": .string("string")]),
                    "depth": .object(["type": .string("integer"), "minimum": .int(0)]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "generate_drawing",
            description: "Render a multi-view ISO 128-30 DXF technical drawing. Pass `bodyId` for a single-part drawing (sections / dimensions honoured), or `bodyIds` (2+) for a general-arrangement / assembly sheet — shared views with a parts list and a numbered balloon per body. Pass a DrawingSpec object (sheet, title, views, sections, dimensions, ...).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string"), "description": .string("Single body — standard part drawing.")]),
                    "bodyIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Two or more bodies — general-arrangement assembly sheet with a parts list. Takes precedence over `bodyId`."),
                    ]),
                    "outputPath": .object(["type": .string("string")]),
                    "spec": .object([
                        "type": .string("object"),
                        "description": .string("DrawingSpec object: { sheet, title?, views, sections?, dimensions?, ... }. See OCCTSwiftScripts/Sources/DrawingComposer/Spec.swift. For a general-arrangement sheet, per-view sections/dimensions are not applied."),
                    ]),
                ]),
                "required": .array([.string("outputPath"), .string("spec")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "execute_script",
            description: "Compile and run an arbitrary Swift CAD script via a cached SPM workspace. The script must import OCCTSwift and ScriptHarness, accumulate geometry on a ScriptContext, and call ctx.emit(). Cold start ~60s on first call (full SPM build of OCCTSwift); subsequent calls ~1-2s incremental.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "code": .object([
                        "type": .string("string"),
                        "description": .string("Complete Swift source for main.swift."),
                    ]),
                    "description": .object([
                        "type": .string("string"),
                        "description": .string("Short description of what this script creates."),
                    ]),
                ]),
                "required": .array([.string("code")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "set_assembly_metadata",
            description: "Write XCAF document- or component-level metadata onto an OCAF document and save as binary .xbf. Mirrors occtkit set-metadata.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "inputPath": .object(["type": .string("string"), "description": .string("STEP / XBF input.")]),
                    "outputPath": .object(["type": .string("string"), "description": .string("Output .xbf path.")]),
                    "scope": .object([
                        "type": .string("string"),
                        "enum": .array([.string("document"), .string("component")]),
                    ]),
                    "componentId": .object(["type": .string("integer")]),
                    "metadata": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "title": .object(["type": .string("string")]),
                            "drawnBy": .object(["type": .string("string")]),
                            "material": .object(["type": .string("string")]),
                            "weight": .object(["type": .string("number")]),
                            "revision": .object(["type": .string("string")]),
                            "partNumber": .object(["type": .string("string")]),
                            "customAttrs": .object([
                                "type": .string("object"),
                                "additionalProperties": .object(["type": .string("string")]),
                            ]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("inputPath"), .string("outputPath"), .string("metadata")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "check_thickness",
            description: "Wall-thickness analysis (sheet metal / casting / 3D-printing). UV-grid sample each face + cast inward ray to opposite wall. Reports min/max/mean and flags samples below minAcceptable.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "minAcceptable": .object(["type": .string("number")]),
                    "samplingDensity": .object([
                        "type": .string("string"),
                        "enum": .array([.string("coarse"), .string("medium"), .string("fine")]),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "render_preview",
            description: "Headless Metal render of the current scene (or a subset) to PNG. Uses OCCTSwiftViewport's OffscreenRenderer + OCCTSwiftTools' Shape→ViewportBody bridge. Mesh-scale bodies (imported STL/OBJ scans; >10k edges) render via a linear tessellation path — edge overlays kept up to 100k edges (bulk wireframe), surface-only beyond — so large scans return in seconds instead of hanging.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "outputPath": .object(["type": .string("string")]),
                    "bodyIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "options": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "camera": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("iso"), .string("front"), .string("back"),
                                    .string("top"), .string("bottom"), .string("left"), .string("right"),
                                ]),
                            ]),
                            "cameraPosition": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")]),
                                "minItems": .int(3), "maxItems": .int(3),
                            ]),
                            "cameraTarget": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")]),
                                "minItems": .int(3), "maxItems": .int(3),
                            ]),
                            "cameraUp": .object([
                                "type": .string("array"),
                                "items": .object(["type": .string("number")]),
                                "minItems": .int(3), "maxItems": .int(3),
                            ]),
                            "width": .object(["type": .string("integer"), "minimum": .int(1)]),
                            "height": .object(["type": .string("integer"), "minimum": .int(1)]),
                            "displayMode": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("wireframe"), .string("shaded"),
                                    .string("shadedWithEdges"), .string("flat"),
                                    .string("xray"), .string("rendered"),
                                ]),
                            ]),
                            "background": .object([
                                "type": .string("string"),
                                "description": .string("'light' | 'dark' | 'transparent' | '#rrggbb' / '#rrggbbaa'"),
                            ]),
                            "renderAnnotations": .object([
                                "type": .string("boolean"),
                                "description": .string("Overlay sidecar annotations (Trihedron / WorkPlane / Axis / BoundingBox / DiffMarker). Default true."),
                            ]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("outputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "pick_surface_point",
            description: "Cast a ray through pixel (screenX, screenY) of a render_preview-framed view and return the nearest world-space surface point [x,y,z] on a body, plus the bodyId and a selectionId. Pass the SAME options (camera / width / height) you rendered the preview with so the pixel maps to the same ray. The returned selectionId is a valid add_dimension anchor, so you can pick two points and dimension between them — measure to an arbitrary point on a face, not just a topology centroid.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "screenX": .object(["type": .string("number"), "description": .string("Pixel X (top-left origin) in the options.width×height image.")]),
                    "screenY": .object(["type": .string("number"), "description": .string("Pixel Y (top-left origin) in the options.width×height image.")]),
                    "id": .object(["type": .string("string"), "description": .string("Optional explicit selectionId for the picked point.")]),
                    "options": .object([
                        "type": .string("object"),
                        "description": .string("Camera / framing — same shape as render_preview.options (camera, cameraPosition/Target/Up, width, height)."),
                    ]),
                ]),
                "required": .array([.string("screenX"), .string("screenY")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "remap_selection",
            description: "Remap selectionIds across a scene mutation using a position-matching heuristic (closest-centroid within a body-bbox-relative tolerance). Returns each input mapped to zero or more new selectionIds plus a `fate` ('preserved' | 'approximate' | 'lost'). High-confidence for transforms / in-place edits; approximate for fillets / chamfers / boolean splits.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "selectionIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "toleranceMmFraction": .object([
                        "type": .string("number"),
                        "description": .string("Fraction of body bbox diagonal to use as the match tolerance. Default 0.01."),
                    ]),
                ]),
                "required": .array([.string("selectionIds")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "find_correspondences",
            description: "Map selectionIds from a source body onto a target body that's a known transform of the source (typically a mirror_or_pattern output). Returns each source id mapped to one target selectionId (or null) with confidenceMm + fate ('matched' | 'lost'). `transform` is optional: when omitted, falls back to provenance metadata recorded by mirror_or_pattern, then to bbox-translation inference. Use this for cross-body workflows; remap_selection is for the within-body case.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sourceSelectionIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                    "targetBodyId": .object(["type": .string("string")]),
                    "transform": .object([
                        "type": .string("object"),
                        "description": .string("Optional. Transform applied to source anchors before nearest-neighbour search. Exactly one of `translate` / `mirror` / `rotate` / `compound` per object. `compound.steps` is an array of nested transform objects applied in order."),
                        "properties": .object([
                            "kind": .object([
                                "type": .string("string"),
                                "enum": .array([
                                    .string("translate"), .string("mirror"),
                                    .string("rotate"),    .string("compound"),
                                ]),
                            ]),
                            "offset": .object([
                                "type": .string("array"),
                                "description": .string("translate: [dx, dy, dz]"),
                                "items": .object(["type": .string("number")]),
                            ]),
                            "planeOrigin": .object([
                                "type": .string("array"),
                                "description": .string("mirror: a point on the mirror plane"),
                                "items": .object(["type": .string("number")]),
                            ]),
                            "planeNormal": .object([
                                "type": .string("array"),
                                "description": .string("mirror: plane normal (any length, normalized internally)"),
                                "items": .object(["type": .string("number")]),
                            ]),
                            "axisOrigin": .object([
                                "type": .string("array"),
                                "description": .string("rotate: a point on the rotation axis"),
                                "items": .object(["type": .string("number")]),
                            ]),
                            "axisDirection": .object([
                                "type": .string("array"),
                                "description": .string("rotate: axis direction (any length)"),
                                "items": .object(["type": .string("number")]),
                            ]),
                            "angleDeg": .object([
                                "type": .string("number"),
                                "description": .string("rotate: angle in degrees, right-hand rule about axisDirection"),
                            ]),
                            "steps": .object([
                                "type": .string("array"),
                                "description": .string("compound: array of transform objects applied in order"),
                                "items": .object(["type": .string("object")]),
                            ]),
                        ]),
                        "required": .array([.string("kind")]),
                    ]),
                    "toleranceMmFraction": .object([
                        "type": .string("number"),
                        "description": .string("Fraction of target bbox diagonal to use as the match tolerance. Default 0.01."),
                    ]),
                ]),
                "required": .array([.string("sourceSelectionIds"), .string("targetBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "add_dimension",
            description: "Compute a linear / angular / radial dimension from selectionIds, persist to <output_dir>/annotations.json. render_preview overlays it. linear needs anchors.from + anchors.to; angular needs anchors.armA + anchors.apex + anchors.armB; radial needs anchors.circularEdge.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("linear"), .string("angular"), .string("radial")]),
                    ]),
                    "anchors": .object([
                        "type": .string("object"),
                        "additionalProperties": .object(["type": .string("string")]),
                    ]),
                    "label": .object(["type": .string("string")]),
                    "showDiameter": .object(["type": .string("boolean")]),
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("kind"), .string("anchors")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "add_scene_primitive",
            description: "Add a Trihedron / WorkPlane / Axis / PointCloud annotation to <output_dir>/annotations.json. render_preview overlays it. params shape mirrors the OCCTSwiftAIS init: trihedron {origin,axisLength}; workPlane {origin,normal,size,color}; axis {from,to,color,radius}; pointCloud {points,colors?,pointRadius}.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("trihedron"), .string("workPlane"), .string("axis"), .string("pointCloud")]),
                    ]),
                    "params": .object([
                        "type": .string("object"),
                    ]),
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("kind"), .string("params")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "remove_scene_annotation",
            description: "Remove a dimension or scene primitive from <output_dir>/annotations.json by id. Returns whether the id was found.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "id": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("id")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "show_bounding_box",
            description: "Compute a body's axis-aligned bounding box and register it as a `boundingBox` scene primitive. Returns min/max/extent/center inline so the LLM can reason about the body's footprint without a separate compute_metrics call.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "primitiveId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "diff_overlay",
            description: "Visualise a recent scene change. For each body added/removed/modified since N runs ago, register a tinted scene primitive at its bbox center (added=green, removed=red, changed=yellow). Returns the lists of affected body ids plus the registered primitive ids.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "select_by_feature",
            description: "Run AAG feature recognition (recognize_features) and register a selectionId for each detected hole / pocket. Returns selectionIds the LLM can then dimension or refer back to without re-running query_topology.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "kinds": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array([.string("pocket"), .string("hole")]),
                        ]),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "list_selections",
            description: "Return every active selectionId in the SelectionRegistry plus its anchor metadata. Cheap introspection — useful when the LLM has lost track of which picks it has made earlier in the session.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "clear_selections",
            description: "Drop every selectionId from the SelectionRegistry. Returns the count cleared.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "list_annotations",
            description: "Read the <output_dir>/annotations.json sidecar and return its dimensions + scene primitives.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "auto_dimension",
            description: "Run AAG hole detection, then add a radial dimension to each hole's circular rim edge. One call instead of N (recognize_features → select_topology → add_dimension per hole). Returns a list of dimensionIds + selectionIds the LLM can refer to later.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "showDiameter": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, dimension shows diameter instead of radius. Default false."),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "select_topology",
            description: "Pick faces / edges / vertices on a scene body matching criteria. Returns server-tracked selectionIds (sel:<bodyId>#<kind>[<idx>]) plus an anchor snapshot — the LLM can refer back via remap_selection / add_dimension.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("body"), .string("face"), .string("edge"), .string("vertex")]),
                    ]),
                    "filter": .object([
                        "type": .string("object"),
                        "description": .string("face: surfaceType, minArea, maxArea, normalDirection, normalTolerance. edge: curveType, minLength, maxLength."),
                    ]),
                    "limit": .object(["type": .string("integer"), "minimum": .int(1)]),
                ]),
                "required": .array([.string("bodyId"), .string("kind")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "ping",
            description: "Sanity-check tool — returns 'pong' so callers can verify the OCCTMCP Swift server is alive.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "remove_body",
            description: "Delete a body from the current scene by id. Removes the body's BREP file from the output directory and re-emits the manifest (triggers viewport reload).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object([
                        "type": .string("string"),
                        "description": .string("The id of the body to remove."),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "clear_scene",
            description: "Remove every body from the current scene. Optionally preserves the compare_versions history ring buffer.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "keepHistory": .object([
                        "type": .string("boolean"),
                        "description": .string("If true, keep the compare_versions history ring. Default false."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "rename_body",
            description: "Change a body's id in the scene manifest. Fails if the new id is already in use.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "newBodyId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId"), .string("newBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "set_appearance",
            description: "Update color / opacity / roughness / metallic / display name for a scene body without re-running a script. The viewport reloads automatically.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "color": .object([
                        "type": .string("array"),
                        "description": .string("RGBA or RGB array (0-1 per channel)."),
                        "items": .object(["type": .string("number")]),
                    ]),
                    "opacity": .object([
                        "type": .string("number"),
                        "description": .string("Sets color alpha (0-1). Leaves RGB unchanged."),
                    ]),
                    "roughness": .object(["type": .string("number")]),
                    "metallic": .object(["type": .string("number")]),
                    "name": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "compute_metrics",
            description: "Compute volume / surface area / center of mass / bounding box / principal axes for a scene body. Direct OCCTSwift call, no occtkit subprocess. `boundingBox` is the default Bnd_Box (control-point hull — over-reports curved B-spline geometry); request `boundingBoxOptimal` for a tight BRepBndLib::AddOptimal extent that matches the exact surface / mesh.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "metrics": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Subset to compute. Default: all except boundingBoxOptimal. Items: volume, surfaceArea, centerOfMass, boundingBox, boundingBoxOptimal, principalAxes. boundingBoxOptimal (tight AddOptimal extent) is opt-in — list it explicitly."),
                    ]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "query_topology",
            description: "Find faces / edges / vertices on a body matching criteria. Returns stable IDs (face[N], edge[N], vertex[N]).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "entity": .object([
                        "type": .string("string"),
                        "enum": .array([.string("face"), .string("edge"), .string("vertex")]),
                    ]),
                    "filter": .object([
                        "type": .string("object"),
                        "description": .string("Optional: surfaceType, curveType, minArea, maxArea."),
                    ]),
                    "limit": .object(["type": .string("integer"), "minimum": .int(1)]),
                ]),
                "required": .array([.string("bodyId"), .string("entity")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "measure_distance",
            description: "Minimum distance between two scene bodies. Pass computeContacts=true to also return up to 32 contact pairs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fromBodyId": .object(["type": .string("string")]),
                    "toBodyId": .object(["type": .string("string")]),
                    "computeContacts": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("fromBodyId"), .string("toBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "measure_deviation",
            description: "Signed, spatially-resolved surface deviation between two scene bodies — the metric for certifying a reconstruction against its source mesh. Unlike measure_distance (minimum gap, ≈0 for overlapping bodies), this samples each body's tessellated surface and reports, in BOTH directions (`fromToTo` = from's surface vs to / over-extension, `toToFrom` = under-coverage): max, rms, mean, p95 (robust worst-case), `signedMean` (≠0 ⇒ a systematic proud(+)/shy(−) bias a Hausdorff hides), signedMin/signedMax, and a worstPoint — plus `symmetricHausdorff`. Optional `sectionAxis`+`sections` bins the forward samples along an axis into per-station signedMean (a near-constant non-zero value across stations ⇒ systematic section-shape error). Mesh-based; fidelity scales with `deflection` (default 0.5% of the from-body bbox diagonal). `maxSamples` (default 20000) stride-subsamples per direction.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fromBodyId": .object(["type": .string("string")]),
                    "toBodyId": .object(["type": .string("string")]),
                    "deflection": .object([
                        "type": .string("number"),
                        "description": .string("Mesh linear deflection (model units). Smaller = finer = tighter bound. Default: 0.5% of the from-body bbox diagonal."),
                    ]),
                    "maxSamples": .object([
                        "type": .string("integer"),
                        "description": .string("Max source surface samples per direction (stride-subsampled). Default 20000."),
                    ]),
                    "sectionAxis": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(3), "maxItems": .int(3),
                        "description": .string("[x,y,z] axis to bin the forward (from→to) samples along. When set with `sections`, the report gains a per-station signedMean array."),
                    ]),
                    "sections": .object([
                        "type": .string("integer"),
                        "description": .string("Number of along-axis bins for the per-section signedMean sweep (≥2). Requires sectionAxis."),
                    ]),
                    "signMode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("robust"), .string("nearest")]),
                        "description": .string(signModeDescription),
                    ]),
                ]),
                "required": .array([.string("fromBodyId"), .string("toBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "deviation_histogram",
            description: "Signed point-to-surface deviation DISTRIBUTION of `fromBodyId` vs `referenceBodyId`: μ (mean — non-zero ⇒ systematic bias), σ, median, p95 (of |dev|), proud/shy extremes, percent within ±tolerance, and a bucket histogram — plus an optional PNG. A tight unimodal histogram on 0 is honest noise; a non-zero mean or two humps is a systematic shape error even when the headline mean looks small.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fromBodyId": .object(["type": .string("string")]),
                    "referenceBodyId": .object(["type": .string("string")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the from-body bbox diagonal.")]),
                    "bins": .object(["type": .string("integer"), "description": .string("Histogram bucket count. Default 40.")]),
                    "maxSamples": .object(["type": .string("integer"), "description": .string("Max from-surface vertices sampled (stride-subsampled). Default 50000.")]),
                    "tolerance": .object(["type": .string("number"), "description": .string("± band (model units); report fraction of samples within it + shade it on the PNG.")]),
                    "outputPath": .object(["type": .string("string"), "description": .string("PNG path for the histogram image. Omit to return stats only.")]),
                    "signMode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("robust"), .string("nearest")]),
                        "description": .string(signModeDescription),
                    ]),
                ]),
                "required": .array([.string("fromBodyId"), .string("referenceBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "cross_section_compare",
            description: "Slice BOTH bodies at N stations across their shared axis overlap, overlay the two 2D profiles, and report per-station signed-mean (the direct detector of a systematic section offset), RMS, area ratio, centroid offset, and a pose-robust radial shape scalar (catches wrong-shape a Hausdorff misses). Default `outerEnvelope` mode compares against the reference's OUTER boundary per angular direction, so inner window-return / frame paths of a thin-wall / scanned part don't pollute the aggregate. Each station reports `axisCoord` (world position along the axis). The highest-leverage tool for a reconstruction whose cross-section is the wrong shape everywhere yet whose 3D mean looks fine. Optional per-station overlay PNGs.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fromBodyId": .object(["type": .string("string"), "description": .string("Candidate body (e.g. the reconstruction).")]),
                    "referenceBodyId": .object(["type": .string("string"), "description": .string("Reference body (e.g. the source mesh).")]),
                    "axis": .object(["type": .string("array"), "items": .object(["type": .string("number")]), "minItems": .int(3), "maxItems": .int(3), "description": .string("[x,y,z] section sweep axis (e.g. the carbody longitudinal axis).")]),
                    "stations": .object(["type": .string("integer"), "description": .string("Number of evenly-spaced cut planes across the bodies' shared overlap. Default 12.")]),
                    "through": .object(["type": .string("array"), "items": .object(["type": .string("number")]), "minItems": .int(3), "maxItems": .int(3), "description": .string("A point the axis passes through. Default: from-body bbox centre.")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the from-body bbox diagonal.")]),
                    "outerEnvelope": .object(["type": .string("boolean"), "description": .string("Compare against the reference's OUTER boundary per angular direction (default true) so inner window-return / frame paths don't pollute the metric. Set false for raw point-to-main-loop comparison.")]),
                    "outputDir": .object(["type": .string("string"), "description": .string("Directory for per-station overlay PNGs. Omit to return numbers only.")]),
                    "imagePrefix": .object(["type": .string("string"), "description": .string("Filename prefix for station PNGs. Default \"section\".")]),
                ]),
                "required": .array([.string("fromBodyId"), .string("referenceBodyId"), .string("axis")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "signed_deviation_heatmap",
            description: "Render `fromBodyId`'s surface coloured by SIGNED distance to `referenceBodyId` — proud (over-build) red, on-target near-white, shy (under-build) blue — via a diverging colormap, with a colorbar legend. Shows exactly WHERE a reconstruction departs, which a scalar deviation can't. Per-triangle bands; pure-Swift offscreen render to PNG. CAVEAT: the sign is only trustworthy when `referenceBodyId` is a watertight/single-surface solid. Against an OPEN, thin-walled reference (a raw scan/STL skin where an outer and inner surface are a small gap apart) the nearest-triangle sign can flip per sample with no real positional meaning; those triangles render GREY instead of red/blue and are counted in the response's `ambiguousTriangles`/`ambiguousFraction`. A mostly-grey render means trust the magnitude (or `cross_section_compare`), not this tool's sign.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "fromBodyId": .object(["type": .string("string")]),
                    "referenceBodyId": .object(["type": .string("string")]),
                    "outputPath": .object(["type": .string("string")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the from-body bbox diagonal.")]),
                    "bands": .object(["type": .string("integer"), "description": .string("Colormap band count. Default 11.")]),
                    "clamp": .object(["type": .string("number"), "description": .string("|signed| ≥ clamp saturates to full red/blue. Default: p95 of |signed|.")]),
                    "signMode": .object([
                        "type": .string("string"),
                        "enum": .array([.string("robust"), .string("nearest")]),
                        "description": .string(signModeDescription),
                    ]),
                    "options": .object(["type": .string("object"), "description": .string("Render options — same shape as render_preview.options (camera, width, height, background).")]),
                ]),
                "required": .array([.string("fromBodyId"), .string("referenceBodyId"), .string("outputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "overlay_render",
            description: "Render the reference mesh (`meshBodyId`, semi-transparent amber) superimposed over the opaque candidate solid (`solidBodyId`, steel-grey) — see in 3D exactly where the reconstruction departs from the source mesh. Pure-Swift offscreen render to PNG.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "solidBodyId": .object(["type": .string("string"), "description": .string("Opaque body (the candidate solid).")]),
                    "meshBodyId": .object(["type": .string("string"), "description": .string("Translucent body (the reference mesh).")]),
                    "outputPath": .object(["type": .string("string")]),
                    "transparency": .object(["type": .string("number"), "description": .string("Reference-mesh opacity 0.05–0.95. Default 0.5.")]),
                    "options": .object(["type": .string("object"), "description": .string("Render options — same shape as render_preview.options.")]),
                ]),
                "required": .array([.string("solidBodyId"), .string("meshBodyId"), .string("outputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "transform_body",
            description: "Apply translate / rotate / uniform-scale to a scene body. Without outputBodyId, replaces in place; with outputBodyId, adds a new body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "translate": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(3), "maxItems": .int(3),
                    ]),
                    "rotateAxisAngle": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(4), "maxItems": .int(4),
                        "description": .string("[axisX, axisY, axisZ, radians]"),
                    ]),
                    "rotateEulerXyz": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")]),
                        "minItems": .int(3), "maxItems": .int(3),
                    ]),
                    "scale": .object(["type": .string("number")]),
                    "inPlace": .object(["type": .string("boolean")]),
                    "outputBodyId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "boolean_op",
            description: "Boolean op (union / subtract / intersect / split) between two scene bodies. Output is added as a new body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "op": .object([
                        "type": .string("string"),
                        "enum": .array([.string("union"), .string("subtract"), .string("intersect"), .string("split")]),
                    ]),
                    "aBodyId": .object(["type": .string("string")]),
                    "bBodyId": .object(["type": .string("string")]),
                    "outputBodyId": .object(["type": .string("string")]),
                    "removeInputs": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("op"), .string("aBodyId"), .string("bBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mirror_or_pattern",
            description: "Mirror / linear / circular pattern of a body. Output is a single (possibly compound) body added to the scene.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "kind": .object([
                        "type": .string("string"),
                        "enum": .array([.string("mirror"), .string("linear"), .string("circular")]),
                    ]),
                    "params": .object([
                        "type": .string("object"),
                        "description": .string("Mirror: planeNormal (required), planeOrigin (optional). Linear: direction, spacing, count. Circular: axisOrigin, axisDirection, totalCount, totalAngle (optional)."),
                    ]),
                    "outputBodyId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId"), .string("kind"), .string("params")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "generate_mesh",
            description: "Tessellate a scene body into triangles + quality metrics. Optionally inline geometry or write to .stl/.obj.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "linearDeflection": .object(["type": .string("number")]),
                    "angularDeflection": .object(["type": .string("number")]),
                    "returnGeometry": .object(["type": .string("boolean")]),
                    "outputPath": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "simplify_mesh",
            description: "QEM mesh decimation via OCCTSwiftMesh (vendored meshoptimizer). Outputs .stl or .obj.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "outputPath": .object(["type": .string("string")]),
                    "targetTriangleCount": .object(["type": .string("integer"), "minimum": .int(1)]),
                    "targetReduction": .object(["type": .string("number")]),
                    "preserveBoundary": .object(["type": .string("boolean")]),
                    "preserveTopology": .object(["type": .string("boolean")]),
                    "maxHausdorffDistance": .object(["type": .string("number")]),
                    "linearDeflection": .object(["type": .string("number")]),
                    "angularDeflection": .object(["type": .string("number")]),
                ]),
                "required": .array([.string("bodyId"), .string("outputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "heal_shape",
            description: "Heal imported / non-watertight geometry via OCCT ShapeFix. Returns before/after stats.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "outputBodyId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "read_brep",
            description: "Add a .brep from disk to the scene as a new body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "inputPath": .object(["type": .string("string")]),
                    "bodyId": .object(["type": .string("string")]),
                    "color": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("number")]),
                    ]),
                    "allowInvalid": .object([
                        "type": .string("boolean"),
                        "description": .string("Load a topologically invalid / loose-face shape as-is (skip the validity write-gate) so compute_metrics / measure_deviation / validate_geometry can run on an in-progress reconstruction. Default false."),
                    ]),
                ]),
                "required": .array([.string("inputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "import_file",
            description: "Multi-format CAD import (STEP / IGES / BREP / STL / OBJ). Mesh formats (STL / OBJ) land as a raw triangulated shell — the reference scan the deviation / cross-section tools compare against. Adds the imported shape as a single body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "inputPath": .object(["type": .string("string")]),
                    "format": .object([
                        "type": .string("string"),
                        "description": .string("Explicit format overrides extension sniffing. `auto` sniffs the extension."),
                        "enum": .array([.string("auto"), .string("step"), .string("iges"), .string("obj"), .string("brep"), .string("stl")]),
                    ]),
                    "idPrefix": .object(["type": .string("string")]),
                    "allowInvalid": .object([
                        "type": .string("boolean"),
                        "description": .string("Import a topologically invalid / loose-face shape as-is (skip the validity write-gate) so the analysis tools can measure an in-progress reconstruction. Default false."),
                    ]),
                ]),
                "required": .array([.string("inputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "export_scene",
            description: "Export the current scene (or a subset) to step / iges / brep / stl / obj / gltf / glb.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("step"), .string("iges"), .string("brep"),
                            .string("stl"), .string("obj"), .string("gltf"), .string("glb"),
                        ]),
                    ]),
                    "outputPath": .object(["type": .string("string")]),
                    "bodyIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                    ]),
                ]),
                "required": .array([.string("format"), .string("outputPath")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "compare_versions",
            description: "Diff the current scene against a snapshot from N runs ago. Detects added / removed / appearance-changed / file-changed bodies.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "since": .object([
                        "type": .string("integer"),
                        "minimum": .int(1),
                        "description": .string("How many runs back to compare against. Default 1."),
                    ]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        // ── reconstruct_* — read/write the attributed reconstruction graph (#33)
        Tool(
            name: "reconstruct_get_graph",
            description: "Export the attributed reconstruction graph as JSON: topology counts, every annotated node (with its reconstruct.* attributes), and instance clusters. Pass `sessionId` for an existing session, or `bodyId` to start one from a scene body. Nodes are addressed as `<kind>:<index>` (e.g. `face:3`).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionId": .object(["type": .string("string"), "description": .string("Existing reconstruction session id.")]),
                    "bodyId": .object(["type": .string("string"), "description": .string("Scene body to start a new session from (sessionId defaults to bodyId).")]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "reconstruct_set_decision",
            description: "Annotate a node's reconstruction decision: `decidedBy` (geometric | ml | human) and/or `accepted` (accept/reject a proposed fit). At least one must be supplied.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionId": .object(["type": .string("string")]),
                    "node": .object(["type": .string("string"), "description": .string("Target node as `<kind>:<index>`, e.g. `face:3`.")]),
                    "decidedBy": .object([
                        "type": .string("string"),
                        "enum": .array([.string("geometric"), .string("ml"), .string("human")]),
                    ]),
                    "accepted": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("sessionId"), .string("node")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "reconstruct_force_fit",
            description: "Override a node's fitted surface type (e.g. force `cylinder`). Records the override as an attribute for the OCCTReconstruct engine to honour on its next pass; it does not re-fit here.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionId": .object(["type": .string("string")]),
                    "node": .object(["type": .string("string"), "description": .string("Target node as `<kind>:<index>`.")]),
                    "surfaceType": .object(["type": .string("string"), "description": .string("Forced surface type, e.g. plane / cylinder / cone / sphere / torus.")]),
                ]),
                "required": .array([.string("sessionId"), .string("node"), .string("surfaceType")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "reconstruct_confirm_instances",
            description: "Confirm or reject a congruence cluster (\"these N nodes are one part definition\"). Tags every listed node with `clusterId` and the `confirmed` flag.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionId": .object(["type": .string("string")]),
                    "clusterId": .object(["type": .string("string")]),
                    "nodes": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Cluster member nodes as `<kind>:<index>`."),
                    ]),
                    "confirmed": .object(["type": .string("boolean"), "description": .string("Default true.")]),
                ]),
                "required": .array([.string("sessionId"), .string("clusterId"), .string("nodes")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "reconstruct_export_session",
            description: "Write the session's attributed graph snapshot to disk (byte-stable JSON). Defaults to <output_dir>/reconstruct/<sessionId>.session.json. Round-trips losslessly via reconstruct_import_session.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "sessionId": .object(["type": .string("string")]),
                    "path": .object(["type": .string("string"), "description": .string("Optional output path.")]),
                ]),
                "required": .array([.string("sessionId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "reconstruct_import_session",
            description: "Reload a graph snapshot file into a session and return its state. `sessionId` defaults to the file's stem.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "path": .object(["type": .string("string")]),
                    "sessionId": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("path")]),
                "additionalProperties": .bool(false),
            ])
        ),
        // ── mesh zone tools (#101/#102) ─────────────────────────────────
        Tool(
            name: "segment_mesh_zones",
            description: "Split a body's mesh into surface zones (plane / cylinder / sphere / cone) via OCCTSwiftMesh's dihedral region-growing + primitive-fit merge. Each zone gets a stable `zone:<bodyId>#<n>` id (largest-first) plus a fitted primitive (kind, params, residual, inlier ratio), a slippage classification (kind: plane/sphere/cylinder/extrusion/revolution/helix/freeform, plus its characteristic axisPoint/axisDirection/pitch and a confidence in [0,1] — Gelfand-Guibas local slippage analysis, OCCTSwiftMesh#26/#31), and is minted into the zone registry (<output_dir>/zones.json) so a later zone_continuity_sweep can resolve it without re-segmenting. axisDirection's SIGN is arbitrary and its MEANING is kind-dependent: the surface NORMAL for plane (never a sweep direction), the rotation/screw axis for cylinder/revolution/helix, the extrude direction for extrusion, nil for sphere (no preferred axis) and freeform. confidence is a spectral-gap diagnostic, not a probability — a near-symmetric body's true eigen-spectrum has no clean separation to begin with, so it reads as low-confidence rather than confidently wrong. Optionally renders a categorical per-zone PNG and/or registers each zone as its own scene body (facet-shell BREP) for downstream measurement tools.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "maxDihedralDegrees": .object(["type": .string("number"), "description": .string("Region-growing breaks where adjacent face normals exceed this angle. Default 20.")]),
                    "mergeToleranceMm": .object(["type": .string("number"), "description": .string("Absolute mm merge tolerance (converted internally to a fraction of the body's bbox diagonal). Default: library default (0.4% of bbox diagonal).")]),
                    "minRegionTriangles": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Regions smaller than this after growing + merging are dropped and counted in truncatedTriangleCount. Default 8.")]),
                    "maxZones": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Cap on returned zones; the largest are kept, the rest counted in truncatedTriangleCount. Default 64.")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the body's bbox diagonal.")]),
                    "registerZones": .object(["type": .string("boolean"), "description": .string("If true, register each zone (up to registerCap, largest-first) as its own scene body `<bodyId>_zone<n>` (facet-shell BREP via writeBREP(allowInvalid:)). Default false.")]),
                    "registerCap": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Max zones to register as bodies when registerZones is true. Default 32.")]),
                    "render": .object(["type": .string("boolean"), "description": .string("Render a categorical per-zone PNG with a legend. Default true.")]),
                    "renderPath": .object(["type": .string("string"), "description": .string("Override the default render path (<output_dir>/<bodyId>_zones.png).")]),
                    "options": .object(["type": .string("object"), "description": .string("Render options — same shape as render_preview.options (camera, width, height, background).")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "zone_continuity_sweep",
            description: "Per-zone (or whole-body) loftable-extent map: slices along an axis at N stations, compares each station's 2D profile against a running reference, and reports maximal within-tolerance runs (the completable/loftable extents) plus deviation intervals between them, each with world axisCoord spans and magnitudes. Pass zoneId (from segment_mesh_zones) to sweep only that zone's own triangles — slicing just the zone keeps a neighbouring feature from polluting its verdict; omit it to sweep the whole body. Axis resolution (see axisSource in the response): an explicit axis argument always wins; otherwise a zoneId-scoped sweep whose zone has a slippage classification of cylinder/extrusion/revolution/helix (never plane — its slippage axis is the surface NORMAL — and never sphere/freeform) with confidence >= 0.25 defaults to that axis (axisSource \"slippage\"); anything else, including every whole-body sweep, falls back to the zone/body's principal axis via PCA (axisSource \"pca\"), with a warning naming the rejected kind/confidence when a low-confidence slippage classification was the reason. Revolve-aware angular stationing for revolution zones is not yet implemented (#109 follow-up). Optional render (zone/body colored by nearest-station verdict: constant=blue, deviating=red, missed=grey) and per-station strip chart.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "zoneId": .object(["type": .string("string"), "description": .string("A zone:<bodyId>#<n> id from segment_mesh_zones. Omit to sweep the whole body.")]),
                    "axis": .object(["type": .string("array"), "items": .object(["type": .string("number")]), "minItems": .int(3), "maxItems": .int(3), "description": .string("[x,y,z] sweep axis. Default: the zone's own slippage axis when eligible (cylinder/extrusion/revolution/helix, confidence >= 0.25) and zoneId is given; otherwise the zone/body's principal axis via PCA over its triangle vertices. See axisSource in the response.")]),
                    "stations": .object(["type": .string("integer"), "minimum": .int(2), "description": .string("Number of evenly-spaced cut planes across the zone/body's axis extent (2% end margin). Default 32.")]),
                    "toleranceMm": .object(["type": .string("number"), "description": .string("Within-tolerance verdict threshold on profile RMS (mm). Default 0.5.")]),
                    "lateralToleranceMm": .object(["type": .string("number"), "description": .string("Within-tolerance verdict threshold on profile centroid offset (mm). Default: same as toleranceMm.")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection for a whole-body sweep. Default 0.5% of the body's bbox diagonal. Ignored (and warned) for a zoneId-scoped sweep, which always re-meshes at the zone's own segmentation deflection so triangleIndices stay valid.")]),
                    "render": .object(["type": .string("boolean"), "description": .string("Render the zone/body colored by nearest-station verdict. Default true.")]),
                    "renderPath": .object(["type": .string("string"), "description": .string("Override the default render path.")]),
                    "chart": .object(["type": .string("boolean"), "description": .string("Render a per-station profileRmsMm-vs-axisCoord strip chart PNG with the tolerance line. Default false.")]),
                    "chartPath": .object(["type": .string("string"), "description": .string("Override the default chart path.")]),
                    "options": .object(["type": .string("object"), "description": .string("Render options — same shape as render_preview.options.")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "list_zones",
            description: "Return every zone in the zone registry (<output_dir>/zones.json), optionally filtered to one body. Cheap introspection — see what segment_mesh_zones has minted without re-segmenting.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string"), "description": .string("Restrict to this body's zones. Omit to list every zone across all bodies.")]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "clear_zones",
            description: "Drop zones from the zone registry and its <output_dir>/zones.json sidecar, optionally for one body only. Returns the count cleared.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string"), "description": .string("Clear only this body's zones. Omit to clear every zone.")]),
                ]),
                "additionalProperties": .bool(false),
            ])
        ),
        // ── mesh inspection (Phase 2 of the mesh-analysis expansion) ────
        Tool(
            name: "mesh_diagnose",
            description: "Printability-check-list integrity report over a body's mesh: watertight, edge/vertex-manifold, orientable, connected components, boundary loops, Euler characteristic / genus, duplicate/degenerate triangle counts, and sliver signals (minAngleDegrees, aspectRatio). `checks[]` derives pass/warn/fail verdicts from the raw counts. IMPORTANT: self-intersection is NOT checked (an OCCTSwiftMesh limitation) — a self-intersecting closed manifold still reports isWatertight: true.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the body's bbox diagonal.")]),
                    "weldToleranceMm": .object(["type": .string("number"), "minimum": .double(0), "description": .string("Absolute mm weld tolerance used internally before computing manifoldness. Default 0 (auto: 1e-6 x the mesh's bbox diagonal).")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mesh_thickness",
            description: "Mesh-domain wall thickness via the ray method (normal-opposite, first-hit): the complement to the BREP-only check_thickness, which degrades on facet shells (a raw STL import is one BREP face per facet). Samples up to maxSamples surface points and casts a ray from each along its inward normal against an internal triangle BVH; the first hit distance is the local thickness. Rays that exit without hitting anything (open shells) are excluded from the stats and counted in noHitSamples. Optional coneAngleDegrees averages 5 rays per sample (the SDF convention: takes the median) for a more robust estimate near edges/features.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "maxSamples": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Cap on surface sample points (stride-subsampled). Default 2000.")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the body's bbox diagonal.")]),
                    "thresholdMm": .object(["type": .string("number"), "minimum": .double(0), "description": .string("If set, adds a belowThreshold section reporting samples thinner than this.")]),
                    "coneAngleDegrees": .object(["type": .string("number"), "minimum": .double(0), "maximum": .double(89), "description": .string("Half-angle of a 5-ray averaging cone (center + 4 boundary rays), median taken. 0 (default) casts a single ray.")]),
                    "chart": .object(["type": .string("boolean"), "description": .string("Render a thicknessMm histogram PNG. Default false.")]),
                    "chartPath": .object(["type": .string("string"), "description": .string("Override the default chart path (<output_dir>/<bodyId>_thickness.png).")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "detect_symmetry",
            description: "Detect reflective (mirror-plane) symmetry: 3 candidate planes through the area-weighted centroid, normal to each PCA principal axis, verified by reflecting sampled surface points across the plane and measuring their unsigned nearest distance back to the mesh's own surface. A candidate is `symmetric` when its p95 residual is within toleranceMm. Reports all 3 candidates sorted best-first, plus bestPlane when any passes. Rotational/axis symmetry detection is deferred to a later phase — this covers mirror-plane symmetry only.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "maxSamples": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Cap on surface sample points (stride-subsampled). Default 2000.")]),
                    "toleranceMm": .object(["type": .string("number"), "minimum": .double(0), "description": .string("A candidate plane is symmetric when its p95 residual is within this. Default 0.5.")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the body's bbox diagonal.")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "align_bodies",
            description: "GOM-style alignment: register a SOURCE body onto a REFERENCE body via point-to-plane ICP (PCA pre-align + normal-space sampling + trimmed correspondence, OCCTSwiftMesh#22/#25). `mode: \"bestFit\"` (default) runs the full pre-align + ICP pipeline; `mode: \"preAlign\"` stops after the coarse PCA/bbox stage (maxIterations forced to 0, ignored if supplied) — GOM's \"pre-align\" tier. localBestFit / 3-2-1 / RPS-datum alignment are deferred. Returns the recovered rigid transform (translation + axis-angle rotation) and residual stats; scan-vs-CAD deviation tools (measure_deviation, cross_section_compare, etc.) are meaningless before the two bodies are in a shared frame, which is what this tool establishes. KNOWN LIMITATIONS (see docs/reference/mesh-analysis.md#align_bodies): near-degenerate principal axes make the PCA pre-align orientation ambiguous (near-symmetric bodies may converge to a plausible wrong pose — watch `converged` and `residualRmsMm`); bodies with continuous symmetry about an axis (cylinders) have an unobservable rotation about that axis. `apply: true` writes the recovered transform onto the SOURCE body in place (same generation-reset history semantics as transform_body); omit or leave false to only measure.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string"), "description": .string("The SOURCE (moving) body — the one that gets registered onto referenceBodyId.")]),
                    "referenceBodyId": .object(["type": .string("string"), "description": .string("The REFERENCE (fixed) body bodyId is aligned onto.")]),
                    "mode": .object(["type": .string("string"), "enum": .array([.string("bestFit"), .string("preAlign")]), "description": .string("\"bestFit\" (default): full PCA pre-align + ICP refinement. \"preAlign\": PCA/bbox coarse pose only (maxIterations forced to 0).")]),
                    "maxSamples": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Cap on source correspondence-search sample points (normal-space sampled). Default 2000.")]),
                    "trimFraction": .object(["type": .string("number"), "minimum": .double(0), "description": .string("Drop the worst trimFraction of surviving correspondences by residual each iteration (trimmed ICP; robust to partial overlap). Default 0.1.")]),
                    "correspondenceDistanceCapMm": .object(["type": .string("number"), "exclusiveMinimum": .double(0), "description": .string("Absolute mm cap rejecting correspondences farther apart than this. Default: auto, 0.15x the reference body's bbox diagonal.")]),
                    "maxIterations": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Max ICP refinement iterations after pre-align. Default 50. Ignored (forced to 0) when mode is \"preAlign\".")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection for BOTH bodies. Default 0.5% of the source body's bbox diagonal.")]),
                    "apply": .object(["type": .string("boolean"), "description": .string("If true, write the recovered transform onto the source body in place (generation-reset history, same as transform_body). Default false (measure only).")]),
                ]),
                "required": .array([.string("bodyId"), .string("referenceBodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "mesh_curvature",
            description: "Per-vertex discrete curvature over a body's own mesh (Rusinkiewicz per-face tensor, OCCTSwiftMesh.Mesh.vertexCurvatures, #23/#24): principal curvatures k1 (larger magnitude, convex-positive) / k2, mean = (k1+k2)/2, gaussian = k1*k2, plus a colored render and stats. No reference body needed — Phase 3 of the mesh-analysis expansion, the single-body curvature render mode deferred from #101. UNITS: k1/k2/mean are 1/mm; gaussian is 1/mm^2 (a different unit — k1*k2). Internally welds the mesh before computing curvature (vertexCurvatures' own precondition: unwelded input degrades to zero curvature everywhere) — triangleCount/vertexCount in the response are the WELDED counts. `colorBy` picks which channel drives both the render and highCurvatureFraction; `clampPercentile` (default 0.95) clamps the diverging colormap symmetrically at that percentile of |colorBy value| (1.0 = no clamp) so a few extreme vertices (mesh edges, sharp fillets) don't wash out the map. `flatFraction` is colorBy-independent: fraction of vertices with max(|k1|,|k2|) below 0.1/bboxDiag (1/mm), an absolute model-scale flatness threshold. Warns if the internal weld demonstrably failed to merge any vertices (mesh appears unweldable), a real precondition failure distinct from a genuinely flat body reading near-zero curvature. Related upstream primitives not yet available (tracked, not implemented here): curvature-ordered segmentation seeding (OCCTSwiftMesh#29, no MCP-side tracking issue), crease-edge detection (OCCTSwiftMesh#28 / OCCTMCP#108), RANSAC primitive fitting (OCCTSwiftMesh#27 / OCCTMCP#107), slippage-based zone classification (OCCTSwiftMesh#26 / OCCTMCP#109), generalized winding number orientation (OCCTSwiftMesh#30, no MCP-side tracking issue).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the body's bbox diagonal.")]),
                    "colorBy": .object(["type": .string("string"), "enum": .array([.string("mean"), .string("gaussian"), .string("k1"), .string("maxAbs")]), "description": .string("Which channel drives the render and highCurvatureFraction. \"maxAbs\" = max(|k1|,|k2|). Default \"mean\".")]),
                    "clampPercentile": .object(["type": .string("number"), "exclusiveMinimum": .double(0), "maximum": .double(1), "description": .string("Colormap clamp: the p-th percentile of |colorBy value|. 1.0 = no clamp. Default 0.95.")]),
                    "render": .object(["type": .string("boolean"), "description": .string("Render a per-triangle colored PNG with a colorbar legend. Default true.")]),
                    "renderPath": .object(["type": .string("string"), "description": .string("Override the default render path (<output_dir>/<bodyId>_curvature.png).")]),
                    "chart": .object(["type": .string("boolean"), "description": .string("Render a histogram PNG of the colorBy channel. Default false.")]),
                    "chartPath": .object(["type": .string("string"), "description": .string("Override the default chart path (<output_dir>/<bodyId>_curvature_hist.png).")]),
                    "options": .object(["type": .string("object"), "description": .string("Render options — same shape as render_preview.options (camera, width, height, background).")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
        Tool(
            name: "detect_mesh_features",
            description: "Crease-ring feature outlines (doors, panels, window returns, recesses) on a raw scan mesh via dihedral-fold-edge detection (OCCTSwiftMesh.Mesh.creaseEdges, OCCTSwiftMesh#28), for meshes where recognize_features (BREP/AAG) cannot operate at all — a scanned/STL body has no B-rep face/edge structure to recognize features against. Meshes the body, welds it (MANDATORY precondition: on unwelded input every edge is a boundary edge and the dihedral angle is undefined, so zero creases are ever found regardless of the body's actual geometry), then chains dihedral-fold edges exceeding minAngleDegrees into closed rings (e.g. a door outline) and open paths (a crease running off an open mesh boundary), largest-first. Y/T junctions where 3+ creases meet split cleanly into separate rings/paths rather than being wandered through arbitrarily; leftover edges that couldn't be chained are counted in unchainedCreaseEdgeCount, never dropped. When segment_mesh_zones has already been run for this body (same mesh state, verified by signature), each ring reports containingZones: the zone id(s) whose triangles are incident to the ring's own vertices, majority first — omitted with a warning if the zone table is stale or the internal weld guard failed, omitted silently (no warning) if no zones are registered for this body at all. Optional render: the body surface as a neutral translucent grey mesh, plus each ring as its own categorically-colored wireframe overlay with a legend.",
            name: "fit_primitives",
            description: "RANSAC primitive report over a body's (or one zone's) mesh: Schnabel-style global-inlier extraction (OCCTSwiftMesh.Mesh.segmentedRANSAC/segmentedAutoSelect, OCCTSwiftMesh#27/#32). Distinct from segment_mesh_zones' per-region fits: RANSAC claims GLOBAL inliers, so ONE primitive can span regions the dihedral grower keeps separate (e.g. a cylinder interrupted by a boss) — the reverse-engineering question zone fits can't answer. Pass zoneId (from segment_mesh_zones) to fit only that zone's own triangles (re-meshed at the zone's own stored deflection); omit it to fit the whole body. `strategy: \"ransac\"` (default) always uses RANSAC; `strategy: \"auto\"` runs segmentedAutoSelect's dihedral-vs-RANSAC bake-off and reports which won plus both scores (strategyScores). Deterministic: repeat calls with identical arguments against an unchanged mesh/zone return byte-identical primitive tables. `uncoveredFraction` is the fraction of triangles NO primitive ever claimed, computed BEFORE any maxPrimitives cap; a maxPrimitives cap is applied afterward and reported as a SEPARATE warning naming its own triangle count, never folded into uncoveredFraction. Optional categorical per-primitive PNG render (largest-support-first coloring, same band-group + legend machinery as segment_mesh_zones).",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "bodyId": .object(["type": .string("string")]),
                    "minAngleDegrees": .object(["type": .string("number"), "exclusiveMinimum": .double(0), "maximum": .double(180), "description": .string("Dihedral fold-angle threshold in degrees; an edge whose two triangles' normals differ by at least this much is a crease. Default 30.")]),
                    "maxRings": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Cap on returned rings/paths; the largest (by length) are kept, the rest counted in a warning. Default 64.")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection. Default 0.5% of the body's bbox diagonal.")]),
                    "render": .object(["type": .string("boolean"), "description": .string("Render the body with each ring overlaid as a categorically-colored wireframe, with a legend. Default true.")]),
                    "renderPath": .object(["type": .string("string"), "description": .string("Override the default render path (<output_dir>/<bodyId>_features.png).")]),
                    "zoneId": .object(["type": .string("string"), "description": .string("A zone:<bodyId>#<n> id from segment_mesh_zones, scoping the fit to just that zone's own triangles (re-meshed at the zone's own stored deflection so triangleIndices stay valid). Omit to fit the whole body.")]),
                    "strategy": .object(["type": .string("string"), "enum": .array([.string("ransac"), .string("auto")]), "description": .string("\"ransac\" (default): Schnabel-style global-inlier RANSAC extraction only. \"auto\": runs segmentedAutoSelect's dihedral-vs-RANSAC substantial-clean-coverage bake-off and reports which strategy won (strategyScores).")]),
                    "inlierEpsilonMm": .object(["type": .string("number"), "exclusiveMinimum": .double(0), "description": .string("Absolute mm point-to-primitive distance for a triangle to count as an inlier of a candidate. Default: library auto (0.5% of the fitted mesh's bbox diagonal).")]),
                    "minSupportTriangles": .object(["type": .string("integer"), "minimum": .int(1), "description": .string("Minimum inlier-cluster triangle count for a candidate primitive to be accepted; smaller clusters are left unclaimed. Default: library default (30). For strategy \"auto\", also sets the dihedral bake-off candidate's minRegionTriangles, so both strategies are compared on a consistent floor.")]),
                    "maxPrimitives": .object(["type": .string("integer"), "minimum": .int(0), "description": .string("Cap on returned primitives (largest-support-first kept). Triangles in the dropped primitives are named in a warning with their own count, kept separate from uncoveredFraction (which reflects only triangles no primitive ever claimed, at any cap).")]),
                    "deflection": .object(["type": .string("number"), "description": .string("Mesh linear deflection for a whole-body fit. Default 0.5% of the body's bbox diagonal. Ignored (and warned) for a zoneId-scoped fit, which always re-meshes at the zone's own segmentation deflection.")]),
                    "render": .object(["type": .string("boolean"), "description": .string("Render a categorical per-primitive PNG with a legend. Default true.")]),
                    "renderPath": .object(["type": .string("string"), "description": .string("Override the default render path (<output_dir>/<bodyId>_primitives.png).")]),
                    "options": .object(["type": .string("object"), "description": .string("Render options — same shape as render_preview.options (camera, width, height, background).")]),
                ]),
                "required": .array([.string("bodyId")]),
                "additionalProperties": .bool(false),
            ])
        ),
    ]
}

struct ToolCatalog: Encodable {
    let tools: [Tool]
    let count: Int
}

/// Recursively convert an MCP `Value` (the dynamic JSON wrapper) into an
/// `[String: AnyCodable]` so it can land in `PrimitiveAnnotation.params`.
func paramsToAnyCodable(_ value: Value?) -> [String: AnyCodable] {
    guard case .object(let obj)? = value else { return [:] }
    return obj.mapValues(toAnyCodable)
}
func toAnyCodable(_ value: Value) -> AnyCodable {
    switch value {
    case .bool(let v):    return .bool(v)
    case .int(let v):     return .number(Double(v))
    case .double(let v):  return .number(v)
    case .string(let v):  return .string(v)
    case .array(let arr): return .array(arr.map(toAnyCodable))
    case .object(let o):  return .object(o.mapValues(toAnyCodable))
    case .null:           return .null
    case .data:           return .null  // base64 blobs not used by annotations params
    @unknown default:     return .null
    }
}

/// `.robust` unless the caller explicitly asks for `"nearest"` — an unparseable
/// or absent value gets the mode that can't invert a sign silently (#72).
func parseSignMode(_ value: Value?) -> DeviationTools.SignMode {
    guard let raw = value?.stringValue, let mode = DeviationTools.SignMode(rawValue: raw) else {
        return .robust
    }
    return mode
}

func parseRenderOptions(_ value: Value?) -> RenderPreviewTool.Options {
    var opts = RenderPreviewTool.Options()
    guard case .object(let o)? = value else { return opts }
    if let s = o["camera"]?.stringValue, let p = RenderPreviewTool.CameraPreset(rawValue: s) {
        opts.camera = p
    }
    func vec3(_ key: String) -> SIMD3<Float>? {
        guard let arr = o[key]?.arrayValue, arr.count == 3,
              let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue else { return nil }
        return SIMD3(Float(x), Float(y), Float(z))
    }
    opts.cameraPosition = vec3("cameraPosition")
    opts.cameraTarget = vec3("cameraTarget")
    opts.cameraUp = vec3("cameraUp")
    if let n = o["width"]?.intValue { opts.width = n }
    if let n = o["height"]?.intValue { opts.height = n }
    if let s = o["displayMode"]?.stringValue, let m = DisplayMode(rawValue: s) {
        opts.displayMode = m
    }
    if let s = o["background"]?.stringValue {
        switch s {
        case "light":        opts.background = .light
        case "dark":         opts.background = .dark
        case "transparent":  opts.background = .transparent
        default:             opts.background = .hex(s)
        }
    }
    if let b = o["renderAnnotations"]?.boolValue {
        opts.renderAnnotations = b
    }
    return opts
}

func dispatch(callName: String, arguments: [String: Value]) async -> CallTool.Result {
    switch callName {
    case "ping":
        return ToolText("pong").asCallToolResult()

    case "show_bounding_box":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("show_bounding_box requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await GapFillerTools.showBoundingBox(
            bodyId: bodyId,
            primitiveId: arguments["primitiveId"]?.stringValue
        ).asCallToolResult()

    case "diff_overlay":
        let since = arguments["since"]?.intValue ?? 1
        return await GapFillerTools.diffOverlay(since: since).asCallToolResult()

    case "select_by_feature":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("select_by_feature requires `bodyId`.", isError: true).asCallToolResult()
        }
        let kinds = arguments["kinds"]?.arrayValue?.compactMap { $0.stringValue }
        return await GapFillerTools.selectByFeature(bodyId: bodyId, kinds: kinds).asCallToolResult()

    case "add_dimension":
        guard let kindStr = arguments["kind"]?.stringValue,
              let kind = AnnotationsTools.DimensionKind(rawValue: kindStr) else {
            return ToolText("add_dimension requires `kind`.", isError: true).asCallToolResult()
        }
        var anchors: [String: String] = [:]
        if case .object(let a)? = arguments["anchors"] {
            for (k, v) in a {
                if let s = v.stringValue { anchors[k] = s }
            }
        }
        return await AnnotationsTools.addDimension(
            kind: kind,
            anchors: anchors,
            label: arguments["label"]?.stringValue,
            showDiameter: arguments["showDiameter"]?.boolValue ?? false,
            id: arguments["id"]?.stringValue
        ).asCallToolResult()

    case "add_scene_primitive":
        guard let kindStr = arguments["kind"]?.stringValue,
              let kind = AnnotationsTools.PrimitiveKind(rawValue: kindStr) else {
            return ToolText("add_scene_primitive requires `kind`.", isError: true).asCallToolResult()
        }
        let params = paramsToAnyCodable(arguments["params"])
        return await AnnotationsTools.addScenePrimitive(
            kind: kind, params: params,
            id: arguments["id"]?.stringValue
        ).asCallToolResult()

    case "remove_scene_annotation":
        guard let id = arguments["id"]?.stringValue else {
            return ToolText("remove_scene_annotation requires `id`.", isError: true).asCallToolResult()
        }
        return await AnnotationsTools.removeSceneAnnotation(id: id).asCallToolResult()

    case "remap_selection":
        guard let ids = arguments["selectionIds"]?.arrayValue?.compactMap({ $0.stringValue }), !ids.isEmpty else {
            return ToolText("remap_selection requires `selectionIds` array.", isError: true).asCallToolResult()
        }
        let tol = arguments["toleranceMmFraction"]?.numberValue ?? 0.01
        return await RemapTools.remapSelection(
            selectionIds: ids, toleranceMmFraction: tol
        ).asCallToolResult()

    case "find_correspondences":
        guard let ids = arguments["sourceSelectionIds"]?.arrayValue?.compactMap({ $0.stringValue }), !ids.isEmpty else {
            return ToolText("find_correspondences requires `sourceSelectionIds` array.", isError: true).asCallToolResult()
        }
        guard let targetId = arguments["targetBodyId"]?.stringValue else {
            return ToolText("find_correspondences requires `targetBodyId`.", isError: true).asCallToolResult()
        }
        // transform is now optional — find_correspondences falls back
        // to provenance metadata (mirror_or_pattern emits this) and
        // then bbox-translation inference when omitted.
        var transform: CorrespondenceTools.TransformHint?
        if let transformValue = arguments["transform"] {
            do {
                let data = try JSONEncoder().encode(transformValue)
                transform = try JSONDecoder().decode(CorrespondenceTools.TransformHint.self, from: data)
            } catch {
                return ToolText(
                    "transform parse failed: \(error.localizedDescription)",
                    isError: true
                ).asCallToolResult()
            }
        }
        let tol = arguments["toleranceMmFraction"]?.numberValue ?? 0.01
        return await CorrespondenceTools.findCorrespondences(
            sourceSelectionIds: ids,
            targetBodyId: targetId,
            transform: transform,
            toleranceMmFraction: tol
        ).asCallToolResult()

    case "list_selections":
        return await RegistryIntrospectionTools.listSelections().asCallToolResult()

    case "clear_selections":
        return await RegistryIntrospectionTools.clearSelections().asCallToolResult()

    case "list_annotations":
        return await RegistryIntrospectionTools.listAnnotations().asCallToolResult()

    case "auto_dimension":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("auto_dimension requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await AutoDimensionTool.autoDimension(
            bodyId: bodyId,
            showDiameter: arguments["showDiameter"]?.boolValue ?? false
        ).asCallToolResult()

    case "select_topology":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let kind = arguments["kind"]?.stringValue else {
            return ToolText("select_topology requires `bodyId` and `kind`.", isError: true).asCallToolResult()
        }
        var filter = SelectionTools.Filter()
        if case .object(let f)? = arguments["filter"] {
            filter.surfaceType = f["surfaceType"]?.stringValue
            filter.curveType = f["curveType"]?.stringValue
            filter.minArea = f["minArea"]?.doubleValue
            filter.maxArea = f["maxArea"]?.doubleValue
            filter.minLength = f["minLength"]?.doubleValue
            filter.maxLength = f["maxLength"]?.doubleValue
            if let arr = f["normalDirection"]?.arrayValue, arr.count == 3,
               let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
                filter.normalDirection = SIMD3(x, y, z)
            }
            filter.normalTolerance = f["normalTolerance"]?.doubleValue
        }
        let limit = arguments["limit"]?.intValue
        return await SelectionTools.selectTopology(
            bodyId: bodyId, kind: kind, filter: filter, limit: limit
        ).asCallToolResult()

    case "set_assembly_metadata":
        guard let inputPath = arguments["inputPath"]?.stringValue,
              let outputPath = arguments["outputPath"]?.stringValue else {
            return ToolText("set_assembly_metadata requires `inputPath` and `outputPath`.", isError: true).asCallToolResult()
        }
        let scope: AssemblyTools.MetadataScope = (arguments["scope"]?.stringValue)
            .flatMap(AssemblyTools.MetadataScope.init(rawValue:)) ?? .document
        let componentId: Int64? = arguments["componentId"]?.intValue.map(Int64.init)
        var meta = AssemblyTools.AssemblyMetadata()
        if case .object(let m)? = arguments["metadata"] {
            meta.title = m["title"]?.stringValue
            meta.drawnBy = m["drawnBy"]?.stringValue
            meta.material = m["material"]?.stringValue
            meta.weight = m["weight"]?.doubleValue
            meta.revision = m["revision"]?.stringValue
            meta.partNumber = m["partNumber"]?.stringValue
            if case .object(let attrs)? = m["customAttrs"] {
                for (k, v) in attrs {
                    if let s = v.stringValue { meta.customAttrs[k] = s }
                }
            }
        }
        return await AssemblyTools.setAssemblyMetadata(
            inputPath: inputPath,
            outputPath: outputPath,
            scope: scope,
            componentId: componentId,
            metadata: meta
        ).asCallToolResult()

    case "check_thickness":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("check_thickness requires `bodyId`.", isError: true).asCallToolResult()
        }
        let density: EngineeringTools.SamplingDensity =
            (arguments["samplingDensity"]?.stringValue)
                .flatMap(EngineeringTools.SamplingDensity.init(rawValue:)) ?? .medium
        return await EngineeringTools.checkThickness(
            bodyId: bodyId,
            minAcceptable: arguments["minAcceptable"]?.doubleValue,
            samplingDensity: density
        ).asCallToolResult()

    case "render_preview":
        guard let outputPath = arguments["outputPath"]?.stringValue else {
            return ToolText("render_preview requires `outputPath`.", isError: true).asCallToolResult()
        }
        let ids = arguments["bodyIds"]?.arrayValue?.compactMap { $0.stringValue }
        let opts = parseRenderOptions(arguments["options"])
        return await RenderPreviewTool.render(
            outputPath: outputPath, bodyIds: ids, options: opts
        ).asCallToolResult()

    case "pick_surface_point":
        // numberValue (not doubleValue): an integer pixel like 200 round-trips
        // through JSON to Value.int, and doubleValue returns nil for .int.
        guard let sx = arguments["screenX"]?.numberValue,
              let sy = arguments["screenY"]?.numberValue else {
            return ToolText("pick_surface_point requires `screenX` and `screenY`.", isError: true).asCallToolResult()
        }
        return await RayPickTool.pickSurfacePoint(
            screenX: sx,
            screenY: sy,
            options: parseRenderOptions(arguments["options"]),
            id: arguments["id"]?.stringValue
        ).asCallToolResult()

    case "execute_script":
        guard let code = arguments["code"]?.stringValue else {
            return ToolText("execute_script requires `code`.", isError: true).asCallToolResult()
        }
        return await ExecuteScriptTool.execute(
            code: code,
            description: arguments["description"]?.stringValue
        ).asCallToolResult()

    case "apply_feature":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let feature = arguments["feature"] else {
            return ToolText("apply_feature requires `bodyId` and `feature`.", isError: true).asCallToolResult()
        }
        return await FeatureTools.applyFeature(
            bodyId: bodyId,
            feature: feature,
            outputBodyId: arguments["outputBodyId"]?.stringValue
        ).asCallToolResult()

    case "inspect_assembly":
        return await AssemblyTools.inspectAssembly(
            bodyId: arguments["bodyId"]?.stringValue,
            inputPath: arguments["inputPath"]?.stringValue,
            depth: arguments["depth"]?.intValue
        ).asCallToolResult()

    case "generate_drawing":
        guard let outputPath = arguments["outputPath"]?.stringValue,
              let spec = arguments["spec"] else {
            return ToolText("generate_drawing requires `outputPath` and `spec`.", isError: true).asCallToolResult()
        }
        // Accept either a single `bodyId` or a `bodyIds` array (general-arrangement).
        let ids = arguments["bodyIds"]?.arrayValue?.compactMap { $0.stringValue }
            ?? arguments["bodyId"]?.stringValue.map { [$0] }
        guard let bodyIds = ids, !bodyIds.isEmpty else {
            return ToolText("generate_drawing requires `bodyId` or a non-empty `bodyIds`.", isError: true).asCallToolResult()
        }
        return await DrawingTools.generateDrawing(
            bodyIds: bodyIds, outputPath: outputPath, spec: spec
        ).asCallToolResult()

    case "get_api_reference":
        let category = arguments["category"]?.stringValue ?? "mcp_tools"
        if category == "mcp_tools" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let payload = ToolCatalog(tools: catalogTools(), count: catalogTools().count)
            if let data = try? encoder.encode(payload),
               let str = String(data: data, encoding: .utf8) {
                return ToolText(str).asCallToolResult()
            }
            return ToolText("Failed to encode tool catalog.", isError: true).asCallToolResult()
        }
        return ToolText(
            "OCCTSwift API documentation lives at https://github.com/gsdali/OCCTSwift — browse the public func declarations there. " +
                "Pass category=\"mcp_tools\" to get this server's live tool catalog as JSON."
        ).asCallToolResult()

    case "get_scene":
        return await CoreTools.getScene().asCallToolResult()

    case "get_script":
        return await CoreTools.getScript().asCallToolResult()

    case "export_model":
        return await CoreTools.exportModel().asCallToolResult()

    case "validate_geometry":
        return await AnalysisTools.validateGeometry(
            bodyId: arguments["bodyId"]?.stringValue
        ).asCallToolResult()

    case "recognize_features":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("recognize_features requires `bodyId`.", isError: true).asCallToolResult()
        }
        let kinds = arguments["kinds"]?.arrayValue?.compactMap { $0.stringValue }
        return await AnalysisTools.recognizeFeatures(bodyId: bodyId, kinds: kinds).asCallToolResult()

    case "analyze_clearance":
        guard let ids = arguments["bodyIds"]?.arrayValue?.compactMap({ $0.stringValue }), !ids.isEmpty else {
            return ToolText("analyze_clearance requires `bodyIds` array.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.analyzeClearance(
            bodyIds: ids,
            computeContacts: arguments["computeContacts"]?.boolValue ?? true
        ).asCallToolResult()

    case "graph_validate":
        guard let path = arguments["brep_path"]?.stringValue else {
            return ToolText("graph_validate requires `brep_path`.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.graphValidate(brepPath: path).asCallToolResult()

    case "graph_compact":
        guard let inP = arguments["brep_path"]?.stringValue,
              let outP = arguments["output_path"]?.stringValue else {
            return ToolText("graph_compact requires `brep_path` and `output_path`.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.graphCompact(brepPath: inP, outputPath: outP).asCallToolResult()

    case "graph_dedup":
        guard let inP = arguments["brep_path"]?.stringValue,
              let outP = arguments["output_path"]?.stringValue else {
            return ToolText("graph_dedup requires `brep_path` and `output_path`.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.graphDedup(brepPath: inP, outputPath: outP).asCallToolResult()

    case "feature_recognize":
        guard let path = arguments["brep_path"]?.stringValue else {
            return ToolText("feature_recognize requires `brep_path`.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.featureRecognize(brepPath: path).asCallToolResult()

    case "graph_select":
        guard let path = arguments["brep_path"]?.stringValue,
              let query = arguments["query"]?.stringValue else {
            return ToolText("graph_select requires `brep_path` and `query`.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.graphSelect(
            brepPath: path,
            query: query,
            face: arguments["face"]?.intValue,
            edge: arguments["edge"]?.intValue,
            vertex: arguments["vertex"]?.intValue,
            edgeClass: arguments["class"]?.stringValue
        ).asCallToolResult()

    case "graph_ml":
        guard let path = arguments["brep_path"]?.stringValue else {
            return ToolText("graph_ml requires `brep_path`.", isError: true).asCallToolResult()
        }
        return await AnalysisTools.graphML(
            brepPath: path,
            description: arguments["description"]?.stringValue
        ).asCallToolResult()

    case "remove_body":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("remove_body requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await SceneTools.removeBody(bodyId: bodyId).asCallToolResult()

    case "clear_scene":
        let keepHistory = arguments["keepHistory"]?.boolValue ?? false
        return await SceneTools.clearScene(keepHistory: keepHistory).asCallToolResult()

    case "rename_body":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let newBodyId = arguments["newBodyId"]?.stringValue else {
            return ToolText("rename_body requires `bodyId` and `newBodyId`.", isError: true).asCallToolResult()
        }
        return await SceneTools.renameBody(bodyId: bodyId, newBodyId: newBodyId).asCallToolResult()

    case "set_appearance":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("set_appearance requires `bodyId`.", isError: true).asCallToolResult()
        }
        let update = SceneTools.AppearanceUpdate(
            color: arguments["color"]?.arrayValue?.compactMap { $0.doubleValue.flatMap { Float($0) } },
            opacity: arguments["opacity"]?.doubleValue.flatMap { Float($0) },
            roughness: arguments["roughness"]?.doubleValue.flatMap { Float($0) },
            metallic: arguments["metallic"]?.doubleValue.flatMap { Float($0) },
            name: arguments["name"]?.stringValue
        )
        return await SceneTools.setAppearance(bodyId: bodyId, update: update).asCallToolResult()

    case "compute_metrics":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("compute_metrics requires `bodyId`.", isError: true).asCallToolResult()
        }
        let metricsArr = arguments["metrics"]?.arrayValue?.compactMap { $0.stringValue }
        let metrics: Set<String>? = metricsArr.flatMap { $0.isEmpty ? nil : Set($0) }
        return await IntrospectionTools.computeMetrics(bodyId: bodyId, metrics: metrics).asCallToolResult()

    case "query_topology":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let entity = arguments["entity"]?.stringValue else {
            return ToolText("query_topology requires `bodyId` and `entity`.", isError: true).asCallToolResult()
        }
        var filter = IntrospectionTools.TopologyFilter()
        if case .object(let f)? = arguments["filter"] {
            filter.surfaceType = f["surfaceType"]?.stringValue
            filter.curveType = f["curveType"]?.stringValue
            filter.minArea = f["minArea"]?.doubleValue
            filter.maxArea = f["maxArea"]?.doubleValue
        }
        let limit = arguments["limit"]?.intValue
        return await IntrospectionTools.queryTopology(
            bodyId: bodyId, entity: entity, filter: filter, limit: limit
        ).asCallToolResult()

    case "measure_distance":
        guard let fromId = arguments["fromBodyId"]?.stringValue,
              let toId = arguments["toBodyId"]?.stringValue else {
            return ToolText("measure_distance requires `fromBodyId` and `toBodyId`.", isError: true).asCallToolResult()
        }
        let computeContacts = arguments["computeContacts"]?.boolValue ?? false
        return await IntrospectionTools.measureDistance(
            fromBodyId: fromId, toBodyId: toId, computeContacts: computeContacts
        ).asCallToolResult()

    case "measure_deviation":
        guard let fromId = arguments["fromBodyId"]?.stringValue,
              let toId = arguments["toBodyId"]?.stringValue else {
            return ToolText("measure_deviation requires `fromBodyId` and `toBodyId`.", isError: true).asCallToolResult()
        }
        let deflection = arguments["deflection"]?.numberValue
        let maxSamples = arguments["maxSamples"]?.intValue ?? 20_000
        var sectionAxis: SIMD3<Double>? = nil
        if let arr = arguments["sectionAxis"]?.arrayValue, arr.count == 3,
           let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
            sectionAxis = SIMD3(x, y, z)
        }
        let sectionCount = arguments["sections"]?.intValue ?? 0
        return await DeviationTools.measureDeviation(
            fromBodyId: fromId, toBodyId: toId, deflection: deflection, maxSamples: maxSamples,
            sectionAxis: sectionAxis, sectionCount: sectionCount,
            signMode: parseSignMode(arguments["signMode"])
        ).asCallToolResult()

    case "deviation_histogram":
        guard let fromId = arguments["fromBodyId"]?.stringValue,
              let refId = arguments["referenceBodyId"]?.stringValue else {
            return ToolText("deviation_histogram requires `fromBodyId` and `referenceBodyId`.", isError: true).asCallToolResult()
        }
        return await DeviationHistogramTool.deviationHistogram(
            fromBodyId: fromId,
            referenceBodyId: refId,
            deflection: arguments["deflection"]?.numberValue,
            bins: arguments["bins"]?.intValue ?? 40,
            maxSamples: arguments["maxSamples"]?.intValue ?? 50_000,
            tolerance: arguments["tolerance"]?.numberValue,
            signMode: parseSignMode(arguments["signMode"]),
            outputPath: arguments["outputPath"]?.stringValue
        ).asCallToolResult()

    case "cross_section_compare":
        guard let fromId = arguments["fromBodyId"]?.stringValue,
              let refId = arguments["referenceBodyId"]?.stringValue,
              let axisArr = arguments["axis"]?.arrayValue, axisArr.count == 3,
              let ax = axisArr[0].numberValue, let ay = axisArr[1].numberValue, let az = axisArr[2].numberValue else {
            return ToolText("cross_section_compare requires `fromBodyId`, `referenceBodyId`, and `axis` [x,y,z].", isError: true).asCallToolResult()
        }
        var through: SIMD3<Double>? = nil
        if let t = arguments["through"]?.arrayValue, t.count == 3,
           let tx = t[0].numberValue, let ty = t[1].numberValue, let tz = t[2].numberValue {
            through = SIMD3(tx, ty, tz)
        }
        return await CrossSectionCompareTool.crossSectionCompare(
            fromBodyId: fromId,
            referenceBodyId: refId,
            axis: SIMD3(ax, ay, az),
            stations: arguments["stations"]?.intValue ?? 12,
            through: through,
            deflection: arguments["deflection"]?.numberValue,
            outerEnvelope: arguments["outerEnvelope"]?.boolValue ?? true,
            outputDir: arguments["outputDir"]?.stringValue,
            imagePrefix: arguments["imagePrefix"]?.stringValue ?? "section"
        ).asCallToolResult()

    case "signed_deviation_heatmap":
        guard let fromId = arguments["fromBodyId"]?.stringValue,
              let refId = arguments["referenceBodyId"]?.stringValue,
              let outputPath = arguments["outputPath"]?.stringValue else {
            return ToolText("signed_deviation_heatmap requires `fromBodyId`, `referenceBodyId`, and `outputPath`.", isError: true).asCallToolResult()
        }
        return await HeatmapTools.signedDeviationHeatmap(
            fromBodyId: fromId,
            referenceBodyId: refId,
            outputPath: outputPath,
            deflection: arguments["deflection"]?.numberValue,
            bands: arguments["bands"]?.intValue ?? 11,
            clamp: arguments["clamp"]?.numberValue,
            signMode: parseSignMode(arguments["signMode"]),
            options: parseRenderOptions(arguments["options"])
        ).asCallToolResult()

    case "overlay_render":
        guard let solidId = arguments["solidBodyId"]?.stringValue,
              let meshId = arguments["meshBodyId"]?.stringValue,
              let outputPath = arguments["outputPath"]?.stringValue else {
            return ToolText("overlay_render requires `solidBodyId`, `meshBodyId`, and `outputPath`.", isError: true).asCallToolResult()
        }
        return await HeatmapTools.overlayRender(
            solidBodyId: solidId,
            meshBodyId: meshId,
            outputPath: outputPath,
            transparency: arguments["transparency"]?.numberValue ?? 0.5,
            options: parseRenderOptions(arguments["options"])
        ).asCallToolResult()

    case "transform_body":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("transform_body requires `bodyId`.", isError: true).asCallToolResult()
        }
        var opts = ConstructionTools.TransformOptions()
        if let arr = arguments["translate"]?.arrayValue, arr.count == 3,
           let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
            opts.translate = SIMD3(x, y, z)
        }
        if let arr = arguments["rotateAxisAngle"]?.arrayValue, arr.count == 4,
           let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue,
           let r = arr[3].doubleValue {
            opts.rotateAxisAngle = (SIMD3(x, y, z), r)
        }
        if let arr = arguments["rotateEulerXyz"]?.arrayValue, arr.count == 3,
           let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
            opts.rotateEulerXyz = SIMD3(x, y, z)
        }
        opts.scale = arguments["scale"]?.doubleValue
        opts.inPlace = arguments["inPlace"]?.boolValue
        opts.outputBodyId = arguments["outputBodyId"]?.stringValue
        return await ConstructionTools.transformBody(bodyId: bodyId, options: opts).asCallToolResult()

    case "boolean_op":
        guard let opStr = arguments["op"]?.stringValue,
              let op = ConstructionTools.BooleanOp(rawValue: opStr),
              let a = arguments["aBodyId"]?.stringValue,
              let b = arguments["bBodyId"]?.stringValue else {
            return ToolText("boolean_op requires `op`, `aBodyId`, `bBodyId`.", isError: true).asCallToolResult()
        }
        return await ConstructionTools.booleanOp(
            op: op,
            aBodyId: a, bBodyId: b,
            outputBodyId: arguments["outputBodyId"]?.stringValue,
            removeInputs: arguments["removeInputs"]?.boolValue ?? false
        ).asCallToolResult()

    case "mirror_or_pattern":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let kindStr = arguments["kind"]?.stringValue,
              let kind = ConstructionTools.PatternKind(rawValue: kindStr) else {
            return ToolText("mirror_or_pattern requires `bodyId` and `kind`.", isError: true).asCallToolResult()
        }
        var p = ConstructionTools.PatternParams()
        if case .object(let f)? = arguments["params"] {
            if let arr = f["planeOrigin"]?.arrayValue, arr.count == 3,
               let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
                p.planeOrigin = SIMD3(x, y, z)
            }
            if let arr = f["planeNormal"]?.arrayValue, arr.count == 3,
               let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
                p.planeNormal = SIMD3(x, y, z)
            }
            if let arr = f["direction"]?.arrayValue, arr.count == 3,
               let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
                p.direction = SIMD3(x, y, z)
            }
            p.spacing = f["spacing"]?.numberValue
            p.count = f["count"]?.intValue
            if let arr = f["axisOrigin"]?.arrayValue, arr.count == 3,
               let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
                p.axisOrigin = SIMD3(x, y, z)
            }
            if let arr = f["axisDirection"]?.arrayValue, arr.count == 3,
               let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
                p.axisDirection = SIMD3(x, y, z)
            }
            p.totalCount = f["totalCount"]?.intValue
            p.totalAngle = f["totalAngle"]?.doubleValue
        }
        return await ConstructionTools.mirrorOrPattern(
            bodyId: bodyId, kind: kind, params: p,
            outputBodyId: arguments["outputBodyId"]?.stringValue
        ).asCallToolResult()

    case "generate_mesh":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("generate_mesh requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await MeshTools.generateMesh(
            bodyId: bodyId,
            linearDeflection: arguments["linearDeflection"]?.doubleValue ?? 0.1,
            angularDeflection: arguments["angularDeflection"]?.doubleValue ?? 0.5,
            returnGeometry: arguments["returnGeometry"]?.boolValue ?? false,
            outputPath: arguments["outputPath"]?.stringValue
        ).asCallToolResult()

    case "simplify_mesh":
        guard let bodyId = arguments["bodyId"]?.stringValue,
              let outputPath = arguments["outputPath"]?.stringValue else {
            return ToolText("simplify_mesh requires `bodyId` and `outputPath`.", isError: true).asCallToolResult()
        }
        return await MeshTools.simplifyMesh(
            bodyId: bodyId, outputPath: outputPath,
            targetTriangleCount: arguments["targetTriangleCount"]?.intValue,
            targetReduction: arguments["targetReduction"]?.doubleValue,
            preserveBoundary: arguments["preserveBoundary"]?.boolValue ?? true,
            preserveTopology: arguments["preserveTopology"]?.boolValue ?? true,
            maxHausdorffDistance: arguments["maxHausdorffDistance"]?.doubleValue,
            linearDeflection: arguments["linearDeflection"]?.doubleValue ?? 0.1,
            angularDeflection: arguments["angularDeflection"]?.doubleValue ?? 0.5
        ).asCallToolResult()

    case "heal_shape":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("heal_shape requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await HealingTools.healShape(
            bodyId: bodyId,
            outputBodyId: arguments["outputBodyId"]?.stringValue
        ).asCallToolResult()

    case "read_brep":
        guard let inputPath = arguments["inputPath"]?.stringValue else {
            return ToolText("read_brep requires `inputPath`.", isError: true).asCallToolResult()
        }
        let color = arguments["color"]?.arrayValue?.compactMap { $0.doubleValue.flatMap { Float($0) } }
        return await IOTools.readBrep(
            inputPath: inputPath,
            bodyId: arguments["bodyId"]?.stringValue,
            color: color,
            allowInvalid: arguments["allowInvalid"]?.boolValue ?? false
        ).asCallToolResult()

    case "import_file":
        guard let inputPath = arguments["inputPath"]?.stringValue else {
            return ToolText("import_file requires `inputPath`.", isError: true).asCallToolResult()
        }
        let format = (arguments["format"]?.stringValue).flatMap(IOTools.ImportFormat.init(rawValue:)) ?? .auto
        return await IOTools.importFile(
            inputPath: inputPath,
            format: format,
            idPrefix: arguments["idPrefix"]?.stringValue ?? "imported",
            allowInvalid: arguments["allowInvalid"]?.boolValue ?? false
        ).asCallToolResult()

    case "export_scene":
        guard let formatStr = arguments["format"]?.stringValue,
              let format = IOTools.ExportFormat(rawValue: formatStr),
              let outputPath = arguments["outputPath"]?.stringValue else {
            return ToolText("export_scene requires `format` and `outputPath`.", isError: true).asCallToolResult()
        }
        let ids = arguments["bodyIds"]?.arrayValue?.compactMap { $0.stringValue }
        return await IOTools.exportScene(format: format, outputPath: outputPath, bodyIds: ids).asCallToolResult()

    case "compare_versions":
        let since = arguments["since"]?.intValue ?? 1
        return await SceneTools.compareVersions(since: since).asCallToolResult()

    case "reconstruct_get_graph":
        return await ReconstructTools.getGraph(
            sessionId: arguments["sessionId"]?.stringValue,
            bodyId: arguments["bodyId"]?.stringValue
        ).asCallToolResult()

    case "reconstruct_set_decision":
        guard let sessionId = arguments["sessionId"]?.stringValue,
              let node = arguments["node"]?.stringValue else {
            return ToolText("reconstruct_set_decision requires `sessionId` and `node`.", isError: true).asCallToolResult()
        }
        return await ReconstructTools.setDecision(
            sessionId: sessionId,
            node: node,
            decidedBy: arguments["decidedBy"]?.stringValue,
            accepted: arguments["accepted"]?.boolValue
        ).asCallToolResult()

    case "reconstruct_force_fit":
        guard let sessionId = arguments["sessionId"]?.stringValue,
              let node = arguments["node"]?.stringValue,
              let surfaceType = arguments["surfaceType"]?.stringValue else {
            return ToolText("reconstruct_force_fit requires `sessionId`, `node`, and `surfaceType`.", isError: true).asCallToolResult()
        }
        return await ReconstructTools.forceFit(
            sessionId: sessionId, node: node, surfaceType: surfaceType
        ).asCallToolResult()

    case "reconstruct_confirm_instances":
        guard let sessionId = arguments["sessionId"]?.stringValue,
              let clusterId = arguments["clusterId"]?.stringValue,
              let nodes = arguments["nodes"]?.arrayValue?.compactMap({ $0.stringValue }), !nodes.isEmpty else {
            return ToolText("reconstruct_confirm_instances requires `sessionId`, `clusterId`, and a non-empty `nodes` array.", isError: true).asCallToolResult()
        }
        return await ReconstructTools.confirmInstances(
            sessionId: sessionId,
            clusterId: clusterId,
            nodes: nodes,
            confirmed: arguments["confirmed"]?.boolValue ?? true
        ).asCallToolResult()

    case "reconstruct_export_session":
        guard let sessionId = arguments["sessionId"]?.stringValue else {
            return ToolText("reconstruct_export_session requires `sessionId`.", isError: true).asCallToolResult()
        }
        return await ReconstructTools.exportSession(
            sessionId: sessionId, path: arguments["path"]?.stringValue
        ).asCallToolResult()

    case "reconstruct_import_session":
        guard let path = arguments["path"]?.stringValue else {
            return ToolText("reconstruct_import_session requires `path`.", isError: true).asCallToolResult()
        }
        return await ReconstructTools.importSession(
            path: path, sessionId: arguments["sessionId"]?.stringValue
        ).asCallToolResult()

    case "segment_mesh_zones":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("segment_mesh_zones requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await MeshZoneTools.segmentMeshZones(
            bodyId: bodyId,
            maxDihedralDegrees: arguments["maxDihedralDegrees"]?.numberValue ?? 20,
            mergeToleranceMm: arguments["mergeToleranceMm"]?.numberValue,
            minRegionTriangles: arguments["minRegionTriangles"]?.intValue ?? 8,
            maxZones: arguments["maxZones"]?.intValue ?? 64,
            deflection: arguments["deflection"]?.numberValue,
            registerZones: arguments["registerZones"]?.boolValue ?? false,
            registerCap: arguments["registerCap"]?.intValue ?? 32,
            render: arguments["render"]?.boolValue ?? true,
            renderPath: arguments["renderPath"]?.stringValue,
            options: parseRenderOptions(arguments["options"])
        ).asCallToolResult()

    case "zone_continuity_sweep":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("zone_continuity_sweep requires `bodyId`.", isError: true).asCallToolResult()
        }
        var axis: SIMD3<Double>? = nil
        if let arr = arguments["axis"]?.arrayValue, arr.count == 3,
           let x = arr[0].numberValue, let y = arr[1].numberValue, let z = arr[2].numberValue {
            axis = SIMD3(x, y, z)
        }
        return await ZoneSweepTool.zoneContinuitySweep(
            bodyId: bodyId,
            zoneId: arguments["zoneId"]?.stringValue,
            axis: axis,
            stations: arguments["stations"]?.intValue ?? 32,
            toleranceMm: arguments["toleranceMm"]?.numberValue ?? 0.5,
            lateralToleranceMm: arguments["lateralToleranceMm"]?.numberValue,
            deflection: arguments["deflection"]?.numberValue,
            render: arguments["render"]?.boolValue ?? true,
            renderPath: arguments["renderPath"]?.stringValue,
            chart: arguments["chart"]?.boolValue ?? false,
            chartPath: arguments["chartPath"]?.stringValue,
            options: parseRenderOptions(arguments["options"])
        ).asCallToolResult()

    case "list_zones":
        return await RegistryIntrospectionTools.listZones(bodyId: arguments["bodyId"]?.stringValue).asCallToolResult()

    case "clear_zones":
        return await RegistryIntrospectionTools.clearZones(bodyId: arguments["bodyId"]?.stringValue).asCallToolResult()

    case "mesh_diagnose":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("mesh_diagnose requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await MeshDiagnoseTools.meshDiagnose(
            bodyId: bodyId,
            deflection: arguments["deflection"]?.numberValue,
            weldToleranceMm: arguments["weldToleranceMm"]?.numberValue ?? 0
        ).asCallToolResult()

    case "mesh_thickness":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("mesh_thickness requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await MeshThicknessTools.meshThickness(
            bodyId: bodyId,
            maxSamples: arguments["maxSamples"]?.intValue ?? 2000,
            deflection: arguments["deflection"]?.numberValue,
            thresholdMm: arguments["thresholdMm"]?.numberValue,
            coneAngleDegrees: arguments["coneAngleDegrees"]?.numberValue ?? 0,
            chart: arguments["chart"]?.boolValue ?? false,
            chartPath: arguments["chartPath"]?.stringValue
        ).asCallToolResult()

    case "detect_symmetry":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("detect_symmetry requires `bodyId`.", isError: true).asCallToolResult()
        }
        return await SymmetryTools.detectSymmetry(
            bodyId: bodyId,
            maxSamples: arguments["maxSamples"]?.intValue ?? 2000,
            toleranceMm: arguments["toleranceMm"]?.numberValue ?? 0.5,
            deflection: arguments["deflection"]?.numberValue
        ).asCallToolResult()

    case "align_bodies":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("align_bodies requires `bodyId`.", isError: true).asCallToolResult()
        }
        guard let referenceBodyId = arguments["referenceBodyId"]?.stringValue else {
            return ToolText("align_bodies requires `referenceBodyId`.", isError: true).asCallToolResult()
        }
        // An unrecognized mode must error, not silently fall back to bestFit: MCP clients don't
        // reliably validate the schema's enum, and the description itself names deferred modes
        // (localBestFit / 3-2-1 / RPS) a caller could plausibly try.
        let mode: AlignTools.Mode
        if let modeString = arguments["mode"]?.stringValue {
            guard let parsed = AlignTools.Mode(rawValue: modeString) else {
                return ToolText(
                    "align_bodies: unknown mode \"\(modeString)\". Valid modes: \"bestFit\" (default), \"preAlign\". " +
                    "localBestFit / 3-2-1 / RPS-datum alignment are not implemented yet.",
                    isError: true
                ).asCallToolResult()
            }
            mode = parsed
        } else {
            mode = .bestFit
        }
        return await AlignTools.alignBodies(
            bodyId: bodyId,
            referenceBodyId: referenceBodyId,
            mode: mode,
            maxSamples: arguments["maxSamples"]?.intValue ?? 2000,
            trimFraction: arguments["trimFraction"]?.numberValue ?? 0.1,
            correspondenceDistanceCapMm: arguments["correspondenceDistanceCapMm"]?.numberValue,
            maxIterations: arguments["maxIterations"]?.intValue ?? 50,
            deflection: arguments["deflection"]?.numberValue,
            apply: arguments["apply"]?.boolValue ?? false
        ).asCallToolResult()

    case "mesh_curvature":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("mesh_curvature requires `bodyId`.", isError: true).asCallToolResult()
        }
        // Same #106 convention as align_bodies' `mode`: an unrecognized colorBy must error,
        // naming the valid values, not silently fall back to the default.
        let colorBy: MeshCurvatureTools.ColorBy
        if let colorByString = arguments["colorBy"]?.stringValue {
            guard let parsed = MeshCurvatureTools.ColorBy(rawValue: colorByString) else {
                let valid = MeshCurvatureTools.ColorBy.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                return ToolText(
                    "mesh_curvature: unknown colorBy \"\(colorByString)\". Valid values: \(valid).",
                    isError: true
                ).asCallToolResult()
            }
            colorBy = parsed
        } else {
            colorBy = .mean
        }
        return await MeshCurvatureTools.meshCurvature(
            bodyId: bodyId,
            deflection: arguments["deflection"]?.numberValue,
            colorBy: colorBy,
            clampPercentile: arguments["clampPercentile"]?.numberValue ?? 0.95,
            render: arguments["render"]?.boolValue ?? true,
            renderPath: arguments["renderPath"]?.stringValue,
            chart: arguments["chart"]?.boolValue ?? false,
            chartPath: arguments["chartPath"]?.stringValue,
            options: parseRenderOptions(arguments["options"])
        ).asCallToolResult()

    case "detect_mesh_features":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("detect_mesh_features requires `bodyId`.", isError: true).asCallToolResult()
        }
        // Dispatch-level guard (the #106 convention): an invalid minAngleDegrees must error here
        // too, not just inside the tool function — this is the layer an MCP client's own schema
        // validation can be bypassed at.
        let minAngle = arguments["minAngleDegrees"]?.numberValue ?? 30
        guard minAngle > 0, minAngle <= 180 else {
            return ToolText("detect_mesh_features: minAngleDegrees must be in (0, 180].", isError: true).asCallToolResult()
        }
        return await MeshFeatureTools.detectMeshFeatures(
            bodyId: bodyId,
            minAngleDegrees: minAngle,
            maxRings: arguments["maxRings"]?.intValue ?? 64,
    case "fit_primitives":
        guard let bodyId = arguments["bodyId"]?.stringValue else {
            return ToolText("fit_primitives requires `bodyId`.", isError: true).asCallToolResult()
        }
        // Same #106 convention as align_bodies' `mode` / mesh_curvature's `colorBy`: an
        // unrecognized strategy must error, naming the valid values, not silently fall back.
        let strategy: FitPrimitivesTools.Strategy
        if let strategyString = arguments["strategy"]?.stringValue {
            guard let parsed = FitPrimitivesTools.Strategy(rawValue: strategyString) else {
                let valid = FitPrimitivesTools.Strategy.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
                return ToolText(
                    "fit_primitives: unknown strategy \"\(strategyString)\". Valid values: \(valid).",
                    isError: true
                ).asCallToolResult()
            }
            strategy = parsed
        } else {
            strategy = .ransac
        }
        return await FitPrimitivesTools.fitPrimitives(
            bodyId: bodyId,
            zoneId: arguments["zoneId"]?.stringValue,
            strategy: strategy,
            inlierEpsilonMm: arguments["inlierEpsilonMm"]?.numberValue,
            minSupportTriangles: arguments["minSupportTriangles"]?.intValue,
            maxPrimitives: arguments["maxPrimitives"]?.intValue,
            deflection: arguments["deflection"]?.numberValue,
            render: arguments["render"]?.boolValue ?? true,
            renderPath: arguments["renderPath"]?.stringValue,
            options: parseRenderOptions(arguments["options"])
        ).asCallToolResult()

    default:
        return ToolText("Unknown tool: \(callName)", isError: true).asCallToolResult()
    }
}
