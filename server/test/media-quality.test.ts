import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdir, readFile, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { it } from 'node:test';
import { mediaSourceID, QUALITY_FORMAT_SORT } from '../src/media-quality.js';
import { selectDirectMedia } from '../src/direct-media.js';
import { fakeDownload, fixture, sampleBytes, sampleURL } from './fixtures.js';

const cap = 2 * 1024 ** 3, maxDuration = 3600;
const video = (width: number, height: number, fps: number, codec = 'avc1.640033') => ({
  width, height, fps, vcodec: codec, acodec: 'mp4a.40.2', ext: 'mp4', protocol: 'https',
  url: `https://rr1.googlevideo.com/videoplayback?width=${width}&fps=${fps}`,
});

it('selects the best H264 up to 1080p (60fps over 30fps, over 720p) and ignores anything above 1080p', () => {
  for (const [width, height] of [[1920, 1080], [1080, 1920]]) {
    const plan = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(1280, 720, 30), video(width!, height!, 30), video(width!, height!, 60), video(3840, 2160, 60)] }, 'youtube', cap, maxDuration);
    assert.deepEqual(plan?.expected, { width, height, fps: 60, hasAudio: true, videoCodec: 'h264', audioCodec: 'aac-lc' });
    assert.equal(plan?.convert, false);
    assert.equal(new URL(plan!.assets[0]!.url).searchParams.get('fps'), '60');
  }
  const capped = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(1280, 720, 30), video(3840, 2160, 30), video(2160, 3840, 60)] }, 'youtube', cap, maxDuration);
  assert.deepEqual([capped?.expected.width, capped?.expected.height, capped?.convert], [1280, 720, false]);
  assert.equal(QUALITY_FORMAT_SORT, 'res:2160,fps:60,vcodec:h264,acodec:aac');
});

it('measures 1080p like YouTube: a widescreen 1920x818 H264 plays directly and a 2048x872 original is above 1080p', () => {
  const plan = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(2048, 872, 24, 'av01.0.08M.08'), video(1920, 818, 24, 'vp09.00.40.08'), video(1920, 818, 24)] }, 'youtube', cap, maxDuration);
  assert.equal(plan?.convert, false); assert.equal(plan?.fallback, undefined);
  assert.deepEqual([plan?.expected.width, plan?.expected.height, plan?.expected.videoCodec], [1920, 818, 'h264']);
});

it('ignores anything above 1080p: a 1080p H264 plays directly, 720p plays directly when nothing up to 1080p is better', () => {
  const plan = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(3840, 2160, 60, 'av01.0.13M.08'), video(3840, 2160, 30), video(1920, 1080, 60)] }, 'youtube', cap, maxDuration);
  assert.equal(plan?.convert, false); assert.equal(plan?.fallback, undefined); assert.equal(plan?.expected.videoCodec, 'h264');
  assert.deepEqual([plan?.expected.width, plan?.expected.height, plan?.expected.fps], [1920, 1080, 60]);
  const only720 = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(3840, 2160, 60, 'av01.0.13M.08'), video(1280, 720, 60)] }, 'youtube', cap, maxDuration);
  assert.equal(only720?.convert, false); assert.equal(only720?.fallback, undefined);
  assert.deepEqual([only720?.expected.width, only720?.expected.height], [1280, 720]);
  // A 1080p original the phone cannot play directly, with only a 720p H264, is converted at 1080p (never 4K).
  const hybrid = selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(3840, 2160, 60, 'av01.0.13M.08'), video(1920, 1080, 60, 'av01.0.09M.08'), video(1280, 720, 60)] }, 'youtube', cap, maxDuration);
  assert.equal(hybrid?.convert, true); assert.deepEqual([hybrid?.expected.width, hybrid?.expected.videoCodec], [1920, 'av1']);
  assert.deepEqual([hybrid?.fallback?.expected.width, hybrid?.fallback?.expected.fps], [1280, 60]);
  assert.equal(selectDirectMedia({ acodec: 'mp4a.40.2', formats: [video(3840, 2160, 60, 'avc1.64003C')] }, 'youtube', cap, maxDuration), undefined, 'Only formats above 1080p: nothing is used.');
});

it('returns the quality marker and the 1080p raster (never above 1080p) on metadata-only direct responses', async () => {
  const f = await fixture({}, fakeDownload, {
    inspect: async () => ({ acodec: 'mp4a.40.2', formats: [{ ...video(3840, 2160, 60), url: 'https://scontent.cdninstagram.com/synthetic-4k.mp4' }, { ...video(1920, 1080, 60), url: 'https://scontent.cdninstagram.com/synthetic.mp4' }] }),
    lookup: async () => [{ address: '8.8.8.8', family: 4 }],
  });
  try {
    const response = await fetch(`${f.origin}/v2/media/resolve`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: sampleURL }) });
    assert.equal(response.status, 200);
    const result = await response.json() as { qualityVersion: number; delivery: { expected: { width: number; height: number } } };
    assert.equal(result.qualityVersion, 2);
    assert.deepEqual(result.delivery.expected, { width: 1920, height: 1080, fps: 60, hasAudio: true, videoCodec: 'h264', audioCodec: 'aac-lc' });
  } finally { await f.close(); }
});

it('never reuses a legacy720p prepared entry for the new quality profile and retains that old cache until expiry', async () => {
  let preparations = 0;
  const f = await fixture({}, async (...args) => { preparations++; return fakeDownload(...args); });
  try {
    const oldID = createHash('sha256').update(`roast-v1:${sampleURL}`).digest('hex').slice(0, 24);
    const oldDirectory = join(f.config.cacheDir, oldID); await mkdir(oldDirectory);
    const legacy = { id: oldID, title: 'Old720p', sourceUrl: sampleURL, platform: 'instagram',
      duration: 12.5, width: 720, height: 1280, hasAudio: true, bytes: sampleBytes.length,
      createdAt: new Date().toISOString(), expiresAt: new Date(Date.now() + 3600_000).toISOString() };
    await writeFile(join(oldDirectory, 'video.mp4'), sampleBytes);
    await writeFile(join(oldDirectory, 'manifest.json'), JSON.stringify(legacy));
    // Store-level behavior: no route prepares videos any more.
    const fresh = await f.store.resolve(sampleURL);
    assert.equal(fresh.id, mediaSourceID(sampleURL)); assert.notEqual(fresh.id, oldID); assert.equal(fresh.qualityVersion, 2); assert.equal(preparations, 1);
    assert.equal((await stat(join(oldDirectory, 'video.mp4'))).size, sampleBytes.length);
    assert.equal(JSON.parse(await readFile(join(f.config.cacheDir, fresh.id, 'manifest.json'), 'utf8')).qualityVersion, 2);
  } finally { await f.close(); }
});
