import assert from 'node:assert/strict';
import { it } from 'node:test';
import { selectDirectMedia, directCDNURL, sanitizeDirectMedia, validateDirectMedia, directPublicAddress, type DirectPlan } from '../src/direct-media.js';
import { instagramReel, tiktokHEVC, tiktokSameRaster, xH264, xOpaque, youtube1080, youtube4K } from './format-fixtures.js';

it('sends the best opaque X mp4 as a direct link when X lists audio renditions without a codec', () => {
  const plan = selectDirectMedia(xOpaque(), 'x', 2 * 1024 ** 3, 3600) as DirectPlan;
  assert.ok(plan, 'X must not fall to NO_DIRECT_MEDIA');
  assert.equal(plan.convert, false);
  assert.deepEqual(plan.assets.map(asset => asset.role), ['muxed']);
  assert.match(plan.assets[0]!.url, /\/728x720\//);
  assert.equal(plan.expected.videoCodec, 'unknown');
  assert.equal(plan.expected.hasAudio, true);
  assert.equal(plan.fallback, undefined);
});

const cap = 2 * 1024 ** 3, maxDuration = 3600;
const url = 'https://rr1.googlevideo.com/videoplayback?signature=synthetic-secret';
const video = (changes = {}) => ({ format_id: 'h264', width: 1280, height: 720, fps: 30, protocol: 'https', ext: 'mp4', vcodec: 'avc1.64001f', acodec: 'none', url, ...changes });
const audio = (changes = {}) => ({ format_id: 'aac', vcodec: 'none', acodec: 'mp4a.40.2', ext: 'm4a', protocol: 'https', url: 'https://rr2.googlevideo.com/audio?signature=synthetic', asr: 48000, audio_channels: 2, ...changes });
const itag = (asset: { url: string } | undefined) => new URL(asset!.url).searchParams.get('itag');
const roles = (plan: { assets: { role: string }[] } | undefined) => plan?.assets.map(a => a.role);

it('chooses a same-quality H264/AAC-LC progressive file directly and strips every unapproved header', () => {
  const info = { title: 'Synthetic', duration: 19, acodec: 'mp4a.40.2', http_headers: { 'User-Agent': 'Fixture/1', Referer: 'https://www.youtube.com/', Cookie: 'never-forward', Authorization: 'never-forward' },
    formats: [video({ vcodec: 'vp9', ext: 'webm', acodec: 'opus' }), video({ acodec: 'mp4a.40.2' })] };
  const plan = selectDirectMedia(info, 'youtube', cap, maxDuration);
  assert.equal(plan?.convert, false); assert.equal(plan?.fallback, undefined);
  assert.deepEqual(roles(plan), ['muxed']);
  assert.deepEqual(plan?.assets[0]?.headers, { 'User-Agent': 'Fixture/1', Referer: 'https://www.youtube.com/' });
  assert.deepEqual(plan?.expected, { width: 1280, height: 720, fps: 30, duration: 19, hasAudio: true, videoCodec: 'h264', audioCodec: 'aac-lc' });
  assert.equal(plan?.maxBytes, cap);
  assert.ok(!JSON.stringify(plan).includes('never-forward'));
});

it('pairs split H264 with the original-language AAC rather than dropping audio or selecting another dub', () => {
  const plan = selectDirectMedia({ duration: 20, acodec: 'opus', requested_formats: [video(), audio({ acodec: 'opus', language: 'en' })],
    formats: [video(), audio({ language: 'es', abr: 300 }), audio({ language: 'en', abr: 128, url: 'https://rr2.googlevideo.com/audio?lang=en' })] }, 'youtube', cap, maxDuration);
  assert.deepEqual(roles(plan), ['video', 'audio']);
  assert.equal(new URL(plan!.assets[1]!.url).searchParams.get('lang'), 'en');
  assert.equal(plan?.convert, false);
  assert.equal(selectDirectMedia({ acodec: 'opus', formats: [video()] }, 'youtube', cap, maxDuration), undefined, 'Audio is never dropped');
});

it('measured Instagram reel: converts the 1080p VP9 original with HE-AAC and falls back to the best opaque progressive MP4', () => {
  const plan = selectDirectMedia(instagramReel(), 'instagram', cap, maxDuration)!;
  assert.equal(plan.convert, true);
  assert.deepEqual(roles(plan), ['video', 'audio']);
  assert.match(plan.assets[0]!.url, /1080v\.mp4/); assert.match(plan.assets[1]!.url, /a\.m4a/);
  assert.deepEqual(plan.expected, { width: 1080, height: 1920, hasAudio: true, videoCodec: 'vp9', audioCodec: 'he-aac' });
  assert.deepEqual(roles(plan.fallback), ['muxed']);
  assert.match(plan.fallback!.assets[0]!.url, /progressive-3\.mp4/, 'yt-dlp lists worst to best; the last opaque file is preferred');
  assert.deepEqual(plan.fallback!.expected, { hasAudio: true, videoCodec: 'unknown', audioCodec: 'unknown' });
  assert.deepEqual(plan.assets[0]!.headers, { 'User-Agent': 'Synthetic/1' });
  assert.equal(plan.maxBytes, cap);
});

it('uses an opaque progressive MP4 without conversion when no known-codec video exists', () => {
  const info = instagramReel();
  const plan = selectDirectMedia({ ...info, formats: info.formats.filter(f => f.vcodec !== 'vp09.00.40.08.00.01.01.01.00') }, 'instagram', cap, maxDuration)!;
  assert.equal(plan.convert, false); assert.equal(plan.fallback, undefined);
  assert.match(plan.assets[0]!.url, /progressive-3\.mp4/);
  assert.equal(plan.expected.videoCodec, 'unknown');
});

it('YouTube 4K60: the 1080p60 H264 + AAC-LC version plays directly, the AV1 original is not converted; WebM is never offered', () => {
  const plan = selectDirectMedia(youtube4K(), 'youtube', cap, maxDuration)!;
  assert.equal(plan.convert, false); assert.equal(plan.fallback, undefined);
  assert.deepEqual([itag(plan.assets[0]), itag(plan.assets[1])], ['299', '140']);
  assert.deepEqual(plan.expected, { width: 1920, height: 1080, fps: 60, duration: 212, hasAudio: true, videoCodec: 'h264', audioCodec: 'aac-lc' });
  for (const id of ['315', '303', '251', '401']) assert.ok(!JSON.stringify(plan).includes(`itag=${id}&`), `itag ${id} must not be offered`);
});

it('YouTube 1080p60: H264 that matches the original raster and frame rate is delivered directly', () => {
  const plan = selectDirectMedia(youtube1080(), 'youtube', cap, maxDuration)!;
  assert.equal(plan.convert, false); assert.equal(plan.fallback, undefined);
  assert.deepEqual([itag(plan.assets[0]), itag(plan.assets[1])], ['299', '140']);
  assert.equal(plan.expected.fps, 60);
});

it('an H264 below 1080p is only a fallback for a better original; 1080p H264 plays directly even at a lower frame rate', () => {
  const original = video({ width: 1080, height: 1920, fps: 60, vcodec: 'vp9', acodec: 'mp4a.40.2', url: 'https://scontent.cdninstagram.com/vp9.mp4' });
  const low = video({ width: 720, height: 1280, fps: 60, acodec: 'mp4a.40.2', url: 'https://scontent.cdninstagram.com/native.mp4' });
  const converted = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [original, low] }, 'instagram', cap, maxDuration)!;
  assert.equal(converted.convert, true); assert.match(converted.assets[0]!.url, /vp9\.mp4/);
  assert.match(converted.fallback!.assets[0]!.url, /native\.mp4/); assert.equal(converted.fallback!.expected.videoCodec, 'h264');
  const full = video({ width: 1080, height: 1920, fps: 30, acodec: 'mp4a.40.2', url: 'https://scontent.cdninstagram.com/native.mp4' });
  const direct = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [original, full] }, 'instagram', cap, maxDuration)!;
  assert.equal(direct.convert, false); assert.equal(direct.fallback, undefined); assert.match(direct.assets[0]!.url, /native\.mp4/);
});

it('TikTok: converts a muxed bytevc1 (HEVC) original and falls back to the H264 file', () => {
  const plan = selectDirectMedia(tiktokHEVC(), 'tiktok', cap, maxDuration)!;
  assert.equal(plan.convert, true); assert.match(plan.assets[0]!.url, /hevc-1080/);
  assert.deepEqual(plan.expected, { width: 1080, height: 1920, fps: 30, duration: 15.2, hasAudio: true, videoCodec: 'hevc', audioCodec: 'aac-lc' });
  assert.match(plan.fallback!.assets[0]!.url, /h264-720/);
  for (const codec of ['hvc1.1.6.L120.90', 'hev1.1.6.L93.B0', 'hevc', 'h265']) {
    assert.equal(selectDirectMedia({ acodec: 'none', formats: [video({ vcodec: codec })] }, 'youtube', cap, maxDuration)?.expected.videoCodec, 'hevc', codec);
  }
});

it('TikTok: H264 at the same raster and frame rate as the HEVC file is delivered directly', () => {
  const plan = selectDirectMedia(tiktokSameRaster(), 'tiktok', cap, maxDuration)!;
  assert.equal(plan.convert, false); assert.equal(plan.fallback, undefined);
  assert.deepEqual(roles(plan), ['muxed']); assert.match(plan.assets[0]!.url, /h264-1080/);
  assert.equal(plan.expected.videoCodec, 'h264');
});

it('X: H264 + AAC-LC progressive MP4 on video.twimg.com is delivered directly and HLS is ignored', () => {
  const plan = selectDirectMedia(xH264(), 'x', cap, maxDuration)!;
  assert.equal(plan.convert, false); assert.equal(plan.fallback, undefined);
  assert.deepEqual(roles(plan), ['muxed']); assert.match(plan.assets[0]!.url, /vid\/1080x1920\.mp4/);
  assert.deepEqual(plan.expected, { width: 1080, height: 1920, fps: 30, duration: 24.1, hasAudio: true, videoCodec: 'h264', audioCodec: 'aac-lc' });
  assert.ok(!JSON.stringify(plan).includes('m3u8'));
});

it('a silent source whose only file is an opaque progressive MP4 with acodec none is delivered without conversion', () => {
  const plan = selectDirectMedia({ acodec: 'none', formats: [{ protocol: 'https', ext: 'mp4', url: 'https://rr1.googlevideo.com/o', acodec: 'none' }] }, 'youtube', cap, maxDuration)!;
  assert.equal(plan.convert, false); assert.equal(plan.fallback, undefined);
  assert.deepEqual(roles(plan), ['muxed']);
  assert.deepEqual(plan.expected, { hasAudio: false, videoCodec: 'unknown', audioCodec: 'none' });
});

it('converts H264 whose only audio is HE-AAC, with no fallback when nothing else qualifies', () => {
  const plan = selectDirectMedia({ acodec: 'mp4a.40.5', formats: [video(), audio({ acodec: 'mp4a.40.29' })] }, 'youtube', cap, maxDuration)!;
  assert.equal(plan.convert, true); assert.equal(plan.fallback, undefined);
  assert.deepEqual([plan.expected.videoCodec, plan.expected.audioCodec], ['h264', 'he-aac']);
});

it('rejects segmented playlists, WebM/MKV, rotation, HDR, >60 fps, audio overflow and oversized assets', () => {
  for (const change of [
    { protocol: 'm3u8_native' }, { url: 'https://rr1.googlevideo.com/playlist.m3u8' }, { fragments: [{ url }] }, { manifest_url: 'https://rr1.googlevideo.com/m.mpd' },
    { ext: 'webm', vcodec: 'vp9' }, { ext: 'mkv' }, { rotation: 90 }, { dynamic_range: 'HDR10' }, { fps: 120 },
    { vcodec: 'avc1.6e001f' }, { vcodec: 'vp8' }, { acodec: 'mp4a.40.2', audio_channels: 6 }, { filesize: cap + 1 },
  ]) assert.equal(selectDirectMedia({ acodec: change.acodec ?? 'none', formats: [video(change)] }, 'youtube', cap, maxDuration), undefined, JSON.stringify(change));
});

it('allows direct downloads up to 2 GiB for every duration, unknown sizes included, and keeps the 60-minute limit', () => {
  const mib = 1024 * 1024;
  const pick = (duration: number | undefined, filesize?: number) =>
    selectDirectMedia({ acodec: 'none', ...(duration === undefined ? {} : { duration }), formats: [video(filesize === undefined ? {} : { filesize })] }, 'youtube', cap, maxDuration);
  for (const duration of [undefined, 30, 900, 3599]) assert.equal(pick(duration, 1536 * mib)?.maxBytes, cap, String(duration));
  assert.equal(pick(60)?.maxBytes, cap, 'Unknown sizes are enforced by the phone while downloading');
  assert.equal(pick(60, cap + 1), undefined);
  assert.equal(pick(3600.2, 10 * mib)?.maxBytes, cap);
  assert.equal(pick(3601, 10 * mib), undefined);
  const split = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video({ filesize: cap - 1000 }), audio({ filesize: 2000 })] }, 'youtube', cap, maxDuration);
  assert.equal(split, undefined, 'Known sizes are totalled across video and audio');
});

it('enforces exact platform CDN ownership, TLS443 and safe URL syntax', () => {
  for (const valid of ['https://rr1.googlevideo.com/v', 'https://googlevideo.com/v']) assert.ok(directCDNURL(valid, 'youtube'));
  for (const invalid of [
    'https://googlevideo.com.evil.test/v', 'https://evilgooglevideo.com/v', 'http://rr1.googlevideo.com/v', 'https://user:pass@rr1.googlevideo.com/v',
    'https://rr1.googlevideo.com:444/v', 'https://127.0.0.1/v', 'https://2130706433/v', 'https://[::1]/v', 'https://rr1.googlevideo.com./v',
    'https://rr1.googlevideo.com/v#fragment', 'https://rr1.googlevideo.com/v\r\nCookie: secret',
  ]) assert.equal(directCDNURL(invalid, 'youtube'), undefined);
  assert.ok(directCDNURL('https://video.twimg.com/video.mp4', 'x'));
  assert.equal(directCDNURL('https://evil.video.twimg.com/video.mp4', 'x'), undefined);
  assert.equal(directCDNURL(url, 'instagram'), undefined);
  assert.ok(directCDNURL('https://v16-webapp-prime.tiktok.com/v.mp4', 'tiktok'));
  assert.equal(directCDNURL('https://www.tiktok.com/v.mp4', 'tiktok'), undefined);
  const info = instagramReel();
  const offHost = { ...info, formats: info.formats.map(f => f.format_id === 'dash-1080v' ? { ...f, url: 'https://evil.example/1080v.mp4' } : f) };
  assert.match(selectDirectMedia(offHost, 'instagram', cap, maxDuration)!.assets[0]!.url, /720v\.mp4/, 'Unapproved hosts are never candidates');
});

it('rejects unsafe allowed-header values and unapproved IPC headers', () => {
  for (const headers of [{ 'User-Agent': 'bad\nheader' }, { Referer: 'https://evil.test/' }, { Origin: 'https://www.youtube.com/path' }]) {
    assert.equal(selectDirectMedia({ acodec: 'none', formats: [video({ http_headers: headers })] }, 'youtube', cap, maxDuration), undefined);
  }
  const plan = selectDirectMedia({ acodec: 'none', formats: [video()] }, 'youtube', cap, maxDuration)!;
  assert.throws(() => sanitizeDirectMedia({ ...plan, assets: [{ ...plan.assets[0], headers: { Cookie: 'private' } }] }, 'youtube', cap, maxDuration));
  assert.throws(() => sanitizeDirectMedia({ ...plan, maxBytes: cap + 1 }, 'youtube', cap, maxDuration));
  assert.throws(() => sanitizeDirectMedia({ ...plan, assets: [{ ...plan.assets[0], role: 'audio' }] }, 'youtube', cap, maxDuration));
});

it('sanitizes the hybrid manifest shape for primary and fallback', () => {
  // Without its 1080p H264 (itag 299) the 4K AV1 original is converted, with the 720p60 H264 as the fallback.
  const hybrid = youtube4K(); hybrid.formats = hybrid.formats.filter(f => !String(f.url).includes('itag=299'));
  const youtube = selectDirectMedia(hybrid, 'youtube', cap, maxDuration)!;
  assert.equal(youtube.convert, true); assert.ok(youtube.fallback);
  assert.deepEqual(sanitizeDirectMedia(JSON.parse(JSON.stringify(youtube)), 'youtube', cap, maxDuration), youtube);
  const instagram = selectDirectMedia(instagramReel(), 'instagram', cap, maxDuration)!;
  assert.deepEqual(sanitizeDirectMedia(JSON.parse(JSON.stringify(instagram)), 'instagram', cap, maxDuration), instagram);
  const fallback = youtube.fallback!;
  const invalid: unknown[] = [
    { ...youtube, convert: undefined }, { ...youtube, convert: 'yes' },
    { ...youtube, expected: { ...youtube.expected, videoCodec: 'vp8' } }, { ...youtube, expected: { ...youtube.expected, audioCodec: 'opus' } },
    { ...youtube, expected: { ...youtube.expected, fps: 120 } }, { ...youtube, expected: { ...youtube.expected, duration: 3601 } },
    { ...youtube, assets: [youtube.assets[0], youtube.assets[0]] }, { ...youtube, assets: [youtube.assets[0]] },
    { ...youtube, fallback: { ...fallback, assets: [{ ...fallback.assets[0], url: 'https://evil.example/v' }] } },
    { ...youtube, fallback: { ...fallback, assets: [{ ...fallback.assets[0], headers: { Cookie: 'x' } }, fallback.assets[1]] } },
    { ...youtube, fallback: { ...fallback, assets: [fallback.assets[0], { ...fallback.assets[1], role: 'muxed' }] } },
    { ...youtube, fallback: { ...fallback, expected: { ...fallback.expected, width: 7680, height: 4320 } } },
    { ...youtube, fallback: { ...fallback, expected: { ...fallback.expected, hasAudio: false } } },
    { ...youtube, fallback: { ...fallback, expected: { ...fallback.expected, videoCodec: 'theora' } } },
    { ...youtube, fallback: { assets: fallback.assets } }, { ...youtube, fallback: null },
  ];
  for (const value of invalid) assert.throws(() => sanitizeDirectMedia(value, 'youtube', cap, maxDuration), JSON.stringify(value).slice(0, 200));
  assert.throws(() => sanitizeDirectMedia(youtube, 'youtube', cap, 200), 'The configured duration limit applies to private manifests');
  const { duration: _omitted, ...unknown } = youtube.expected;
  assert.deepEqual(sanitizeDirectMedia({ ...youtube, expected: unknown }, 'youtube', cap, maxDuration).expected, unknown);
  assert.equal(sanitizeDirectMedia({ ...youtube, maxBytes: 1024 }, 'youtube', cap, maxDuration).maxBytes, 1024);
});

it('checks every DNS answer for primary and fallback hosts and refuses private/mapped/reserved IPv6 without fetching the CDN', async () => {
  const plan = selectDirectMedia({ acodec: 'none', formats: [video()] }, 'youtube', cap, maxDuration)!;
  let calls = 0;
  assert.deepEqual(await validateDirectMedia(plan, 'youtube', cap, maxDuration, async host => { calls++; assert.equal(host, 'rr1.googlevideo.com'); return [{ address: '8.8.8.8', family: 4 }]; }), plan);
  assert.equal(calls, 1);
  for (const address of ['127.0.0.1', '10.1.2.3', '169.254.169.254', '::1', '::ffff:127.0.0.1', 'fc00::1', '2001:db8::1', '2001::1', '2002:0808:0808::1', '3fff::1']) {
    assert.equal(directPublicAddress(address), false, address);
    await assert.rejects(validateDirectMedia(plan, 'youtube', cap, maxDuration, async () => [{ address: '8.8.8.8', family: 4 }, { address, family: address.includes(':') ? 6 : 4 }]));
  }
  assert.ok(directPublicAddress('2607:f8b0:4000::1'));

  const hybrid: DirectPlan = { ...plan, convert: true, fallback: { assets: [{ ...plan.assets[0]!, url: 'https://rr9.googlevideo.com/fallback' }], expected: plan.expected } };
  const hosts: string[] = [];
  await validateDirectMedia(hybrid, 'youtube', cap, maxDuration, async host => { hosts.push(host); return [{ address: '8.8.8.8', family: 4 }]; });
  assert.deepEqual(hosts.sort(), ['rr1.googlevideo.com', 'rr9.googlevideo.com']);
  await assert.rejects(validateDirectMedia(hybrid, 'youtube', cap, maxDuration, async host => [{ address: host === 'rr9.googlevideo.com' ? '10.0.0.1' : '8.8.8.8', family: 4 }]),
    { code: 'DIRECT_SOURCE_UNAVAILABLE' }, 'A private fallback host rejects the whole manifest');
});
