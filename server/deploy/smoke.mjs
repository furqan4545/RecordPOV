// Explicit operator smoke test. No cookies, authentication, or user recordings.
import assert from 'node:assert/strict';

const args = process.argv.slice(2);
const base = new URL(args[0] ?? 'https://api.recordpov.app');
assert.equal(base.protocol, 'https:', 'Use the public HTTPS origin');
assert.equal(base.pathname, '/', 'Pass an origin, without a path');
const source = args[1];
const health = await fetch(new URL('/health', base), {signal: AbortSignal.timeout(10_000)});
assert.equal(health.status, 200, `Health: HTTP ${health.status}`);
console.log('HTTPS health: OK');

if (!source) {
  console.log('Pass a public social video URL as the second argument to test a real import.');
  process.exit(0);
}

const started = performance.now();
const response = await fetch(new URL('/v1/media/resolve', base), {
  method: 'POST', headers: {'Content-Type': 'application/json'},
  body: JSON.stringify({url: source}), signal: AbortSignal.timeout(945_000),
});
const payload = await response.json();
assert.equal(response.status, 200, `Resolve HTTP ${response.status}: ${JSON.stringify(payload)}`);
const file = new URL(payload.playbackUrl);
assert.equal(file.origin, base.origin, 'Playback must use the public HTTPS origin');
assert.match(file.pathname, /^\/v1\/media\/[a-f0-9]{24}\/file$/);
const expires = Date.parse(payload.expiresAt) - Date.now();
assert(expires > 0 && expires <= 14_400_000 + 60_000, 'Expected a live, at most four-hour cache entry');
const range = await fetch(file, {headers: {Range: 'bytes=0-31'}, signal: AbortSignal.timeout(15_000)});
assert.equal(range.status, 206, 'Byte-range playback support');
assert.equal(range.headers.get('content-type'), 'video/mp4');
const contentRange = range.headers.get('content-range') ?? '';
assert.match(contentRange, /^bytes 0-31\/[0-9]+$/);
assert(Number(contentRange.split('/')[1]) <= 2_147_483_648, 'Media-size bound');
const bytes = new Uint8Array(await range.arrayBuffer());
assert.equal(bytes.length, 32);
assert.equal(new TextDecoder().decode(bytes.slice(4, 8)), 'ftyp', 'Normalized MP4 header');
console.log(JSON.stringify({result: 'OK', seconds: Math.round((performance.now() - started) / 100) / 10,
  title: payload.title, platform: payload.platform, duration: payload.duration,
  fileBytes: Number(contentRange.split('/')[1]), range: range.status}));
