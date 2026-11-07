import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { chmod, mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { it } from 'node:test';
import { promisify } from 'node:util';
import { repairH264Level } from '../src/h264-level-repair.js';
import { canRemuxNative, prepareCompatibleMedia, probeLocalMedia } from '../src/media-normalizer.js';
import { executablePath } from '../src/process.js';

const execute = promisify(execFile);
const tools = (() => {
  try { return { ffmpeg: executablePath('ffmpeg'), ffprobe: executablePath('ffprobe') }; }
  catch { return undefined; }
})();
const options = { timeout: 30_000, skip: tools ? false : 'H264 level-repair integration requires FFmpeg and ffprobe.' };

async function command(args: string[]): Promise<string> {
  assert.ok(tools);
  return (await execute(tools.ffmpeg, ['-hide_banner', '-loglevel', 'error', '-nostdin', '-y', ...args],
    { maxBuffer: 8 * 1024 * 1024 })).stdout;
}
async function fixture(path: string, tenBit = false): Promise<void> {
  await command(['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=24',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=48000', '-t', '0.75',
    '-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', tenBit ? 'high10' : 'high',
    '-level:v', '6.2', '-pix_fmt', tenBit ? 'yuv420p10le' : 'yuv420p',
    '-c:a', 'aac', '-profile:a', 'aac_low', '-ac', '1', '-movflags', '+faststart', path]);
}
async function inDirectory(run: (directory: string) => Promise<void>): Promise<void> {
  const directory = await mkdtemp(join(tmpdir(), 'recordpov-h264-level-'));
  try { await run(directory); } finally { await rm(directory, { recursive: true, force: true }); }
}

it('repairs an overdeclared H264 level while preserving every decoded frame and compressed AAC sample', options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = join(directory, 'source.mp4'), output = join(directory, 'repaired.mp4');
    const signal = new AbortController().signal;
    await fixture(source);
    const before = await probeLocalMedia(source, tools.ffprobe, signal);
    assert.equal(before.streams?.find(stream => stream.codec_type === 'video')?.level, 62);
    assert.equal(canRemuxNative(before), false);
    const stages: string[] = [];
    const result = await prepareCompatibleMedia(source, output, tools, signal, event => stages.push(event.stage));
    assert.equal(result.mode, 'level-repair');
    assert.deepEqual(stages, ['sourceProbe', 'levelRepair', 'outputProbe']);
    const after = await probeLocalMedia(output, tools.ffprobe, signal);
    assert.equal(canRemuxNative(after), true);
    assert.ok(Math.abs(Number(after.format?.duration) - Number(before.format?.duration)) <= 0.001);
    const decodedVideo = (file: string) => command(['-i', file, '-map', '0:v:0', '-an', '-f', 'framemd5', 'pipe:1']);
    assert.equal(await decodedVideo(output), await decodedVideo(source), 'All decoded frames, timestamps and geometry must remain identical.');
    const compressedAudio = (file: string) => command(['-i', file, '-map', '0:a:0', '-c', 'copy', '-f', 'hash', '-hash', 'sha256', 'pipe:1']);
    assert.equal(await compressedAudio(output), await compressedAudio(source), 'AAC samples must not be re-encoded.');
  });
});

it('does not make an incompatible ten-bit stream satisfy the native-media policy', options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = join(directory, 'ten-bit.mp4'), output = join(directory, 'repaired.mp4');
    const signal = new AbortController().signal;
    await fixture(source, true);
    await repairH264Level(source, output, tools.ffmpeg, signal);
    const after = await probeLocalMedia(output, tools.ffprobe, signal);
    assert.equal(after.streams?.find(stream => stream.codec_type === 'video')?.pix_fmt, 'yuv420p10le');
    assert.equal(canRemuxNative(after), false, 'Changing the level must never bypass pixel/profile compatibility.');
  });
});

it('converts ten-bit input normally without trying to hide its incompatibility behind a level repair', options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = join(directory, 'ten-bit.mp4'), output = join(directory, 'prepared.mp4');
    const signal = new AbortController().signal;
    await fixture(source, true);
    const stages: string[] = [];
    const result = await prepareCompatibleMedia(source, output, tools, signal, event => stages.push(event.stage));
    assert.equal(result.mode, 'transcode');
    assert.deepEqual(stages, ['sourceProbe', 'transcode', 'outputProbe']);
    assert.equal(canRemuxNative(await probeLocalMedia(output, tools.ffprobe, signal)), true);
  });
});

it('removes an incomplete failed repair and completes the original-source conversion instead', options, async () => {
  await inDirectory(async directory => {
    assert.ok(tools);
    const source = join(directory, 'source.mp4'), output = join(directory, 'prepared.mp4');
    const wrapper = join(directory, 'ffmpeg-without-bitstream-filter');
    // Model an FFmpeg build without bitstream filtering, including a partial
    // output left by the failed command. All fallback work uses real FFmpeg.
    await writeFile(wrapper, `#!/usr/bin/env node\nconst {spawnSync}=require('node:child_process');\nconst {writeFileSync}=require('node:fs');\nconst args=process.argv.slice(2);\nif(args.includes('-bsf:v')) {writeFileSync(args.at(-1),'incomplete repair'); process.exit(1);}\nconst result=spawnSync(${JSON.stringify(tools.ffmpeg)},args,{stdio:'inherit'});\nprocess.exit(result.status ?? 1);\n`);
    await chmod(wrapper, 0o700);
    const signal = new AbortController().signal;
    await fixture(source);
    const stages: string[] = [];
    const result = await prepareCompatibleMedia(source, output, { ffmpeg: wrapper, ffprobe: tools.ffprobe }, signal,
      event => stages.push(event.stage));
    assert.equal(result.mode, 'transcode');
    assert.deepEqual(stages, ['sourceProbe', 'levelRepair', 'transcode', 'outputProbe']);
    const final = await probeLocalMedia(output, tools.ffprobe, signal);
    assert.equal(canRemuxNative(final), true);
    assert.equal(result.width, 320); assert.equal(result.height, 180); assert.equal(result.hasAudio, true);
    assert.ok(Math.abs(Number(final.format?.duration) - 0.75) < .15);
  });
});
