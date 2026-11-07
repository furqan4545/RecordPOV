import { spawn } from "node:child_process";
import { accessSync, constants } from "node:fs";
import { delimiter, isAbsolute, resolve } from "node:path";
import { AppError } from "./errors.js";

export class CommandError extends Error {
  constructor(readonly stderr: string, readonly exitCode: number | null) {
    super("Media processing command failed.");
  }
}

export function executablePath(command: string): string {
  const candidates = isAbsolute(command) || /[/\\]/u.test(command)
    ? [resolve(command)]
    : (process.env.PATH || "").split(delimiter).flatMap((directory) => {
      const base = resolve(directory, command);
      return process.platform === "win32" ? [base, `${base}.exe`, `${base}.cmd`] : [base];
    });
  for (const path of candidates) {
    try { accessSync(path, constants.X_OK); return path; } catch { /* Continue searching PATH. */ }
  }
  throw new AppError("DEPENDENCY_MISSING", "Link imports are not configured on this server yet. Import a video from your device instead.", 503);
}

export async function runCommand(command: string, args: string[], signal: AbortSignal, maxOutput = 8 * 1024 * 1024): Promise<string> {
  return await new Promise((resolve, reject) => {
    if (signal.aborted) { reject(signal.reason); return; }
    const child = spawn(command, args, { shell: false, stdio: ["ignore", "pipe", "pipe"], detached: process.platform !== "win32" });
    let stdout = "";
    let stderr = "";
    let exceeded = false;
    let forceKill: ReturnType<typeof setTimeout> | undefined;
    const killGroup = (kind: NodeJS.Signals) => {
      try {
        if (process.platform !== "win32" && child.pid) process.kill(-child.pid, kind);
        else child.kill(kind);
      } catch { /* The process may already have exited. */ }
    };
    const onAbort = () => {
      killGroup("SIGTERM");
      forceKill = setTimeout(() => killGroup("SIGKILL"), 1500);
      forceKill.unref();
    };
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) onAbort();
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (stdout.length + chunk.length > maxOutput) {
        exceeded = true;
        killGroup("SIGKILL");
      } else { stdout += chunk; }
    });
    child.stderr.on("data", (chunk: string) => { stderr = (stderr + chunk).slice(-16000); });
    child.once("error", (error: NodeJS.ErrnoException) => {
      if (error.code === "ENOENT") {
        reject(new AppError("DEPENDENCY_MISSING", "Link imports are not configured on this server yet. Import a video from your device instead.", 503));
      } else if (signal.aborted) { reject(signal.reason); }
      else { reject(error); }
    });
    child.once("close", (code) => {
      signal.removeEventListener("abort", onAbort);
      if (forceKill) clearTimeout(forceKill);
      if (signal.aborted) reject(signal.reason);
      else if (exceeded) reject(new AppError("SOURCE_UNAVAILABLE", "This video returned more information than expected. Try importing a local copy.", 422));
      else if (code === 0) resolve(stdout);
      else reject(new CommandError(stderr, code));
    });
  });
}
