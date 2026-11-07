import type { Config } from './config.js';
import { classifyDownloadError, type PreparedMedia } from './downloader.js';
import { executablePath, runCommand } from './process.js';
import { AppError } from './errors.js';
import { preflightSource, type Source } from './source.js';
import { selectDirectMedia, type DirectPlan } from './direct-media.js';
import { MAX_VIDEO_LONG_SIDE, MAX_VIDEO_SHORT_SIDE, mediaSourceID, QUALITY_FORMAT_SORT } from './media-quality.js';

export interface DirectMetadata { title: string; creator?: string; duration?: number }
// A private control result, never exposed through ordinary error serialization or
// written to a cache manifest. Store cleanup still runs before the API returns it.
export class DirectDelivery extends Error {
  constructor(readonly media: DirectMetadata, readonly delivery: DirectPlan) { super('Direct media is available.'); }
}
export type MetadataInspect = (source: Source, directory: string, signal: AbortSignal) => Promise<Record<string, unknown>>;

export function createMetadataInspector(config: Config, preflight: typeof preflightSource = preflightSource, transport?: { proxyURL: string }): MetadataInspect {
  return async (input, _directory, signal) => {
    const start = performance.now();
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(new AppError('RESOLVE_TIMEOUT', 'This source is taking too long to open. Try again shortly.', 504)), Math.min(config.timeoutMs, 60_000));
    timer.unref();
    const combined = AbortSignal.any([signal, controller.signal]);
    try {
      const source = await preflight(input, combined);
      const args = ['--ignore-config', '--no-plugin-dirs', '--no-remote-components', '--no-exec', '--no-playlist', '--no-cache-dir', '--no-warnings', '--no-progress', '--no-colors',
        '--socket-timeout', '15', '--retries', '1', '--fragment-retries', '1', '--extractor-retries', '0', '--use-extractors', source.extractor,
        '--js-runtimes', `node:${process.execPath}`, '--format', 'bv*+ba/b', '--format-sort', QUALITY_FORMAT_SORT,
        // Auto-translated captions (100+ languages, unused here) can push a Short's metadata past the output limit.
        ...(input.platform === 'youtube' ? ['--extractor-args', 'youtube:skip=translated_subs'] : []),
        ...(transport ? ['--proxy', transport.proxyURL] : []), '--dump-single-json', '--skip-download', source.url];
      // YouTube Shorts can describe themselves in more than 8 MB of JSON; allow up to 32 MB here.
      const raw = await runCommand(executablePath(config.ytDlp), args, combined, 32 * 1024 * 1024);
      const info = JSON.parse(raw) as Record<string, unknown>;
      if (raw.length > 4 * 1024 * 1024) {
        const sizes = Object.entries(info).map(([key, value]) => [key, JSON.stringify(value)?.length ?? 0] as const)
          .sort((a, b) => b[1] - a[1]).slice(0, 6);
        console.info(JSON.stringify({ event: 'media.metadataSize', id: mediaSourceID(input.url), bytes: raw.length, largest: sizes }));
      }
      validateExtractedInfo(info, config);
      return info;
    } catch (error) {
      if (combined.aborted) throw combined.reason;
      throw classifyDownloadError(error);
    } finally {
      clearTimeout(timer);
      console.info(JSON.stringify({ event: 'media.stage', id: mediaSourceID(input.url), platform: input.platform, stage: 'extractDirect', elapsedMs: Math.round(performance.now() - start) }));
    }
  };
}
export function validateExtractedInfo(info: unknown, config: Config): asserts info is Record<string, unknown> {
  if (!info || typeof info !== 'object' || Array.isArray(info)) throw new AppError('SOURCE_UNAVAILABLE', 'This source could not be opened.', 422);
  const row = info as Record<string, unknown>;
  if (row.entries || ['playlist', 'multi_video'].includes(String(row._type))) throw new AppError('SINGLE_VIDEO_REQUIRED', 'Choose a single video link.', 400);
  if (row.is_live || ['is_live', 'is_upcoming', 'post_live'].includes(String(row.live_status))) throw new AppError('LIVE_VIDEO_UNSUPPORTED', 'Choose a finished video.', 422);
  if (typeof row.duration === 'number' && (!Number.isFinite(row.duration) || row.duration <= 0 || row.duration > config.maxDuration)) {
    throw new AppError('VIDEO_TOO_LONG', `Choose a video under ${Math.floor(config.maxDuration / 60)} minutes.`, 413);
  }
}
export function directFromInfo(info: Record<string, unknown>, source: Source, config: Config): DirectDelivery | undefined {
  validateExtractedInfo(info, config);
  const plan = selectDirectMedia(info, source.platform, config.maxBytes, config.maxDuration);
  if (!plan) return undefined;
  const creator = [info.uploader, info.channel, info.creator].find(value => typeof value === 'string');
  return new DirectDelivery({
    title: typeof info.title === 'string' ? info.title.slice(0, 300) : 'Video',
    ...(typeof creator === 'string' ? { creator: creator.slice(0, 100) } : {}),
    ...(typeof info.duration === 'number' ? { duration: info.duration } : {}),
  }, plan);
}
export function sanitizePreparedMedia(value: unknown, config: Config): PreparedMedia {
  const media = value as PreparedMedia;
  if (!media || typeof media.title !== 'string' || !Number.isFinite(media.duration) || media.duration <= 0 || media.duration > config.maxDuration + 0.2 ||
      !Number.isSafeInteger(media.width) || !Number.isSafeInteger(media.height) || media.width < 1 || media.height < 1 ||
      Math.max(media.width, media.height) > MAX_VIDEO_LONG_SIDE || Math.min(media.width, media.height) > MAX_VIDEO_SHORT_SIDE || typeof media.hasAudio !== 'boolean') throw new Error('Invalid private media result.');
  return { title: media.title.slice(0, 300), duration: media.duration, width: media.width, height: media.height, hasAudio: media.hasAudio,
    ...(typeof media.creator === 'string' ? { creator: media.creator.slice(0, 100) } : {}),
    ...(typeof media.thumbnailUrl === 'string' ? { thumbnailUrl: media.thumbnailUrl.slice(0, 8192) } : {}) };
}
