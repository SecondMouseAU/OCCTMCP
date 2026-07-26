/**
 * Regression test for #128: ServeProcess.ensureChild() must not spawn two
 * occtkit children when two send() calls race before any child exists.
 *
 * Exercises the real spawn path (no mocking of `child_process`/`resolveOcctkit` —
 * ESM named exports aren't reconfigurable, so `node:test`'s `mock.method` can't
 * stub them in place). Instead, a tiny fake "occtkit" executable is placed at
 * the front of PATH; it records its own PID to a counter file on startup and
 * echoes back a valid serve envelope per JSONL request line. Firing two
 * concurrent send() calls before either has awaited a child into existence
 * reproduces the exact race window described in #128: this is deterministic
 * in outcome (the fix guarantees exactly one spawn) even though the low-level
 * scheduling of the two concurrent awaits is not.
 *
 * Run with:  node --test tests/unit/
 */

import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, delimiter } from "node:path";

const FAKE_OCCTKIT_SOURCE = `#!/usr/bin/env node
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

appendFileSync(process.env.FAKE_OCCTKIT_COUNTER, process.pid + "\\n");

const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  if (!line.trim()) return;
  process.stdout.write(JSON.stringify({ ok: true, exit: 0, stdout: "", stderr: "" }) + "\\n");
});
`;

let binDir;
let counterFile;
let originalPath;
let ServeProcess;

before(async () => {
  originalPath = process.env.PATH;
  binDir = mkdtempSync(join(tmpdir(), "occtmcp-fake-occtkit-"));
  counterFile = join(binDir, "spawns.txt");
  writeFileSync(counterFile, "");

  const shimPath = join(binDir, "occtkit");
  writeFileSync(shimPath, FAKE_OCCTKIT_SOURCE);
  chmodSync(shimPath, 0o755);

  process.env.PATH = binDir + delimiter + originalPath;
  process.env.FAKE_OCCTKIT_COUNTER = counterFile;

  ({ ServeProcess } = await import("../../dist/occtkit-serve.js"));
});

after(() => {
  process.env.PATH = originalPath;
  delete process.env.FAKE_OCCTKIT_COUNTER;
  rmSync(binDir, { recursive: true, force: true });
});

describe("ServeProcess ensureChild race (#128)", () => {
  it("spawns exactly one child when two send() calls race with no child yet", async () => {
    const sp = new ServeProcess();
    try {
      const [r1, r2] = await Promise.all([sp.send("/tmp/does-not-matter.swift"), sp.send("/tmp/does-not-matter.swift")]);
      assert.equal(r1.ok, true);
      assert.equal(r2.ok, true);

      const pids = readFileSync(counterFile, "utf-8").split("\n").filter((l) => l.trim() !== "");
      assert.equal(pids.length, 1, `expected exactly one occtkit spawn, got ${pids.length}: ${pids.join(",")}`);
    } finally {
      sp.shutdown();
    }
  });
});
