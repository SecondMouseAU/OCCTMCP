import { execFile } from "child_process";
import { existsSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";
import { promisify } from "util";
import { SCRIPTS_PROJECT } from "./paths.js";

const execFileAsync = promisify(execFile);

export interface OcctkitInvocation {
  /** The executable to spawn. */
  command: string;
  /** Args prepended before the verb. Empty for PATH, `swift run …` for fallback. */
  baseArgs: string[];
  /** Working directory for the spawn (only set when using the sibling-repo fallback). */
  cwd?: string;
}

let cache: OcctkitInvocation | undefined;

/**
 * Invocation for a WASI build of occtkit (`OCCTMCP_OCCTKIT_WASM=<path to occtkit.wasm>`), run
 * through `wasi-run.js` on Node's own `node:wasi`. It lets the geometry verbs run where there is no
 * macOS `occtkit`, such as a Linux cloud session. The WASI build has no `run` (so no
 * `execute_script`), no `render-preview`, `graph-ml`, `graph-query` or `simplify-mesh`, and no
 * `--serve`; those tools fail with the verb's "Unknown subcommand" error.
 */
export function wasmInvocation(wasmPath: string): OcctkitInvocation {
  const runner = join(dirname(fileURLToPath(import.meta.url)), "wasi-run.js");
  return { command: process.execPath, baseArgs: ["--no-warnings", runner, wasmPath] };
}

async function onPath(): Promise<boolean> {
  try {
    await execFileAsync("which", ["occtkit"]);
    return true;
  } catch {
    return false;
  }
}

export async function resolveOcctkit(): Promise<OcctkitInvocation> {
  const wasm = process.env.OCCTMCP_OCCTKIT_WASM;
  if (wasm) {
    if (!existsSync(wasm)) {
      throw new Error(`OCCTMCP_OCCTKIT_WASM is set but ${wasm} does not exist.`);
    }
    // Not cached: the variable can change between calls (tests toggle it) and building this is cheap.
    return wasmInvocation(wasm);
  }

  if (cache) return cache;

  if (await onPath()) {
    cache = { command: "occtkit", baseArgs: [] };
    return cache;
  }

  if (existsSync(join(SCRIPTS_PROJECT, "Package.swift"))) {
    cache = {
      command: "swift",
      baseArgs: ["run", "-c", "release", "occtkit"],
      cwd: SCRIPTS_PROJECT,
    };
    return cache;
  }

  throw new Error(
    "occtkit not found. Install one of:\n" +
      "  • `make install` from ~/Projects/OCCTSwiftScripts (puts occtkit on $PATH)\n" +
      "  • clone OCCTSwiftScripts to ~/Projects/OCCTSwiftScripts so `swift run occtkit` is available\n" +
      "Requires OCCTSwiftScripts >= v0.5.0-rc.1."
  );
}
