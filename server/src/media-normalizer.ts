import { rm } from 'node:fs/promises';
import { AppError } from './errors.js';
import { runCommand } from './process.js';
import { repairH264Level } from './h264-level-repair.js';
import { MAX_H264_LEVEL, MAX_VIDEO_FPS, MAX_VIDEO_LONG_SIDE, MAX_VIDEO_SHORT_SIDE } from './media-quality.js';

export interface ProbeStream {
  index?: number;
  codec_type?: string;
  codec_name?: string;
  profile?: string;
  level?: number;
  width?: number;
  height?: number;
  pix_fmt?: string;
  sample_aspect_ratio?: string;
  display_aspect_ratio?: string;
  field_order?: string;
  avg_frame_rate?: string;
  r_frame_rate?: string;
  channels?: number;
  channel_layout?: string;
  sample_rate?: string;
  tags?: { rotate?: string };
  disposition?: { attached_pic?: number };
  side_data_list?: { side_data_type?: string; rotation?: number; displaymatrix?: string }[];
}
export interface MediaProbe { format?: { duration?: string; format_name?: string; tags?: { major_brand?: string } }; streams?: ProbeStream[] }
export type NormalizerStage = 'sourceProbe' | 'remux' | 'levelRepair' | 'audioTranscode' | 'transcode' | 'outputProbe';
export interface NormalizerTiming { stage: NormalizerStage; elapsedMs: number }
export interface CompatibleMedia { duration: number; width: number; height: number; hasAudio: boolean; mode: 'remux' | 'level-repair' | 'audio-transcode' | 'transcode' }

function rate(value: string | undefined): number {
  if (!value || !/^\d+(?:\/\d+)?$/.test(value)) return NaN;
  const [numerator, denominator = 1] = value.split('/').map(Number);
  return Number(numerator) / denominator;
}
function dimensions(video: ProbeStream): boolean {
  const { width = 0, height = 0 } = video;
  return Number.isSafeInteger(width) && Number.isSafeInteger(height) && width > 0 && height > 0 &&
    width % 2 === 0 && height % 2 === 0 && Math.max(width, height) <= MAX_VIDEO_LONG_SIDE && Math.min(width, height) <= MAX_VIDEO_SHORT_SIDE;
}
export function identityOrientation(video: ProbeStream): boolean {
  if (video.tags?.rotate !== undefined) {
    const angle = Number(video.tags.rotate);
    if (!Number.isFinite(angle) || angle % 360 !== 0) return false;
  }
  for (const side of video.side_data_list ?? []) {
    if (side.rotation !== undefined && (!Number.isFinite(side.rotation) || side.rotation % 360 !== 0)) return false;
    if (side.side_data_type === 'Display Matrix') {
      // Rotation=0 does not rule out a mirrored/skewed display matrix.
      if (!side.displaymatrix) return false;
      const matrix = side.displaymatrix.trim().split('\n').flatMap(line => {
        const values = line.slice(line.indexOf(':') + 1).trim();
        return values.split(/\s+/).map(Number);
      });
      const identity = [65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824];
      if (matrix.length !== identity.length || matrix.some((value, i) => value !== identity[i])) return false;
    }
  }
  return true;
}

export function squarePixels(probe: MediaProbe, video: ProbeStream): boolean {
  if (video.sample_aspect_ratio === '1:1') return true;
  if (video.sample_aspect_ratio !== undefined) return false;
  // ISO MP4 requires a pasp atom to declare non-square pixels. FFprobe may omit
  // SAR entirely when neither that atom nor H264 VUI declares a non-square SAR.
  // Require a genuine MP4 brand; the shared MOV/MP4 demuxer name alone is not
  // enough to infer this for QuickTime MOV, Matroska or unknown containers.
  const brand = probe.format?.tags?.major_brand ?? '';
  if (!probe.format?.format_name?.split(',').includes('mp4') ||
      !/^(?:isom|iso[2-9]|mp4[12]|avc[13]|M4V |dash|msdh|msix|cmfc|cmfs)$/.test(brand)) return false;
  if (video.display_aspect_ratio !== undefined) {
    const match = /^(\d+):(\d+)$/.exec(video.display_aspect_ratio);
    if (!match || !Number(match[1]) || !Number(match[2]) ||
        Number(match[1]) * Number(video.height) !== Number(match[2]) * Number(video.width)) return false;
  }
  return true;
}

export async function probeLocalMedia(path: string, ffprobe: string, signal: AbortSignal): Promise<MediaProbe> {
  const raw = await runCommand(ffprobe, ['-v', 'error', '-protocol_whitelist', 'file,pipe', '-show_format', '-show_streams', '-of', 'json', path], signal);
  const result = JSON.parse(raw) as MediaProbe;
  if (!result || typeof result !== 'object' || !Array.isArray(result.streams)) throw invalidMedia();
  return result;
}

/** Unknown facts deliberately choose normalization rather than optimistic copying. */
export function canCopyNativeVideo(probe: MediaProbe): boolean {
  const streams = probe.streams ?? [];
  const videos = streams.filter(stream => stream.codec_type === 'video');
  const audios = streams.filter(stream => stream.codec_type === 'audio');
  const video = videos[0];
  const duration = Number(probe.format?.duration);
  if (!video || videos.length !== 1 || audios.length > 1 || video.disposition?.attached_pic === 1 ||
      !Number.isFinite(duration) || duration <= 0 || video.codec_name !== 'h264' ||
      !['Constrained Baseline', 'Baseline', 'Main', 'High'].includes(video.profile ?? '') ||
      !Number.isFinite(video.level) || video.level! < 9 || video.level! > MAX_H264_LEVEL ||
      video.pix_fmt !== 'yuv420p' || video.field_order !== 'progressive' ||
      !squarePixels(probe, video) || !dimensions(video) || !identityOrientation(video)) return false;
  for (const value of [video.avg_frame_rate, video.r_frame_rate]) {
    const fps = rate(value);
    if (!Number.isFinite(fps) || fps <= 0 || fps > MAX_VIDEO_FPS + 0.001) return false;
  }
  return true;
}

function nativeAudio(audio: ProbeStream): boolean {
  return audio.codec_name === 'aac' && audio.profile === 'LC' &&
    [1, 2].includes(audio.channels ?? 0) && Number(audio.sample_rate) >= 8000 && Number(audio.sample_rate) <= 48000 &&
    (!audio.channel_layout || ['mono', 'stereo'].includes(audio.channel_layout));
}
export function canRemuxNative(probe: MediaProbe): boolean {
  return canCopyNativeVideo(probe) && (probe.streams ?? []).filter(stream => stream.codec_type === 'audio').every(nativeAudio);
}

export async function prepareCompatibleMedia(
  inputPath: string, outputPath: string, executables: { ffmpeg: string; ffprobe: string }, signal: AbortSignal,
  onStage?: (event: NormalizerTiming) => void,
): Promise<CompatibleMedia> {
  const timed = async <T>(stage: NormalizerStage, task: () => Promise<T>): Promise<T> => {
    const start = performance.now();
    try { return await task(); }
    finally { try { onStage?.({ stage, elapsedMs: Math.round(performance.now() - start) }); } catch { /* Observability cannot break an import. */ } }
  };
  const probe = async (path: string, stage: 'sourceProbe' | 'outputProbe'): Promise<MediaProbe> => timed(stage, async () => {
    return probeLocalMedia(path, executables.ffprobe, signal);
  });
  const source = await probe(inputPath, 'sourceProbe');
  const video = source.streams?.find(stream => stream.codec_type === 'video' && stream.disposition?.attached_pic !== 1);
  const audio = source.streams?.find(stream => stream.codec_type === 'audio');
  if (!video) throw invalidMedia();
  const map = (stream: ProbeStream | undefined, fallback: string) =>
    stream && Number.isSafeInteger(stream.index) && stream.index! >= 0 ? `0:${stream.index}` : fallback;
  const common = [
    '-nostdin', '-hide_banner', '-loglevel', 'error', '-protocol_whitelist', 'file,pipe', '-i', inputPath,
    '-map', map(video, '0:v:0'), '-map', map(audio, '0:a:0?'), '-sn', '-dn',
    '-map_metadata', '-1', '-map_chapters', '-1',
  ];
  const audioBounds = audio ? [
    ...(![1, 2].includes(audio.channels ?? 0) ? ['-ac', '2'] : []),
    ...(!(Number(audio.sample_rate) >= 8000 && Number(audio.sample_rate) <= 48000) ? ['-ar', '48000'] : []),
  ] : [];
  function validated(result: MediaProbe, mode: CompatibleMedia['mode']): CompatibleMedia {
    const finalVideo = result.streams?.find(stream => stream.codec_type === 'video');
    const finalAudio = result.streams?.find(stream => stream.codec_type === 'audio');
    const duration = Number(result.format?.duration);
    if (!finalVideo || finalVideo.codec_name !== 'h264' || !dimensions(finalVideo) ||
        !Number.isFinite(duration) || duration <= 0 || (finalAudio && finalAudio.codec_name !== 'aac') ||
        Boolean(audio) !== Boolean(finalAudio)) throw invalidMedia();
    return { duration, width: finalVideo.width!, height: finalVideo.height!, hasAudio: Boolean(finalAudio), mode };
  }
  // Some otherwise native sources overdeclare their H264 level (for example,
  // 1080p30 marked 6.2). Let FFmpeg infer it from the encoded SPS properties.
  // Only attempt this when the level is the sole compatibility failure, then
  // require the same strict native policy before accepting the copied samples.
  if (Number.isFinite(video.level) && video.level! > MAX_H264_LEVEL && video.level! <= 62 &&
      canRemuxNative({ ...source, streams: (source.streams ?? []).map(stream => stream === video ? { ...stream, level: MAX_H264_LEVEL } : stream) })) {
    try {
      await timed('levelRepair', () => repairH264Level(inputPath, outputPath, executables.ffmpeg, signal));
      const final = await probe(outputPath, 'outputProbe');
      const finalVideo = final.streams?.find(stream => stream.codec_type === 'video');
      if (!finalVideo || !canRemuxNative(final) || finalVideo.width !== video.width || finalVideo.height !== video.height ||
          (['avg_frame_rate', 'r_frame_rate'] as const).some(key => Math.abs(rate(finalVideo[key]) - rate(video[key])) > .001) ||
          Math.abs(Number(final.format?.duration) - Number(source.format?.duration)) > .15) throw invalidMedia();
      return validated(final, 'level-repair');
    } catch (error) {
      if (signal.aborted) throw signal.reason;
      await rm(outputPath, { force: true });
    }
  }
  if (canCopyNativeVideo(source)) {
    try {
      const onlyAudio = !canRemuxNative(source);
      await timed(onlyAudio ? 'audioTranscode' : 'remux', () => runCommand(executables.ffmpeg, [
        ...common, ...(onlyAudio ? ['-c:v', 'copy', '-c:a', 'aac', '-b:a', '192k', ...audioBounds] : ['-c', 'copy']),
        '-movflags', '+faststart', outputPath,
      ], signal));
      const final = await probe(outputPath, 'outputProbe');
      if (!canRemuxNative(final) || Math.abs(Number(final.format?.duration) - Number(source.format?.duration)) > 0.15) throw invalidMedia();
      return validated(final, onlyAudio ? 'audio-transcode' : 'remux');
    } catch (error) {
      if (signal.aborted) throw signal.reason;
      // An unusual container/timestamp must get the established safe path.
      await rm(outputPath, { force: true });
    }
  }
  await timed('transcode', () => runCommand(executables.ffmpeg, [
    ...common,
    '-vf', `scale='if(gte(iw,ih),min(iw,${MAX_VIDEO_LONG_SIDE}),min(iw,${MAX_VIDEO_SHORT_SIDE}))':'if(gte(iw,ih),min(ih,${MAX_VIDEO_SHORT_SIDE}),min(ih,${MAX_VIDEO_LONG_SIDE}))':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1${[video.avg_frame_rate, video.r_frame_rate].some(value => rate(value) > MAX_VIDEO_FPS + 0.001) ? `,fps=${MAX_VIDEO_FPS}` : ''}`,
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p', '-fps_mode', 'passthrough',
    ...(audio && nativeAudio(audio) ? ['-c:a', 'copy'] : ['-c:a', 'aac', '-b:a', '192k', ...audioBounds]), '-movflags', '+faststart', outputPath,
  ], signal));
  return validated(await probe(outputPath, 'outputProbe'), 'transcode');
}

function invalidMedia() { return new AppError('INVALID_MEDIA', 'The platform did not return a playable video. Import a local copy instead.', 422); }
