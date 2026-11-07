import assert from 'node:assert/strict';
import { it } from 'node:test';
import { readdir } from 'node:fs/promises';
import { join } from 'node:path';
import type { Download } from '../src/downloader.js';
import { fakeDownload, fixture, sampleURL } from './fixtures.js';
import { instagramReel } from './format-fixtures.js';

const info = () => ({ title: 'Public fixture', duration: 12.5, acodec: 'aac', width: 720, height: 1280,
  formats: [{ format_id: 'ready', width: 720, height: 1280, fps: 30, protocol: 'https', ext: 'mp4', vcodec: 'h264', acodec: 'aac',
    url: 'https://scontent.cdninstagram.com/video.mp4?signature=private-test-url', http_headers: { 'User-Agent': 'Fixture', Cookie: 'do-not-forward' } }] });
const lookup = async () => [{ address: '8.8.8.8', family: 4 }];
const post = (origin: string, path = '/v2/media/resolve', token?: string) => fetch(origin + path, { method: 'POST', headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify({ url: sampleURL }) });
/** Links-only routes must never download, convert or store media. */
const forbiddenDownload: Download = async () => assert.fail('A resolve route called the downloader/normalizer');
const cacheEntries = async (cacheDir: string) => (await readdir(cacheDir)).filter(name => name !== '.staging');

it('v2 returns a no-store links-only direct manifest without downloading or persisting signed URLs', async () => {
  const logs: unknown[] = [], originalLog = console.info;
  const f = await fixture({}, forbiddenDownload, { inspect: async () => info(), lookup });
  console.info = (...args) => { logs.push(args); };
  try {
    const response = await post(f.origin);
    assert.equal(response.status, 200); assert.equal(response.headers.get('cache-control'), 'no-store');
    const result = await response.json();
    assert.equal(result.delivery.kind, 'direct'); assert.equal(result.playbackUrl, undefined);
    assert.equal(result.delivery.convert, false); assert.equal(result.delivery.fallback, undefined);
    assert.equal(result.delivery.maxBytes, f.config.maxBytes);
    assert.equal(result.delivery.assets[0].url.includes('private-test-url'), true);
    assert.deepEqual(result.delivery.assets[0].headers, { 'User-Agent': 'Fixture' });
    assert.deepEqual(result.delivery.expected, { width: 720, height: 1280, fps: 30, duration: 12.5, hasAudio: true, videoCodec: 'h264', audioCodec: 'aac-lc' });
    assert.ok(Date.parse(result.expiresAt) > Date.now() && Date.parse(result.expiresAt) <= Date.now() + 300_000);
    assert.deepEqual(await readdir(join(f.config.cacheDir, '.staging')), []);
    assert.deepEqual(await cacheEntries(f.config.cacheDir), []);
    assert.ok(!JSON.stringify(logs).includes('private-test-url')); assert.ok(!JSON.stringify(logs).includes('do-not-forward'));
  } finally { console.info = originalLog; await f.close(); }
});

it('v2 returns the hybrid convert + fallback manifest for the measured Instagram VP9 reel', async () => {
  const f = await fixture({}, forbiddenDownload, { inspect: async () => instagramReel(), lookup });
  try {
    const response = await post(f.origin); assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.delivery.kind, 'direct'); assert.equal(result.delivery.convert, true);
    assert.deepEqual(result.delivery.assets.map((a: { role: string }) => a.role), ['video', 'audio']);
    assert.deepEqual(result.delivery.expected, { width: 1080, height: 1920, hasAudio: true, videoCodec: 'vp9', audioCodec: 'he-aac' });
    assert.deepEqual(result.delivery.fallback.expected, { hasAudio: true, videoCodec: 'unknown', audioCodec: 'unknown' });
    assert.match(result.delivery.fallback.assets[0].url, /progressive-3\.mp4/);
    assert.ok(!JSON.stringify(result).includes('never-forward'));
    assert.equal(result.title, 'Synthetic reel'); assert.equal(result.duration, undefined);
    assert.deepEqual(await cacheEntries(f.config.cacheDir), []);
  } finally { await f.close(); }
});

it('v2 responds 422 NO_DIRECT_MEDIA when no plan exists and never prepares the video', async () => {
  let inspections = 0;
  const unsupported = { ...info(), formats: [{ ...info().formats[0], vcodec: 'vp9', ext: 'webm', acodec: 'opus' }] };
  const f = await fixture({}, forbiddenDownload, { inspect: async () => { inspections++; return unsupported; }, lookup });
  try {
    const response = await post(f.origin);
    assert.equal(response.status, 422);
    assert.deepEqual(await response.json(), { error: { code: 'NO_DIRECT_MEDIA', message: "This video can't be downloaded directly. Try another link." } });
    assert.equal(inspections, 1);
    assert.deepEqual(await readdir(join(f.config.cacheDir, '.staging')), []);
    assert.deepEqual(await cacheEntries(f.config.cacheDir), []);
  } finally { await f.close(); }
});

it('v2 ignores a valid prepared-cache entry and returns platform links', async () => {
  let inspections = 0, downloads = 0;
  const counting: Download = async (...args) => { downloads++; return fakeDownload(...args); };
  const f = await fixture({}, counting, { inspect: async () => { inspections++; return info(); }, lookup });
  try {
    const prepared = await f.store.resolve(sampleURL);
    assert.ok(await f.store.get(prepared.id));
    assert.equal(downloads, 1, 'Only the seeding call downloads');
    const result = await (await post(f.origin)).json();
    assert.equal(result.delivery.kind, 'direct'); assert.equal(result.playbackUrl, undefined);
    assert.equal(inspections, 1);
    assert.equal(downloads, 1, 'v2 never calls the downloader');
  } finally { await f.close(); }
});

it('v1 resolve responds 410 UPDATE_REQUIRED, starts no work and still counts toward the shared rate limit', async () => {
  let inspections = 0;
  const f = await fixture({}, forbiddenDownload, { inspect: async () => { inspections++; return info(); }, lookup });
  try {
    const old = await post(f.origin, '/v1/media/resolve');
    assert.equal(old.status, 410);
    assert.deepEqual(await old.json(), { error: { code: 'UPDATE_REQUIRED', message: 'Update RecordPOV to import videos.' } });
    assert.equal(inspections, 0);
    assert.deepEqual(await readdir(join(f.config.cacheDir, '.staging')), []);
    for (let i = 0; i < 19; i++) assert.equal((await post(f.origin, '/v1/media/resolve')).status, 410);
    assert.equal((await post(f.origin)).status, 429);
    assert.equal(inspections, 0);
  } finally { await f.close(); }
});

it('v2 rejects private primary CDN DNS, shares authentication/quota and does not cache metadata on failure', async () => {
  const f = await fixture({ apiToken: 'fixture-token' }, forbiddenDownload, { inspect: async () => instagramReel(),
    lookup: async host => [{ address: host === 'scontent.cdninstagram.com' ? '127.0.0.1' : '8.8.8.8', family: 4 }] });
  try {
    assert.equal((await post(f.origin)).status, 401);
    const failure = await post(f.origin, '/v2/media/resolve', 'fixture-token'); assert.equal(failure.status, 422);
    assert.equal((await failure.json()).error.code, 'DIRECT_SOURCE_UNAVAILABLE');
    assert.deepEqual(await cacheEntries(f.config.cacheDir), []);
    for (let i = 0; i < 19; i++) await post(f.origin, '/v2/media/resolve', 'fixture-token');
    assert.equal((await post(f.origin, '/v1/media/resolve', 'fixture-token')).status, 429);
  } finally { await f.close(); }
});

it('v2 rejects the manifest when only the fallback host resolves to a private address', async () => {
  const reel = instagramReel();
  const fallbackHost = 'scontent-fallback.cdninstagram.com';
  const formats = reel.formats.map(f => f.vcodec === null ? { ...f, url: f.url.replace('scontent.cdninstagram.com', fallbackHost) } : f);
  const hosts: string[] = [];
  const f = await fixture({}, forbiddenDownload, { inspect: async () => ({ ...reel, formats }),
    lookup: async host => { hosts.push(host); return [{ address: host === fallbackHost ? '127.0.0.1' : '8.8.8.8', family: 4 }]; } });
  try {
    const failure = await post(f.origin); assert.equal(failure.status, 422);
    assert.equal((await failure.json()).error.code, 'DIRECT_SOURCE_UNAVAILABLE');
    assert.ok(hosts.includes('scontent.cdninstagram.com') && hosts.includes(fallbackHost));
    assert.deepEqual(await cacheEntries(f.config.cacheDir), []);
  } finally { await f.close(); }
});

it('canceling metadata extraction aborts its queued job and removes staging without downloading', async () => {
  let started!: () => void, aborted!: () => void;
  const start = new Promise<void>(resolve => { started = resolve; });
  const stopped = new Promise<void>(resolve => { aborted = resolve; });
  const f = await fixture({}, forbiddenDownload, {
    inspect: async (_source, _directory, signal) => new Promise((_, reject) => {
      started(); signal.addEventListener('abort', () => { aborted(); reject(signal.reason); }, { once: true });
    }), lookup,
  });
  try {
    const controller = new AbortController();
    const request = fetch(f.origin + '/v2/media/resolve', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ url: sampleURL }), signal: controller.signal });
    const rejected = assert.rejects(request); await start; controller.abort(); await rejected; await stopped;
    for (let i = 0; i < 100 && (await readdir(join(f.config.cacheDir, '.staging'))).length; i++) await new Promise(resolve => setTimeout(resolve, 5));
    assert.deepEqual(await readdir(join(f.config.cacheDir, '.staging')), []);
  } finally { await f.close(); }
});

it('metadata extraction shares the bounded work queue', async () => {
  let release!: () => void, started!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const first = new Promise<void>(resolve => { started = resolve; });
  const f = await fixture({ concurrency: 1, queueLimit: 0 }, forbiddenDownload, { inspect: async () => { started(); await gate; return info(); }, lookup });
  try {
    const pending = post(f.origin); await first;
    const busy = await post(f.origin); assert.equal(busy.status, 503); assert.equal((await busy.json()).error.code, 'SERVER_BUSY');
    release(); assert.equal((await pending).status, 200);
  } finally { release(); await f.close(); }
});
