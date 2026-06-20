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
    public static let serverVersion = "0.1.0"
}

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
            description: "Per-body topology validation. Wraps GraphIO + TopologyGraph.validate() in-process.",
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
            description: "Local B-rep graph adjacency / selection query (no full-graph dump). query=face-neighbors needs `face` (returns adjacent faces + convexity + shared-edge count); edge-faces needs `edge`; vertex-edges needs `vertex`; face-adjacency returns the full attributed face-adjacency graph (gAAG); edges-class needs `class` (boundary|non-manifold|seam|degenerate). Face indices follow shape.faces() order (the face[N] scheme query_topology emits); edge/vertex indices are TopologyGraph indices.",
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
            description: "Headless Metal render of the current scene (or a subset) to PNG. Uses OCCTSwiftViewport's OffscreenRenderer + OCCTSwiftTools' Shape→ViewportBody bridge.",
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
            description: "Surface deviation (one-sided + symmetric Hausdorff) between two scene bodies — the metric for certifying a reconstruction against its source mesh. Unlike measure_distance (minimum gap, ≈0 for overlapping bodies), this samples each body's tessellated surface and reports the worst / RMS / mean distance to the other in BOTH directions: `fromToTo` (from's surface vs to — over-extension) and `toToFrom` (under-coverage), each with a worstPoint, plus `symmetricHausdorff`. Mesh-based; fidelity scales with `deflection` (default 0.5% of the from-body bbox diagonal). `maxSamples` (default 20000) stride-subsamples the source surface per direction.",
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
                ]),
                "required": .array([.string("fromBodyId"), .string("toBodyId")]),
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
            description: "Multi-format CAD import (STEP / IGES / BREP). Adds the imported shape as a single body.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "inputPath": .object(["type": .string("string")]),
                    "format": .object([
                        "type": .string("string"),
                        "enum": .array([.string("auto"), .string("step"), .string("iges"), .string("obj"), .string("brep")]),
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
        let deflection = arguments["deflection"]?.doubleValue
        let maxSamples = arguments["maxSamples"]?.intValue ?? 20_000
        return await DeviationTools.measureDeviation(
            fromBodyId: fromId, toBodyId: toId, deflection: deflection, maxSamples: maxSamples
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

    default:
        return ToolText("Unknown tool: \(callName)", isError: true).asCallToolResult()
    }
}
