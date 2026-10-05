import { existsSync } from "fs";
import { tmpdir } from "os";
import { delimiter } from "path";
import { outputDir } from "./paths.js";

/**
 * Host directories preopened for the WASI occtkit (see wasi-run.ts): the scene output directory,
 * the temp directory, the current directory, and any in OCCTMCP_WASI_PREOPEN. Missing ones are
 * dropped, because node:wasi refuses a preopen that does not exist.
 */
export function preopenDirs(env: NodeJS.ProcessEnv = process.env): string[] {
  const extra = (env.OCCTMCP_WASI_PREOPEN ?? "").split(delimiter).filter((d) => d.length > 0);
  const dirs = [outputDir(), tmpdir(), process.cwd(), ...extra];
  return [...new Set(dirs)].filter((d) => existsSync(d));
}
