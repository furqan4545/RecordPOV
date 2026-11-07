import { resolve } from "node:path";
import { isIP } from "node:net";

export interface Config {
  host: string;
  port: number;
  cacheDir: string;
  publicBaseURL?: string;
  apiToken?: string;
  corsOrigins: string[];
  ytDlp: string;
  ffmpeg: string;
  ffprobe: string;
  maxDuration: number;
  maxBytes: number;
  timeoutMs: number;
  cacheTTL: number;
  maxCacheBytes: number;
  concurrency: number;
  queueLimit: number;
  trustedProxyIPs?: string[];
  youtubeIPCPath?: string;
  youtubeTimeoutMs?: number;
}

function numberFromEnv(name: string, fallback: number, min: number, max: number): number {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw new Error(`${name} must be an integer between ${min} and ${max}.`);
  }
  return value;
}

export function loadConfig(): Config {
  const publicBaseURL = process.env.PUBLIC_BASE_URL?.replace(/\/+$/, "");
  if (publicBaseURL) {
    const url = new URL(publicBaseURL);
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.search || url.hash || url.pathname !== "/") {
      throw new Error("PUBLIC_BASE_URL must be an HTTP(S) origin without credentials, a path or a query.");
    }
  }
  const apiToken = process.env.API_TOKEN;
  const trustedProxyIPs = (process.env.TRUSTED_PROXY_IPS || "").split(",").map((entry) => entry.trim()).filter(Boolean);
  if (trustedProxyIPs.some((entry) => isIP(entry) === 0)) {
    throw new Error("TRUSTED_PROXY_IPS must contain only exact proxy IP addresses, separated by commas.");
  }
  return {
    host: process.env.HOST || "127.0.0.1",
    port: numberFromEnv("PORT", 8787, 0, 65535),
    cacheDir: resolve(process.env.CACHE_DIR || ".cache"),
    ...(publicBaseURL ? { publicBaseURL } : {}),
    ...(apiToken ? { apiToken } : {}),
    corsOrigins: (process.env.CORS_ORIGINS || "").split(",").map((entry) => entry.trim()).filter(Boolean),
    ytDlp: process.env.YTDLP_PATH || "yt-dlp",
    ffmpeg: process.env.FFMPEG_PATH || "ffmpeg",
    ffprobe: process.env.FFPROBE_PATH || "ffprobe",
    maxDuration: numberFromEnv("MAX_DURATION_SECONDS", 3600, 1, 7200),
    maxBytes: numberFromEnv("MAX_MEDIA_BYTES", 2 * 1024 ** 3, 1024, 2 * 1024 ** 3),
    timeoutMs: numberFromEnv("RESOLVE_TIMEOUT_SECONDS", 180, 10, 900) * 1000,
    cacheTTL: numberFromEnv("CACHE_TTL_SECONDS", 86400, 60, 7 * 86400),
    maxCacheBytes: numberFromEnv("MAX_CACHE_BYTES", 8 * 1024 ** 3, 1024, 100 * 1024 ** 3),
    concurrency: numberFromEnv("MAX_CONCURRENT_DOWNLOADS", 2, 1, 8),
    queueLimit: numberFromEnv("MAX_QUEUED_DOWNLOADS", 8, 0, 100),
    trustedProxyIPs,
    ...(process.env.YOUTUBE_IPC_PATH ? { youtubeIPCPath: resolve(process.env.YOUTUBE_IPC_PATH) } : {}),
    youtubeTimeoutMs: numberFromEnv("YOUTUBE_TIMEOUT_SECONDS", 600, 60, 600) * 1000,
  };
}
