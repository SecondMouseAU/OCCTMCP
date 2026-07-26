import { readFile, writeFile, unlink, readdir } from "fs/promises";
import { existsSync } from "fs";
import { execFile } from "child_process";
import { join } from "path";
import { promisify } from "util";
import { outputDir, manifestPath, tempScriptPath } from "./paths.js";
import { resolveOcctkit } from "./occtkit.js";

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
  graphs?: Array<{ id: string; file: string; sourceBodyId?: string; stats?: object }>;
  metadata?: object;
};

// ── history ring buffer (in-memory) ─────────────────────────────────────────

const MAX_SNAPSHOTS = 10;
const history: Manifest[] = [];

function pushSnapshot(m: Manifest): void {
  history.push(structuredClone(m));
  if (history.length > MAX_SNAPSHOTS) history.shift();
}

/**
 * Snapshot the current manifest into the history ring. No-op if the manifest
 * doesn't exist. Called pre-mutation by every scene-mutating tool, and by
 * `executeScript` so each run leaves a checkpoint.
 */
export async function snapshotScene(): Promise<void> {
  const mp = manifestPath();
  if (!existsSync(mp)) return;
  try {
    const m = JSON.parse(await readFile(mp, "utf-8")) as Manifest;
    pushSnapshot(m);
  } catch {
    // ignore — bad manifest at snapshot time is not the snapshotter's problem
  }
}

export function clearHistory(): void {
  history.length = 0;
}

// ── manifest helpers ────────────────────────────────────────────────────────

async function readManifest(): Promise<Manifest> {
  return JSON.parse(await readFile(manifestPath(), "utf-8")) as Manifest;
}

async function writeManifest(m: Manifest): Promise<void> {
  m.timestamp = new Date().toISOString();
  await writeFile(manifestPath(), JSON.stringify(m, null, 2), "utf-8");
}

function noScene(): ToolResult {
  return {
    content: [
      {
        type: "text" as const,
        text: "No scene loaded. Run execute_script first.",
      },
    ],
  };
}

function text(t: string): ToolResult {
  return { content: [{ type: "text" as const, text: t }] };
}

function findBody(m: Manifest, id: string): { idx: number; body: Body } | null {
  const idx = m.bodies.findIndex((b) => b.id === id);
  if (idx < 0) return null;
  return { idx, body: m.bodies[idx]! };
}

// ── remove_body ─────────────────────────────────────────────────────────────

export async function removeBody(bodyId: string): Promise<ToolResult> {
  if (!existsSync(manifestPath())) return noScene();
  await snapshotScene();

  const m = await readManifest();
  const found = findBody(m, bodyId);
  if (!found) return text(`Body not found: ${bodyId}`);

  const filePath = join(outputDir(), found.body.file);
  m.bodies.splice(found.idx, 1);
  await writeManifest(m);
  await unlink(filePath).catch(() => {});

  return text(`Removed body "${bodyId}" (file: ${found.body.file}). Remaining: ${m.bodies.length}.`);
}

// ── clear_scene ─────────────────────────────────────────────────────────────

export async function clearScene(keepHistory: boolean): Promise<ToolResult> {
  if (!existsSync(manifestPath())) return noScene();
  await snapshotScene();

  const m = await readManifest();
  const removedCount = m.bodies.length;
  const filesToDelete = m.bodies.map((b) => join(outputDir(), b.file));

  m.bodies = [];
  m.description = "(cleared)";
  await writeManifest(m);

  await Promise.all(filesToDelete.map((p) => unlink(p).catch(() => {})));

  if (!keepHistory) clearHistory();

  return text(`Cleared ${removedCount} bodies from scene.${keepHistory ? "" : " History reset."}`);
}

// ── rename_body ─────────────────────────────────────────────────────────────

export async function renameBody(
  bodyId: string,
  newBodyId: string
): Promise<ToolResult> {
  if (!existsSync(manifestPath())) return noScene();
  await snapshotScene();

  const m = await readManifest();
  const found = findBody(m, bodyId);
  if (!found) return text(`Body not found: ${bodyId}`);

  if (m.bodies.some((b) => b.id === newBodyId)) {
    return text(`Cannot rename: a body with id "${newBodyId}" already exists.`);
  }

  found.body.id = newBodyId;
  await writeManifest(m);

  return text(`Renamed "${bodyId}" → "${newBodyId}".`);
}

// ── set_appearance ──────────────────────────────────────────────────────────

export async function setAppearance(
  bodyId: string,
  color?: number[],
  opacity?: number,
  roughness?: number,
  metallic?: number,
  name?: string
): Promise<ToolResult> {
  if (!existsSync(manifestPath())) return noScene();
  await snapshotScene();

  const m = await readManifest();
  const found = findBody(m, bodyId);
  if (!found) return text(`Body not found: ${bodyId}`);

  const applied: Record<string, unknown> = {};
  if (color !== undefined) {
    if (color.length !== 3 && color.length !== 4) {
      return text(`color must be [r,g,b] or [r,g,b,a]; got length ${color.length}.`);
    }
    const rgba = color.length === 3 ? [...color, found.body.color?.[3] ?? 1] : color;
    found.body.color = rgba;
    applied.color = rgba;
  }
  if (opacity !== undefined) {
    const c = found.body.color ?? [0.7, 0.7, 0.7, 1];
    c[3] = opacity;
    found.body.color = c;
    applied.opacity = opacity;
  }
  if (roughness !== undefined) {
    found.body.roughness = roughness;
    applied.roughness = roughness;
  }
  if (metallic !== undefined) {
    found.body.metallic = metallic;
    applied.metallic = metallic;
  }
  if (name !== undefined) {
    found.body.name = name;
    applied.name = name;
  }

  if (Object.keys(applied).length === 0) {
    return text(`No appearance fields provided. Pass at least one of: color, opacity, roughness, metallic, name.`);
  }

  await writeManifest(m);
  return text(
    `Updated appearance of "${bodyId}":\n${JSON.stringify(applied, null, 2)}`
  );
}

// ── compare_versions ────────────────────────────────────────────────────────

type Diff = {
  since: number;
  available: number;
  added: string[];
  removed: string[];
  appearanceChanged: Array<{ id: string; fields: string[] }>;
  fileChanged: string[];
  unchanged: string[];
};

function bodyKey(b: Body): string {
  return b.id ?? `__noid_${b.file}`;
}

function appearanceFields(b: Body): Record<string, unknown> {
  return {
    color: b.color,
    name: b.name,
    roughness: b.roughness,
    metallic: b.metallic,
  };
}

function diffManifests(prev: Manifest, curr: Manifest, since: number): Diff {
  const prevById = new Map(prev.bodies.map((b) => [bodyKey(b), b]));
  const currById = new Map(curr.bodies.map((b) => [bodyKey(b), b]));

  const added: string[] = [];
  const removed: string[] = [];
  const appearanceChanged: Array<{ id: string; fields: string[] }> = [];
  const fileChanged: string[] = [];
  const unchanged: string[] = [];

  for (const [k, b] of currById) {
    if (!prevById.has(k)) {
      added.push(k);
      continue;
    }
    const pb = prevById.get(k)!;
    const fields: string[] = [];
    const pa = appearanceFields(pb);
    const ca = appearanceFields(b);
    for (const f of ["color", "name", "roughness", "metallic"]) {
      if (JSON.stringify(pa[f]) !== JSON.stringify(ca[f])) fields.push(f);
    }
    if (pb.file !== b.file) {
      fileChanged.push(k);
    }
    if (fields.length > 0) {
      appearanceChanged.push({ id: k, fields });
    }
    if (fields.length === 0 && pb.file === b.file) {
      unchanged.push(k);
    }
  }

  for (const k of prevById.keys()) {
    if (!currById.has(k)) removed.push(k);
  }

  return { since, available: 0, added, removed, appearanceChanged, fileChanged, unchanged };
}

export async function compareVersions(since: number): Promise<ToolResult> {
  if (!existsSync(manifestPath())) return noScene();

  const current = await readManifest();
  const idx = history.length - since;
  if (idx < 0 || idx >= history.length) {
    return text(
      `Not enough history: requested ${since} runs back, only ${history.length} snapshots available. ` +
        `Make at least ${since} state changes (execute_script or scene-mutation tools) before comparing.`
    );
  }
  const prev = history[idx]!;
  const diff = diffManifests(prev, current, since);
  diff.available = history.length;
  return text(JSON.stringify(diff, null, 2));
}

// ── export_scene ────────────────────────────────────────────────────────────

const EXPORTERS: Record<string, (varName: string, urlVar: string) => string> = {
  step: (s, u) => `try Exporter.writeSTEP(shape: ${s}, to: ${u})`,
  iges: (s, u) => `try Exporter.writeIGES(shape: ${s}, to: ${u})`,
  brep: (s, u) => `try Exporter.writeBREP(shape: ${s}, to: ${u})`,
  stl: (s, u) => `try Exporter.writeSTL(shape: ${s}, to: ${u})`,
  obj: (s, u) => `try Exporter.writeOBJ(shape: ${s}, to: ${u})`,
  gltf: (s, u) => `try Exporter.writeGLTF(shape: ${s}, to: ${u}, binary: false)`,
  glb: (s, u) => `try Exporter.writeGLTF(shape: ${s}, to: ${u}, binary: true)`,
};

function swiftStringLiteral(s: string): string {
  return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
}

export async function exportScene(
  format: string,
  outputPath: string,
  bodyIds?: string[]
): Promise<ToolResult> {
  const fmt = format.toLowerCase();
  const exporter = EXPORTERS[fmt];
  if (!exporter) {
    return text(
      `Unknown format: ${format}. Supported: ${Object.keys(EXPORTERS).join(", ")}.`
    );
  }
  if (!existsSync(manifestPath())) return noScene();

  const m = await readManifest();
  let bodies = m.bodies;
  if (bodyIds && bodyIds.length > 0) {
    const idSet = new Set(bodyIds);
    bodies = bodies.filter((b) => b.id !== undefined && idSet.has(b.id));
    const found = new Set(bodies.map((b) => b.id));
    const missing = bodyIds.filter((id) => !found.has(id));
    if (missing.length > 0) {
      return text(`Body ids not found in scene: ${missing.join(", ")}`);
    }
  }
  if (bodies.length === 0) {
    return text("No bodies to export.");
  }

  const dir = outputDir();
  const loadLines = bodies.map((b, i) => {
    const path = swiftStringLiteral(join(dir, b.file));
    return `let s${i} = try Shape.loadBREP(fromPath: ${path})`;
  });
  const arr = bodies.map((_, i) => `s${i}`).join(", ");
  const compoundOrSingle =
    bodies.length === 1 ? "let exportShape = s0" :
      `guard let exportShape = Shape.compound([${arr}]) else {\n    fputs("Failed to build compound\\n", stderr); exit(1)\n}`;
  const outUrl = swiftStringLiteral(outputPath);
  const exportCall = exporter("exportShape", `URL(fileURLWithPath: ${outUrl})`);

  const code = [
    "import OCCTSwift",
    "import Foundation",
    "",
    ...loadLines,
    compoundOrSingle,
    exportCall,
    `print("Wrote ${outputPath}")`,
    "",
  ].join("\n");

  const scriptPath = tempScriptPath();
  await writeFile(scriptPath, code, "utf-8");

  try {
    const oc = await resolveOcctkit();
    const { stdout, stderr } = await execFileAsync(
      oc.command,
      [...oc.baseArgs, "run", scriptPath],
      { cwd: oc.cwd, timeout: 180_000, maxBuffer: 10 * 1024 * 1024 }
    );
    let fileSize = 0;
    if (existsSync(outputPath)) {
      const { statSync } = await import("fs");
      fileSize = statSync(outputPath).size;
    }
    const tail = (stderr || "").trim();
    return text(
      `Exported ${bodies.length} bodies → ${outputPath} (${format}, ${fileSize} bytes).\n` +
        (stdout?.trim() ? `\n${stdout.trim()}` : "") +
        (tail ? `\n\nstderr:\n${tail}` : "")
    );
  } catch (err: unknown) {
    const e = err as { stdout?: string; stderr?: string; message?: string };
    const out = [e.stdout?.trim(), e.stderr?.trim()].filter(Boolean).join("\n");
    return text(`Export failed.\n\n${out || e.message || "Unknown error"}`);
  } finally {
    await unlink(scriptPath).catch(() => {});
  }
}

// ── helpers exposed for tests/diagnostics ──────────────────────────────────

export const __test = { history };
