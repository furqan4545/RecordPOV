import { lookup as systemLookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { AppError } from './errors.js';
import { isPublicAddress, type Platform } from './source.js';
import { MAX_H264_LEVEL, MAX_VIDEO_FPS, MAX_VIDEO_LONG_SIDE, MAX_VIDEO_SHORT_SIDE } from './media-quality.js';

export interface DirectAsset { role: 'muxed' | 'video' | 'audio'; url: string; headers: Record<string, string> }
export type VideoCodec = 'h264' | 'hevc' | 'vp9' | 'av1' | 'unknown';
export type AudioCodec = 'aac-lc' | 'he-aac' | 'aac' | 'unknown' | 'none';
export interface DirectExpected {
  duration?: number; width?: number; height?: number; fps?: number; hasAudio: boolean;
  videoCodec?: VideoCodec; audioCodec?: AudioCodec;
}
export interface DirectAssetSet { assets: DirectAsset[]; expected: DirectExpected }
/**
 * Links-only hybrid plan. `assets` is the primary set; `convert` tells the phone
 * that the primary is the original and must be converted on the device to
 * H.264 + AAC-LC. `fallback` is the best directly playable set (or an opaque
 * progressive MP4) the phone may download instead when it cannot use the original.
 */
export interface DirectPlan extends DirectAssetSet {
  kind: 'direct'; maxBytes: number; convert: boolean; fallback?: DirectAssetSet;
}
export type DirectLookup = (host: string) => Promise<{ address: string; family: number }[]>;
type Row = Record<string, unknown>;
const roots: Record<Platform, string[]> = {
  instagram: ['cdninstagram.com', 'fbcdn.net'], youtube: ['googlevideo.com'], x: [],
  tiktok: ['tiktokcdn.com', 'tiktokcdn-us.com', 'tiktokcdn-eu.com', 'tiktokv.com', 'ibytedtos.com', 'byteoversea.com'],
};
const exact: Record<Platform, string[]> = { instagram: [], youtube: [], x: ['video.twimg.com'], tiktok: ['v16-webapp-prime.tiktok.com', 'v19-webapp-prime.tiktok.com'] };
const object = (v: unknown): Row | undefined => v && typeof v === 'object' && !Array.isArray(v) ? v as Row : undefined;
const finite = (v: unknown): number | undefined => typeof v === 'number' && Number.isFinite(v) ? v : undefined;
const positive = (v: unknown): number | undefined => { const n = finite(v); return n !== undefined && n > 0 ? n : undefined; };
const within = (host: string, root: string) => host === root || host.endsWith(`.${root}`);
export function directCDNURL(value: unknown, platform: Platform): string | undefined {
  if (typeof value !== 'string' || value.length > 16_384 || /[\x00-\x20\x7f\\]/.test(value)) return undefined;
  try {
    const url = new URL(value), host = url.hostname;
    if (url.protocol !== 'https:' || (url.port && url.port !== '443') || url.username || url.password || url.hash ||
        isIP(host) || host.endsWith('.') || !host.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label)) ||
        !(exact[platform].includes(host) || roots[platform].some(root => within(host, root))) ||
        /\.(?:m3u8|mpd)(?:$|\/)/i.test(url.pathname)) return undefined;
    return url.href;
  } catch { return undefined; }
}

function platformPage(value: string, platform: Platform, originOnly: boolean): boolean {
  try {
    const url = new URL(value);
    const pageRoots: Record<Platform, string[]> = { instagram: ['instagram.com'], youtube: ['youtube.com', 'youtu.be'], x: ['x.com', 'twitter.com'], tiktok: ['tiktok.com'] };
    return url.protocol === 'https:' && !url.username && !url.password && !url.port && !url.hash &&
      pageRoots[platform].some(root => within(url.hostname, root)) && (!originOnly || value === url.origin);
  } catch { return false; }
}
function headersFor(info: Row, format: Row, platform: Platform): Record<string, string> | undefined {
  const combined = { ...object(info.http_headers), ...object(format.http_headers) };
  const result: Record<string, string> = {};
  const allowed: Record<string, string> = { 'user-agent': 'User-Agent', referer: 'Referer', origin: 'Origin', accept: 'Accept' };
  if (Object.keys(combined).length > 64) return undefined;
  for (const [name, value] of Object.entries(combined)) {
    const canonical = allowed[name.toLowerCase()];
    if (!canonical) continue; // Cookie/Authorization/Host are never forwarded.
    if (typeof value !== 'string' || !value || value.length > (canonical === 'Referer' ? 2048 : 512) || /[^\x20-\x7e]/.test(value) ||
        (canonical === 'Referer' && !platformPage(value, platform, false)) ||
        (canonical === 'Origin' && !platformPage(value, platform, true)) ||
        (result[canonical] !== undefined && result[canonical] !== value)) return undefined;
    result[canonical] = value;
  }
  return result;
}
function h264(value: unknown): boolean {
  if (typeof value !== 'string' || !/^(?:h264|avc[13](?:\.[0-9a-f]+)?)$/i.test(value)) return false;
  const profile = /^avc[13]\.([0-9a-f]{2})/i.exec(value)?.[1];
  const level = /^avc[13]\.[0-9a-f]{4}([0-9a-f]{2})$/i.exec(value)?.[1];
  return (!profile || [66, 77, 100].includes(parseInt(profile, 16))) && (!level || parseInt(level, 16) <= MAX_H264_LEVEL);
}
function aac(value: unknown): boolean { return typeof value === 'string' && /^(?:aac|mp4a(?:\.40\.2)?)$/i.test(value); }
const VIDEO_CODECS: readonly VideoCodec[] = ['h264', 'hevc', 'vp9', 'av1', 'unknown'];
const AUDIO_CODECS: readonly AudioCodec[] = ['aac-lc', 'he-aac', 'aac', 'unknown', 'none'];
// MPEG-4 Audio object types that are AAC profiles (ISO/IEC 14496-3), plus MPEG-2 AAC (0x66-0x68).
const AAC_OBJECT_TYPES = new Set([1, 2, 3, 4, 5, 6, 17, 19, 20, 22, 23, 29, 39, 42]);
function videoCodec(value: unknown): Exclude<VideoCodec, 'unknown'> | undefined {
  if (h264(value)) return 'h264';
  if (typeof value !== 'string') return undefined;
  if (/^(?:hevc|h265|bytevc1|(?:hvc1|hev1)(?:\.[0-9a-z.]+)?)$/i.test(value)) return 'hevc';
  if (/^(?:vp9|vp09(?:\.[0-9.]+)?)$/i.test(value)) return 'vp9';
  if (/^(?:av1|av01(?:\.[0-9a-z.]+)?)$/i.test(value)) return 'av1';
  return undefined;
}
function audioCodec(value: unknown): Exclude<AudioCodec, 'unknown' | 'none'> | undefined {
  if (aac(value)) return 'aac-lc';
  if (typeof value !== 'string') return undefined;
  if (/^mp4a\.40\.(?:5|29)$/i.test(value)) return 'he-aac';
  const objectType = /^mp4a\.40\.([0-9]{1,2})$/i.exec(value)?.[1];
  if ((objectType !== undefined && AAC_OBJECT_TYPES.has(Number(objectType))) || /^mp4a\.6[678]$/i.test(value)) return 'aac';
  return undefined;
}
function unknownCodec(value: unknown): boolean { return value === undefined || value === null || value === '' || value === 'unknown'; }
function raster(format: Row): { width: number; height: number } | undefined {
  const width = positive(format.width), height = positive(format.height);
  if (!width || !height || !Number.isSafeInteger(width) || !Number.isSafeInteger(height) || width % 2 || height % 2 ||
      Math.max(width, height) > MAX_VIDEO_LONG_SIDE || Math.min(width, height) > MAX_VIDEO_SHORT_SIDE) return undefined;
  return { width, height };
}
function file(format: Row): boolean {
  return format.protocol === 'https' && !format.fragments && !format.manifest_url &&
    !['m3u8', 'mpd'].includes(String(format.ext)) &&
    (finite(format.fps) === undefined || Number(format.fps) <= MAX_VIDEO_FPS + 0.001) &&
    (finite(format.rotation) === undefined || Number(format.rotation) % 360 === 0) &&
    (!format.dynamic_range || format.dynamic_range === 'SDR');
}
/** MP4-family containers only: iOS cannot demux WebM/Matroska. */
function mp4Family(format: Row): boolean { return format.ext === 'mp4' || format.ext === 'm4a'; }
const pixels = (f: Row) => (positive(f.width) ?? 0) * (positive(f.height) ?? 0);
const frameRate = (f: Row) => positive(f.fps) ?? 0;
/** YouTube-style quality class: the short side, or the 16:9 equivalent for wider pictures (1920x818 is 1080p). */
const qualityClass = (f: Row) => {
  const width = positive(f.width) ?? 0, height = positive(f.height) ?? 0;
  return Math.max(Math.min(width, height), Math.round(Math.max(width, height) * 9 / 16));
};
const videoRank = (a: Row, b: Row) => pixels(b) - pixels(a) || frameRate(b) - frameRate(a) || Number(b.tbr ?? 0) - Number(a.tbr ?? 0);
const audioRank = (a: Row, b: Row) => Number(b.abr ?? b.tbr ?? 0) - Number(a.abr ?? a.tbr ?? 0);
interface Choice extends DirectAssetSet { video?: Row }

/** Pure selection also runs inside the network:none worker. DNS is checked by the API. */
export function selectDirectMedia(value: unknown, platform: Platform, maxBytes: number, maxDuration: number): DirectPlan | undefined {
  const info = object(value); if (!info) return undefined;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1024) return undefined;
  const formats = Array.isArray(info.formats) ? info.formats.map(object).filter((f): f is Row => Boolean(f)) : [];
  const isKnownAudio = (codec: unknown) => typeof codec === 'string' && !['none', 'unknown', ''].includes(codec);
  const knownAudio = formats.some(f => isKnownAudio(f.acodec));
  // X lists its audio renditions (vcodec 'none') without a codec string; they still mean the source has audio.
  const audioRenditions = formats.some(f => f.vcodec === 'none');
  const hasAudio = knownAudio || audioRenditions || isKnownAudio(info.acodec) ? true : info.acodec === 'none' ? false : undefined;
  if (hasAudio === undefined) return undefined;
  const duration = positive(info.duration);
  if (duration !== undefined && duration > maxDuration + 0.2) return undefined;
  const make = (format: Row, role: DirectAsset['role']): DirectAsset | undefined => {
    const url = directCDNURL(format.url, platform), headers = headersFor(info, format, platform);
    return url && headers ? { role, url, headers } : undefined;
  };
  // Unknown sizes are allowed; the phone enforces maxBytes while downloading.
  const sizeOK = (items: Row[]) => items.reduce((sum, f) => sum + (positive(f.filesize) ?? positive(f.filesize_approx) ?? 0), 0) <= maxBytes;
  const selectedAudio = Array.isArray(info.requested_formats) ? info.requested_formats.map(object).find(f => f?.vcodec === 'none' && isKnownAudio(f.acodec)) : undefined;
  const language = typeof selectedAudio?.language === 'string' ? selectedAudio.language : typeof info.language === 'string' ? info.language : undefined;
  const sameAudio = (f: Row) => (!language || f.language === undefined || f.language === null || f.language === language) &&
    (finite(f.audio_channels) === undefined || Number(f.audio_channels) <= 2) && (finite(f.asr) === undefined || Number(f.asr) <= 48000);
  const expect = (video: Row, codec: VideoCodec, audio: AudioCodec): DirectExpected => ({
    ...(duration !== undefined ? { duration } : {}), ...raster(video),
    ...(positive(video.fps) !== undefined ? { fps: Number(video.fps) } : {}), hasAudio, videoCodec: codec, audioCodec: audio,
  });
  // Owner's rule: nothing above 1080p is ever used; the best version up to 1080p is taken.
  const videos = formats.filter(f => file(f) && mp4Family(f) && raster(f) && videoCodec(f.vcodec) && qualityClass(f) <= 1080).sort(videoRank);
  const audios = formats.filter(f => f.vcodec === 'none' && file(f) && mp4Family(f) && audioCodec(f.acodec) && sameAudio(f)).sort(audioRank);
  // Best video by raster, then fps, then bitrate. Playable = H.264 with AAC-LC only.
  const best = (playable: boolean): Choice | undefined => {
    for (const v of videos) {
      const codec = videoCodec(v.vcodec)!;
      if (playable && codec !== 'h264') continue;
      if (!hasAudio) {
        const asset = v.acodec === 'none' ? make(v, 'muxed') : undefined;
        if (asset && sizeOK([v])) return { video: v, assets: [asset], expected: expect(v, codec, 'none') };
      } else if (v.acodec === 'none') {
        for (const a of audios) {
          const audio = audioCodec(a.acodec)!;
          if (playable && audio !== 'aac-lc') continue;
          const va = make(v, 'video'), aa = make(a, 'audio');
          if (va && aa && sizeOK([v, a])) return { video: v, assets: [va, aa], expected: expect(v, codec, audio) };
        }
      } else {
        const audio = audioCodec(v.acodec), asset = make(v, 'muxed');
        if (audio && (!playable || audio === 'aac-lc') && sameAudio(v) && asset && sizeOK([v])) return { video: v, assets: [asset], expected: expect(v, codec, audio) };
      }
    }
    return undefined;
  };
  // yt-dlp lists formats worst to best, so the last usable opaque progressive MP4 is preferred.
  const opaque = (): Choice | undefined => {
    for (const f of [...formats].reverse()) {
      const sized = (f.width !== undefined && f.width !== null) || (f.height !== undefined && f.height !== null);
      if (!file(f) || f.ext !== 'mp4' || !unknownCodec(f.vcodec) || (hasAudio && f.acodec === 'none') || (sized && !raster(f))) continue;
      const asset = make(f, 'muxed');
      if (!asset || !sizeOK([f])) continue;
      return { assets: [asset], expected: {
        ...(duration !== undefined ? { duration } : {}), ...raster(f),
        ...(positive(f.fps) !== undefined ? { fps: Number(f.fps) } : {}), hasAudio, videoCodec: 'unknown',
        audioCodec: hasAudio ? audioCodec(f.acodec) ?? 'unknown' : 'none',
      } };
    }
    return undefined;
  };
  const plan = (choice: Choice, convert: boolean, fallback?: Choice): DirectPlan => ({
    kind: 'direct', assets: choice.assets, expected: choice.expected, maxBytes, convert,
    ...(fallback ? { fallback: { assets: fallback.assets, expected: fallback.expected } } : {}),
  });
  const original = best(false);
  if (!original?.video) {
    const progressive = opaque();
    return progressive ? plan(progressive, false) : undefined;
  }
  const playable = best(true);
  // Owner's rule: convert only when the directly playable H264 is below 1080p (for example 720p) and the
  // original is better. A 1080p-or-better playable version plays directly, with no conversion on the phone.
  if (playable?.video && (qualityClass(playable.video) >= 1080 ||
      (pixels(playable.video) >= pixels(original.video) && frameRate(playable.video) >= frameRate(original.video)))) return plan(playable, false);
  return plan(original, true, playable ?? opaque());
}

function sanitizeAssetSet(value: unknown, platform: Platform, maxDuration: number): DirectAssetSet {
  const set = object(value), expected = object(set?.expected);
  if (!set || !expected || typeof expected.hasAudio !== 'boolean' || !Array.isArray(set.assets) || set.assets.length < 1 || set.assets.length > 2) throw unsafe();
  const assets = set.assets.map(v => {
    const asset = object(v), url = directCDNURL(asset?.url, platform), rawHeaders = object(asset?.headers);
    if (!asset || !url || !rawHeaders || !['muxed', 'video', 'audio'].includes(String(asset.role))) throw unsafe();
    const headers = headersFor({}, { http_headers: rawHeaders }, platform);
    if (!headers || Object.keys(headers).length !== Object.keys(rawHeaders).length) throw unsafe();
    return { role: asset.role as DirectAsset['role'], url, headers };
  });
  const roles = assets.map(a => a.role).sort().join(',');
  if (!(roles === 'muxed' || (roles === 'audio,video' && expected.hasAudio))) throw unsafe();
  if ((expected.duration !== undefined && (!positive(expected.duration) || Number(expected.duration) > maxDuration + 0.2)) ||
      ((expected.width !== undefined || expected.height !== undefined) && !raster(expected)) ||
      (expected.fps !== undefined && (!positive(expected.fps) || Number(expected.fps) > MAX_VIDEO_FPS + 0.001)) ||
      (expected.videoCodec !== undefined && !VIDEO_CODECS.includes(expected.videoCodec as VideoCodec)) ||
      (expected.audioCodec !== undefined && !AUDIO_CODECS.includes(expected.audioCodec as AudioCodec))) throw unsafe();
  return { assets, expected: {
    hasAudio: expected.hasAudio, ...(expected.duration !== undefined ? { duration: Number(expected.duration) } : {}),
    ...(expected.width !== undefined ? { width: Number(expected.width), height: Number(expected.height) } : {}),
    ...(expected.fps !== undefined ? { fps: Number(expected.fps) } : {}),
    ...(expected.videoCodec !== undefined ? { videoCodec: expected.videoCodec as VideoCodec } : {}),
    ...(expected.audioCodec !== undefined ? { audioCodec: expected.audioCodec as AudioCodec } : {}),
  } };
}
export function sanitizeDirectMedia(value: unknown, platform: Platform, maxBytes: number, maxDuration: number): DirectPlan {
  const plan = object(value);
  if (plan?.kind !== 'direct' || typeof plan.convert !== 'boolean' ||
      !Number.isSafeInteger(plan.maxBytes) || Number(plan.maxBytes) < 1024 || Number(plan.maxBytes) > maxBytes) throw unsafe();
  const primary = sanitizeAssetSet(plan, platform, maxDuration);
  const fallback = plan.fallback === undefined ? undefined : sanitizeAssetSet(plan.fallback, platform, maxDuration);
  return { kind: 'direct', assets: primary.assets, expected: primary.expected, maxBytes: Number(plan.maxBytes), convert: plan.convert, ...(fallback ? { fallback } : {}) };
}
export function directPublicAddress(address: string): boolean {
  if (isIP(address) === 4) return isPublicAddress(address);
  if (isIP(address) !== 6) return false;
  const parts = address.toLowerCase().split(':'), first = parseInt(parts[0] ?? '', 16), second = parseInt(parts[1] || '0', 16);
  return first >= 0x2000 && first <= 0x3fff && first !== 0x2002 && first !== 0x3fff &&
    !(first === 0x2001 && (second < 0x200 || second === 0xdb8));
}
export async function validateDirectMedia(value: unknown, platform: Platform, maxBytes: number, maxDuration: number, lookup: DirectLookup = host => systemLookup(host, { all: true })): Promise<DirectPlan> {
  const plan = sanitizeDirectMedia(value, platform, maxBytes, maxDuration);
  for (const host of new Set([...plan.assets, ...(plan.fallback?.assets ?? [])].map(asset => new URL(asset.url).hostname))) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const addresses = await Promise.race([lookup(host), new Promise<never>((_, reject) => { timer = setTimeout(() => reject(unsafe()), 5000); timer.unref(); })]);
      if (!addresses.length || addresses.some(address => !directPublicAddress(address.address))) throw unsafe();
    } catch { throw unsafe(); } finally { if (timer) clearTimeout(timer); }
  }
  return plan;
}
function unsafe() { return new AppError('DIRECT_SOURCE_UNAVAILABLE', 'This source needs standard video preparation. Please try again.', 422); }
export function noDirectMedia() { return new AppError('NO_DIRECT_MEDIA', "This video can't be downloaded directly. Try another link.", 422); }
