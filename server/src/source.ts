import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { AppError } from "./errors.js";

export type Platform = "instagram" | "youtube" | "x" | "tiktok";
export interface Source {
  url: string;
  platform: Platform;
  extractor: string;
  isShortLink: boolean;
}

const INSTAGRAM = new Set(["instagram.com", "www.instagram.com", "m.instagram.com"]);
const YOUTUBE = new Set(["youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"]);
const X = new Set(["x.com", "www.x.com", "twitter.com", "www.twitter.com", "mobile.twitter.com"]);
const TIKTOK = new Set(["tiktok.com", "www.tiktok.com", "m.tiktok.com"]);
const TIKTOK_SHORT = new Set(["vm.tiktok.com", "vt.tiktok.com"]);

function invalid(): never {
  throw new AppError("UNSUPPORTED_URL", "Paste a link to a single Instagram, YouTube, X or TikTok video.", 400);
}

export function normalizeSource(input: unknown): Source {
  if (typeof input !== "string" || input.length > 2048 || input.length === 0) return invalid();
  let url: URL;
  try { url = new URL(input.trim()); } catch { return invalid(); }
  if (url.protocol !== "https:" || url.username || url.password || url.port || /[\u0000-\u001f\u007f]/u.test(input)) return invalid();
  const host = url.hostname;
  const path = url.pathname;
  if (INSTAGRAM.has(host)) {
    const match = /^\/(reel|reels|p|tv)\/([A-Za-z0-9_-]{3,64})\/?$/.exec(path);
    if (!match) return invalid();
    const type = match[1] === "reels" ? "reel" : match[1];
    return { url: `https://www.instagram.com/${type}/${match[2]}/`, platform: "instagram", extractor: "instagram.*", isShortLink: false };
  }
  if (YOUTUBE.has(host) || host === "youtu.be" || host === "www.youtu.be") {
    const id = host.endsWith("youtu.be")
      ? /^\/([A-Za-z0-9_-]{11})\/?$/.exec(path)?.[1]
      : path === "/watch" ? url.searchParams.get("v") : /^\/(?:shorts|live)\/([A-Za-z0-9_-]{11})\/?$/.exec(path)?.[1];
    if (!id || !/^[A-Za-z0-9_-]{11}$/.test(id)) return invalid();
    return { url: `https://www.youtube.com/watch?v=${id}`, platform: "youtube", extractor: "youtube.*", isShortLink: false };
  }
  if (X.has(host)) {
    const match = /^\/([A-Za-z0-9_]{1,30}\/status|i\/web\/status)\/(\d{5,30})\/?$/.exec(path);
    if (!match) return invalid();
    return { url: `https://x.com/${match[1]}/${match[2]}`, platform: "x", extractor: "twitter.*", isShortLink: false };
  }
  if (TIKTOK.has(host)) {
    const match = /^\/@([A-Za-z0-9_.]{1,50})\/video\/(\d{5,30})\/?$/.exec(path);
    if (!match) return invalid();
    return { url: `https://www.tiktok.com/@${match[1]}/video/${match[2]}`, platform: "tiktok", extractor: "tiktok.*", isShortLink: false };
  }
  if (TIKTOK_SHORT.has(host) && /^\/[A-Za-z0-9]{3,40}\/?$/.test(path)) {
    return { url: `https://${host}${path.endsWith("/") ? path : `${path}/`}`, platform: "tiktok", extractor: "tiktok.*", isShortLink: true };
  }
  return invalid();
}

/** Defense in depth for platform lookups; arbitrary hosts never reach an extractor. */
export function isPublicAddress(address: string): boolean {
  if (isIP(address) === 4) {
    const [a = 0, b = 0] = address.split(".").map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && (b === 168 || b === 0)) ||
      (a === 100 && b >= 64 && b <= 127) || (a === 198 && (b === 18 || b === 19 || b === 51)) ||
      (a === 203 && b === 0) || (a === 192 && b === 88));
  }
  if (isIP(address) === 6) {
    const lower = address.toLowerCase();
    if (lower.startsWith("::ffff:")) return isPublicAddress(lower.slice(7));
    return /^[23]/.test(lower) && !/^2001:(?:db8|0:|10:)/.test(lower) && !lower.startsWith("2002:");
  }
  return false;
}

async function assertPublicHost(url: URL): Promise<void> {
  let addresses;
  try { addresses = await lookup(url.hostname, { all: true }); }
  catch { throw new AppError("SOURCE_UNAVAILABLE", "This platform could not be reached. Try again later or import a video from your device.", 422); }
  if (addresses.length === 0 || addresses.some(({ address }) => !isPublicAddress(address))) {
    throw new AppError("UNSAFE_SOURCE", "This video link cannot be opened safely.", 400);
  }
}

export async function preflightSource(source: Source, signal: AbortSignal): Promise<Source> {
  let current = source;
  for (let attempt = 0; attempt < 5; attempt++) {
    const url = new URL(current.url);
    await assertPublicHost(url);
    if (!current.isShortLink) return current;
    let response: Response;
    try {
      response = await fetch(url, { method: "HEAD", redirect: "manual", signal, headers: { "User-Agent": "Roast/0.1" } });
    } catch (error) {
      if (signal.aborted) throw error;
      throw new AppError("SOURCE_UNAVAILABLE", "The short video link could not be opened. Copy the full video link instead.", 422);
    }
    await response.body?.cancel();
    if (response.status === 429) throw new AppError("PLATFORM_RATE_LIMITED", "TikTok is limiting requests right now. Try again later or import a local video.", 429, 60);
    const location = response.headers.get("location");
    if (response.status >= 300 && response.status < 400 && location) {
      const next = normalizeSource(new URL(location, url).href);
      if (next.platform !== "tiktok") throw new AppError("UNSAFE_SOURCE", "This short link does not lead to a TikTok video.", 400);
      current = next;
      continue;
    }
    throw new AppError("SOURCE_UNAVAILABLE", "Copy the full TikTok video link, or import a video from your device.", 422);
  }
  throw new AppError("SOURCE_UNAVAILABLE", "This short link redirects too many times. Copy the full video link instead.", 422);
}
