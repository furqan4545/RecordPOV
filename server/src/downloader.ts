import { readdir, stat, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import type { Config } from "./config.js";
import { AppError } from "./errors.js";
import { CommandError, executablePath, runCommand } from "./process.js";
import { preflightSource, type Source, type Platform } from "./source.js";
import { prepareCompatibleMedia, probeLocalMedia, type NormalizerStage } from "./media-normalizer.js";
import { tryInstagramProgressive, type FormatInventory } from "./instagram-progressive.js";
import { mediaSourceID, QUALITY_FORMAT_SORT } from "./media-quality.js";

/** Source, intermediate and normalized files share one job directory; never stage more than about 6 GiB. */
export const MAX_STAGING_BYTES = 6 * 1024 ** 3;

export interface PreparedMedia {
  title: string;
  creator?: string;
  duration: number;
  thumbnailUrl?: string;
  width: number;
  height: number;
  hasAudio: boolean;
}
export type Download = (source: Source, directory: string, signal: AbortSignal, extractedInfo?: Record<string, unknown>) => Promise<PreparedMedia>;

interface ExtractorInfo extends FormatInventory {
  _type?: string;
  entries?: unknown[];
  title?: string;
  uploader?: string;
  channel?: string;
  creator?: string;
  duration?: number;
  is_live?: boolean;
  live_status?: string;
  thumbnail?: string;
}
export interface DownloadTiming {
  event: "media.stage";
  id: string;
  platform: Platform;
  stage: "preflight" | "extract" | "download" | "selectedProbe" | "candidateDownload" | "candidateProbe" | "total" | NormalizerStage;
  elapsedMs: number;
}
export type TimingHook = (event: DownloadTiming) => void;
interface DownloaderOptions {
  // Private output from this job's metadata inspection. Revalidate it before
  // persisting the owner-only load-info file or starting a media download.
  extractedInfo?: Record<string, unknown>;
}

export function classifyDownloadError(error: unknown): AppError {
  if (error instanceof AppError) return error;
  if (!(error instanceof CommandError)) return new AppError("SOURCE_UNAVAILABLE", "This video could not be opened. Try again later or import a copy from your device.", 422);
  const message = error.stderr.toLowerCase();
  if (/429|rate.?limit|too many requests/.test(message)) return new AppError("PLATFORM_RATE_LIMITED", "This platform is limiting requests right now. Try again later or import a local video.", 429, 60);
  if (/not a bot|captcha|bot[\s-]?challenge/.test(message)) {
    return new AppError("SOURCE_PLATFORM_BLOCKED", "This platform blocked the download. Choose a video from your device instead.", 422);
  }
  if (/login|log in|sign in|cookies|private|authentication|not authorized|403|restricted|challenge|captcha/.test(message)) {
    return new AppError("SOURCE_RESTRICTED", "This video is not publicly accessible to the server. Import a copy from your device instead.", 422);
  }
  if (/not found|unavailable|removed|deleted|404|no video|no media/.test(message)) return new AppError("SOURCE_UNAVAILABLE", "This link does not contain an accessible video. Check the link or import a local copy.", 422);
  if (/max.?filesize|larger than/.test(message)) return new AppError("VIDEO_TOO_LARGE", "This video is too large to import. Choose a smaller video or import a local copy.", 413);
  return new AppError("SOURCE_UNAVAILABLE", "This platform could not provide the video. Try again later or import a copy from your device.", 422);
}

function safeThumbnail(value?: string): string | undefined {
  if (!value || value.length > 8192) return undefined;
  try {
    const url = new URL(value);
    return url.protocol === "https:" && !url.username && !url.password ? url.href : undefined;
  } catch { return undefined; }
}

export function createDownloader(config: Config, preflight: typeof preflightSource = preflightSource,
  transport?: { proxyURL: string }, onTiming: TimingHook = event => console.info(JSON.stringify(event)), options: DownloaderOptions = {}): Download {
  return async (input, directory, signal, extractedInfo) => {
    const totalStart = performance.now();
    const id = mediaSourceID(input.url);
    const emit = (stage: DownloadTiming["stage"], elapsedMs: number) => {
      try { onTiming({ event: "media.stage", id, platform: input.platform, stage, elapsedMs: Math.round(elapsedMs) }); }
      catch { /* Telemetry must not change the result or expose process output. */ }
    };
    const timed = async <T>(stage: DownloadTiming["stage"], task: () => Promise<T>): Promise<T> => {
      const start = performance.now();
      try { return await task(); } finally { emit(stage, performance.now() - start); }
    };
    const infoPath = join(directory, "extractor-info.json");
    const localController = new AbortController();
    const combined = AbortSignal.any([signal, localController.signal]);
    const monitor = setInterval(() => {
      void readdir(directory).then(async (files) => {
        const sizes = await Promise.all(files.map(async (file) => (await stat(join(directory, file))).size));
        if (sizes.reduce((sum, size) => sum + size, 0) > Math.min(config.maxBytes * 3, MAX_STAGING_BYTES)) {
          localController.abort(new AppError("VIDEO_TOO_LARGE", "This video is too large to import. Choose a smaller video.", 413));
        }
      }).catch(() => {});
    }, 1000);
    monitor.unref();
    try {
      const ytDlp = executablePath(config.ytDlp);
      const ffmpeg = executablePath(config.ffmpeg);
      const ffprobe = executablePath(config.ffprobe);
      const source = await timed("preflight", () => preflight(input, combined));
      const shared = [
        "--ignore-config", "--no-plugin-dirs", "--no-remote-components", "--no-exec", "--no-playlist", "--no-warnings", "--no-progress",
        "--no-colors", "--socket-timeout", "15", "--retries", "1", "--fragment-retries", "1", "--extractor-retries", "0",
        "--use-extractors", source.extractor, "--js-runtimes", `node:${process.execPath}`,
      ];
      if (transport) shared.push("--proxy", transport.proxyURL);
      const selection = ["--format", "bv*+ba/b", "--format-sort", QUALITY_FORMAT_SORT];
      const inspected = extractedInfo ?? options.extractedInfo;
      const rawInfo = inspected === undefined
        ? await timed("extract", () => runCommand(ytDlp, [...shared, ...selection, "--dump-single-json", "--skip-download", source.url], combined))
        : JSON.stringify(inspected);
      let info: ExtractorInfo;
      try { info = inspected === undefined ? JSON.parse(rawInfo) as ExtractorInfo : inspected as ExtractorInfo; }
      catch { throw new AppError("SOURCE_UNAVAILABLE", "The platform returned an unreadable video. Import a local copy instead.", 422); }
      if (!info || typeof info !== "object" || Array.isArray(info)) throw new AppError("SOURCE_UNAVAILABLE", "The platform returned an unreadable video. Import a local copy instead.", 422);
      if (info._type === "playlist" || info._type === "multi_video" || info.entries) {
        throw new AppError("SINGLE_VIDEO_REQUIRED", "Choose a single video link, rather than a carousel or playlist.", 400);
      }
      if (info.is_live || ["is_live", "is_upcoming", "post_live"].includes(info.live_status || "")) {
        throw new AppError("LIVE_VIDEO_UNSUPPORTED", "Choose a finished video. Live streams cannot be imported.", 422);
      }
      if (typeof info.duration === "number" && (!Number.isFinite(info.duration) || info.duration <= 0 || info.duration > config.maxDuration)) {
        throw new AppError("VIDEO_TOO_LONG", `Choose a video under ${Math.floor(config.maxDuration / 60)} minutes, or import a local copy.`, 413);
      }
      // Reuse this job's private extractor output rather than request the page,
      // player and format list a second time. Never serve/cache/log this file.
      await writeFile(infoPath, rawInfo, { mode: 0o600, flag: "wx" });
      await timed("download", () => runCommand(ytDlp, [
        ...shared, "--max-filesize", String(config.maxBytes),
        ...selection,
        "--merge-output-format", "mp4", "--ffmpeg-location", ffmpeg,
        "--output", join(directory, "source.%(ext)s"), "--load-info-json", infoPath,
      ], combined));
      const sourceFiles = (await readdir(directory)).filter((file) => /^source\.[a-z0-9]+$/i.test(file) && !file.endsWith(".part"));
      if (sourceFiles.length !== 1) throw new AppError("SOURCE_UNAVAILABLE", "The platform did not provide a complete video. Import a local copy instead.", 422);
      let sourcePath = join(directory, sourceFiles[0]!);
      if ((await stat(sourcePath)).size > config.maxBytes) throw new AppError("VIDEO_TOO_LARGE", "This video is too large to import. Choose a smaller video.", 413);
      const selectedProbe = await timed("selectedProbe", () => probeLocalMedia(sourcePath, ffprobe, combined));
      if (Number(selectedProbe.format?.duration) > config.maxDuration + 0.2) {
        throw new AppError("VIDEO_TOO_LONG", `Choose a video under ${Math.floor(config.maxDuration / 60)} minutes.`, 413);
      }
      // Platform metadata can omit duration/FPS. The already downloaded source
      // is the quality/duration/audio baseline, retained until a proven match.
      if (source.platform === "instagram") {
        const progressive = await tryInstagramProgressive({
          info, actualSelectedProbe: selectedProbe, directory, infoPath, ytDlp, ffprobe,
          sharedArgs: [...shared, "--ffmpeg-location", ffmpeg], signal: combined, maxBytes: config.maxBytes,
          onStage: event => emit(event.stage, event.elapsedMs),
        });
        if (progressive) sourcePath = progressive;
      }
      const { duration, width, height, hasAudio } = await prepareCompatibleMedia(sourcePath, join(directory, "video.mp4"),
        { ffmpeg, ffprobe }, combined, event => emit(event.stage, event.elapsedMs));
      if (duration > config.maxDuration + 0.2) throw new AppError("VIDEO_TOO_LONG", `Choose a video under ${Math.floor(config.maxDuration / 60)} minutes.`, 413);
      const thumbnailUrl = safeThumbnail(info.thumbnail);
      const creator = (info.uploader || info.channel || info.creator)?.slice(0, 100);
      return {
        title: (info.title || "Untitled video").slice(0, 300), duration,
        width, height, hasAudio,
        ...(creator ? { creator } : {}), ...(thumbnailUrl ? { thumbnailUrl } : {}),
      };
    } catch (error) {
      if (combined.aborted && combined.reason instanceof AppError) throw combined.reason;
      throw classifyDownloadError(error);
    } finally {
      clearInterval(monitor);
      await rm(infoPath, { force: true }).catch(() => {});
      emit("total", performance.now() - totalStart);
    }
  };
}
