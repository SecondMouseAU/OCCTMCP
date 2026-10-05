/**
 * Unit tests for the WASI occtkit selection (src/occtkit.ts, src/wasi-preopens.ts).
 * No wasm module is run here; tests/integration/wasm-occtkit.test.mjs does that.
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";

const { wasmInvocation } = await import("../../dist/occtkit.js");
const { preopenDirs } = await import("../../dist/wasi-preopens.js");

describe("wasmInvocation", () => {
  it("runs the module through node and wasi-run.js, silencing the experimental warning", () => {
    const inv = wasmInvocation("/x/occtkit.wasm");
    assert.equal(inv.command, process.execPath);
    assert.equal(inv.baseArgs[0], "--no-warnings");
    assert.match(inv.baseArgs[1], /wasi-run\.js$/);
    assert.equal(inv.baseArgs[2], "/x/occtkit.wasm");
    assert.equal(inv.cwd, undefined);
  });
});

describe("preopenDirs", () => {
  it("includes the temp directory and OCCTMCP_WASI_PREOPEN entries, deduplicated", () => {
    const extra = mkdtempSync(join(tmpdir(), "occtmcp-preopen-"));
    try {
      const dirs = preopenDirs({ OCCTMCP_WASI_PREOPEN: [extra, tmpdir()].join(delimiter) });
      assert.ok(dirs.includes(tmpdir()));
      assert.ok(dirs.includes(extra));
      assert.equal(new Set(dirs).size, dirs.length);
    } finally {
      rmSync(extra, { recursive: true, force: true });
    }
  });

  it("drops directories that do not exist", () => {
    const dirs = preopenDirs({ OCCTMCP_WASI_PREOPEN: "/definitely/not/here" });
    assert.ok(!dirs.includes("/definitely/not/here"));
  });
});
