import assert from "node:assert/strict";
import { once } from "node:events";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createServer, connect, type AddressInfo, type Socket } from "node:net";
import { join } from "node:path";
import { it } from "node:test";
import { WebSocket } from "ws";
import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { MediaStore } from "../src/store.js";
import { YouTubeBroker } from "../src/youtube-broker.js";
import { startYouTubeWorker } from "../src/youtube-worker.js";
import { IPCChannel } from "../src/youtube-ipc.js";
import { YouTubeSocks } from "../src/youtube-socks.js";
import { allowedYouTubeDestination, binaryFrame, MAX_DATA, parseBinary, parseControl, STREAM_WINDOW, StreamCredit } from "../src/youtube-protocol.js";
import { fakeDownload, sampleURL } from "./fixtures.js";

const youtubeURL = "https://www.youtube.com/watch?v=jNQXAC9IVRw";
interface Capability { sessionId: string; token: string; socketUrl: string; expiresAt: string }

it("limits relay destinations to genuine platform DNS names on TLS443", () => {
  for (const host of ["youtube.com", "www.youtube.com", "rr1.sn-123.googlevideo.com", "i.ytimg.com", "youtubei.googleapis.com"]) assert(allowedYouTubeDestination(host, 443));
  for (const host of ["youtube.com.evil.org", "evilyoutube.com", "127.0.0.1", "[::1]", "localhost", "youtube.com/secret", "user@youtube.com", "www..youtube.com", "youtube.com.", "www.youtube.com\n", "other.googleapis.com"]) assert(!allowedYouTubeDestination(host, 443), host);
  assert(!allowedYouTubeDestination("www.youtube.com", 80));
});

it("enforces binary framing, control bounds and exact finite byte credit", () => {
  const credit = new StreamCredit();
  for (let i = 0; i < 8; i++) credit.consume(MAX_DATA);
  assert.equal(credit.available, 0); assert.throws(() => credit.consume(1));
  for (const invalid of [0, -1, 1.5, "32768", STREAM_WINDOW]) assert.throws(() => credit.acknowledge(invalid));
  credit.acknowledge(MAX_DATA); credit.consume(MAX_DATA); credit.acknowledge(MAX_DATA);
  assert.equal(credit.available, MAX_DATA);
  const frame = binaryFrame(41, Buffer.from("tls bytes"));
  assert.equal(parseBinary(frame).id, 41); assert.equal(parseBinary(frame).payload.toString(), "tls bytes");
  for (const invalid of [Buffer.alloc(5), Buffer.from([2, 0, 0, 0, 1, 1]), Buffer.from([1, 0, 0, 0, 0, 1]), Buffer.alloc(MAX_DATA + 6)]) assert.throws(() => parseBinary(invalid));
  assert.throws(() => parseControl(Buffer.from("[]"))); assert.throws(() => parseControl(Buffer.alloc(4097)));
});

const h264Formats = "[{url:'https://rr1.googlevideo.com/videoplayback?signature=private-test',ext:'mp4',protocol:'https',width:1280,height:720,fps:30,vcodec:'avc1.64001f',acodec:'mp4a.40.2'}]";
// AV1 4K60 original, H.264 1080p60 + AAC-LC fallback, and a WebM tier that must never be offered.
const hybridFormats = "[{url:'https://rr1.googlevideo.com/videoplayback?itag=140',ext:'m4a',protocol:'https',vcodec:'none',acodec:'mp4a.40.2'}," +
  "{url:'https://rr1.googlevideo.com/videoplayback?itag=299',ext:'mp4',protocol:'https',width:1920,height:1080,fps:60,vcodec:'avc1.64002a',acodec:'none'}," +
  "{url:'https://rr1.googlevideo.com/videoplayback?itag=315',ext:'webm',protocol:'https',width:3840,height:2160,fps:60,vcodec:'vp9',acodec:'none'}," +
  "{url:'https://rr2.googlevideo.com/videoplayback?itag=401',ext:'mp4',protocol:'https',width:3840,height:2160,fps:60,vcodec:'av01.0.13M.08',acodec:'none'}]";
const noDirectFormats = "[{url:'https://rr1.googlevideo.com/videoplayback?itag=315',ext:'webm',protocol:'https',width:3840,height:2160,fps:60,vcodec:'vp9',acodec:'opus'}]";

async function setup(workerEnabled = false, attachmentMs = 20_000, lifetimeMs = 630_000, formats?: string) {
  const root = await mkdtemp("/tmp/rp-youtube-");
  const cacheDir = join(root, "cache"), ipcDir = join(root, "ipc"), tools = join(root, "tools");
  await mkdir(tools);
  const config = { ...loadConfig(), host: "127.0.0.1", port: 0, cacheDir, concurrency: 1, queueLimit: 4, maxBytes: 5 * 1024 * 1024, maxCacheBytes: 10 * 1024 * 1024, timeoutMs: 3000, youtubeTimeoutMs: 15_000 };
  if (workerEnabled) {
    const scripts = {
      ytdlp: `const fs=require('node:fs'),net=require('node:net'),path=require('node:path');const a=process.argv.slice(2);const p=new URL(a[a.indexOf('--proxy')+1]);if(p.protocol!=='socks5h:'||p.hostname!=='127.0.0.1')process.exit(31);const s=net.connect(Number(p.port),p.hostname);let b=Buffer.alloc(0),stage=0,bytes=0;const meta=a.includes('--dump-single-json');s.on('connect',()=>s.write(Buffer.from([5,1,0])));s.on('data',d=>{b=Buffer.concat([b,d]);if(stage===0&&b.length>=2){if(b[1]!==0)process.exit(32);b=b.subarray(2);stage=1;const h=Buffer.from('www.youtube.com');s.write(Buffer.concat([Buffer.from([5,1,0,3,h.length]),h,Buffer.from([1,187])]));}if(stage===1&&b.length>=10){if(b[1]!==0)process.exit(33);b=b.subarray(10);stage=2;s.write(meta?'meta':'media');}if(stage===2){bytes+=b.length;b=Buffer.alloc(0);}});s.on('end',()=>{s.end();if(meta)console.log(JSON.stringify({title:'Public synthetic YouTube',duration:19}));else{if(bytes!==2097152)process.exit(34);fs.writeFileSync(a[a.indexOf('--output')+1].replace('%(ext)s','mp4'),Buffer.alloc(bytes,7));}});s.on('error',()=>process.exit(35));`,
      ffmpeg: `const fs=require('node:fs'),a=process.argv.slice(2);fs.copyFileSync(a[a.indexOf('-i')+1],a.at(-1));`,
      ffprobe: `console.log(JSON.stringify({format:{duration:'19'},streams:[{codec_type:'video',codec_name:'h264',width:1280,height:720},{codec_type:'audio',codec_name:'aac'}]}));`,
    };
    for (const [name, code] of Object.entries(scripts)) { const file = join(tools, name); await writeFile(file, `#!${process.execPath}\n${code}`); await chmod(file, 0o755); }
    config.ytDlp = join(tools, "ytdlp"); config.ffmpeg = join(tools, "ffmpeg"); config.ffprobe = join(tools, "ffprobe");
  }
  if (workerEnabled && formats) {
    const extractor = join(tools, "ytdlp");
    const script = await readFile(extractor, "utf8");
    await writeFile(extractor, script.replace("title:'Public synthetic YouTube',duration:19", `title:'Public synthetic YouTube',duration:19,formats:${formats}`));
  }
  const store = new MediaStore(config, async () => assert.fail("YouTube routes must never download or prepare media")); await store.initialize();
  const worker = workerEnabled ? await startYouTubeWorker(config, ipcDir) : undefined;
  const broker = new YouTubeBroker(config, ipcDir, lifetimeMs, attachmentMs), server = createApp(config, store, broker, { lookup: async () => [{ address: "8.8.8.8", family: 4 }] });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const origin = `http://127.0.0.1:${(server.address() as AddressInfo).port}`;
  const capability = async (url = youtubeURL) => {
    const response = await fetch(`${origin}/v1/media/youtube/sessions`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url }) });
    return { status: response.status, value: await response.json() as Capability };
  };
  return { root, config, ipcDir, origin, broker, capability, store,
    close: async () => { broker.dispose(); store.dispose(); server.closeAllConnections(); await new Promise<void>(resolve => server.close(() => resolve())); await worker?.close(); await rm(root, { recursive: true, force: true }); } };
}

async function attach(capability: Capability): Promise<WebSocket> {
  const peer = new WebSocket(capability.socketUrl, { headers: { "X-YouTube-Session-Token": capability.token }, perMessageDeflate: false });
  const ready = await new Promise<Buffer>((resolve, reject) => { peer.once("error", reject); peer.once("message", raw => resolve(Buffer.from(raw as Buffer))); });
  assert.deepEqual(JSON.parse(ready.toString()), { type: "ready", version: 1 }); return peer;
}

function resolveVideo(origin: string, capability: Capability, url = youtubeURL, path = "/v2/media/resolve") {
  return fetch(`${origin}${path}`, { method: "POST", headers: { "Content-Type": "application/json", "X-YouTube-Session-Token": capability.token }, body: JSON.stringify({ url, youtubeSessionId: capability.sessionId }) });
}

it("binds capability to the exact video, client and one connected single-use claim", async () => {
  const f = await setup();
  try {
    assert.equal((await f.capability(sampleURL)).status, 400);
    const { value: capability } = await f.capability();
    assert.match(capability.token, /^[A-Za-z0-9_-]{43}$/); assert(!capability.socketUrl.includes(capability.token));
    assert.throws(() => f.broker.claim(capability.sessionId, capability.token, youtubeURL, "127.0.0.1"));
    const peer = await attach(capability);
    assert.throws(() => f.broker.claim(capability.sessionId, "a".repeat(43), youtubeURL, "127.0.0.1"));
    assert.throws(() => f.broker.claim(capability.sessionId, capability.token, youtubeURL, "192.0.2.2"));
    assert.throws(() => f.broker.claim(capability.sessionId, capability.token, "https://youtu.be/bkPwFqa89gE", "127.0.0.1"));
    const claim = f.broker.claim(capability.sessionId, capability.token, youtubeURL, "127.0.0.1");
    assert.throws(() => f.broker.claim(capability.sessionId, capability.token, youtubeURL, "127.0.0.1"));
    const cancelled = once(claim.signal, "abort"), closed = once(peer, "close"); peer.close(); await Promise.all([cancelled, closed]); assert(claim.signal.aborted);
  } finally { await f.close(); }
});

it("caps sessions and expires an unclaimed attached peer", async () => {
  const f = await setup(false, 1000, 2000);
  try {
    const first = await f.capability(); const peer = await attach(first.value);
    assert.equal((await f.capability()).status, 200); assert.equal((await f.capability()).status, 503);
    await once(peer, "close"); assert.throws(() => f.broker.claim(first.value.sessionId, first.value.token, youtubeURL, "127.0.0.1"));
    assert.equal((await f.capability()).status, 200);
  } finally { await f.close(); }
});

it("rejects unsolicited relay frames instead of becoming a public socket proxy", async () => {
  const f = await setup();
  try {
    const { value } = await f.capability(); const peer = await attach(value), closed = once(peer, "close");
    peer.send(JSON.stringify({ type: "open", id: 1, host: "www.youtube.com", port: 443 }));
    await closed; assert.throws(() => f.broker.claim(value.sessionId, value.token, youtubeURL, "127.0.0.1"));
  } finally { await f.close(); }
});

/** A phone peer that answers worker streams with bounded credit; "meta" gets 16 bytes, "media" 2 MiB. */
function servePeer(peer: WebSocket) {
  const streams = new Map<number, { credit: number; offset: number; total: number; request: string; ended: boolean }>();
  let largestOutstanding = 0;
  const pump = (id: number) => {
    const stream = streams.get(id)!;
    while (stream.credit > 0 && stream.offset < stream.total) {
      const size = Math.min(MAX_DATA, stream.credit, stream.total - stream.offset);
      peer.send(binaryFrame(id, Buffer.alloc(size, 7))); stream.credit -= size; stream.offset += size;
      largestOutstanding = Math.max(largestOutstanding, STREAM_WINDOW - stream.credit);
    }
    if (stream.offset === stream.total && !stream.ended) { stream.ended = true; peer.send(JSON.stringify({ type: "end", id })); }
  };
  peer.on("message", (raw, binary) => {
    const data = Buffer.from(raw as Buffer);
    if (binary) {
      const frame = parseBinary(data), stream = streams.get(frame.id)!;
      stream.request += frame.payload.toString(); peer.send(JSON.stringify({ type: "ack", id: frame.id, bytes: frame.payload.length }));
      if (stream.request === "meta" || stream.request === "media") { stream.total = stream.request === "meta" ? 16 : 2 * 1024 * 1024; pump(frame.id); }
    } else {
      const control = parseControl(data), id = control.id!;
      if (control.type === "open") { assert(allowedYouTubeDestination(control.host, control.port)); assert(!streams.has(id)); streams.set(id, { credit: STREAM_WINDOW, offset: 0, total: 0, request: "", ended: false }); peer.send(JSON.stringify({ type: "opened", id })); }
      else if (control.type === "ack") { const stream = streams.get(id)!; stream.credit += control.bytes!; assert(stream.credit <= STREAM_WINDOW); pump(id); }
    }
  });
  return { streams, largestOutstanding: () => largestOutstanding };
}

it("v1 with a YouTube session answers 410 without claiming the session or starting the worker", async () => {
  const f = await setup(true, 20_000, 630_000, h264Formats);
  try {
    const { value } = await f.capability(); const peer = await attach(value), relay = servePeer(peer);
    const old = await resolveVideo(f.origin, value, youtubeURL, "/v1/media/resolve");
    assert.equal(old.status, 410); assert.equal((await old.json() as { error: { code: string } }).error.code, "UPDATE_REQUIRED");
    assert.equal(relay.streams.size, 0, "v1 must not reach the worker");
    // The untouched session can still be used by an updated app.
    const response = await resolveVideo(f.origin, value); assert.equal(response.status, 200, JSON.stringify(await response.clone().json()));
    const body = await response.text();
    assert.equal(relay.streams.size, 1); assert(relay.largestOutstanding() <= STREAM_WINDOW);
    const key = await readFile(join(f.ipcDir, "worker.key"), "utf8");
    for (const secret of [value.token, key, "socks5h", "youtubeSessionId"]) assert(!body.includes(secret));
    assert.equal((await resolveVideo(f.origin, value)).status, 403, "Sessions remain single-use");
    peer.close(); await once(peer, "close");
    assert.equal((await stat(join(f.ipcDir, "worker.sock"))).mode & 0o777, 0o600);
    assert.equal((await stat(f.ipcDir)).mode & 0o777, 0o700);
  } finally { await f.close(); }
});

for (const [name, formats] of [["direct", h264Formats], ["hybrid", hybridFormats], ["none", noDirectFormats]] as const) it(`v2 isolated YouTube worker returns links only (${name})`, async () => {
  const f = await setup(true, 20_000, 630_000, formats);
  try {
    const { value } = await f.capability(), peer = await attach(value), relay = servePeer(peer);
    const response = await resolveVideo(f.origin, value);
    assert.equal(peer.readyState, WebSocket.OPEN, "WSS must remain open through the resolve response");
    assert.equal(response.headers.get("cache-control"), "no-store");
    assert.deepEqual([...relay.streams.values()].map(stream => stream.request), ["meta"], "Only metadata crosses the relay; media is never downloaded");
    if (name === "none") {
      assert.equal(response.status, 422);
      assert.deepEqual(await response.json(), { error: { code: "NO_DIRECT_MEDIA", message: "This video can't be downloaded directly. Try another link." } });
    } else {
      assert.equal(response.status, 200, JSON.stringify(await response.clone().json()));
      type Set = { assets: { role: string; url: string }[]; expected: Record<string, unknown> };
      const result = await response.json() as { id: string; playbackUrl?: string; delivery: Set & { kind: string; convert: boolean; maxBytes: number; fallback?: Set } };
      assert.equal(result.delivery.kind, "direct"); assert.equal(result.playbackUrl, undefined);
      assert.equal(result.delivery.maxBytes, f.config.maxBytes);
      await assert.rejects(stat(join(f.config.cacheDir, result.id)), { code: "ENOENT" });
      if (name === "direct") {
        assert.equal(result.delivery.convert, false); assert.equal(result.delivery.fallback, undefined);
        assert.match(result.delivery.assets[0]!.url, /signature=private-test/);
      } else {
        // A 4K AV1 original with an H264 1080p60 version: the 1080p H264 plays directly, nothing is converted.
        const itags = (set: Set) => set.assets.map(asset => new URL(asset.url).searchParams.get("itag"));
        assert.equal(result.delivery.convert, false); assert.equal(result.delivery.fallback, undefined);
        assert.deepEqual(itags(result.delivery), ["299", "140"]);
        assert.equal(result.delivery.expected.videoCodec, "h264");
        assert.equal(result.delivery.expected.width, 1920); assert.equal(result.delivery.expected.height, 1080);
        assert(!JSON.stringify(result).includes("itag=315"), "WebM is never offered");
        assert(!JSON.stringify(result).includes("itag=401"), "The 4K AV1 original is not offered when 1080p H264 exists");
      }
    }
    assert.deepEqual(await readdir(join(f.config.cacheDir, ".staging")), []);
    assert.deepEqual((await readdir(f.config.cacheDir)).filter(entry => entry !== ".staging"), []);
    peer.close(); await once(peer, "close");
  } finally { await f.close(); }
});

it("rejects unauthenticated worker IPC before source/path processing", async () => {
  const f = await setup(true);
  try {
    const socket = connect(join(f.ipcDir, "worker.sock")); await once(socket, "connect");
    const ipc = new IPCChannel(socket);
    const result = new Promise<Record<string, unknown>>(resolve => ipc.once("frame", data => resolve(JSON.parse((data as Buffer).toString()))));
    ipc.send({ type: "job", auth: "wrong", jobId: "a".repeat(24), sourceURL: "https://127.0.0.1/", directoryName: "../../escape" });
    assert.equal((await result).type, "failure"); ipc.close(); assert.deepEqual(await readdir(join(f.config.cacheDir, ".staging")), []);
  } finally { await f.close(); }
});

it("cancels running metadata extraction and removes staging when the phone disconnects", async () => {
  const f = await setup(true);
  try {
    const { value } = await f.capability(), peer = await attach(value);
    const opened = new Promise<void>(resolve => peer.on("message", (raw, binary) => {
      if (binary) return;
      const control = parseControl(Buffer.from(raw as Buffer));
      if (control.type === "open") { peer.send(JSON.stringify({ type: "opened", id: control.id })); resolve(); }
    }));
    const resolving = resolveVideo(f.origin, value);
    await opened; peer.terminate();
    const response = await resolving;
    assert.equal(response.status, 422); assert.equal((await response.json() as { error: { code: string } }).error.code, "YOUTUBE_PEER_DISCONNECTED");
    assert.deepEqual(await readdir(join(f.config.cacheDir, ".staging")), []);
  } finally { await f.close(); }
});

it("closes the entire claimed session for impossible acknowledgement credit", async () => {
  const f = await setup(true);
  try {
    const { value } = await f.capability(), peer = await attach(value);
    peer.on("message", (raw, binary) => {
      if (binary) return;
      const control = parseControl(Buffer.from(raw as Buffer));
      if (control.type === "open") peer.send(JSON.stringify({ type: "ack", id: control.id, bytes: 1 }));
    });
    const closed = once(peer, "close"), resolving = resolveVideo(f.origin, value);
    await closed; const response = await resolving; assert.equal(response.status, 422);
    assert.deepEqual(await readdir(join(f.config.cacheDir, ".staging")), []);
  } finally { await f.close(); }
});

function fixedReader(socket: Socket) {
  let buffered = Buffer.alloc(0), wake: (() => void) | undefined;
  socket.on("data", (part: Buffer) => { buffered = Buffer.concat([buffered, part]); wake?.(); });
  return async (count: number) => {
    while (buffered.length < count) await new Promise<void>(resolve => { wake = resolve; });
    wake = undefined; const data = Buffer.from(buffered.subarray(0, count)); buffered = buffered.subarray(count); return data;
  };
}
async function socksClient(port: number, host: string, destinationPort = 443) {
  const socket = connect({ host: "127.0.0.1", port, allowHalfOpen: true });
  socket.on("error", () => {}); const read = fixedReader(socket);
  await once(socket, "connect"); socket.write(Buffer.from([5, 1, 0])); assert.deepEqual(await read(2), Buffer.from([5, 0]));
  const name = Buffer.from(host), tail = Buffer.alloc(2); tail.writeUInt16BE(destinationPort);
  socket.write(Buffer.concat([Buffer.from([5, 1, 0, 3, name.length]), name, tail]));
  return { socket, read };
}

it("SOCKS refuses private/arbitrary/numeric destinations without emitting an open", async () => {
  const frames: object[] = [], relay = new YouTubeSocks(data => { if (!Buffer.isBuffer(data)) frames.push(data); }, () => assert.fail("Unexpected relay failure"));
  const port = await relay.start();
  try {
    for (const [host, destinationPort] of [["127.0.0.1", 443], ["example.org", 443], ["www.youtube.com", 80]] as const) {
      const client = await socksClient(port, host, destinationPort);
      assert.equal((await client.read(10))[1], 2); client.socket.destroy();
    }
    assert.equal(frames.length, 0);
  } finally { relay.dispose(); }
});

it("SOCKS preserves TCP half-close so response bytes arrive after request EOF", async () => {
  let relay: YouTubeSocks; let streamID = 0;
  const controls: string[] = [];
  relay = new YouTubeSocks((data, binary) => {
    if (binary) { const frame = parseBinary(data as Buffer); relay.receive(Buffer.from(JSON.stringify({ type: "ack", id: frame.id, bytes: frame.payload.length })), false); }
    else {
      const control = data as { type: string; id: number }; controls.push(control.type);
      if (control.type === "open") { streamID = control.id; queueMicrotask(() => relay.receive(Buffer.from(JSON.stringify({ type: "opened", id: streamID })), false)); }
      if (control.type === "end") {
        relay.receive(binaryFrame(streamID, Buffer.from("reply")), true);
        relay.receive(Buffer.from(JSON.stringify({ type: "end", id: streamID })), false);
      }
    }
  }, () => assert.fail("Unexpected relay failure"));
  const port = await relay.start();
  try {
    const client = await socksClient(port, "www.youtube.com"); assert.equal((await client.read(10))[1], 0);
    client.socket.end(Buffer.from("request")); assert.equal((await client.read(5)).toString(), "reply"); assert(controls.includes("end")); client.socket.destroy();
  } finally { relay.dispose(); }
});

it("keeps the YouTube worker off every network and shares only cache and owner-only IPC", async () => {
  const compose = await readFile(new URL("../deploy/compose.yaml", import.meta.url), "utf8");
  const worker = compose.split("\n  youtube-worker:\n")[1]!.split("\nvolumes:")[0]!;
  assert.match(worker, /network_mode: none/); assert(!worker.includes("ports:")); assert(!worker.includes("docker.sock"));
  assert.match(worker, /read_only: true/); assert.match(worker, /no-new-privileges:true/); assert.match(worker, /cap_drop: \[ALL\]/);
  assert.match(worker, /temporary-media:\/cache/); assert.match(worker, /youtube-ipc:\/ipc/);
  const edge = await readFile(new URL("../deploy/compose.caddy.yaml", import.meta.url), "utf8");
  assert.match(edge, /net\.ipv4\.tcp_congestion_control:\s*bbr/);
  assert(!compose.includes("tcp_congestion_control"), "The transfer setting must not reach resolver or network-disabled worker namespaces");
  assert(!edge.includes("network_mode: host"), "The edge TCP setting requires its dedicated namespace");
});
