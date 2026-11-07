import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";
import { planInstagramProgressive, tryInstagramProgressive, type FormatInventory, type TrialTiming } from "../src/instagram-progressive.js";
import type { MediaProbe } from "../src/media-normalizer.js";

const candidateID = "opaque-variant-37";
function inventory(hasAudio = true): FormatInventory {
  return { width: 720, height: 1280, fps: 30, duration: 3, vcodec: "vp9", acodec: hasAudio ? "opus" : "none",
    formats: [
      { format_id: candidateID, vcodec: null, ext: "mp4", protocol: "https", url: "https://cdn.example.test/first.mp4?signature=synthetic" },
      { format_id: "opaque-variant-84", vcodec: null, ext: "mp4", protocol: "https", url: "https://cdn.example.test/second.mp4" },
    ] };
}
function probeFixture(options: { width?: number; height?: number; hasAudio?: boolean; duration?: number; fps?: string } = {}): MediaProbe {
  return { format: { duration: String(options.duration ?? 3), format_name: "mov,mp4,m4a,3gp,3g2,mj2", tags: { major_brand: "isom" } },
    streams: [
      { index: 0, codec_type: "video", codec_name: "h264", profile: "High", level: 31, pix_fmt: "yuv420p",
        width: options.width ?? 720, height: options.height ?? 1280, sample_aspect_ratio: "1:1", field_order: "progressive",
        avg_frame_rate: options.fps ?? "30/1", r_frame_rate: options.fps ?? "30/1" },
      ...(options.hasAudio === false ? [] : [{ index: 1, codec_type: "audio", codec_name: "aac", profile: "LC", channels: 1,
        channel_layout: "mono", sample_rate: "48000" }]),
    ] };
}

interface Harness {
  directory: string; infoPath: string; ytDlp: string; ffprobe: string; log: string; probeLog: string; started: string;
}
async function withHarness(settings: { probe?: MediaProbe; hang?: boolean; bytes?: number }, run: (harness: Harness) => Promise<void>): Promise<void> {
  const root = await mkdtemp(join(tmpdir(), "recordpov-ig-trial-"));
  const directory = join(root, "work"), tools = join(root, "tools");
  await mkdir(directory); await mkdir(tools);
  const harness: Harness = { directory, infoPath: join(directory, "extractor-info.json"), ytDlp: join(tools, "downloader.cjs"),
    ffprobe: join(tools, "probe.cjs"), log: join(root, "calls.jsonl"), probeLog: join(root, "probes.jsonl"), started: join(root, "started") };
  const metadata = join(root, "probe.json");
  await writeFile(harness.infoPath, JSON.stringify(inventory()), { mode: 0o600 });
  await writeFile(metadata, JSON.stringify(settings.probe ?? probeFixture()));
  const downloader = `const fs=require('node:fs'); const args=process.argv.slice(2);
fs.appendFileSync(${JSON.stringify(harness.log)},JSON.stringify(args)+'\\n');
const info=args[args.indexOf('--load-info-json')+1]; if(!info||(fs.statSync(info).mode&511)!==384)process.exit(31);
const output=args[args.indexOf('--output')+1].replace('%(ext)s','mp4');
fs.writeFileSync(output,Buffer.alloc(${settings.bytes ?? 64},42));fs.writeFileSync(output+'.part','partial fixture');
fs.writeFileSync(${JSON.stringify(harness.started)},'ready');
${settings.hang ? "setTimeout(()=>process.exit(0),30000);" : ""}`;
  const prober = `const fs=require('node:fs');fs.appendFileSync(${JSON.stringify(harness.probeLog)},JSON.stringify(process.argv.slice(2))+'\\n');process.stdout.write(fs.readFileSync(${JSON.stringify(metadata)}));`;
  for (const [path, body] of [[harness.ytDlp, downloader], [harness.ffprobe, prober]]) {
    await writeFile(path!, `#!${process.execPath}\n${body}\n`); await chmod(path!, 0o755);
  }
  try { await run(harness); } finally { await rm(root, { recursive: true, force: true }); }
}
function options(harness: Harness, signal = new AbortController().signal) {
  return { info: inventory(), directory: harness.directory, infoPath: harness.infoPath, ytDlp: harness.ytDlp, ffprobe: harness.ffprobe,
    sharedArgs: ["--ignore-config", "--no-exec", "--no-remote-components"], signal, maxBytes: 1024 };
}
async function calls(path: string): Promise<string[][]> {
  try { return (await readFile(path, "utf8")).trim().split("\n").filter(Boolean).map(value => JSON.parse(value) as string[]); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
}
async function assertClean(harness: Harness, accepted = false): Promise<void> {
  const names = await readdir(harness.directory);
  assert.ok(!names.some(name => name.startsWith("candidate.")), "Every candidate and partial file must be removed.");
  assert.equal(names.includes("source.mp4"), accepted);
  assert.ok(names.includes("extractor-info.json"), "The caller's metadata must remain available to its fallback.");
}
async function waitForStart(path: string): Promise<void> {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    try { await stat(path); return; } catch { await new Promise(resolve => setTimeout(resolve, 10)); }
  }
  assert.fail("The synthetic candidate process never started.");
}

it("accepts exactly one matching candidate using private metadata and canonicalizes its source path", { timeout: 10_000 }, async () => {
  await withHarness({}, async harness => {
    const info = inventory();
    assert.deepEqual(planInstagramProgressive(info), { formatId: candidateID, width: 720, height: 1280, fps: 30, duration: 3, hasAudio: true });
    const events: TrialTiming[] = [];
    const result = await tryInstagramProgressive({ ...options(harness), onStage: event => events.push(event) });
    assert.equal(result, join(harness.directory, "source.mp4"));
    assert.equal((await stat(result!)).size, 64);
    const downloads = await calls(harness.log);
    assert.equal(downloads.length, 1);
    const args = downloads[0]!;
    assert.equal(args[args.indexOf("--format") + 1], candidateID);
    assert.equal(args[args.indexOf("--load-info-json") + 1], harness.infoPath);
    assert.equal(args[args.indexOf("--max-filesize") + 1], "1024");
    for (const flag of ["--ignore-config", "--no-exec", "--no-remote-components"]) assert.ok(args.includes(flag));
    assert.ok(!args.some(value => value.startsWith("https://")), "The trial must reuse extraction, not request a platform page again.");
    const probes = await calls(harness.probeLog);
    assert.equal(probes.length, 1);
    assert.equal(probes[0]![probes[0]!.indexOf("-protocol_whitelist") + 1], "file,pipe");
    assert.deepEqual(events.map(event => event.stage), ["candidateDownload", "candidateProbe"]);
    for (const event of events) {
      assert.deepEqual(Object.keys(event).sort(), ["elapsedMs", "stage"]);
      assert.ok(Number.isSafeInteger(event.elapsedMs) && event.elapsedMs >= 0);
    }
    await assertClean(harness, true);
  });
});

it("rejects a native-compatible candidate with lower resolution without trying a second variant", async () => {
  await withHarness({ probe: probeFixture({ width: 360, height: 640 }) }, async harness => {
    assert.equal(await tryInstagramProgressive(options(harness)), undefined);
    assert.equal((await calls(harness.log)).length, 1);
    await assertClean(harness);
  });
});

it("rejects a candidate that would silently remove the selected source audio", async () => {
  await withHarness({ probe: probeFixture({ hasAudio: false }) }, async harness => {
    assert.equal(await tryInstagramProgressive(options(harness)), undefined);
    assert.equal((await calls(harness.log)).length, 1);
    await assertClean(harness);
  });
});

it("rejects a shortened candidate despite matching raster and codecs", async () => {
  await withHarness({ probe: probeFixture({ duration: 2 }) }, async harness => {
    assert.equal(await tryInstagramProgressive(options(harness)), undefined);
    await assertClean(harness);
  });
});

it("falls back after its bounded time budget and leaves no candidate files", { timeout: 10_000 }, async () => {
  await withHarness({ hang: true }, async harness => {
    const start = performance.now();
    const result = await tryInstagramProgressive({ ...options(harness), limits: { timeoutMs: 200, maxBytes: 256 } });
    assert.equal(result, undefined);
    assert.ok(performance.now() - start >= 150, "The bounded deadline should expire, rather than immediately rejecting a valid plan.");
    // A heavily loaded runner can exhaust the deadline before Node starts the
    // child. Both pre-launch and mid-download cancellation are valid fallbacks.
    assert.ok((await calls(harness.log)).length <= 1);
    assert.equal((await calls(harness.probeLog)).length, 0);
    await assertClean(harness);
  });
});

it("enforces a lower byte budget even when the downloader ignores its filesize flag", async () => {
  await withHarness({ bytes: 512 }, async harness => {
    assert.equal(await tryInstagramProgressive({ ...options(harness), limits: { timeoutMs: 5000, maxBytes: 128 } }), undefined);
    const args = (await calls(harness.log))[0]!;
    assert.equal(args[args.indexOf("--max-filesize") + 1], "128");
    assert.equal((await calls(harness.probeLog)).length, 0);
    await assertClean(harness);
  });
});

it("propagates parent cancellation instead of swallowing it as a trial fallback", { timeout: 10_000 }, async () => {
  await withHarness({ hang: true }, async harness => {
    const controller = new AbortController();
    const reason = new Error("synthetic parent cancellation");
    const task = tryInstagramProgressive({ ...options(harness, controller.signal), limits: { timeoutMs: 5000, maxBytes: 256 } });
    const rejection = assert.rejects(task, error => error === reason);
    await waitForStart(harness.started);
    controller.abort(reason);
    await rejection;
    assert.equal((await calls(harness.log)).length, 1);
    assert.equal((await calls(harness.probeLog)).length, 0);
    await assertClean(harness);
  });
});

it("does not launch a trial when the selected source is already H264", async () => {
  await withHarness({}, async harness => {
    const info = { ...inventory(), vcodec: "avc1.64001f" };
    assert.equal(planInstagramProgressive(info), undefined);
    assert.equal(await tryInstagramProgressive({ ...options(harness), info }), undefined);
    assert.equal((await calls(harness.log)).length, 0);
    await assertClean(harness);
  });
});

it("accepts an exact 30fps candidate for Instagram's real null-fps metadata shape", async () => {
  await withHarness({ probe: probeFixture({ hasAudio: false }) }, async harness => {
    const info: FormatInventory = { ...inventory(false), fps: null };
    await writeFile(harness.infoPath, JSON.stringify(info), { mode: 0o600 });
    assert.equal(planInstagramProgressive(info)?.fps, 30);
    const result = await tryInstagramProgressive({ ...options(harness), info });
    assert.equal(result, join(harness.directory, "source.mp4"));
    assert.equal((await calls(harness.log)).length, 1);
    await assertClean(harness, true);
  });
});

it("uses the actual selected-file probe when Instagram omits duration and contradicts media facts", async () => {
  await withHarness({ probe: probeFixture({ hasAudio: false }) }, async harness => {
    const base = inventory();
    const info: FormatInventory = {
      vcodec: "vp9", acodec: "opus", width: 360, height: 640, fps: null,
      formats: base.formats!,
      requested_downloads: [{ format_id: "selected-vp9", vcodec: "vp9", acodec: "opus", width: 360, height: 640, fps: null }],
    };
    assert.equal(Object.hasOwn(info, "duration"), false);
    const actualSelectedProbe = probeFixture({ hasAudio: false });
    actualSelectedProbe.format = { duration: "3", format_name: "matroska,webm" };
    const selectedVideo = actualSelectedProbe.streams?.find(stream => stream.codec_type === "video");
    assert.ok(selectedVideo);
    selectedVideo.codec_name = "vp9"; selectedVideo.profile = "Profile 0";
    const original = join(harness.directory, "original-selected.webm");
    await writeFile(original, "already downloaded selected source");
    await writeFile(harness.infoPath, JSON.stringify(info), { mode: 0o600 });
    assert.deepEqual(planInstagramProgressive(info, actualSelectedProbe),
      { formatId: candidateID, width: 720, height: 1280, fps: 30, duration: 3, hasAudio: false });
    const result = await tryInstagramProgressive({ ...options(harness), info, actualSelectedProbe });
    assert.equal(result, join(harness.directory, "source.mp4"));
    assert.equal((await calls(harness.log)).length, 1);
    assert.equal(await readFile(original, "utf8"), "already downloaded selected source");
    await assertClean(harness, true);
  });
});

it("keeps the already downloaded canonical source intact when an actual-probe candidate is rejected", async () => {
  await withHarness({ probe: probeFixture({ width: 360, height: 640, hasAudio: false }) }, async harness => {
    const info: FormatInventory = { ...inventory(false), fps: null };
    delete info.duration;
    const actualSelectedProbe = probeFixture({ hasAudio: false });
    const selectedVideo = actualSelectedProbe.streams?.find(stream => stream.codec_type === "video");
    assert.ok(selectedVideo); selectedVideo.codec_name = "vp9";
    const original = join(harness.directory, "source.mp4");
    await writeFile(original, "original selected video must survive the trial");
    await writeFile(harness.infoPath, JSON.stringify(info), { mode: 0o600 });
    const result = await tryInstagramProgressive({ ...options(harness), info, actualSelectedProbe });
    assert.equal(result, undefined);
    assert.equal(await readFile(original, "utf8"), "original selected video must survive the trial");
    assert.equal((await calls(harness.log)).length, 1);
    await assertClean(harness, true);
  });
});
