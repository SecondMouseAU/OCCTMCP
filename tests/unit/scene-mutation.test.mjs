/**
 * Unit tests for the pure-TS scene-mutation tools (Phase 1).
 *
 * These exercise manifest read/modify/write logic only — no occtkit
 * subprocess. Each test points OCCTMCP_OUTPUT_DIR at a fresh tempdir.
 *
 * Run with:  node --test tests/unit/
 */

import { describe, it, before, after, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

let SCENE_DIR;
let MANIFEST;
let BREP_A;
let BREP_B;

const SAMPLE_MANIFEST = {
  version: 1,
  timestamp: "2026-04-29T00:00:00Z",
  description: "Test scene",
  bodies: [
    { id: "alpha", file: "alpha.brep", format: "brep", color: [1, 0, 0, 1] },
    { id: "beta", file: "beta.brep", format: "brep", color: [0, 1, 0, 1] },
  ],
};

function freshScene() {
  if (SCENE_DIR && existsSync(SCENE_DIR)) {
    rmSync(SCENE_DIR, { recursive: true, force: true });
  }
  const dir = mkdtempSync(join(tmpdir(), "occtmcp-test-"));
  SCENE_DIR = dir;
  MANIFEST = join(dir, "manifest.json");
  BREP_A = join(dir, "alpha.brep");
  BREP_B = join(dir, "beta.brep");
  writeFileSync(MANIFEST, JSON.stringify(SAMPLE_MANIFEST, null, 2));
  writeFileSync(BREP_A, "DUMMY-BREP-A");
  writeFileSync(BREP_B, "DUMMY-BREP-B");
  process.env.OCCTMCP_OUTPUT_DIR = dir;
}

function cleanup() {
  if (SCENE_DIR && existsSync(SCENE_DIR)) {
    rmSync(SCENE_DIR, { recursive: true, force: true });
  }
}

function readManifest() {
  return JSON.parse(readFileSync(MANIFEST, "utf-8"));
}

let sceneTools;

before(async () => {
  // Initialise the env var BEFORE importing scene-tools so its captured
  // module state (history ring) is seeded against a stable tmpdir parent.
  process.env.OCCTMCP_OUTPUT_DIR = mkdtempSync(join(tmpdir(), "occtmcp-init-"));
  sceneTools = await import("../../dist/scene-tools.js");
});

after(() => {
  cleanup();
});

beforeEach(() => {
  freshScene();
  sceneTools.clearHistory();
});

describe("remove_body", () => {
  it("removes the body from manifest and deletes its BREP", async () => {
    const r = await sceneTools.removeBody("alpha");
    assert.match(r.content[0].text, /Removed body "alpha"/);

    const m = readManifest();
    assert.equal(m.bodies.length, 1);
    assert.equal(m.bodies[0].id, "beta");
    assert.equal(existsSync(BREP_A), false);
    assert.equal(existsSync(BREP_B), true);
  });

  it("errors when bodyId is unknown", async () => {
    const r = await sceneTools.removeBody("nope");
    assert.match(r.content[0].text, /Body not found: nope/);
    assert.equal(readManifest().bodies.length, 2);
  });
});

describe("clear_scene", () => {
  it("removes every body and its BREP", async () => {
    const r = await sceneTools.clearScene(false);
    assert.match(r.content[0].text, /Cleared 2 bodies/);
    assert.equal(readManifest().bodies.length, 0);
    assert.equal(existsSync(BREP_A), false);
    assert.equal(existsSync(BREP_B), false);
  });

  it("keepHistory=true preserves the history ring", async () => {
    await sceneTools.removeBody("alpha"); // pushes a snapshot
    await sceneTools.clearScene(true);
    // History should still hold pre-clear snapshot. compare_versions(1)
    // should compare current (empty) vs the previous snapshot.
    const diff = JSON.parse((await sceneTools.compareVersions(1)).content[0].text);
    assert.ok(diff.available > 0);
  });

  it("keepHistory=false (default) clears the ring", async () => {
    await sceneTools.removeBody("alpha");
    await sceneTools.clearScene(false);
    const out = (await sceneTools.compareVersions(1)).content[0].text;
    assert.match(out, /Not enough history/);
  });
});

describe("rename_body", () => {
  it("renames the id in the manifest", async () => {
    const r = await sceneTools.renameBody("alpha", "alpha2");
    assert.match(r.content[0].text, /Renamed "alpha" → "alpha2"/);
    const m = readManifest();
    assert.equal(m.bodies.find((b) => b.file === "alpha.brep").id, "alpha2");
  });

  it("rejects collisions with an existing id", async () => {
    const r = await sceneTools.renameBody("alpha", "beta");
    assert.match(r.content[0].text, /already exists/);
    const m = readManifest();
    assert.equal(m.bodies[0].id, "alpha");
  });

  it("errors when bodyId is unknown", async () => {
    const r = await sceneTools.renameBody("missing", "anything");
    assert.match(r.content[0].text, /Body not found/);
  });
});

describe("set_appearance", () => {
  it("updates color, opacity, name, roughness, metallic", async () => {
    const r = await sceneTools.setAppearance(
      "alpha",
      [0.2, 0.4, 0.6],
      0.5,
      0.8,
      0.1,
      "Alpha part"
    );
    assert.match(r.content[0].text, /Updated appearance of "alpha"/);
    const m = readManifest();
    const body = m.bodies.find((b) => b.id === "alpha");
    assert.deepEqual(body.color, [0.2, 0.4, 0.6, 0.5]);
    assert.equal(body.roughness, 0.8);
    assert.equal(body.metallic, 0.1);
    assert.equal(body.name, "Alpha part");
  });

  it("opacity alone updates only the alpha channel", async () => {
    await sceneTools.setAppearance("alpha", undefined, 0.3);
    const body = readManifest().bodies.find((b) => b.id === "alpha");
    // original colour was [1,0,0,1]; alpha is now 0.3, RGB unchanged
    assert.equal(body.color[0], 1);
    assert.equal(body.color[1], 0);
    assert.equal(body.color[2], 0);
    assert.equal(body.color[3], 0.3);
  });

  it("rejects color arrays of wrong length", async () => {
    const r = await sceneTools.setAppearance("alpha", [1, 0]);
    assert.match(r.content[0].text, /must be \[r,g,b\]/);
  });

  it("complains when no fields are provided", async () => {
    const r = await sceneTools.setAppearance("alpha");
    assert.match(r.content[0].text, /No appearance fields provided/);
  });

  it("errors on unknown bodyId", async () => {
    const r = await sceneTools.setAppearance("nope", [1, 1, 1]);
    assert.match(r.content[0].text, /Body not found/);
  });
});

describe("compare_versions", () => {
  it("reports added when a new body appears", async () => {
    await sceneTools.snapshotScene();
    // mutate after snapshot — add a body manually
    const m = readManifest();
    m.bodies.push({ id: "gamma", file: "gamma.brep", format: "brep" });
    writeFileSync(MANIFEST, JSON.stringify(m));
    const diff = JSON.parse((await sceneTools.compareVersions(1)).content[0].text);
    assert.deepEqual(diff.added, ["gamma"]);
    assert.deepEqual(diff.removed, []);
  });

  it("reports removed when a body is deleted", async () => {
    await sceneTools.removeBody("alpha"); // snapshots first, then removes
    const diff = JSON.parse((await sceneTools.compareVersions(1)).content[0].text);
    assert.deepEqual(diff.removed, ["alpha"]);
    assert.deepEqual(diff.added, []);
  });

  it("reports appearanceChanged when color changes", async () => {
    await sceneTools.setAppearance("alpha", [0.5, 0.5, 0.5]);
    const diff = JSON.parse((await sceneTools.compareVersions(1)).content[0].text);
    assert.equal(diff.appearanceChanged.length, 1);
    assert.equal(diff.appearanceChanged[0].id, "alpha");
    assert.ok(diff.appearanceChanged[0].fields.includes("color"));
  });

  it("reports unchanged for untouched bodies", async () => {
    await sceneTools.removeBody("alpha"); // snapshots and removes
    const diff = JSON.parse((await sceneTools.compareVersions(1)).content[0].text);
    assert.ok(diff.unchanged.includes("beta"));
  });

  it("returns 'not enough history' when ring is shallower than `since`", async () => {
    const r = await sceneTools.compareVersions(5);
    assert.match(r.content[0].text, /Not enough history/);
  });

  it("returns 'not enough history' for since=0 instead of throwing (#130)", async () => {
    await sceneTools.snapshotScene();
    const r = await sceneTools.compareVersions(0);
    assert.match(r.content[0].text, /Not enough history/);
  });
});
