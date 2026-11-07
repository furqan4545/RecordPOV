import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { once } from "node:events";
import type { AddressInfo } from "node:net";
import { createApp } from "../src/app.js";
import type { Config } from "../src/config.js";
import type { Download } from "../src/downloader.js";
import { MediaStore } from "../src/store.js";

export const sampleURL = "https://www.instagram.com/reel/Datls4XT4Hy/";
export const sampleBytes = Buffer.from("0123456789abcdefghijklmnopqrstuvwxyz");
export const fakeDownload: Download = async (_source, directory) => {
  await writeFile(join(directory, "video.mp4"), sampleBytes);
  return { title: "A real test fixture", creator: "Test creator", duration: 12.5, width: 720, height: 1280, hasAudio: true };
};

export async function fixture(overrides: Partial<Config> = {}, download: Download = fakeDownload,
  deliveryOptions: Parameters<typeof createApp>[3] = {}) {
  const directory = await mkdtemp(join(tmpdir(), "roast-server-test-"));
  const config: Config = {
    host: "127.0.0.1", port: 0, cacheDir: directory, corsOrigins: [], ytDlp: "yt-dlp", ffmpeg: "ffmpeg", ffprobe: "ffprobe",
    maxDuration: 900, maxBytes: 1024 * 1024, timeoutMs: 5000, cacheTTL: 3600, maxCacheBytes: 10 * 1024 * 1024,
    concurrency: 2, queueLimit: 8, ...overrides,
  };
  const store = new MediaStore(config, download);
  await store.initialize();
  const server = createApp(config, store, undefined, deliveryOptions);
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  return {
    config, store, server, origin,
    close: async () => {
      store.dispose();
      server.closeAllConnections();
      await new Promise<void>((resolve) => server.close(() => resolve()));
      await rm(directory, { recursive: true, force: true });
    },
  };
}
