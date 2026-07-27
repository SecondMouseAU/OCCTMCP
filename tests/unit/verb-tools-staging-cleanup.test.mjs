/**
 * Regression test for #133: mirrorOrPattern and mergeStagedImport (backing
 * read_brep / import_file) must remove the whole occtmcp-*-<uuid> staging
 * directory they create under $TMPDIR, not just a file inside it.
 *
 * Also covers #149: both functions have early returns (occtkit itself
 * failing, or malformed/missing occtkit output) that sit before the
 * success-path cleanup #133 added, so those paths need their own coverage
 * proving the staging dir is still removed.
 *
 * Same fake-"occtkit"-on-PATH approach as tests/unit/occtkit-serve.test.mjs:
 * ESM named exports aren't reconfigurable, so `node:test`'s `mock.method`
 * can't stub resolveOcctkit()/execFile in place. The fake occtkit reads the
 * JSON request file passed as its last argv, writes whatever staged files
 * the request implies, and prints the stdout shape the real occtkit verb
 * would produce. Failure/malformed-output modes are triggered by markers in
 * the request's own input-file basename (`req.inputBrep`/`req.inputPath`),
 * since that's the only field every call site threads through unchanged —
 * neither mirrorOrPattern's nor mergeStagedImport's public signature exposes
 * a generic "extra request field" passthrough to drive this from the test.
 *
 * Run with:  node --test tests/unit/
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import {
  mkdtempSync,
  rmSync,
  writeFileSync,
  chmodSync,
  readdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter } from "node:path";

const FAKE_OCCTKIT_SOURCE = `#!/usr/bin/env node
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, basename } from "node:path";

const verb = process.argv[2];
const reqPath = process.argv[3];
const req = JSON.parse(readFileSync(reqPath, "utf-8"));
const source = basename(req.inputBrep ?? req.inputPath ?? "");

if (source.includes("SIMULATE-FAIL")) {
  process.stderr.write("simulated occtkit failure");
  process.exitCode = 1;
} else if (verb === "pattern") {
  mkdirSync(req.outputDir, { recursive: true });
  if (source.includes("SIMULATE-MALFORMED")) {
    process.stdout.write("NOT-VALID-JSON{{{");
  } else {
    const outPath = join(req.outputDir, "instance-0.brep");
    writeFileSync(outPath, "FAKE-PATTERN-BREP-0");
    process.stdout.write(JSON.stringify({ outputPaths: [outPath], totalCount: 1 }));
  }
} else if (verb === "load-brep") {
  const staging = req.emitManifest;
  mkdirSync(staging, { recursive: true });
  if (source.includes("SIMULATE-NO-MANIFEST")) {
    process.stdout.write("loaded 1 body but forgot the manifest");
  } else {
    const bodyFile = "imported-0.brep";
    writeFileSync(join(staging, bodyFile), "FAKE-IMPORTED-BREP-0");
    const manifest = {
      version: 1,
      timestamp: new Date().toISOString(),
      bodies: [{ id: "imported0", file: bodyFile, format: "brep" }],
    };
    writeFileSync(join(staging, "manifest.json"), JSON.stringify(manifest));
    process.stdout.write("loaded 1 body");
  }
} else {
  process.stdout.write("{}");
}
`;

let binDir;
let originalPath;
let verbTools;
const sceneDirs = [];

function tmpEntries(prefix) {
  return readdirSync(tmpdir()).filter((name) => name.startsWith(prefix));
}

function freshSceneWithBody(bodyFile = "alpha.brep") {
  const dir = mkdtempSync(join(tmpdir(), "occtmcp-verbtools-scene-"));
  sceneDirs.push(dir);
  writeFileSync(
    join(dir, "manifest.json"),
    JSON.stringify({
      version: 1,
      timestamp: "2026-01-01T00:00:00Z",
      bodies: [{ id: "alpha", file: bodyFile, format: "brep" }],
    })
  );
  writeFileSync(join(dir, bodyFile), "DUMMY-BREP-ALPHA");
  process.env.OCCTMCP_OUTPUT_DIR = dir;
  return dir;
}

before(async () => {
  originalPath = process.env.PATH;
  binDir = mkdtempSync(join(tmpdir(), "occtmcp-fake-occtkit-verbtools-"));
  const shimPath = join(binDir, "occtkit");
  writeFileSync(shimPath, FAKE_OCCTKIT_SOURCE);
  chmodSync(shimPath, 0o755);
  process.env.PATH = binDir + delimiter + originalPath;

  verbTools = await import("../../dist/verb-tools.js");
});

after(() => {
  process.env.PATH = originalPath;
  rmSync(binDir, { recursive: true, force: true });
  for (const dir of sceneDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("mirror_or_pattern staging dir cleanup (#133)", () => {
  it("removes the occtmcp-pattern-* staging directory it creates", async () => {
    freshSceneWithBody();
    const existingBefore = tmpEntries("occtmcp-pattern-");

    const r = await verbTools.mirrorOrPattern(
      "alpha",
      "linear",
      { direction: [1, 0, 0], spacing: 10, count: 2 },
      undefined
    );
    assert.match(r.content[0].text, /Pattern linear on "alpha"/);

    const leaked = tmpEntries("occtmcp-pattern-").filter(
      (name) => !existingBefore.includes(name)
    );
    assert.deepEqual(
      leaked,
      [],
      `expected no leaked pattern staging dirs, found: ${leaked.join(", ")}`
    );
  });
});

describe("mirror_or_pattern staging dir cleanup on error paths (#149)", () => {
  it("removes the staging directory when occtkit itself fails", async () => {
    freshSceneWithBody("alpha-SIMULATE-FAIL.brep");
    const existingBefore = tmpEntries("occtmcp-pattern-");

    const r = await verbTools.mirrorOrPattern(
      "alpha",
      "linear",
      { direction: [1, 0, 0], spacing: 10, count: 2 },
      undefined
    );
    assert.match(r.content[0].text, /occtkit pattern failed/);

    const leaked = tmpEntries("occtmcp-pattern-").filter(
      (name) => !existingBefore.includes(name)
    );
    assert.deepEqual(
      leaked,
      [],
      `expected no leaked pattern staging dirs, found: ${leaked.join(", ")}`
    );
  });

  it("removes the staging directory when pattern output is malformed", async () => {
    freshSceneWithBody("alpha-SIMULATE-MALFORMED.brep");
    const existingBefore = tmpEntries("occtmcp-pattern-");

    const r = await verbTools.mirrorOrPattern(
      "alpha",
      "linear",
      { direction: [1, 0, 0], spacing: 10, count: 2 },
      undefined
    );
    assert.match(r.content[0].text, /Could not parse pattern output/);

    const leaked = tmpEntries("occtmcp-pattern-").filter(
      (name) => !existingBefore.includes(name)
    );
    assert.deepEqual(
      leaked,
      [],
      `expected no leaked pattern staging dirs, found: ${leaked.join(", ")}`
    );
  });
});

describe("read_brep staging dir cleanup (#133)", () => {
  it("removes the occtmcp-load-brep-* staging directory it creates", async () => {
    freshSceneWithBody();
    const sourceDir = mkdtempSync(join(tmpdir(), "occtmcp-verbtools-source-"));
    sceneDirs.push(sourceDir);
    const sourcePath = join(sourceDir, "import-source.brep");
    writeFileSync(sourcePath, "DUMMY-BREP-SOURCE");

    const existingBefore = tmpEntries("occtmcp-load-brep-");

    const r = await verbTools.readBrep(sourcePath);
    assert.match(r.content[0].text, /Imported 1 bodies via load-brep/);

    const leaked = tmpEntries("occtmcp-load-brep-").filter(
      (name) => !existingBefore.includes(name)
    );
    assert.deepEqual(
      leaked,
      [],
      `expected no leaked load-brep staging dirs, found: ${leaked.join(", ")}`
    );
  });
});

describe("read_brep staging dir cleanup on error paths (#149)", () => {
  it("removes the staging directory when occtkit itself fails", async () => {
    freshSceneWithBody();
    const sourceDir = mkdtempSync(join(tmpdir(), "occtmcp-verbtools-source-"));
    sceneDirs.push(sourceDir);
    const sourcePath = join(sourceDir, "import-source-SIMULATE-FAIL.brep");
    writeFileSync(sourcePath, "DUMMY-BREP-SOURCE");

    const existingBefore = tmpEntries("occtmcp-load-brep-");

    const r = await verbTools.readBrep(sourcePath);
    assert.match(r.content[0].text, /occtkit load-brep failed/);

    const leaked = tmpEntries("occtmcp-load-brep-").filter(
      (name) => !existingBefore.includes(name)
    );
    assert.deepEqual(
      leaked,
      [],
      `expected no leaked load-brep staging dirs, found: ${leaked.join(", ")}`
    );
  });

  it("removes the staging directory when no manifest is emitted", async () => {
    freshSceneWithBody();
    const sourceDir = mkdtempSync(join(tmpdir(), "occtmcp-verbtools-source-"));
    sceneDirs.push(sourceDir);
    const sourcePath = join(sourceDir, "import-source-SIMULATE-NO-MANIFEST.brep");
    writeFileSync(sourcePath, "DUMMY-BREP-SOURCE");

    const existingBefore = tmpEntries("occtmcp-load-brep-");

    const r = await verbTools.readBrep(sourcePath);
    assert.match(r.content[0].text, /did not emit a manifest/);

    const leaked = tmpEntries("occtmcp-load-brep-").filter(
      (name) => !existingBefore.includes(name)
    );
    assert.deepEqual(
      leaked,
      [],
      `expected no leaked load-brep staging dirs, found: ${leaked.join(", ")}`
    );
  });
});
