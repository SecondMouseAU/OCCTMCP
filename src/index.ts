#!/usr/bin/env node

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { executeScript, getScene, getScript, exportModel, getApiReference } from "./tools.js";
import {
  graphValidate,
  graphCompact,
  graphDedup,
  graphMl,
  featureRecognize,
} from "./graph-tools.js";
import {
  removeBody,
  clearScene,
  renameBody,
  setAppearance,
  compareVersions,
  exportScene,
} from "./scene-tools.js";
import {
  validateGeometry,
  recognizeFeatures,
  applyFeature,
  generateDrawing,
} from "./api-tools.js";
import {
  computeMetrics,
  queryTopology,
  measureDistance,
  measureDeviation,
  checkThickness,
  analyzeClearance,
  generateMesh,
  transformBody,
  booleanOp,
  mirrorOrPattern,
  healShape,
  readBrep,
  importFile,
  renderPreview,
  inspectAssembly,
  setAssemblyMetadata,
  simplifyMesh,
} from "./verb-tools.js";

export function createServer(): McpServer {
  const server = new McpServer({
    name: "occtmcp",
    version: "0.1.0",
  });
  registerTools(server);
  return server;
}

function registerTools(server: McpServer): void {

// ── execute_script ──────────────────────────────────────────────────────────
// The core tool: write Swift CAD code, compile & run it via OCCTSwiftScripts.
// The viewport app auto-reloads when the manifest is written.
server.tool(
  "execute_script",
  "Write and execute Swift CAD code using the OCCTSwift API. " +
    "The code runs via OCCTSwiftScripts and outputs BREP/STEP files + manifest.json. " +
    "The viewport app auto-reloads on change. " +
    "You have access to the full OCCTSwift API: Shape, Wire, Edge, Face, Surface, Curve2D, Curve3D, etc. " +
    "Use ScriptContext to accumulate geometry and call ctx.emit() at the end.",
  {
    code: z
      .string()
      .describe(
        "Complete Swift source for main.swift. Must import OCCTSwift and ScriptHarness, " +
          "create a ScriptContext, add geometry, and call ctx.emit()."
      ),
    description: z
      .string()
      .optional()
      .describe("Short description of what this script creates"),
  },
  async ({ code, description }) => {
    return executeScript(code, description);
  }
);

// ── get_scene ───────────────────────────────────────────────────────────────
// Read the current manifest to understand what's currently rendered.
server.tool(
  "get_scene",
  "Read the current scene manifest from OCCTSwiftScripts output. " +
    "Returns the list of bodies, their IDs, colors, materials, and metadata.",
  {},
  async () => {
    return getScene();
  }
);

// ── get_script ──────────────────────────────────────────────────────────────
// Return the most recent script run in this MCP session.
server.tool(
  "get_script",
  "Return the source of the most recent Swift CAD script executed in this MCP session. " +
    "Returns a 'no script executed' message if execute_script has not been called yet.",
  {},
  async () => {
    return getScript();
  }
);

// ── export_model ────────────────────────────────────────────────────────────
// Get paths to exported files for downstream use.
server.tool(
  "export_model",
  "List the exported model files (BREP, STEP) from the last script run. " +
    "Returns absolute file paths that can be opened in external CAD tools.",
  {},
  async () => {
    return exportModel();
  }
);

// ── get_api_reference ───────────────────────────────────────────────────────
// Quick reference for the OCCTSwift API surface.
server.tool(
  "get_api_reference",
  "Get a reference guide for OCCTSwift API operations, OR a catalog of every " +
    "MCP tool this server exposes (category=mcp_tools). " +
    "Use this to look up available methods before writing a script, or to " +
    "discover what tools you can call directly without writing Swift.",
  {
    category: z
      .enum([
        "primitives",
        "sweeps",
        "booleans",
        "modifications",
        "transforms",
        "wires",
        "curves2d",
        "curves3d",
        "surfaces",
        "analysis",
        "import_export",
        "topology_graph",
        "topology_graph_builder",
        "all",
        "mcp_tools",
      ])
      .describe("API category to look up. Use 'mcp_tools' for the MCP tool catalog."),
  },
  async ({ category }) => {
    if (category === "mcp_tools") return mcpToolsCatalog();
    return getApiReference(category);
  }
);

function mcpToolsCatalog() {
  // Walk the McpServer's private tool registry. Shape per RegisteredTool in
  // @modelcontextprotocol/sdk: { description, inputSchema (zod), ... }.
  const reg = (server as unknown as {
    _registeredTools: Record<string, {
      description?: string;
      inputSchema?: unknown;
      enabled: boolean;
    }>;
  })._registeredTools;

  const entries = Object.entries(reg)
    .filter(([, t]) => t.enabled)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, t]) => {
      let inputSchema: unknown = {};
      if (t.inputSchema) {
        try {
          inputSchema = z.toJSONSchema(t.inputSchema as z.ZodType);
        } catch {
          inputSchema = { _note: "schema introspection failed" };
        }
      }
      return { name, description: t.description ?? "", inputSchema };
    });

  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify({ tools: entries, count: entries.length }, null, 2),
      },
    ],
  };
}

// ── graph_validate ──────────────────────────────────────────────────────────
// Run BRepGraph validation on a BREP file and return the report JSON.
server.tool(
  "graph_validate",
  "Validate a BREP shape's topology graph. Returns a JSON report: " +
    "validity, error/warning counts, and per-category issue details. " +
    "Use export_model to find BREP paths after execute_script.",
  {
    brep_path: z.string().describe("Absolute path to a BREP file."),
  },
  async ({ brep_path }) => {
    return graphValidate(brep_path);
  }
);

// ── graph_compact ───────────────────────────────────────────────────────────
// Compact a BREP's topology graph (drops unreferenced nodes) and write a
// rebuilt BREP to output_path. Returns JSON stats (nodes before/after).
server.tool(
  "graph_compact",
  "Compact a BREP's topology graph (drops unreferenced nodes) and write the " +
    "rebuilt shape to output_path. Returns a JSON report with before/after " +
    "node counts.",
  {
    brep_path: z.string().describe("Absolute path to the input BREP file."),
    output_path: z.string().describe("Absolute path where the compacted BREP is written."),
  },
  async ({ brep_path, output_path }) => {
    return graphCompact(brep_path, output_path);
  }
);

// ── graph_dedup ─────────────────────────────────────────────────────────────
// Deduplicate shared surface/curve geometry in a BREP, write rebuilt BREP.
server.tool(
  "graph_dedup",
  "Deduplicate shared surface/curve geometry in a BREP's topology graph. " +
    "Writes the rebuilt shape to output_path and returns a JSON report.",
  {
    brep_path: z.string().describe("Absolute path to the input BREP file."),
    output_path: z.string().describe("Absolute path where the deduped BREP is written."),
  },
  async ({ brep_path, output_path }) => {
    return graphDedup(brep_path, output_path);
  }
);

// ── graph_ml ────────────────────────────────────────────────────────────────
// Export the topology graph plus UV/edge samples as ML-friendly JSON.
server.tool(
  "graph_ml",
  "Export a BREP's topology graph as ML-friendly JSON: vertex positions, " +
    "edge/face adjacency (COO), per-face UV-grid samples (position, normal, " +
    "gaussian/mean curvature), and per-edge polyline samples. Output can be " +
    "large for complex shapes — up to ~50 MB.",
  {
    brep_path: z.string().describe("Absolute path to a BREP file."),
    uv_samples: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Per-face UV grid resolution (default 16 × 16)."),
    edge_samples: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Per-edge polyline sample count (default 32)."),
  },
  async ({ brep_path, uv_samples, edge_samples }) => {
    return graphMl(brep_path, uv_samples, edge_samples);
  }
);

// ── feature_recognize ───────────────────────────────────────────────────────
// AAG heuristic detection of pockets and holes.
server.tool(
  "feature_recognize",
  "Detect pockets and cylindrical holes in a BREP via AAG (attributed " +
    "adjacency graph) heuristics. Returns a JSON report listing each " +
    "pocket's floor/wall faces, z-level, depth, and bounds, plus each " +
    "hole's face index, radius, and depth.",
  {
    brep_path: z.string().describe("Absolute path to a BREP file."),
  },
  async ({ brep_path }) => {
    return featureRecognize(brep_path);
  }
);

// ── remove_body ─────────────────────────────────────────────────────────────
server.tool(
  "remove_body",
  "Delete a body from the current scene by id. Removes the body's BREP file " +
    "from the output directory and re-emits the manifest (triggers viewport reload).",
  {
    bodyId: z.string().describe("The id of the body to remove."),
  },
  async ({ bodyId }) => removeBody(bodyId)
);

// ── clear_scene ─────────────────────────────────────────────────────────────
server.tool(
  "clear_scene",
  "Remove every body from the current scene. Optionally preserves the " +
    "compare_versions history ring buffer.",
  {
    keepHistory: z
      .boolean()
      .optional()
      .describe("If true, keep the compare_versions history ring. Default false."),
  },
  async ({ keepHistory }) => clearScene(keepHistory ?? false)
);

// ── rename_body ─────────────────────────────────────────────────────────────
server.tool(
  "rename_body",
  "Change a body's id in the scene manifest. Fails if the new id is already in use.",
  {
    bodyId: z.string().describe("Current body id."),
    newBodyId: z.string().describe("New body id."),
  },
  async ({ bodyId, newBodyId }) => renameBody(bodyId, newBodyId)
);

// ── set_appearance ──────────────────────────────────────────────────────────
server.tool(
  "set_appearance",
  "Update color / opacity / roughness / metallic / display name for a scene " +
    "body without re-running a script. The viewport reloads automatically.",
  {
    bodyId: z.string().describe("Body to update."),
    color: z
      .array(z.number())
      .optional()
      .describe("RGBA or RGB array (0–1 per channel)."),
    opacity: z
      .number()
      .min(0)
      .max(1)
      .optional()
      .describe("Sets color alpha (0–1). Leaves RGB unchanged."),
    roughness: z.number().min(0).max(1).optional(),
    metallic: z.number().min(0).max(1).optional(),
    name: z.string().optional().describe("Human-readable display name."),
  },
  async ({ bodyId, color, opacity, roughness, metallic, name }) =>
    setAppearance(bodyId, color, opacity, roughness, metallic, name)
);

// ── compare_versions ────────────────────────────────────────────────────────
server.tool(
  "compare_versions",
  "Diff the current scene against a snapshot from N runs ago. Detects added / " +
    "removed / appearance-changed / file-changed bodies. Snapshots are taken " +
    "automatically before each execute_script and scene-mutation call.",
  {
    since: z
      .number()
      .int()
      .min(1)
      .optional()
      .describe("How many runs back to compare against. Default 1."),
  },
  async ({ since }) => compareVersions(since ?? 1)
);

// ── export_scene ────────────────────────────────────────────────────────────
server.tool(
  "export_scene",
  "Export current scene bodies (or a subset) to a single file in step / iges / " +
    "brep / stl / obj / gltf / glb format.",
  {
    format: z.enum(["step", "iges", "brep", "stl", "obj", "gltf", "glb"]),
    outputPath: z.string().describe("Absolute path for the exported file."),
    bodyIds: z
      .array(z.string())
      .optional()
      .describe("Body ids to include. Defaults to all bodies in the scene."),
  },
  async ({ format, outputPath, bodyIds }) =>
    exportScene(format, outputPath, bodyIds)
);

// ── validate_geometry ──────────────────────────────────────────────────────
server.tool(
  "validate_geometry",
  "Run topology validation on a scene body (or every body if no id given). " +
    "Wraps occtkit graph-validate per body and returns a per-body report.",
  {
    bodyId: z
      .string()
      .optional()
      .describe("Specific body to validate. If omitted, validates every BREP body."),
  },
  async ({ bodyId }) => validateGeometry(bodyId)
);

// ── recognize_features ─────────────────────────────────────────────────────
server.tool(
  "recognize_features",
  "Detect pockets and holes in a scene body via AAG heuristics. Wraps occtkit " +
    "feature-recognize and resolves the BREP path from the scene manifest.",
  {
    bodyId: z.string().describe("Body to analyse."),
    kinds: z
      .array(z.enum(["pocket", "hole"]))
      .optional()
      .describe("Restrict to certain kinds. Default: both."),
  },
  async ({ bodyId, kinds }) => recognizeFeatures(bodyId, kinds)
);

// ── apply_feature ──────────────────────────────────────────────────────────
server.tool(
  "apply_feature",
  "Apply a single feature (drill / fillet / chamfer / extrude / revolve / " +
    "boolean / thread) to an existing scene body via occtkit reconstruct. " +
    "Without outputBodyId, replaces the body in place. With outputBodyId, " +
    "adds a new body to the scene.",
  {
    bodyId: z.string().describe("Body to apply the feature to."),
    feature: z
      .object({})
      .passthrough()
      .describe(
        "FeatureSpec object with a 'kind' discriminator (e.g. " +
          "'hole', 'fillet', 'chamfer', 'extrude', 'revolve', 'thread', 'boolean'). " +
          "See OCCTSwiftScripts/Sources/occtkit/Commands/Reconstruct.swift for the schema."
      ),
    outputBodyId: z
      .string()
      .optional()
      .describe("If set, write a new body under this id instead of replacing in place."),
  },
  async ({ bodyId, feature, outputBodyId }) =>
    applyFeature(bodyId, feature, outputBodyId)
);

// ── generate_drawing ───────────────────────────────────────────────────────
server.tool(
  "generate_drawing",
  "Generate a multi-view ISO 128-30 technical drawing as DXF for a scene body. " +
    "Pass a DrawingSpec (sheet, title, views, sections, dimensions, …). The " +
    "tool injects the body's BREP path and the output DXF path into the spec, " +
    "then runs occtkit drawing-export.",
  {
    bodyId: z.string().describe("Body to draw."),
    outputPath: z.string().describe("Absolute path for the output DXF."),
    spec: z
      .object({})
      .passthrough()
      .describe(
        "DrawingSpec object: { sheet, title?, views, sections?, dimensions?, ... }. " +
          "See OCCTSwiftScripts/Sources/DrawingComposer/Spec.swift for the schema. " +
          "The 'shape' and 'output' fields are filled in by this tool."
      ),
  },
  async ({ bodyId, outputPath, spec }) =>
    generateDrawing(bodyId, outputPath, spec as Record<string, unknown>)
);

// ── compute_metrics ────────────────────────────────────────────────────────
server.tool(
  "compute_metrics",
  "Compute volume / surface area / center of mass / bounding box / principal " +
    "axes for a scene body. Wraps occtkit metrics. `boundingBox` is the default " +
    "Bnd_Box (control-point hull — over-reports curved B-spline geometry); " +
    "request `boundingBoxOptimal` for a tight BRepBndLib::AddOptimal extent.",
  {
    bodyId: z.string().describe("Body to compute metrics for."),
    metrics: z
      .array(
        z.enum([
          "volume",
          "surfaceArea",
          "centerOfMass",
          "boundingBox",
          "boundingBoxOptimal",
          "principalAxes",
        ])
      )
      .optional()
      .describe(
        "Subset to compute. Default: all except boundingBoxOptimal (opt-in — list it explicitly)."
      ),
  },
  async ({ bodyId, metrics }) => computeMetrics(bodyId, metrics)
);

// ── query_topology ─────────────────────────────────────────────────────────
server.tool(
  "query_topology",
  "Find faces / edges / vertices on a body matching criteria. Returns stable " +
    "IDs (face[N], edge[N], vertex[N]) usable in measure_distance and other " +
    "tools. Wraps occtkit query-topology.",
  {
    bodyId: z.string(),
    entity: z.enum(["face", "edge", "vertex"]),
    filter: z
      .object({})
      .passthrough()
      .optional()
      .describe(
        "AND-combined filter. face: surfaceType, minArea, maxArea, normalDirection, normalTolerance. edge: curveType, minLength, maxLength."
      ),
    limit: z.number().int().positive().optional(),
  },
  async ({ bodyId, entity, filter, limit }) =>
    queryTopology(bodyId, entity, filter as Record<string, unknown> | undefined, limit)
);

// ── measure_distance ──────────────────────────────────────────────────────
server.tool(
  "measure_distance",
  "Minimum distance and (optionally) contacts between two scene bodies. Wraps " +
    "occtkit measure-distance.",
  {
    fromBodyId: z.string(),
    toBodyId: z.string(),
    fromRef: z
      .string()
      .optional()
      .describe('Sub-entity ref or "point:x,y,z". Omit for whole shape.'),
    toRef: z.string().optional(),
    computeContacts: z.boolean().optional(),
  },
  async ({ fromBodyId, toBodyId, fromRef, toRef, computeContacts }) =>
    measureDistance(fromBodyId, toBodyId, fromRef, toRef, computeContacts)
);

// ── measure_deviation ───────────────────────────────────────────────────────
server.tool(
  "measure_deviation",
  "Directed + symmetric surface deviation (Hausdorff) between two scene bodies " +
    "— the metric for certifying a reconstruction against its source mesh. " +
    "Unlike measure_distance (minimum gap, ~0 for overlapping bodies), this " +
    "samples each body's tessellated surface and reports the worst / RMS / mean " +
    "distance to the other in BOTH directions: fromToTo (over-extension) and " +
    "toToFrom (under-coverage), each with a worstPoint, plus symmetricHausdorff. " +
    "Wraps occtkit measure-deviation.",
  {
    fromBodyId: z.string(),
    toBodyId: z.string(),
    deflection: z
      .number()
      .positive()
      .optional()
      .describe(
        "Mesh linear deflection (model units). Smaller = finer = tighter bound. Default: 0.5% of the from-body bbox diagonal."
      ),
    maxSamples: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Max source surface samples per direction (stride-subsampled). Default 20000."),
  },
  async ({ fromBodyId, toBodyId, deflection, maxSamples }) =>
    measureDeviation(fromBodyId, toBodyId, deflection, maxSamples)
);

// ── check_thickness ───────────────────────────────────────────────────────
server.tool(
  "check_thickness",
  "Wall-thickness analysis (sheet metal / casting / 3D printing). Reports " +
    "min/max/mean thickness and flags thin-wall regions. Wraps occtkit check-thickness.",
  {
    bodyId: z.string(),
    minAcceptable: z.number().positive().optional(),
    samplingDensity: z.enum(["coarse", "medium", "fine"]).optional(),
  },
  async ({ bodyId, minAcceptable, samplingDensity }) =>
    checkThickness(bodyId, minAcceptable, samplingDensity)
);

// ── analyze_clearance ─────────────────────────────────────────────────────
server.tool(
  "analyze_clearance",
  "Pairwise interference / minimum-clearance check between 2+ bodies. Wraps " +
    "occtkit analyze-clearance.",
  {
    bodyIds: z.array(z.string()).min(2),
    minClearance: z.number().nonnegative().optional(),
    computeContacts: z.boolean().optional(),
    maxContacts: z.number().int().positive().optional(),
  },
  async ({ bodyIds, minClearance, computeContacts, maxContacts }) =>
    analyzeClearance(bodyIds, minClearance, computeContacts, maxContacts)
);

// ── generate_mesh ─────────────────────────────────────────────────────────
server.tool(
  "generate_mesh",
  "Tessellate a scene body into a triangle mesh. Returns triangle/vertex " +
    "counts + quality metrics; optionally inline geometry or written to a " +
    "mesh file (.stl / .obj). Wraps occtkit mesh.",
  {
    bodyId: z.string(),
    linearDeflection: z.number().positive().optional(),
    angularDeflection: z.number().positive().optional(),
    parallel: z.boolean().optional(),
    returnGeometry: z
      .boolean()
      .optional()
      .describe("Inline triangle data in the response."),
    outputPath: z
      .string()
      .optional()
      .describe("If set, write mesh to this file (.stl / .obj)."),
  },
  async ({ bodyId, linearDeflection, angularDeflection, parallel, returnGeometry, outputPath }) =>
    generateMesh(bodyId, linearDeflection, angularDeflection, parallel, returnGeometry, outputPath)
);

// ── transform_body ────────────────────────────────────────────────────────
server.tool(
  "transform_body",
  "Apply translate / rotate / uniform-scale to a scene body. Without " +
    "outputBodyId, replaces the body in place. With outputBodyId, adds a new " +
    "body. Wraps occtkit transform.",
  {
    bodyId: z.string(),
    translate: z.array(z.number()).length(3).optional(),
    rotateAxisAngle: z
      .array(z.number())
      .length(4)
      .optional()
      .describe("[axisX, axisY, axisZ, radians]"),
    rotateEulerXyz: z.array(z.number()).length(3).optional(),
    scale: z.number().optional().describe("Uniform scale factor."),
    inPlace: z.boolean().optional(),
    outputBodyId: z.string().optional(),
  },
  async ({ bodyId, translate, rotateAxisAngle, rotateEulerXyz, scale, inPlace, outputBodyId }) =>
    transformBody(bodyId, translate, rotateAxisAngle, rotateEulerXyz, scale, inPlace, outputBodyId)
);

// ── boolean_op ────────────────────────────────────────────────────────────
server.tool(
  "boolean_op",
  "Boolean op (union / subtract / intersect / split) between two scene " +
    "bodies. Output is added as a new body. Wraps occtkit boolean.",
  {
    op: z.enum(["union", "subtract", "intersect", "split"]),
    aBodyId: z.string(),
    bBodyId: z.string(),
    outputBodyId: z
      .string()
      .optional()
      .describe("Defaults to '<op>-<a>-<b>'."),
    removeInputs: z.boolean().optional(),
  },
  async ({ op, aBodyId, bBodyId, outputBodyId, removeInputs }) =>
    booleanOp(op, aBodyId, bBodyId, outputBodyId, removeInputs)
);

// ── mirror_or_pattern ─────────────────────────────────────────────────────
server.tool(
  "mirror_or_pattern",
  "Mirror / linear / circular pattern of a body. Output is N new bodies in " +
    "the scene. Wraps occtkit pattern.",
  {
    bodyId: z.string(),
    kind: z.enum(["mirror", "linear", "circular"]),
    params: z
      .object({
        plane: z.string().optional().describe("mirror: 'xy'|'yz'|'zx'"),
        planeOrigin: z.array(z.number()).length(3).optional(),
        planeNormal: z.array(z.number()).length(3).optional(),
        direction: z.array(z.number()).length(3).optional().describe("linear"),
        spacing: z.number().optional().describe("linear"),
        count: z.number().int().positive().optional().describe("linear"),
        axisOrigin: z.array(z.number()).length(3).optional().describe("circular"),
        axisDirection: z.array(z.number()).length(3).optional().describe("circular"),
        totalCount: z.number().int().positive().optional().describe("circular"),
        totalAngle: z.number().optional().describe("circular (radians)"),
      })
      .passthrough(),
    outputBodyIdPrefix: z.string().optional(),
  },
  async ({ bodyId, kind, params, outputBodyIdPrefix }) =>
    mirrorOrPattern(bodyId, kind, params, outputBodyIdPrefix)
);

// ── heal_shape ────────────────────────────────────────────────────────────
server.tool(
  "heal_shape",
  "Heal imported / non-watertight geometry. Returns before/after stats. " +
    "Wraps occtkit heal.",
  {
    bodyId: z.string(),
    options: z
      .object({
        tolerance: z.number().optional(),
        maxTolerance: z.number().optional(),
        minTolerance: z.number().optional(),
        fixSmallEdges: z.boolean().optional(),
        fixSmallFaces: z.boolean().optional(),
        fixGaps: z.boolean().optional(),
        fixSelfIntersection: z.boolean().optional(),
        fixOrientation: z.boolean().optional(),
        unifyDomain: z.boolean().optional(),
      })
      .optional(),
    outputBodyId: z
      .string()
      .optional()
      .describe("If set, write a new body. Otherwise heals in place."),
  },
  async ({ bodyId, options, outputBodyId }) => healShape(bodyId, options, outputBodyId)
);

// ── read_brep ─────────────────────────────────────────────────────────────
server.tool(
  "read_brep",
  "Load a .brep from disk into the scene as a new body. Wraps occtkit load-brep.",
  {
    inputPath: z.string(),
    bodyId: z.string().optional(),
    color: z.string().optional().describe("'#rrggbb' or '#rrggbbaa'."),
  },
  async ({ inputPath, bodyId, color }) => readBrep(inputPath, bodyId, color)
);

// ── import_file ───────────────────────────────────────────────────────────
server.tool(
  "import_file",
  "Multi-format CAD import (STEP / IGES / STL / OBJ) into the scene. Wraps " +
    "occtkit import.",
  {
    inputPath: z.string(),
    format: z.enum(["auto", "step", "iges", "stl", "obj"]).optional(),
    idPrefix: z.string().optional(),
    preserveAssembly: z
      .boolean()
      .optional()
      .describe("STEP only: walk XCAF and emit one body per leaf node."),
    healOnImport: z.boolean().optional(),
  },
  async ({ inputPath, format, idPrefix, preserveAssembly, healOnImport }) =>
    importFile(inputPath, format, idPrefix, preserveAssembly, healOnImport)
);

// ── render_preview ────────────────────────────────────────────────────────
server.tool(
  "render_preview",
  "Render a PNG preview of the current scene (or a subset of bodies). Wraps " +
    "occtkit render-preview.",
  {
    outputPath: z.string().describe("Absolute path for the output PNG."),
    bodyIds: z
      .array(z.string())
      .optional()
      .describe("Restrict to these bodies. Default: all bodies."),
    options: z
      .object({
        camera: z
          .enum(["iso", "front", "back", "top", "bottom", "left", "right"])
          .optional(),
        cameraPosition: z.array(z.number()).length(3).optional(),
        cameraTarget: z.array(z.number()).length(3).optional(),
        cameraUp: z.array(z.number()).length(3).optional(),
        width: z.number().int().positive().optional(),
        height: z.number().int().positive().optional(),
        displayMode: z
          .enum(["shaded", "wireframe", "shaded-with-edges", "flat", "xray", "rendered"])
          .optional(),
        background: z.string().optional(),
      })
      .optional(),
  },
  async ({ outputPath, bodyIds, options }) =>
    renderPreview(outputPath, bodyIds, options)
);

// ── simplify_mesh ─────────────────────────────────────────────────────────
server.tool(
  "simplify_mesh",
  "Decimate a body's mesh to a target triangle count via QEM " +
    "(meshoptimizer, vendored in OCCTSwiftMesh). Outputs an .stl or .obj " +
    "file plus before/after counts and Hausdorff distance. Wraps " +
    "occtkit simplify-mesh.",
  {
    bodyId: z.string(),
    outputPath: z.string().describe("Output mesh path (.stl or .obj)."),
    targetTriangleCount: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Target triangle count. Mutually exclusive with targetReduction."),
    targetReduction: z
      .number()
      .gt(0)
      .lt(1)
      .optional()
      .describe("Fraction to remove (e.g. 0.9 = 90% reduction). Mutually exclusive with targetTriangleCount."),
    preserveBoundary: z.boolean().optional().describe("Default true."),
    preserveTopology: z.boolean().optional().describe("Default true."),
    maxHausdorffDistance: z
      .number()
      .positive()
      .optional()
      .describe("Cap deviation from the input mesh (in input units)."),
    linearDeflection: z.number().positive().optional().describe("Tessellation deflection. Default 0.1."),
    angularDeflection: z.number().positive().optional().describe("Default 0.5 rad."),
  },
  async ({ bodyId, outputPath, ...options }) =>
    simplifyMesh(bodyId, outputPath, options)
);

// ── inspect_assembly ──────────────────────────────────────────────────────
server.tool(
  "inspect_assembly",
  "Walk an XCAF assembly hierarchy: components, instances, names, colors, " +
    "materials, transforms. Pass either a scene bodyId (BREP — degenerate " +
    "response since BREPs carry no XCAF metadata) or an inputPath (STEP / " +
    "IGES / XBF for the full tree). Wraps occtkit inspect-assembly.",
  {
    bodyId: z.string().optional(),
    inputPath: z
      .string()
      .optional()
      .describe("STEP / IGES / XBF / BREP file path. Mutually exclusive with bodyId."),
    depth: z.number().int().nonnegative().optional(),
  },
  async ({ bodyId, inputPath, depth }) => inspectAssembly(bodyId, inputPath, depth)
);

// ── set_assembly_metadata ────────────────────────────────────────────────
server.tool(
  "set_assembly_metadata",
  "Modify XCAF document or per-component metadata (title / material / " +
    "weight / revision / part number / custom attributes). Wraps occtkit " +
    "set-metadata.",
  {
    inputPath: z.string().describe("STEP / IGES / XBF input."),
    outputPath: z.string().describe("Output XBF (or compatible) path."),
    scope: z.enum(["document", "component"]).optional(),
    componentId: z
      .number()
      .int()
      .optional()
      .describe("XCAF label id (when scope=component)."),
    metadata: z
      .object({
        title: z.string().optional(),
        drawnBy: z.string().optional(),
        material: z.string().optional(),
        weight: z.number().optional(),
        revision: z.string().optional(),
        partNumber: z.string().optional(),
        customAttrs: z.record(z.string(), z.string()).optional(),
      })
      .default({}),
  },
  async ({ inputPath, outputPath, scope, componentId, metadata }) =>
    setAssemblyMetadata(inputPath, outputPath, scope, componentId, metadata)
);

}

// ── Start (skipped during in-process imports such as tests) ──────────────────
const isMain =
  import.meta.url === `file://${process.argv[1]}` ||
  import.meta.url.endsWith(process.argv[1]?.replace(/^.*?\/dist\//, "/dist/") ?? "");

if (isMain) {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
}
