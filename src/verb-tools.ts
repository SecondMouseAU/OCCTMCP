import { execFile } from "child_process";
import { readFile, writeFile, unlink, rename, stat } from "fs/promises";
import { existsSync, mkdirSync } from "fs";
import { join, basename, extname, dirname } from "path";
import { tmpdir } from "os";
import { promisify } from "util";
import { randomUUID } from "crypto";
import { outputDir, manifestPath } from "./paths.js";
import { resolveOcctkit } from "./occtkit.js";
import { snapshotScene } from "./scene-tools.js";

const execFileAsync = promisify(execFile);

type ToolResult = { content: Array<{ type: "text"; text: string }> };

type Body = {
  id?: string;
  file: string;
  format?: string;
  name?: string;
  color?: number[];
  roughness?: number;
  metallic?: number;
};

type Manifest = {
  version: number;
  timestamp: string;
  description?: string;
  bodies: Body[];
  graphs?: unknown[];
  metadata?: unknown;
};

function text(t: string): ToolResult {
  return { content: [{ type: "text" as const, text: t }] };
}

async function readManifest(): Promise<Manifest | null> {
  if (!existsSync(manifestPath())) return null;
  return JSON.parse(await readFile(manifestPath(), "utf-8")) as Manifest;
}

async function writeManifest(m: Manifest): Promise<void> {
  m.timestamp = new Date().toISOString();
  await writeFile(manifestPath(), JSON.stringify(m, null, 2), "utf-8");
}

function findBody(m: Manifest, bodyId: string): Body | null {
  return m.bodies.find((b) => b.id === bodyId) ?? null;
}

function bodyPath(b: Body): string {
  return join(outputDir(), b.file);
}

async function runVerbJSON(
  verb: string,
  request: Record<string, unknown>,
  timeoutMs = 120_000
): Promise<{ ok: true; stdout: string } | { ok: false; error: string; stderr: string }> {
  const oc = await resolveOcctkit();
  const reqPath = join(tmpdir(), `occtmcp-${verb}-${randomUUID()}.json`);
  await writeFile(reqPath, JSON.stringify(request), "utf-8");
  try {
    const { stdout } = await execFileAsync(
      oc.command,
      [...oc.baseArgs, verb, reqPath],
      { cwd: oc.cwd, timeout: timeoutMs, maxBuffer: 50 * 1024 * 1024 }
    );
    return { ok: true, stdout: stdout.trim() };
  } catch (err: unknown) {
    const e = err as { stderr?: string; message?: string };
    return { ok: false, error: e.message ?? "unknown error", stderr: (e.stderr ?? "").trim() };
  } finally {
    await unlink(reqPath).catch(() => {});
  }
}

async function runVerbArgs(
  verb: string,
  args: string[],
  timeoutMs = 120_000
): Promise<{ ok: true; stdout: string } | { ok: false; error: string; stderr: string }> {
  const oc = await resolveOcctkit();
  try {
    const { stdout } = await execFileAsync(
      oc.command,
      [...oc.baseArgs, verb, ...args],
      { cwd: oc.cwd, timeout: timeoutMs, maxBuffer: 50 * 1024 * 1024 }
    );
    return { ok: true, stdout: stdout.trim() };
  } catch (err: unknown) {
    const e = err as { stderr?: string; message?: string };
    return { ok: false, error: e.message ?? "unknown error", stderr: (e.stderr ?? "").trim() };
  }
}

function passthroughResult(
  verb: string,
  r: Awaited<ReturnType<typeof runVerbJSON>>
): ToolResult {
  if (!r.ok) {
    return text(`occtkit ${verb} failed.\n\n${r.error}\n${r.stderr}`);
  }
  return text(r.stdout);
}

function freshBrepPath(stem: string): string {
  return join(outputDir(), `${stem}-${randomUUID().slice(0, 8)}.brep`);
}

// ── compute_metrics ────────────────────────────────────────────────────────

export async function computeMetrics(
  bodyId: string,
  metrics?: string[]
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const req: Record<string, unknown> = { inputBrep: bodyPath(body) };
  if (metrics && metrics.length > 0) req.metrics = metrics;
  return passthroughResult("metrics", await runVerbJSON("metrics", req));
}

// ── query_topology ─────────────────────────────────────────────────────────

export async function queryTopology(
  bodyId: string,
  entity: "face" | "edge" | "vertex",
  filter?: Record<string, unknown>,
  limit?: number
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const req: Record<string, unknown> = { inputBrep: bodyPath(body), entity };
  if (filter) req.filter = filter;
  if (limit !== undefined) req.limit = limit;
  return passthroughResult("query-topology", await runVerbJSON("query-topology", req));
}

// ── measure_distance ───────────────────────────────────────────────────────

export async function measureDistance(
  fromBodyId: string,
  toBodyId: string,
  fromRef?: string,
  toRef?: string,
  computeContacts?: boolean
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const a = findBody(m, fromBodyId);
  const b = findBody(m, toBodyId);
  if (!a) return text(`Body not found: ${fromBodyId}`);
  if (!b) return text(`Body not found: ${toBodyId}`);

  const req: Record<string, unknown> = { a: bodyPath(a), b: bodyPath(b) };
  if (fromRef !== undefined) req.fromRef = fromRef;
  if (toRef !== undefined) req.toRef = toRef;
  if (computeContacts !== undefined) req.computeContacts = computeContacts;
  return passthroughResult("measure-distance", await runVerbJSON("measure-distance", req));
}

// ── measure_deviation ────────────────────────────────────────────────────────

export async function measureDeviation(
  fromBodyId: string,
  toBodyId: string,
  deflection?: number,
  maxSamples?: number
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const a = findBody(m, fromBodyId);
  const b = findBody(m, toBodyId);
  if (!a) return text(`Body not found: ${fromBodyId}`);
  if (!b) return text(`Body not found: ${toBodyId}`);

  const req: Record<string, unknown> = { a: bodyPath(a), b: bodyPath(b) };
  if (deflection !== undefined) req.deflection = deflection;
  if (maxSamples !== undefined) req.maxSamples = maxSamples;
  const r = await runVerbJSON("measure-deviation", req);
  if (!r.ok) return text(`occtkit measure-deviation failed.\n\n${r.error}\n${r.stderr}`);
  // occtkit reports on BREP paths, not body ids — re-attach the ids so the Node
  // response matches the Swift server's measure_deviation shape.
  try {
    const parsed = JSON.parse(r.stdout) as Record<string, unknown>;
    return text(JSON.stringify({ from: fromBodyId, to: toBodyId, ...parsed }, null, 2));
  } catch {
    return text(r.stdout);
  }
}

// ── check_thickness ────────────────────────────────────────────────────────

export async function checkThickness(
  bodyId: string,
  minAcceptable?: number,
  samplingDensity?: "coarse" | "medium" | "fine"
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const req: Record<string, unknown> = { inputBrep: bodyPath(body) };
  if (minAcceptable !== undefined) req.minAcceptable = minAcceptable;
  if (samplingDensity !== undefined) req.samplingDensity = samplingDensity;
  return passthroughResult("check-thickness", await runVerbJSON("check-thickness", req, 240_000));
}

// ── analyze_clearance ──────────────────────────────────────────────────────

export async function analyzeClearance(
  bodyIds: string[],
  minClearance?: number,
  computeContacts?: boolean,
  maxContacts?: number
): Promise<ToolResult> {
  if (bodyIds.length < 2) return text(`analyze_clearance needs at least 2 body ids; got ${bodyIds.length}.`);
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const paths: string[] = [];
  for (const id of bodyIds) {
    const b = findBody(m, id);
    if (!b) return text(`Body not found: ${id}`);
    paths.push(bodyPath(b));
  }

  const req: Record<string, unknown> = { inputs: paths };
  if (minClearance !== undefined) req.minClearance = minClearance;
  if (computeContacts !== undefined) req.computeContacts = computeContacts;
  if (maxContacts !== undefined) req.maxContacts = maxContacts;
  return passthroughResult("analyze-clearance", await runVerbJSON("analyze-clearance", req));
}

// ── generate_mesh ──────────────────────────────────────────────────────────

export async function generateMesh(
  bodyId: string,
  linearDeflection?: number,
  angularDeflection?: number,
  parallel?: boolean,
  returnGeometry?: boolean,
  outputPath?: string
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const req: Record<string, unknown> = { inputBrep: bodyPath(body) };
  if (linearDeflection !== undefined) req.linearDeflection = linearDeflection;
  if (angularDeflection !== undefined) req.angularDeflection = angularDeflection;
  if (parallel !== undefined) req.parallel = parallel;
  if (returnGeometry !== undefined) req.returnGeometry = returnGeometry;
  if (outputPath !== undefined) req.outputPath = outputPath;
  return passthroughResult("mesh", await runVerbJSON("mesh", req, 240_000));
}

// ── simplify_mesh ──────────────────────────────────────────────────────────

export async function simplifyMesh(
  bodyId: string,
  outputPath: string,
  options: {
    targetTriangleCount?: number;
    targetReduction?: number;
    preserveBoundary?: boolean;
    preserveTopology?: boolean;
    maxHausdorffDistance?: number;
    linearDeflection?: number;
    angularDeflection?: number;
  }
): Promise<ToolResult> {
  if (
    options.targetTriangleCount === undefined &&
    options.targetReduction === undefined
  ) {
    return text(
      "simplify_mesh requires exactly one of targetTriangleCount or targetReduction."
    );
  }
  if (
    options.targetTriangleCount !== undefined &&
    options.targetReduction !== undefined
  ) {
    return text(
      "simplify_mesh: pass exactly one of targetTriangleCount or targetReduction, not both."
    );
  }
  const ext = outputPath.toLowerCase();
  if (!ext.endsWith(".stl") && !ext.endsWith(".obj")) {
    return text(`simplify_mesh: outputPath must end in .stl or .obj (got ${outputPath}).`);
  }

  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const req: Record<string, unknown> = {
    inputBrep: bodyPath(body),
    outputPath,
    ...options,
  };
  return passthroughResult("simplify-mesh", await runVerbJSON("simplify-mesh", req, 240_000));
}

// ── transform_body ─────────────────────────────────────────────────────────

export async function transformBody(
  bodyId: string,
  translate?: number[],
  rotateAxisAngle?: number[],
  rotateEulerXyz?: number[],
  scale?: number,
  inPlace?: boolean,
  outputBodyId?: string
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const inputPath = bodyPath(body);
  const isInPlace = inPlace ?? !outputBodyId;
  if (!isInPlace && outputBodyId && m.bodies.some((x) => x.id === outputBodyId)) {
    return text(`Output body id "${outputBodyId}" already exists.`);
  }
  const outputPath = isInPlace ? inputPath : freshBrepPath(`xform-${outputBodyId ?? bodyId}`);

  const req: Record<string, unknown> = { inputBrep: inputPath, outputPath };
  if (translate !== undefined) req.translate = translate;
  if (rotateAxisAngle !== undefined) req.rotateAxisAngle = rotateAxisAngle;
  if (rotateEulerXyz !== undefined) req.rotateEulerXyz = rotateEulerXyz;
  if (scale !== undefined) req.scale = scale;

  await snapshotScene();
  const r = await runVerbJSON("transform", req);
  if (!r.ok) return text(`occtkit transform failed.\n\n${r.error}\n${r.stderr}`);

  if (!isInPlace && outputBodyId) {
    m.bodies.push({
      id: outputBodyId,
      file: basename(outputPath),
      format: "brep",
      color: body.color,
      name: body.name,
    });
    await writeManifest(m);
  } else {
    await writeManifest(m);
  }

  return text(
    `Transformed "${bodyId}" → ${isInPlace ? `(in place) ${body.file}` : `new body "${outputBodyId}" → ${basename(outputPath)}`}\n\n${r.stdout}`
  );
}

// ── boolean_op ─────────────────────────────────────────────────────────────

export async function booleanOp(
  op: "union" | "subtract" | "intersect" | "split",
  aBodyId: string,
  bBodyId: string,
  outputBodyId?: string,
  removeInputs?: boolean
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const a = findBody(m, aBodyId);
  const b = findBody(m, bBodyId);
  if (!a) return text(`Body not found: ${aBodyId}`);
  if (!b) return text(`Body not found: ${bBodyId}`);

  const outId = outputBodyId ?? `${op}-${aBodyId}-${bBodyId}`;
  if (m.bodies.some((x) => x.id === outId && x.id !== aBodyId && x.id !== bBodyId)) {
    return text(`Output body id "${outId}" already exists. Pass a different outputBodyId.`);
  }

  const outputPath = freshBrepPath(outId);
  const req = { op, a: bodyPath(a), b: bodyPath(b), outputPath };

  await snapshotScene();
  const r = await runVerbJSON("boolean", req);
  if (!r.ok) return text(`occtkit boolean failed.\n\n${r.error}\n${r.stderr}`);

  m.bodies.push({
    id: outId,
    file: basename(outputPath),
    format: "brep",
    color: a.color,
    name: a.name ? `${op} ${a.name}` : undefined,
  });

  if (removeInputs) {
    for (const id of [aBodyId, bBodyId]) {
      const idx = m.bodies.findIndex((x) => x.id === id);
      if (idx >= 0) {
        const b2 = m.bodies[idx]!;
        await unlink(bodyPath(b2)).catch(() => {});
        m.bodies.splice(idx, 1);
      }
    }
  }

  await writeManifest(m);
  return text(
    `Boolean ${op}(${aBodyId}, ${bBodyId}) → "${outId}" (${basename(outputPath)})${removeInputs ? "; inputs removed" : ""}.\n\n${r.stdout}`
  );
}

// ── mirror_or_pattern ──────────────────────────────────────────────────────

type PatternParams = {
  plane?: string;
  planeOrigin?: number[];
  planeNormal?: number[];
  direction?: number[];
  spacing?: number;
  count?: number;
  axisOrigin?: number[];
  axisDirection?: number[];
  totalCount?: number;
  totalAngle?: number;
};

export async function mirrorOrPattern(
  bodyId: string,
  kind: "mirror" | "linear" | "circular",
  params: PatternParams,
  outputBodyIdPrefix?: string
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const stagingDir = join(tmpdir(), `occtmcp-pattern-${randomUUID()}`);
  mkdirSync(stagingDir, { recursive: true });

  const req: Record<string, unknown> = {
    inputBrep: bodyPath(body),
    outputDir: stagingDir,
    kind,
    ...params,
  };

  await snapshotScene();
  const r = await runVerbJSON("pattern", req);
  if (!r.ok) return text(`occtkit pattern failed.\n\n${r.error}\n${r.stderr}`);

  let parsed: { outputPaths?: string[]; totalCount?: number };
  try {
    parsed = JSON.parse(r.stdout);
  } catch {
    return text(`Could not parse pattern output:\n\n${r.stdout}`);
  }
  const outputs = parsed.outputPaths ?? [];

  const prefix = outputBodyIdPrefix ?? `${kind}-${bodyId}`;
  const sceneDir = outputDir();
  const newIds: string[] = [];
  for (let i = 0; i < outputs.length; i++) {
    const stagedPath = outputs[i]!;
    const finalName = `${prefix}-${i}-${randomUUID().slice(0, 4)}.brep`;
    const finalPath = join(sceneDir, finalName);
    await rename(stagedPath, finalPath).catch(async () => {
      const data = await readFile(stagedPath);
      await writeFile(finalPath, data);
      await unlink(stagedPath).catch(() => {});
    });
    const newId = `${prefix}-${i}`;
    newIds.push(newId);
    m.bodies.push({
      id: newId,
      file: finalName,
      format: "brep",
      color: body.color,
      name: body.name ? `${body.name} (${kind} ${i})` : undefined,
    });
  }
  await writeManifest(m);
  await unlink(stagingDir).catch(() => {});

  return text(
    `Pattern ${kind} on "${bodyId}" → ${newIds.length} bodies: ${newIds.join(", ")}\n\n${r.stdout}`
  );
}

// ── heal_shape ─────────────────────────────────────────────────────────────

export async function healShape(
  bodyId: string,
  options?: {
    tolerance?: number;
    maxTolerance?: number;
    minTolerance?: number;
    fixSmallEdges?: boolean;
    fixSmallFaces?: boolean;
    fixGaps?: boolean;
    fixSelfIntersection?: boolean;
    fixOrientation?: boolean;
    unifyDomain?: boolean;
  },
  outputBodyId?: string
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");
  const body = findBody(m, bodyId);
  if (!body) return text(`Body not found: ${bodyId}`);

  const inputPath = bodyPath(body);
  const isInPlace = !outputBodyId || outputBodyId === bodyId;
  if (!isInPlace && outputBodyId && m.bodies.some((x) => x.id === outputBodyId)) {
    return text(`Output body id "${outputBodyId}" already exists.`);
  }
  const outputPath = isInPlace ? inputPath : freshBrepPath(`heal-${outputBodyId}`);

  const req: Record<string, unknown> = { inputBrep: inputPath, outputPath, ...(options ?? {}) };

  await snapshotScene();
  const r = await runVerbJSON("heal", req, 240_000);
  if (!r.ok) return text(`occtkit heal failed.\n\n${r.error}\n${r.stderr}`);

  if (!isInPlace && outputBodyId) {
    m.bodies.push({
      id: outputBodyId,
      file: basename(outputPath),
      format: "brep",
      color: body.color,
      name: body.name,
    });
  }
  await writeManifest(m);

  return text(
    `Healed "${bodyId}" → ${isInPlace ? `(in place) ${body.file}` : `new body "${outputBodyId}"`}\n\n${r.stdout}`
  );
}

/**
 * load-brep / import write a fresh manifest in their --emit-manifest dir,
 * which would clobber the live scene. So we point the verb at a staging dir,
 * read the staging manifest's bodies, copy each BREP into the live output
 * dir, and append the entries to the live manifest. Snapshot is taken first
 * so compare_versions can see the import.
 */
async function mergeStagedImport(
  verb: "load-brep" | "import",
  req: Record<string, unknown>,
  timeoutMs: number
): Promise<ToolResult> {
  await snapshotScene();
  const staging = join(tmpdir(), `occtmcp-${verb}-${randomUUID()}`);
  mkdirSync(staging, { recursive: true });
  req.emitManifest = staging;

  const r = await runVerbJSON(verb, req, timeoutMs);
  if (!r.ok) return text(`occtkit ${verb} failed.\n\n${r.error}\n${r.stderr}`);

  const stagedManifestPath = join(staging, "manifest.json");
  if (!existsSync(stagedManifestPath)) {
    return text(`${verb} did not emit a manifest at ${stagedManifestPath}.\n\n${r.stdout}`);
  }
  const staged = JSON.parse(await readFile(stagedManifestPath, "utf-8")) as Manifest;

  const live = (await readManifest()) ?? {
    version: 1,
    timestamp: new Date().toISOString(),
    description: undefined,
    bodies: [],
  };

  const sceneDir = outputDir();
  const importedIds: string[] = [];
  const conflicts: string[] = [];

  for (const sb of staged.bodies) {
    if (sb.id && live.bodies.some((x) => x.id === sb.id)) {
      conflicts.push(sb.id);
      continue;
    }
    const stagedBrep = join(staging, sb.file);
    const liveBrep = join(sceneDir, sb.file);
    if (existsSync(liveBrep)) {
      // collision on filename — pick a fresh one
      const stem = basename(sb.file, extname(sb.file));
      const fresh = `${stem}-${randomUUID().slice(0, 8)}${extname(sb.file)}`;
      sb.file = fresh;
    }
    await rename(stagedBrep, join(sceneDir, sb.file)).catch(async () => {
      const data = await readFile(stagedBrep);
      await writeFile(join(sceneDir, sb.file), data);
      await unlink(stagedBrep).catch(() => {});
    });
    live.bodies.push(sb);
    if (sb.id) importedIds.push(sb.id);
  }

  await writeManifest(live);
  await unlink(stagedManifestPath).catch(() => {});

  const summary = [
    `Imported ${importedIds.length} bodies via ${verb}: ${importedIds.join(", ")}.`,
  ];
  if (conflicts.length > 0) {
    summary.push(`Skipped (id conflict): ${conflicts.join(", ")}.`);
  }
  return text(`${summary.join(" ")}\n\n${r.stdout}`);
}

// ── read_brep ──────────────────────────────────────────────────────────────

export async function readBrep(
  inputPath: string,
  bodyId?: string,
  color?: string,
  allowInvalid?: boolean
): Promise<ToolResult> {
  if (!existsSync(inputPath)) return text(`BREP file not found: ${inputPath}`);
  const req: Record<string, unknown> = { inputBrep: inputPath };
  if (bodyId !== undefined) req.id = bodyId;
  if (color !== undefined) req.color = color;
  if (allowInvalid !== undefined) req.allowInvalid = allowInvalid;
  return mergeStagedImport("load-brep", req, 60_000);
}

// ── import_file ────────────────────────────────────────────────────────────

export async function importFile(
  inputPath: string,
  format?: "auto" | "step" | "iges" | "stl" | "obj",
  idPrefix?: string,
  preserveAssembly?: boolean,
  healOnImport?: boolean,
  allowInvalid?: boolean
): Promise<ToolResult> {
  if (!existsSync(inputPath)) return text(`File not found: ${inputPath}`);
  const req: Record<string, unknown> = { inputPath };
  if (format !== undefined) req.format = format;
  if (idPrefix !== undefined) req.idPrefix = idPrefix;
  if (preserveAssembly !== undefined) req.preserveAssembly = preserveAssembly;
  if (healOnImport !== undefined) req.healOnImport = healOnImport;
  if (allowInvalid !== undefined) req.allowInvalid = allowInvalid;
  return mergeStagedImport("import", req, 240_000);
}

// ── inspect_assembly ──────────────────────────────────────────────────────

export async function inspectAssembly(
  bodyId?: string,
  inputPath?: string,
  depth?: number
): Promise<ToolResult> {
  let path: string;
  if (inputPath) {
    if (!existsSync(inputPath)) return text(`File not found: ${inputPath}`);
    path = inputPath;
  } else if (bodyId) {
    const m = await readManifest();
    if (!m) return text("No scene loaded. Run execute_script first.");
    const body = findBody(m, bodyId);
    if (!body) return text(`Body not found: ${bodyId}`);
    path = bodyPath(body);
  } else {
    return text("inspect_assembly requires either bodyId or inputPath.");
  }

  const req: Record<string, unknown> = { inputPath: path };
  if (depth !== undefined) req.depth = depth;
  return passthroughResult("inspect-assembly", await runVerbJSON("inspect-assembly", req));
}

// ── set_assembly_metadata ─────────────────────────────────────────────────

type AssemblyMetadata = {
  title?: string;
  drawnBy?: string;
  material?: string;
  weight?: number;
  revision?: string;
  partNumber?: string;
  customAttrs?: Record<string, string>;
};

export async function setAssemblyMetadata(
  inputPath: string,
  outputPath: string,
  scope: "document" | "component" | undefined,
  componentId: number | undefined,
  metadata: AssemblyMetadata
): Promise<ToolResult> {
  if (!existsSync(inputPath)) return text(`File not found: ${inputPath}`);

  const req: Record<string, unknown> = { inputPath, outputPath, ...metadata };
  if (scope !== undefined) req.scope = scope;
  if (componentId !== undefined) req.componentId = componentId;

  const r = await runVerbJSON("set-metadata", req);
  if (!r.ok) return text(`occtkit set-metadata failed.\n\n${r.error}\n${r.stderr}`);

  let size = 0;
  try {
    size = (await stat(outputPath)).size;
  } catch {
    // ignore
  }
  return text(`Wrote metadata → ${outputPath} (${size} bytes).\n\n${r.stdout}`);
}

// ── render_preview ─────────────────────────────────────────────────────────

export async function renderPreview(
  outputPath: string,
  bodyIds?: string[],
  options?: {
    camera?: string;
    cameraPosition?: number[];
    cameraTarget?: number[];
    cameraUp?: number[];
    width?: number;
    height?: number;
    displayMode?: string;
    background?: string;
  }
): Promise<ToolResult> {
  const m = await readManifest();
  if (!m) return text("No scene loaded. Run execute_script first.");

  const targets = bodyIds && bodyIds.length > 0
    ? bodyIds.map((id) => {
        const b = findBody(m, id);
        if (!b) throw new Error(`Body not found: ${id}`);
        return bodyPath(b);
      })
    : m.bodies.map(bodyPath);

  if (targets.length === 0) return text("No bodies to render.");

  const req: Record<string, unknown> = {
    inputs: targets,
    outputPath,
    ...(options ?? {}),
  };

  const r = await runVerbJSON("render-preview", req, 120_000);
  if (!r.ok) return text(`occtkit render-preview failed.\n\n${r.error}\n${r.stderr}`);

  let size = 0;
  try {
    size = (await stat(outputPath)).size;
  } catch {
    // ignore
  }
  return text(`Rendered → ${outputPath} (${size} bytes).\n\n${r.stdout}`);
}
