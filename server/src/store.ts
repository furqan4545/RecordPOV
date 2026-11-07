import { randomUUID } from "node:crypto";
import { mkdir, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { Config } from "./config.js";
import type { Download, PreparedMedia } from "./downloader.js";
import { AppError } from "./errors.js";
import { WorkQueue } from "./queue.js";
import { normalizeSource, type Platform, type Source } from "./source.js";
import { mediaSourceID, QUALITY_VERSION } from "./media-quality.js";

export interface MediaRecord extends PreparedMedia {
  qualityVersion: number;
  id: string;
  sourceUrl: string;
  platform: Platform;
  expiresAt: string;
  createdAt: string;
  bytes: number;
}
export interface StoredMedia { record: MediaRecord; path: string }
export const MEDIA_ID = /^[a-f0-9]{24}$/;

interface ResolveOptions { download?: Download; inspect?: (source: Source, directory: string, signal: AbortSignal) => Promise<void | Record<string, unknown>>; signal?: AbortSignal; timeoutMs?: number }
interface ImportJob {
  controller: AbortController;
  work: Promise<MediaRecord>;
  waiters: number;
  settled: boolean;
}
function cancelled(): AppError { return new AppError("REQUEST_CANCELLED", "This video import was cancelled.", 499); }

export class MediaStore {
  private readonly inFlight = new Map<string | symbol, ImportJob>();
  private readonly publishing = new Map<string, Promise<void>>();
  private readonly queue: WorkQueue;
  private pruneTimer?: ReturnType<typeof setInterval>;

  constructor(readonly config: Config, private readonly download: Download) {
    this.queue = new WorkQueue(config.concurrency, config.queueLimit);
  }

  async initialize(): Promise<void> {
    await mkdir(this.config.cacheDir, { recursive: true, mode: 0o700 });
    // Staging is never served. Interrupted work can be discarded at process start.
    await rm(join(this.config.cacheDir, ".staging"), { recursive: true, force: true });
    await mkdir(join(this.config.cacheDir, ".staging"), { recursive: true, mode: 0o700 });
    await this.prune();
    this.pruneTimer = setInterval(() => { void this.prune().catch(() => {}); }, Math.min(300_000, this.config.cacheTTL * 500));
    this.pruneTimer.unref();
  }

  dispose(): void { if (this.pruneTimer) clearInterval(this.pruneTimer); }

  async get(id: string): Promise<StoredMedia | undefined> {
    if (!MEDIA_ID.test(id)) return undefined;
    try {
      const record = JSON.parse(await readFile(join(this.config.cacheDir, id, "manifest.json"), "utf8")) as MediaRecord;
      if (record.id !== id || !Number.isFinite(Date.parse(record.expiresAt)) || Date.parse(record.expiresAt) <= Date.now()) return undefined;
      const path = join(this.config.cacheDir, id, "video.mp4");
      const file = await stat(path);
      if (!file.isFile() || file.size !== record.bytes || file.size === 0) return undefined;
      return { record, path };
    } catch { return undefined; }
  }

  async resolve(input: unknown, options?: ResolveOptions): Promise<MediaRecord> {
    options?.signal?.throwIfAborted();
    const source = normalizeSource(input);
    const id = mediaSourceID(source.url);
    const cached = await this.waitFor(this.get(id), options?.signal);
    options?.signal?.throwIfAborted();
    if (cached) return cached.record;
    // Not used by any route: v2 import routes call extract() and never prepare.
    // A phone-owned job must never inherit another phone's cancellation/transport.
    const key = options?.download || options?.inspect ? Symbol(id) : id;
    let job = this.inFlight.get(key);
    if (!job || job.controller.signal.aborted) job = this.start(key, id, source, options);
    return await this.subscribe(key, job, options?.signal);
  }

  /**
   * Links-only metadata work for v2: shares the work queue, deadline and private
   * staging directory with preparation, but never reads or writes the prepared
   * cache and never calls the downloader. Staging is removed before it settles.
   */
  async extract<T>(input: unknown, work: (source: Source, directory: string, signal: AbortSignal) => Promise<T>,
    options: { signal?: AbortSignal; timeoutMs?: number } = {}): Promise<T> {
    options.signal?.throwIfAborted();
    const source = normalizeSource(input);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(new AppError("RESOLVE_TIMEOUT", "This source is taking too long to open. Try again shortly.", 504)), options.timeoutMs ?? this.config.timeoutMs);
    timeout.unref();
    const callerAborted = () => controller.abort(options.signal?.reason ?? cancelled());
    options.signal?.addEventListener("abort", callerAborted, { once: true });
    try {
      return await this.queue.run(async () => {
        const directory = join(this.config.cacheDir, ".staging", `${mediaSourceID(source.url)}-${randomUUID()}`);
        try {
          await mkdir(directory, { recursive: true, mode: 0o700 });
          controller.signal.throwIfAborted();
          const result = await work(source, directory, controller.signal);
          controller.signal.throwIfAborted();
          return result;
        } finally {
          await rm(directory, { recursive: true, force: true });
        }
      }, controller.signal);
    } finally {
      clearTimeout(timeout);
      options.signal?.removeEventListener("abort", callerAborted);
    }
  }

  private start(key: string | symbol, id: string, source: Source, options?: ResolveOptions): ImportJob {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(new AppError("RESOLVE_TIMEOUT", "This video is taking too long to prepare. Try a shorter clip or import a local copy.", 504)), options?.download || options?.inspect ? options.timeoutMs ?? this.config.timeoutMs : this.config.timeoutMs);
    timeout.unref();
    const stopTimeout = () => clearTimeout(timeout);
    controller.signal.addEventListener("abort", stopTimeout, { once: true });
    const work = this.queue.run(async () => {
      const completed = await this.get(id);
      controller.signal.throwIfAborted();
      if (completed) return completed.record;
      const directory = join(this.config.cacheDir, ".staging", `${id}-${randomUUID()}`);
      try {
        await mkdir(directory, { recursive: true, mode: 0o700 });
        controller.signal.throwIfAborted();
        const extractedInfo = await options?.inspect?.(source, directory, controller.signal);
        controller.signal.throwIfAborted();
        const metadata = await (options?.download ?? this.download)(source, directory, controller.signal, extractedInfo || undefined);
        controller.signal.throwIfAborted();
        const file = await stat(join(directory, "video.mp4"));
        if (!file.isFile() || file.size === 0) throw new AppError("INVALID_MEDIA", "The platform did not return a playable video.", 422);
        if (file.size > Math.min(this.config.maxBytes, this.config.maxCacheBytes)) throw new AppError("VIDEO_TOO_LARGE", "This video is too large to import. Choose a smaller video.", 413);
        const createdAt = new Date();
        const record: MediaRecord = {
          ...metadata, id, qualityVersion: QUALITY_VERSION, sourceUrl: source.url, platform: source.platform,
          createdAt: createdAt.toISOString(), expiresAt: new Date(createdAt.getTime() + this.config.cacheTTL * 1000).toISOString(), bytes: file.size,
        };
        // Keep only the normalized file, never the extractor's source files or metadata.
        for (const filename of await readdir(directory)) if (filename !== "video.mp4") await rm(join(directory, filename), { recursive: true, force: true });
        controller.signal.throwIfAborted();
        await writeFile(join(directory, "manifest.json"), JSON.stringify(record), { mode: 0o600 });
        const published = await this.publish(id, directory, record, controller.signal);
        // Publication is the commit point. A later disconnect must not delete valid cache.
        await this.prune(id);
        return published;
      } finally {
        await rm(directory, { recursive: true, force: true });
      }
    }, controller.signal);
    const job: ImportJob = { controller, work, waiters: 0, settled: false };
    this.inFlight.set(key, job);
    const finish = () => {
      job.settled = true;
      clearTimeout(timeout);
      controller.signal.removeEventListener("abort", stopTimeout);
      if (this.inFlight.get(key) === job) this.inFlight.delete(key);
    };
    // Observe both outcomes even when every caller has already disconnected.
    void work.then(finish, finish);
    return job;
  }

  private subscribe(key: string | symbol, job: ImportJob, signal?: AbortSignal): Promise<MediaRecord> {
    job.waiters++;
    const phoneOwned = typeof key === "symbol";
    return new Promise((resolve, reject) => {
      let active = true;
      const detach = () => {
        if (!active) return false;
        active = false;
        signal?.removeEventListener("abort", callerAborted);
        job.controller.signal.removeEventListener("abort", jobAborted);
        if (--job.waiters === 0 && !job.settled) {
          if (this.inFlight.get(key) === job) this.inFlight.delete(key);
          job.controller.abort(typeof key === "symbol" && signal?.aborted ? signal.reason : cancelled());
        }
        return true;
      };
      const callerAborted = () => {
        // Preserve the phone worker's existing abort-and-cleanup-before-response contract.
        if (phoneOwned) { job.controller.abort(signal?.reason ?? cancelled()); return; }
        if (detach()) reject(signal?.reason ?? cancelled());
      };
      const jobAborted = () => { if (detach()) reject(job.controller.signal.reason); };
      job.work.then(
        (record) => { if (detach()) resolve(record); },
        (error: unknown) => { if (detach()) reject(error); },
      );
      signal?.addEventListener("abort", callerAborted, { once: true });
      if (!phoneOwned) job.controller.signal.addEventListener("abort", jobAborted, { once: true });
      if (signal?.aborted) callerAborted();
      else if (!phoneOwned && job.controller.signal.aborted) jobAborted();
    });
  }

  private waitFor<T>(work: Promise<T>, signal?: AbortSignal): Promise<T> {
    if (!signal) return work;
    return new Promise((resolve, reject) => {
      const aborted = () => { signal.removeEventListener("abort", aborted); reject(signal.reason); };
      signal.addEventListener("abort", aborted, { once: true });
      work.then(
        (result) => { signal.removeEventListener("abort", aborted); resolve(result); },
        (error: unknown) => { signal.removeEventListener("abort", aborted); reject(error); },
      );
      if (signal.aborted) aborted();
    });
  }

  private async publish(id: string, directory: string, record: MediaRecord, signal: AbortSignal): Promise<MediaRecord> {
    const previous = this.publishing.get(id);
    let release!: () => void;
    const published = new Promise<void>((resolve) => { release = resolve; });
    this.publishing.set(id, published);
    try {
      await previous;
      signal.throwIfAborted();
      const existing = await this.get(id);
      signal.throwIfAborted();
      if (existing) return existing.record;
      const destination = join(this.config.cacheDir, id);
      await rm(destination, { recursive: true, force: true });
      signal.throwIfAborted();
      await rename(directory, destination);
      return record;
    } finally {
      release();
      if (this.publishing.get(id) === published) this.publishing.delete(id);
    }
  }

  private async prune(protectedId?: string): Promise<void> {
    const entries = await readdir(this.config.cacheDir, { withFileTypes: true });
    const files: { id: string; bytes: number; created: number }[] = [];
    for (const entry of entries) {
      if (!entry.isDirectory() || !MEDIA_ID.test(entry.name)) continue;
      const item = await this.get(entry.name);
      if (!item) {
        if (entry.name !== protectedId) await rm(join(this.config.cacheDir, entry.name), { recursive: true, force: true });
      } else { files.push({ id: entry.name, bytes: item.record.bytes, created: Date.parse(item.record.createdAt) }); }
    }
    let total = files.reduce((sum, item) => sum + item.bytes, 0);
    for (const file of files.sort((a, b) => a.created - b.created)) {
      if (total <= this.config.maxCacheBytes || file.id === protectedId) continue;
      await rm(join(this.config.cacheDir, file.id), { recursive: true, force: true });
      total -= file.bytes;
    }
  }
}
