import { spawn, ChildProcess } from "child_process";
import { resolveOcctkit } from "./occtkit.js";

export interface ServeEnvelope {
  ok: boolean;
  exit: number;
  stdout: string;
  stderr: string;
  error?: string;
}

interface PendingRequest {
  resolve: (env: ServeEnvelope) => void;
  reject: (err: Error) => void;
  timeoutId: NodeJS.Timeout;
}

/**
 * Long-lived `occtkit run --serve` child. Sends one JSONL request per call,
 * receives one envelope per response (post-OCCTSwiftScripts#5 framing).
 *
 * Strictly serial — the upstream serve loop processes lines one at a time,
 * so we queue requests and dispatch envelopes in FIFO order.
 *
 * On timeout: kills the child, rejects all pending requests, and lets the
 * next call respawn. On crash: same.
 *
 * On a pre-fix occtkit (envelope shape doesn't match): marks serve as
 * unsupported for the rest of the session so callers stop trying.
 */
export class ServeProcess {
  private child?: ChildProcess;
  private buffer = "";
  private queue: PendingRequest[] = [];
  private supported = true;
  private spawning?: Promise<void>;

  isSupported(): boolean {
    return this.supported;
  }

  async send(scriptPath: string, timeoutMs = 120_000): Promise<ServeEnvelope> {
    if (!this.supported) {
      throw new Error("occtkit --serve marked unsupported earlier this session");
    }
    await this.ensureChild();
    return new Promise<ServeEnvelope>((resolve, reject) => {
      const timeoutId = setTimeout(() => {
        const idx = this.queue.findIndex((r) => r.resolve === resolve);
        if (idx >= 0) this.queue.splice(idx, 1);
        this.killChild();
        reject(new Error(`occtkit --serve request timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      this.queue.push({ resolve, reject, timeoutId });
      const req = JSON.stringify({ args: [scriptPath] }) + "\n";
      this.child!.stdin!.write(req);
    });
  }

  private async ensureChild(): Promise<void> {
    if (this.child && this.child.exitCode === null && !this.child.killed) return;

    // this.spawning is set synchronously (before the first await below), so a
    // second concurrent send() that reaches this method before the spawn
    // settles observes it already set and awaits the SAME promise instead of
    // racing its own spawn. Cleared via .finally() so a later respawn (after
    // the child dies) isn't permanently blocked by a one-time flag.
    if (!this.spawning) {
      this.spawning = this.spawnChild().finally(() => {
        this.spawning = undefined;
      });
    }
    return this.spawning;
  }

  private async spawnChild(): Promise<void> {
    const oc = await resolveOcctkit();
    const args = [...oc.baseArgs, "run", "--serve"];
    const child = spawn(oc.command, args, {
      cwd: oc.cwd,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.child = child;
    this.buffer = "";

    child.stdout!.on("data", (chunk: Buffer) => this.onStdout(chunk));
    child.stderr!.on("data", (chunk: Buffer) => {
      process.stderr.write(`[occtkit serve] ${chunk}`);
    });
    child.on("exit", (code, signal) => this.onExit(code, signal));
    child.on("error", (err) => {
      process.stderr.write(`[occtkit serve] spawn error: ${err.message}\n`);
    });
  }

  private onStdout(chunk: Buffer): void {
    this.buffer += chunk.toString("utf-8");
    let nl: number;
    while ((nl = this.buffer.indexOf("\n")) !== -1) {
      const line = this.buffer.slice(0, nl);
      this.buffer = this.buffer.slice(nl + 1);
      if (line.trim() === "") continue;
      this.dispatch(line);
    }
  }

  private dispatch(line: string): void {
    const pending = this.queue.shift();
    if (!pending) {
      process.stderr.write(`[occtkit serve] unsolicited line dropped: ${line.slice(0, 200)}\n`);
      return;
    }
    clearTimeout(pending.timeoutId);

    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      pending.reject(new Error(`occtkit serve emitted unparseable line: ${line.slice(0, 200)}`));
      return;
    }
    if (
      typeof parsed !== "object" ||
      parsed === null ||
      typeof (parsed as { ok?: unknown }).ok !== "boolean"
    ) {
      // Pre-fix occtkit (or some other client) — disable for the session.
      this.supported = false;
      this.killChild();
      pending.reject(
        new Error(
          "occtkit --serve envelope is missing the `ok` field. " +
            "OCCTSwiftScripts predates the framing fix (#5) — falling back to one-shot mode."
        )
      );
      return;
    }
    pending.resolve(parsed as ServeEnvelope);
  }

  private onExit(code: number | null, signal: NodeJS.Signals | null): void {
    const failed = this.queue.splice(0);
    for (const r of failed) {
      clearTimeout(r.timeoutId);
      r.reject(new Error(`occtkit --serve exited (code=${code} signal=${signal})`));
    }
    this.child = undefined;
    this.buffer = "";
  }

  private killChild(): void {
    if (this.child && !this.child.killed) {
      this.child.kill("SIGTERM");
    }
  }

  shutdown(): void {
    if (this.child?.stdin) this.child.stdin.end();
    this.killChild();
  }
}

let singleton: ServeProcess | undefined;

export function getServeProcess(): ServeProcess {
  if (!singleton) {
    singleton = new ServeProcess();
    process.on("exit", () => singleton?.shutdown());
  }
  return singleton;
}

export function serveDisabled(): boolean {
  return process.env.OCCTMCP_OCCTKIT_NO_SERVE === "1";
}
