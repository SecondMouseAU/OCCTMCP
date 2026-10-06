/**
 * Integration test: the geometry tools through the WASI occtkit, against analytic answers.
 *
 * Skipped unless OCCTMCP_OCCTKIT_WASM points at an occtkit.wasm (see docs/guides/wasm-core.md).
 * The two bodies are 10 x 10 x 10 cubes offset by 5 in x and y, so every expected figure is exact
 * geometry, not a reference run: volume 1000, overlap 250, union 1750, subtract 750.
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const WASM = process.env.OCCTMCP_OCCTKIT_WASM;
const skip = WASM ? false : "OCCTMCP_OCCTKIT_WASM is not set";

let SCENE_DIR;
let verb;

function cube(name, x0, y0) {
  const req = {
    outputDir: SCENE_DIR,
    outputName: name,
    features: [
      {
        kind: "extrude",
        id: name,
        profile_points_2d: [[x0, y0], [x0 + 10, y0], [x0 + 10, y0 + 10], [x0, y0 + 10]],
        plane_origin: [0, 0, 0],
        plane_normal: [0, 0, 1],
        length: 10,
      },
    ],
  };
  const reqPath = join(SCENE_DIR, `${name}.json`);
  writeFileSync(reqPath, JSON.stringify(req));
  execFileSync(process.execPath, ["--no-warnings", "dist/wasi-run.js", WASM, "reconstruct", reqPath], {
    env: { ...process.env, OCCTMCP_OUTPUT_DIR: SCENE_DIR },
  });
}

const near = (actual, expected, tol = 1e-6) =>
  assert.ok(Math.abs(actual - expected) < tol, `${actual} is not within ${tol} of ${expected}`);

before(async () => {
  if (skip) return;
  SCENE_DIR = mkdtempSync(join(tmpdir(), "occtmcp-wasm-"));
  process.env.OCCTMCP_OUTPUT_DIR = SCENE_DIR;
  cube("a", 0, 0);
  cube("b", 5, 5);
  writeFileSync(
    join(SCENE_DIR, "manifest.json"),
    JSON.stringify({
      version: 1,
      timestamp: new Date().toISOString(),
      description: "wasm integration scene",
      bodies: [
        { id: "a", file: "a.brep", format: "brep", color: [0.8, 0.7, 0.3, 1] },
        { id: "b", file: "b.brep", format: "brep", color: [0.3, 0.7, 0.8, 1] },
      ],
    })
  );
  verb = await import("../../dist/verb-tools.js");
});

after(() => {
  if (SCENE_DIR) rmSync(SCENE_DIR, { recursive: true, force: true });
});

const json = (r) => JSON.parse(r.content[0].text);

describe("geometry tools on the WASI occtkit", { skip }, () => {
  it("compute_metrics: volume, area and centre of mass of a cube", async () => {
    const d = json(await verb.computeMetrics("a"));
    near(d.volume, 1000);
    near(d.surfaceArea, 600);
    d.centerOfMass.forEach((c) => near(c, 5));
  });

  it("measure_distance: overlapping cubes are 0 apart", async () => {
    const d = json(await verb.measureDistance("a", "b"));
    near(d.minDistance, 0);
  });

  it("boolean_op: intersect, union and subtract volumes", async () => {
    for (const [op, expected] of [["intersect", 250], ["union", 1750], ["subtract", 750]]) {
      const out = `${op}-out`;
      await verb.booleanOp(op, "a", "b", out);
      near(json(await verb.computeMetrics(out)).volume, expected);
    }
  });

  it("check_thickness: a 10 mm cube is 10 mm thick", async () => {
    const d = json(await verb.checkThickness("a"));
    near(d.minThickness, 10, 1e-3);
  });

  it("a verb the WASI build omits fails with the verb error, not a crash", async () => {
    const r = await verb.simplifyMesh("a", join(SCENE_DIR, "x.stl"), { targetReduction: 0.5 });
    assert.match(r.content[0].text, /Unknown subcommand|failed/i);
  });
});
