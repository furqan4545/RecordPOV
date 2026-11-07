import { randomBytes, timingSafeEqual } from "node:crypto";
import { chmod, mkdir, realpath, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import type { Config } from "./config.js";
import { loadConfig } from "./config.js";
import { createDownloader } from "./downloader.js";
import { asAppError, AppError } from "./errors.js";
import { IPCChannel } from "./youtube-ipc.js";
import { normalizeSource } from "./source.js";
import { YouTubeSocks } from "./youtube-socks.js";
import { createMetadataInspector, directFromInfo } from "./media-delivery.js";
import { noDirectMedia } from "./direct-media.js";

/** The deployment runs this process with network_mode:none, not on the API network. */
export async function startYouTubeWorker(config: Config, ipcDirectory: string) {
  await mkdir(ipcDirectory, { recursive: true, mode: 0o700 }); await chmod(ipcDirectory, 0o700);
  const auth = randomBytes(32).toString("base64url"), path = join(ipcDirectory, "worker.sock");
  await writeFile(join(ipcDirectory, "worker.key"), auth, { mode: 0o600 });
  await chmod(join(ipcDirectory, "worker.key"), 0o600); await rm(path, { force: true });
  let active = false;
  const connections = new Set<IPCChannel>();
  const server = createServer(socket => {
    if (connections.size >= 4) { socket.destroy(); return; }
    const ipc = new IPCChannel(socket); connections.add(ipc);
    const controller = new AbortController();
    let claimed = false, proxy: YouTubeSocks | undefined;
    let deadline: ReturnType<typeof setTimeout> | undefined;
    const attachment = setTimeout(() => ipc.close(), 3000); attachment.unref();
    ipc.once("closed", () => { clearTimeout(attachment); if (deadline) clearTimeout(deadline); controller.abort(new AppError("YOUTUBE_PEER_DISCONNECTED", "The YouTube connection ended. Keep the app open and try again.", 422)); proxy?.dispose(); connections.delete(ipc); });
    ipc.on("frame", (data: Buffer, binary: boolean) => {
      if (claimed) {
        try { proxy?.receive(data, binary); } catch { ipc.close(); }
        return;
      }
      // Mark synchronously, before asynchronous path validation can admit a second job.
      claimed = true; clearTimeout(attachment);
      void (async () => {
        let ownsActive = false;
        try {
          if (binary || data.length > 4096) throw new Error("Job authentication failed");
          const job = JSON.parse(data.toString("utf8")) as Record<string, unknown>;
          if (job.type !== "job" || typeof job.auth !== "string" || job.auth.length !== auth.length || !timingSafeEqual(Buffer.from(job.auth), Buffer.from(auth))) throw new Error("Job authentication failed");
          if (active) throw new AppError("SERVER_BUSY", "A YouTube video is being prepared. Try again shortly.", 503, 10);
          if (typeof job.jobId !== "string" || !/^[A-Za-z0-9_-]{24}$/.test(job.jobId) || typeof job.directoryName !== "string" || !/^[a-f0-9]{24}-[0-9a-f-]{36}$/.test(job.directoryName)) throw new Error("Invalid private job");
          if (job.mode !== undefined && job.mode !== "prepare" && job.mode !== "delivery") throw new Error("Invalid private job mode");
          const source = normalizeSource(job.sourceURL);
          if (source.platform !== "youtube" || source.url !== job.sourceURL) throw new Error("YouTube-only worker");
          active = true; ownsActive = true;
          const staging = await realpath(join(config.cacheDir, ".staging"));
          const directory = await realpath(join(staging, job.directoryName));
          if (directory !== resolve(staging, job.directoryName)) throw new Error("Invalid staging directory");
          const jobTimeout = Math.min(config.youtubeTimeoutMs ?? 600_000, Number.isSafeInteger(job.timeoutMs) && Number(job.timeoutMs) > 0 ? Number(job.timeoutMs) : 600_000);
          deadline = setTimeout(() => { controller.abort(new AppError("RESOLVE_TIMEOUT", "This YouTube video is taking too long. Try a shorter clip.", 504)); }, jobTimeout); deadline.unref();
          if (controller.signal.aborted) throw controller.signal.reason;
          proxy = new YouTubeSocks((message, isBinary) => ipc.send(message, isBinary), () => ipc.close());
          const port = await proxy.start();
          const preflight = async (requested: typeof source) => {
            if (requested.platform !== "youtube" || requested.url !== source.url) throw new Error("Invalid worker source");
            return requested;
          };
          const transport = { proxyURL: `socks5h://127.0.0.1:${port}` };
          if (job.mode === "delivery") {
            // Links only: delivery never falls through to downloading or preparing media.
            const info = await createMetadataInspector(config, preflight, transport)(source, directory, controller.signal);
            const direct = directFromInfo(info, source, config);
            if (!direct) throw noDirectMedia();
            ipc.send({ type: "direct-result", media: direct.media, delivery: direct.delivery }); return;
          }
          const download = createDownloader(config, preflight, transport);
          const media = await download(source, directory, controller.signal);
          ipc.send({ type: "result", media });
        } catch (error) {
          const failure = asAppError(error);
          try { ipc.send({ type: "failure", code: failure.code, status: failure.status, message: failure.message }); } catch { ipc.close(); }
        } finally {
          if (deadline) clearTimeout(deadline); proxy?.dispose(); if (ownsActive) active = false;
          // Keep the frame alive until the result has reached the API, then close.
          socket.end();
        }
      })();
    });
  });
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(path, () => { server.removeListener("error", reject); resolve(); }); });
  await chmod(path, 0o600);
  return { close: async () => { for (const ipc of connections) ipc.close(); await new Promise<void>(resolve => server.close(() => resolve())); await rm(path, { force: true }); } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const worker = await startYouTubeWorker(loadConfig(), process.env.YOUTUBE_IPC_PATH || "/ipc");
  console.log("YouTube worker ready on private Unix transport; no direct network.");
  for (const signal of ["SIGINT", "SIGTERM"] as const) process.once(signal, () => { void worker.close().then(() => process.exit(0)); setTimeout(() => process.exit(0), 3000).unref(); });
}
