import { timingSafeEqual } from "node:crypto";
import { createReadStream } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import type { Config } from "./config.js";
import { AppError, asAppError } from "./errors.js";
import { parseRange } from "./range.js";
import { MediaStore, MEDIA_ID } from "./store.js";
import { clientAddress } from "./client-address.js";
import type { YouTubeBroker } from "./youtube-broker.js";
import { normalizeSource } from "./source.js";
import { createMetadataInspector, DirectDelivery, directFromInfo, type MetadataInspect } from "./media-delivery.js";
import { noDirectMedia, validateDirectMedia, type DirectLookup } from "./direct-media.js";
import { mediaSourceID, QUALITY_VERSION } from "./media-quality.js";

function json(response: ServerResponse, status: number, payload: unknown): void {
  const body = JSON.stringify(payload);
  response.writeHead(status, { "Content-Type": "application/json; charset=utf-8", "Content-Length": Buffer.byteLength(body), "Cache-Control": "no-store" });
  response.end(body);
}

async function readBody(request: IncomingMessage): Promise<unknown> {
  if (!/^application\/json(?:\s*;.*)?$/i.test(request.headers["content-type"] || "")) {
    request.resume();
    throw new AppError("JSON_REQUIRED", "Send the video link as JSON.", 415);
  }
  return await new Promise((resolve, reject) => {
    const parts: Buffer[] = [];
    let size = 0;
    let settled = false;
    request.on("data", (part: Buffer) => {
      if (settled) return;
      size += part.length;
      if (size > 4096) {
        settled = true;
        reject(new AppError("REQUEST_TOO_LARGE", "This request is too large. Paste only the video link.", 413));
      } else parts.push(part);
    });
    request.once("end", () => {
      if (settled) return;
      settled = true;
      try { resolve(JSON.parse(Buffer.concat(parts).toString("utf8"))); }
      catch { reject(new AppError("INVALID_JSON", "Paste a valid video link.", 400)); }
    });
    request.once("error", (error) => { if (!settled) { settled = true; reject(error); } });
  });
}

function authorized(request: IncomingMessage, config: Config): boolean {
  if (!config.apiToken) return true;
  const actual = Buffer.from(request.headers.authorization || "");
  const expected = Buffer.from(`Bearer ${config.apiToken}`);
  return actual.length === expected.length && timingSafeEqual(actual, expected);
}

function requestOrigin(request: IncomingMessage, config: Config): string {
  if (config.publicBaseURL) return config.publicBaseURL;
  const host = request.headers.host;
  if (!host || /[\s/@\\?#]/u.test(host)) throw new AppError("INVALID_HOST", "The server address is not valid.", 400);
  let origin: URL;
  try { origin = new URL(`http://${host}`); }
  catch { throw new AppError("INVALID_HOST", "The server address is not valid.", 400); }
  if (!origin.hostname || origin.pathname !== "/") throw new AppError("INVALID_HOST", "The server address is not valid.", 400);
  return origin.origin;
}

export function createApp(config: Config, store: MediaStore, youtube?: YouTubeBroker,
  deliveryOptions: { inspect?: MetadataInspect; lookup?: DirectLookup } = {}) {
  const inspect = deliveryOptions.inspect ?? createMetadataInspector(config);
  const rateLimits = new Map<string, { count: number; until: number }>();
  const server = createServer((request, response) => {
    const requestStarted = performance.now();
    response.setHeader("X-Content-Type-Options", "nosniff");
    response.setHeader("Referrer-Policy", "no-referrer");
    const origin = request.headers.origin;
    if (origin && config.corsOrigins.includes(origin)) {
      response.setHeader("Access-Control-Allow-Origin", origin);
      response.setHeader("Vary", "Origin");
      response.setHeader("Access-Control-Allow-Methods", "GET, HEAD, POST, OPTIONS");
      response.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization, Range, X-YouTube-Session-Token");
      response.setHeader("Access-Control-Expose-Headers", "Content-Range, Accept-Ranges, Content-Length");
    }
    void (async () => {
      const url = new URL(request.url || "/", "http://localhost");
      if (request.method === "GET" && url.pathname === "/health") {
        json(response, 200, { status: "ok", service: "roast-media", version: "0.1.0" });
        return;
      }
      if (request.method === "OPTIONS" && origin && config.corsOrigins.includes(origin)) {
        response.writeHead(204); response.end(); return;
      }
      if (!authorized(request, config)) throw new AppError("UNAUTHORIZED", "The media server needs a valid access token.", 401);
      if (request.method === "POST" && ["/v1/media/resolve", "/v2/media/resolve", "/v1/media/youtube/sessions"].includes(url.pathname)) {
        const key = clientAddress(request, config);
        const now = Date.now();
        if (rateLimits.size > 5000) for (const [ip, value] of rateLimits) if (value.until <= now) rateLimits.delete(ip);
        const previous = rateLimits.get(key);
        const limit = previous && previous.until > now ? previous : { count: 0, until: now + 60_000 };
        rateLimits.set(key, limit);
        if (++limit.count > 20) throw new AppError("RATE_LIMITED", "Please wait a moment before opening another video.", 429, Math.ceil((limit.until - now) / 1000));
        // Links-only imports: v1 prepared the video on the server and is retired.
        if (url.pathname === "/v1/media/resolve") {
          request.resume();
          throw new AppError("UPDATE_REQUIRED", "Update RecordPOV to import videos.", 410);
        }
        const body = await readBody(request);
        if (!body || typeof body !== "object" || Array.isArray(body)) throw new AppError("INVALID_REQUEST", "Paste a valid video link.", 400);
        const publicOrigin = requestOrigin(request, config);
        const input = body as { url?: unknown; youtubeSessionId?: unknown };
        if (url.pathname === "/v1/media/youtube/sessions") {
          if (!youtube) throw new AppError("YOUTUBE_WORKER_UNAVAILABLE", "YouTube preparation is restarting. Try again shortly.", 503, 10);
          json(response, 200, youtube.create(input.url, key, publicOrigin)); return;
        }
        const source = normalizeSource(input.url);
        const assisted = source.platform === "youtube" && youtube;
        if (!assisted && input.youtubeSessionId !== undefined) throw new AppError("YOUTUBE_URL_REQUIRED", "Choose one YouTube video.", 400);
        const claim = assisted ? youtube.claim(input.youtubeSessionId, request.headers["x-youtube-session-token"], input.url, key) : undefined;
        const caller = new AbortController();
        const cancel = () => {
          caller.abort(new AppError("REQUEST_CANCELLED", "This video import was cancelled.", 499));
          claim?.cancel();
        };
        const responseClosed = () => { if (!response.writableFinished) cancel(); };
        request.once("aborted", cancel); response.once("close", responseClosed);
        if (request.aborted || response.destroyed) cancel();
        // v2 only extracts metadata and returns platform links; it never reads the
        // prepared cache, downloads, converts or stores the video.
        const validated = async (candidate: DirectDelivery, signal: AbortSignal) => {
          const delivery = await validateDirectMedia(candidate.delivery, source.platform, config.maxBytes, config.maxDuration, deliveryOptions.lookup);
          signal.throwIfAborted();
          return new DirectDelivery(candidate.media, delivery);
        };
        let direct: DirectDelivery;
        try {
          direct = claim
            ? await store.extract(input.url, async (requested, directory, signal) => validated(await claim.deliver(requested, directory, signal), signal),
              { signal: claim.signal, timeoutMs: config.youtubeTimeoutMs ?? 600_000 })
            : await store.extract(input.url, async (requested, directory, signal) => {
              const info = await inspect(requested, directory, signal);
              const candidate = directFromInfo(info, requested, config);
              if (!candidate) throw noDirectMedia();
              return validated(candidate, signal);
            }, { signal: caller.signal });
        } finally { request.removeListener("aborted", cancel); response.removeListener("close", responseClosed); claim?.finish(); }
        if (response.destroyed) return;
        const id = mediaSourceID(source.url);
        const elapsedMs = Math.round(performance.now() - requestStarted);
        response.setHeader("Server-Timing", `resolve;dur=${elapsedMs}`);
        console.info(JSON.stringify({ event: "media.resolve", id, platform: source.platform, elapsedMs }));
        json(response, 200, { id, ...direct.media, qualityVersion: QUALITY_VERSION, sourceUrl: source.url, platform: source.platform,
          expiresAt: new Date(Date.now() + 300_000).toISOString(), delivery: direct.delivery });
        return;
      }
      const match = /^\/v1\/media\/([a-f0-9]{24})\/file$/.exec(url.pathname);
      if (match && ["GET", "HEAD"].includes(request.method || "")) {
        const id = match[1]!;
        if (!MEDIA_ID.test(id)) throw new AppError("NOT_FOUND", "This video is not available.", 404);
        const media = await store.get(id);
        if (!media) throw new AppError("MEDIA_EXPIRED", "This imported video has expired. Open the original link again.", 404);
        const { record, path } = media;
        const etag = `"${id}-${record.bytes}"`;
        response.setHeader("Content-Type", "video/mp4");
        response.setHeader("Accept-Ranges", "bytes");
        response.setHeader("ETag", etag);
        response.setHeader("Last-Modified", new Date(record.createdAt).toUTCString());
        response.setHeader("Cache-Control", `private, max-age=${Math.max(0, Math.floor((Date.parse(record.expiresAt) - Date.now()) / 1000))}`);
        response.setHeader("Content-Disposition", `inline; filename="take-${id}.mp4"`);
        if (request.headers["if-none-match"] === etag && !request.headers.range) {
          response.writeHead(304); response.end(); return;
        }
        const header = request.headers.range;
        let start = 0;
        let end = record.bytes - 1;
        let partial = false;
        if (header && (!request.headers["if-range"] || request.headers["if-range"] === etag)) {
          try { ({ start, end } = parseRange(header, record.bytes)); partial = true; }
          catch (error) { response.setHeader("Content-Range", `bytes */${record.bytes}`); throw error; }
        }
        response.setHeader("Content-Length", end - start + 1);
        if (partial) response.setHeader("Content-Range", `bytes ${start}-${end}/${record.bytes}`);
        response.writeHead(partial ? 206 : 200);
        if (request.method === "HEAD") { response.end(); return; }
        const file = createReadStream(path, { start, end });
        response.once("close", () => file.destroy());
        file.once("error", () => response.destroy());
        file.pipe(response);
        return;
      }
      throw new AppError("NOT_FOUND", "This endpoint does not exist.", 404);
    })().catch((error: unknown) => {
      if (response.headersSent || response.destroyed) return;
      const failure = asAppError(error);
      if (failure.retryAfter) response.setHeader("Retry-After", failure.retryAfter);
      json(response, failure.status, { error: { code: failure.code, message: failure.message } });
    });
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5000;
  server.maxHeadersCount = 50;
  youtube?.attach(server);
  return server;
}
