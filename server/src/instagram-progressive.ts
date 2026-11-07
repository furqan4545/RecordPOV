import { readdir, stat, rm, rename } from 'node:fs/promises';
import { join } from 'node:path';
import { canCopyNativeVideo, probeLocalMedia, squarePixels, identityOrientation, type MediaProbe } from './media-normalizer.js';
import { runCommand } from './process.js';
import { MAX_VIDEO_FPS, MAX_VIDEO_LONG_SIDE, MAX_VIDEO_SHORT_SIDE } from './media-quality.js';

export interface SourceFormat {
  format_id?: string;
  vcodec?: string | null;
  acodec?: string | null;
  width?: number | null;
  height?: number | null;
  fps?: number | null;
  ext?: string;
  protocol?: string;
  url?: string;
}
export interface FormatInventory extends SourceFormat {
  duration?: number;
  formats?: SourceFormat[];
  requested_formats?: SourceFormat[];
  requested_downloads?: SourceFormat[];
}
export interface TrialPlan { formatId: string; width: number; height: number; fps: number; duration: number; hasAudio: boolean }
export interface TrialTiming { stage: 'candidateDownload' | 'candidateProbe'; elapsedMs: number }

/** An opaque progressive version is a bounded candidate, never assumed native. */
export function planInstagramProgressive(info: FormatInventory, actualSelectedProbe?: MediaProbe): TrialPlan | undefined {
  const selected = info.requested_formats?.find(format => format.vcodec && format.vcodec !== 'none')
    ?? info.requested_downloads?.find(format => format.vcodec && format.vcodec !== 'none') ?? info;
  const actualVideo = actualSelectedProbe?.streams?.find(stream => stream.codec_type === 'video' && stream.disposition?.attached_pic !== 1);
  if (actualSelectedProbe && (!actualVideo || !squarePixels(actualSelectedProbe, actualVideo) || !identityOrientation(actualVideo))) return undefined;
  const codec = actualVideo?.codec_name ?? selected.vcodec;
  if (!codec || codec === 'none' || /^(?:avc[13]|h264)(?:\.|$)/i.test(codec)) return undefined;
  const width = actualVideo ? actualVideo.width : selected.width ?? info.width;
  const height = actualVideo ? actualVideo.height : selected.height ?? info.height;
  // Missing metadata may use the traditional 30fps guess only for trial planning;
  // an actual source probe is authoritative and must match the candidate.
  const fps = actualVideo ? frameRate(actualVideo.avg_frame_rate) : selected.fps ?? info.fps ?? 30;
  const duration = actualSelectedProbe ? Number(actualSelectedProbe.format?.duration) : info.duration;
  if (actualVideo && (!Number.isFinite(frameRate(actualVideo.r_frame_rate)) || frameRate(actualVideo.r_frame_rate) > MAX_VIDEO_FPS + 0.001)) return undefined;
  if (!Number.isSafeInteger(width) || !Number.isSafeInteger(height) || !width || !height || width < 0 || height < 0 ||
      width % 2 || height % 2 || Math.max(width, height) > MAX_VIDEO_LONG_SIDE || Math.min(width, height) > MAX_VIDEO_SHORT_SIDE ||
      typeof fps !== 'number' || !Number.isFinite(fps) || fps <= 0 || fps > MAX_VIDEO_FPS + 0.001 ||
      typeof duration !== 'number' || !Number.isFinite(duration) || duration <= 0) return undefined;
  const combined = [...(info.requested_formats ?? []), ...(info.requested_downloads ?? [])];
  const audio = actualSelectedProbe ? Boolean(actualSelectedProbe.streams?.some(stream => stream.codec_type === 'audio')) : combined.some(format => typeof format.acodec === 'string' && format.acodec !== 'none')
    ? true : info.acodec === 'none' ? false : typeof info.acodec === 'string' && info.acodec ? true : undefined;
  if (audio === undefined) return undefined;
  const candidate = info.formats?.find(format => {
    if (format.vcodec && format.vcodec !== 'unknown') return false;
    if (format.ext !== 'mp4' || format.protocol !== 'https' ||
        !format.format_id || !/^[A-Za-z0-9_.-]{1,128}$/.test(format.format_id) || !format.url) return false;
    if (/^(?:all|mergeall|best|worst|bestvideo|bestaudio|worstvideo|worstaudio|b|bv|ba|w|wv|wa)(?:\.|$)/i.test(format.format_id)) return false;
    if ((format.width && format.width !== width) || (format.height && format.height !== height) ||
        (format.fps && Math.abs(format.fps - fps) > 0.05)) return false;
    try { const url = new URL(format.url); return url.protocol === 'https:' && !url.username && !url.password; }
    catch { return false; }
  });
  return candidate ? { formatId: candidate.format_id!, width, height, fps, duration, hasAudio: audio } : undefined;
}

export async function tryInstagramProgressive(options: {
  info: FormatInventory; directory: string; infoPath: string; ytDlp: string; ffprobe: string;
  actualSelectedProbe?: MediaProbe;
  sharedArgs: string[]; signal: AbortSignal; maxBytes: number;
  limits?: { timeoutMs: number; maxBytes: number };
  onStage?: (event: TrialTiming) => void;
}): Promise<string | undefined> {
  const plan = planInstagramProgressive(options.info, options.actualSelectedProbe);
  if (!plan) return undefined;
  if (options.signal.aborted) throw options.signal.reason;
  const maxBytes = Math.min(options.maxBytes, 32 * 1024 * 1024, options.limits?.maxBytes ?? Infinity);
  const timeoutMs = Math.min(10_000, options.limits?.timeoutMs ?? 10_000);
  if (!Number.isSafeInteger(maxBytes) || maxBytes <= 0 || !Number.isFinite(timeoutMs) || timeoutMs <= 0) return undefined;
  const controller = new AbortController();
  const signal = AbortSignal.any([options.signal, controller.signal]);
  const timer = setTimeout(() => controller.abort(new Error('Progressive candidate budget elapsed.')), timeoutMs);
  timer.unref();
  const files = async () => (await readdir(options.directory)).filter(name => name.startsWith('candidate.'));
  const monitor = setInterval(() => {
    void files().then(async names => {
      const sizes = await Promise.all(names.map(async name => (await stat(join(options.directory, name))).size));
      if (sizes.reduce((sum, size) => sum + size, 0) > maxBytes) controller.abort(new Error('Progressive candidate byte budget exceeded.'));
    }).catch(() => {});
  }, 100);
  monitor.unref();
  const timed = async <T>(stage: TrialTiming['stage'], task: () => Promise<T>): Promise<T> => {
    const start = performance.now();
    try { return await task(); }
    finally { try { options.onStage?.({ stage, elapsedMs: Math.round(performance.now() - start) }); } catch { /* No private metadata in telemetry. */ } }
  };
  try {
    await timed('candidateDownload', () => runCommand(options.ytDlp, [
      ...options.sharedArgs, '--max-filesize', String(maxBytes), '--format', plan.formatId,
      '--output', join(options.directory, 'candidate.%(ext)s'), '--load-info-json', options.infoPath,
    ], signal));
    const names = (await files()).filter(name => /^candidate\.[a-z0-9]+$/i.test(name) && !name.endsWith('.part'));
    if (names.length !== 1) return undefined;
    const path = join(options.directory, names[0]!);
    if ((await stat(path)).size > maxBytes) return undefined;
    const probe = await timed('candidateProbe', () => probeLocalMedia(path, options.ffprobe, signal));
    if (!matchesPlan(probe, plan)) return undefined;
    if (signal.aborted) throw signal.reason;
    const destination = join(options.directory, 'source.mp4');
    await rename(path, destination);
    return destination;
  } catch (error) {
    if (options.signal.aborted) throw options.signal.reason;
    // A trial failure changes neither the requested quality nor overall budget:
    // the caller downloads its originally selected format normally instead.
    return undefined;
  } finally {
    clearTimeout(timer); clearInterval(monitor);
    await Promise.all((await files()).map(name => rm(join(options.directory, name), { force: true }))).catch(() => {});
  }
}

function matchesPlan(probe: MediaProbe, plan: TrialPlan): boolean {
  const video = probe.streams?.find(stream => stream.codec_type === 'video');
  const [numerator, denominator = 1] = (video?.avg_frame_rate ?? '').split('/').map(Number);
  const fps = Number(numerator) / denominator;
  return canCopyNativeVideo(probe) && video?.width === plan.width && video.height === plan.height &&
    Number.isFinite(fps) && Math.abs(fps - plan.fps) <= 0.05 &&
    Math.abs(Number(probe.format?.duration) - plan.duration) <= 0.2 &&
    Boolean(probe.streams?.some(stream => stream.codec_type === 'audio')) === plan.hasAudio;
}

function frameRate(value: string | undefined): number {
  const [numerator, denominator = 1] = (value ?? '').split('/').map(Number);
  return Number(numerator) / denominator;
}
