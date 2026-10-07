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
 * stdin, stdout and stderr are inherited, the environment is this process's, and the module's exit
 * code becomes this process's.
 */

import { readFile } from "fs/promises";
import { WASI } from "node:wasi";
import { preopenDirs } from "./wasi-preopens.js";

/** The module uses WebAssembly exception handling (exnref), which V8 enables by default from Node 22. */
const MIN_NODE_MAJOR = 22;

async function main(): Promise<number> {
  const major = parseInt(process.versions.node, 10);
  if (major < MIN_NODE_MAJOR) {
    process.stderr.write(
      `wasi-run: the WASI occtkit needs Node ${MIN_NODE_MAJOR} or newer; this is ${process.version}. ` +
        `Node 20 and 21 fail to compile the module ("invalid value type 'noexternref'").\n`
    );
    return 2;
  }
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
    // The same environment a native occtkit gets from execFile (verbs may read OCCTMCP_* variables).
    env: Object.fromEntries(
      Object.entries(process.env).filter((e): e is [string, string] => typeof e[1] === "string")
    ),
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
