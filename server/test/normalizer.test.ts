import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { it } from "node:test";
import { promisify } from "node:util";
import { canRemuxNative, prepareCompatibleMedia } from "../src/media-normalizer.js";
import { executablePath } from "../src/process.js";

const execute = promisify(execFile);
const tools = (() => {
  try { return { ffmpeg: executablePath(process.env.FFMPEG_PATH || "ffmpeg"), ffprobe: executablePath(process.env.FFPROBE_PATH || "ffprobe") }; }
  catch { return undefined; }
})();
const options = { timeout: 30_000, skip: tools ? false : "Synthetic normalizer integration requires FFmpeg and ffprobe." };

interface Stream {
  codec_type?: string; codec_name?: string; profile?: string; pix_fmt?: string; width?: number; height?: number;
  sample_aspect_ratio?: string; display_aspect_ratio?: string; avg_frame_rate?: string; channels?: number; sample_rate?: string;
  side_data_list?: { rotation?: number; displaymatrix?: string }[];
  tags?: { rotate?: string };
}
interface Probe { streams: Stream[]; format: { duration: string; format_name?: string; tags?: { major_brand?: string; compatible_brands?: string } } }

async function command(path: string, args: string[]): Promise<Buffer> {
  const result = await execute(path, args, { encoding: "buffer", maxBuffer: 16 * 1024 * 1024 });
  return result.stdout;
}
async function ffmpeg(args: string[]): Promise<Buffer> {
  assert.ok(tools);
  return await command(tools.ffmpeg, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", ...args]);
}
async function probe(path: string): Promise<Probe> {
  assert.ok(tools);
  return JSON.parse((await command(tools.ffprobe, ["-v", "error", "-show_streams", "-show_format", "-of", "json", path])).toString()) as Probe;
}
async function fixture(directory: string, video = "testsrc2=size=320x180:rate=24", audio = true): Promise<string> {
  const path = join(directory, "source.mp4");
  await ffmpeg(["-f", "lavfi", "-i", video,
    ...(audio ? ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000"] : []),
    "-t", "1.25", "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "main", "-level:v", "4.1", "-pix_fmt", "yuv420p",
    ...(audio ? ["-c:a", "aac", "-profile:a", "aac_low", "-b:a", "96k", "-ac", "1"] : ["-an"]),
    "-movflags", "+faststart", path]);
  return path;
}
async function encodedHash(path: string, track: "v" | "a"): Promise<string> {
  return (await ffmpeg(["-i", path, "-map", `0:${track}:0`, "-c", "copy", "-f", "hash", "-hash", "sha256", "pipe:1"])).toString().trim();
}
async function rotatedFixture(source: string, destination: string): Promise<void> {
  // Write the standard MP4 track-header display matrix directly. FFmpeg releases
  // disagree on whether `-metadata rotate=90` still writes this metadata.
  // ffprobe below independently verifies the resulting real container transform.
  const data = await readFile(source);
  const typeOffset = data.indexOf(Buffer.from("tkhd"));
  assert.ok(typeOffset >= 4, "Synthetic MP4 must contain a track header.");
  const version = data[typeOffset + 4];
  assert.ok(version === 0 || version === 1);
  const matrixOffset = typeOffset + (version === 0 ? 44 : 56);
  const matrix = [0, -65536, 0, 65536, 0, 0, 0, 0, 1073741824];
  matrix.forEach((value, index) => data.writeInt32BE(value, matrixOffset + index * 4));
  await writeFile(destination, data);
}
async function audioSignal(path: string): Promise<{ rms: number; tone: number; other: number }> {
  const pcm = await ffmpeg(["-i", path, "-map", "0:a:0", "-ac", "1", "-ar", "48000", "-f", "f32le", "pipe:1"]);
  const start = Math.round(.15 * 48_000), count = Math.min(Math.round(.8 * 48_000), pcm.length / 4 - start);
  assert.ok(count > 10_000, "Decode real PCM samples, not just audio-track metadata.");
  let energy = 0, toneReal = 0, toneImag = 0, otherReal = 0, otherImag = 0;
  for (let i = 0; i < count; i++) {
    const sample = pcm.readFloatLE((start + i) * 4);
    energy += sample * sample;
    const phase = 2 * Math.PI * i / 48_000;
    toneReal += sample * Math.cos(phase * 440); toneImag += sample * Math.sin(phase * 440);
    otherReal += sample * Math.cos(phase * 710); otherImag += sample * Math.sin(phase * 710);
  }
  return { rms: Math.sqrt(energy / count), tone: 2 * Math.hypot(toneReal, toneImag) / count,
    other: 2 * Math.hypot(otherReal, otherImag) / count };
}
async function assertAudibleTone(path: string): Promise<void> {
  const signal = await audioSignal(path);
  assert.ok(signal.rms > .06 && signal.rms < .12, `Expected non-silent, unclipped 440Hz source; RMS=${signal.rms}`);
  assert.ok(signal.tone > .09, `Expected the actual 440Hz signal, amplitude=${signal.tone}`);
  assert.ok(signal.tone > signal.other * 20, "The expected tone must dominate an unrelated frequency.");
}
async function inDirectory(run: (directory: string) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), "recordpov-normalizer-"));
  try { await run(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}
function framesPerSecond(value: string | undefined): number {
  const [numerator, denominator] = (value ?? "0/1").split("/").map(Number);
  return (numerator ?? 0) / (denominator ?? 1);
}

it("remuxes a compatible source without re-encoding video or the audible source audio", options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = await fixture(directory);
    const output = join(directory, "prepared.mp4");
    const stages: string[] = [];
    const result = await prepareCompatibleMedia(source, output, tools, new AbortController().signal, event => {
      assert.ok(event.elapsedMs >= 0); stages.push(event.stage);
    });
    assert.equal(result.mode, "remux");
    assert.equal(result.width, 320); assert.equal(result.height, 180); assert.equal(result.hasAudio, true);
    assert.deepEqual(stages, ["sourceProbe", "remux", "outputProbe"]);
    assert.equal(await encodedHash(output, "v"), await encodedHash(source, "v"), "Compressed video samples must be unchanged.");
    assert.equal(await encodedHash(output, "a"), await encodedHash(source, "a"), "Compressed source audio samples must be unchanged.");
    const before = await probe(source), after = await probe(output);
    assert.ok(Math.abs(Number(before.format.duration) - Number(after.format.duration)) <= .15);
    await assertAudibleTone(output);
    const inputSignal = await audioSignal(source), outputSignal = await audioSignal(output);
    assert.ok(Math.abs(inputSignal.rms - outputSignal.rms) < .002, "Remux must not lower source audio gain.");
  });
});

it("physically orients rotated input through the transcode fallback and retains source audio", options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = await fixture(directory);
    const rotated = join(directory, "rotated.mp4"), output = join(directory, "prepared.mp4");
    await rotatedFixture(source, rotated);
    const original = (await probe(rotated)).streams.find(stream => stream.codec_type === "video");
    assert.ok(original?.side_data_list?.some(data => Math.abs(data.rotation ?? 0) === 90), "The fixture must contain real rotation metadata.");
    const result = await prepareCompatibleMedia(rotated, output, tools, new AbortController().signal);
    assert.equal(result.mode, "transcode");
    assert.equal(result.width, 180); assert.equal(result.height, 320);
    const video = (await probe(output)).streams.find(stream => stream.codec_type === "video");
    assert.equal(video?.codec_name, "h264"); assert.equal(video?.pix_fmt, "yuv420p");
    assert.ok(video?.side_data_list?.every(data => !data.rotation || data.rotation % 360 === 0) ?? true);
    await assertAudibleTone(output);
  });
});

it("keeps compatible 1600x900 60fps media unchanged instead of shrinking it to 720p30", options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = await fixture(directory, "testsrc2=size=1600x900:rate=60");
    const output = join(directory, "prepared.mp4");
    const result = await prepareCompatibleMedia(source, output, tools, new AbortController().signal);
    assert.equal(result.mode, "remux");
    assert.equal(result.width, 1600); assert.equal(result.height, 900);
    assert.equal(result.width % 2, 0); assert.equal(result.height % 2, 0);
    const video = (await probe(output)).streams.find(stream => stream.codec_type === "video");
    assert.ok(Math.abs(framesPerSecond(video?.avg_frame_rate) - 60) < .001);
    assert.equal(await encodedHash(output, "v"), await encodedHash(source, "v"));
    assert.equal(video?.sample_aspect_ratio, "1:1"); assert.equal(video?.pix_fmt, "yuv420p");
    await assertAudibleTone(output);
  });
});

it("preserves actual 4K60 geometry and AAC samples when AV1 requires H264 conversion", { ...options, timeout: 60_000 }, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = join(directory, "original-av1.mp4"), output = join(directory, "prepared.mp4");
    await ffmpeg(["-f", "lavfi", "-i", "color=c=blue:size=3840x2160:rate=60", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
      "-t", "0.1", "-c:v", "libaom-av1", "-cpu-used", "8", "-row-mt", "1", "-threads", "2", "-crf", "40", "-b:v", "0", "-pix_fmt", "yuv420p",
      "-c:a", "aac", "-profile:a", "aac_low", "-ac", "1", source]);
    const original = await probe(source);
    assert.equal(original.streams.find(stream => stream.codec_type === "video")?.codec_name, "av1");
    const result = await prepareCompatibleMedia(source, output, tools, new AbortController().signal);
    assert.equal(result.mode, "transcode"); assert.equal(result.width, 3840); assert.equal(result.height, 2160);
    const after = await probe(output), video = after.streams.find(stream => stream.codec_type === "video");
    assert.equal(video?.codec_name, "h264"); assert.equal(video?.pix_fmt, "yuv420p");
    assert.ok(Math.abs(framesPerSecond(video?.avg_frame_rate) - 60) < .001);
    assert.equal(await encodedHash(output, "a"), await encodedHash(source, "a"), "Already compatible AAC must survive video conversion unchanged.");
    assert.ok(Math.abs(Number(after.format.duration) - Number(original.format.duration)) <= .15);
  });
});

it("keeps a compatible silent video silent while preserving its compressed video samples", options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = await fixture(directory, "testsrc2=size=180x320:rate=24", false);
    const output = join(directory, "prepared.mp4");
    const result = await prepareCompatibleMedia(source, output, tools, new AbortController().signal);
    assert.equal(result.mode, "remux"); assert.equal(result.hasAudio, false);
    assert.equal(result.width, 180); assert.equal(result.height, 320);
    assert.equal((await probe(output)).streams.filter(stream => stream.codec_type === "audio").length, 0);
    assert.equal(await encodedHash(output, "v"), await encodedHash(source, "v"));
  });
});

it("copies compatible H264 video while converting only Opus audio to native AAC", options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const original = await fixture(directory);
    const source = join(directory, "h264-opus.mkv"), output = join(directory, "prepared.mp4");
    await ffmpeg(["-i", original, "-c:v", "copy", "-c:a", "libopus", "-b:a", "96k", source]);
    const before = await probe(source);
    assert.equal(before.streams.find(stream => stream.codec_type === "audio")?.codec_name, "opus");
    const stages: string[] = [];
    const result = await prepareCompatibleMedia(source, output, tools, new AbortController().signal,
      event => { stages.push(event.stage); });
    assert.equal(result.mode, "audio-transcode"); assert.equal(result.hasAudio, true);
    assert.ok(stages.includes("audioTranscode")); assert.ok(!stages.includes("transcode"));
    assert.equal(await encodedHash(output, "v"), await encodedHash(source, "v"), "Audio conversion must leave compressed video samples untouched.");
    const after = await probe(output);
    const audio = after.streams.find(stream => stream.codec_type === "audio");
    assert.equal(audio?.codec_name, "aac"); assert.equal(audio?.profile, "LC");
    assert.ok(audio?.channels === 1 || audio?.channels === 2);
    assert.ok(Number(audio?.sample_rate) >= 8000 && Number(audio?.sample_rate) <= 48000);
    assert.ok(Math.abs(Number(after.format.duration) - Number(before.format.duration)) <= .15);
    await assertAudibleTone(output);
    const inputSignal = await audioSignal(source), outputSignal = await audioSignal(output);
    assert.ok(Math.abs(inputSignal.rms - outputSignal.rms) < .01, "Audio-only conversion must retain source gain.");
  });
});

it("remuxes an actual square-pixel MP4 with no declared SAR without re-encoding its video", options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = join(directory, "missing-sar.mp4"), output = join(directory, "prepared.mp4");
    await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=720x1280:rate=30", "-t", "0.4", "-vf", "setsar=0",
      "-c:v", "libx264", "-preset", "veryfast", "-profile:v", "high", "-level:v", "3.1", "-pix_fmt", "yuv420p",
      "-an", "-movflags", "+faststart", source]);
    const before = await probe(source);
    const video = before.streams.find(stream => stream.codec_type === "video");
    assert.ok(video);
    assert.equal(video.sample_aspect_ratio, undefined, "The real fixture must omit SAR, rather than merely mocking probe metadata.");
    assert.equal(video.display_aspect_ratio, undefined, "No contradictory display aspect ratio may be present.");
    assert.ok(before.format.format_name?.split(",").includes("mp4"));
    assert.equal(before.format.tags?.major_brand, "isom");
    assert.ok(before.format.tags?.compatible_brands?.includes("mp41"));
    assert.equal(canRemuxNative(before), true);
    const result = await prepareCompatibleMedia(source, output, tools, new AbortController().signal);
    assert.equal(result.mode, "remux"); assert.equal(result.hasAudio, false);
    assert.equal(result.width, 720); assert.equal(result.height, 1280);
    assert.equal(await encodedHash(output, "v"), await encodedHash(source, "v"), "Inferring square pixels must not re-encode or change video packets.");
    assert.ok(Math.abs(Number((await probe(output)).format.duration) - Number(before.format.duration)) <= .15);
  });
});
