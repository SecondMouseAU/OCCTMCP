#!/usr/bin/env node
/**
 * Runs a WASI build of occtkit under Node's `node:wasi`.
 *
 *   node wasi-run.js <occtkit.wasm> <occtkit args...>
 *
 * WASI has no working directory and no ambient filesystem, so the directories the verbs read and
 * write are preopened at the same path they have on the host. That keeps every absolute path the
 * tools already pass (output directory, request staging files in the temp directory) valid inside
 * the module. Preopened: the scene output directory, the temp directory, the current directory, and
 * any directories in OCCTMCP_WASI_PREOPEN (separated by the platform path delimiter). Relative
 * paths do not resolve under WASI; the tools pass absolute ones.
 *
 * stdin, stdout and stderr are inherited, and the module's exit code becomes this process's.
 */

import { readFile } from "fs/promises";
import { WASI } from "node:wasi";
import { preopenDirs } from "./wasi-preopens.js";

async function main(): Promise<number> {
  const [wasmPath, ...args] = process.argv.slice(2);
  if (!wasmPath) {
    process.stderr.write("usage: wasi-run <occtkit.wasm> <occtkit args...>\n");
    return 2;
  }
  const preopens: Record<string, string> = {};
  for (const d of preopenDirs()) preopens[d] = d;
  const wasi = new WASI({
    version: "preview1",
    args: ["occtkit", ...args],
    env: {},
    preopens,
    returnOnExit: true,
  });
  const module = await WebAssembly.compile(await readFile(wasmPath));
  const instance = await WebAssembly.instantiate(module, wasi.getImportObject() as WebAssembly.Imports);
  return wasi.start(instance);
}

main().then(
  (code) => {
    process.exitCode = code;
  },
  (err: unknown) => {
    process.stderr.write(`wasi-run: ${err instanceof Error ? err.message : String(err)}\n`);
    process.exitCode = 1;
  }
);
