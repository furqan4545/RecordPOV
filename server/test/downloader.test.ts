import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, writeFile, readFile, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { delimiter, join } from "node:path";
import { it } from "node:test";
import { loadConfig } from "../src/config.js";
import { classifyDownloadError, createDownloader, type DownloadTiming } from "../src/downloader.js";
import { AppError } from "../src/errors.js";
import { CommandError, executablePath } from "../src/process.js";
import { normalizeSource } from "../src/source.js";
import { sampleURL } from "./fixtures.js";

it("reuses owner-only extractor metadata without a second platform URL and emits only safe timings", async () => {
  const folder = await mkdtemp(join(tmpdir(), "roast-downloader-test-"));
  const tools = join(folder, "tools");
  const output = join(folder, "output");
  await mkdir(tools); await mkdir(output);
  const originalPath = process.env.PATH;
  try {
    const scripts: Record<string, string> = {
      "fake-ytdlp": `const fs = require('node:fs'); const path = require('node:path'); const args = process.argv.slice(2); const log=${JSON.stringify(join(folder, "calls.json"))}; const calls=fs.existsSync(log)?JSON.parse(fs.readFileSync(log,'utf8')):[]; calls.push(args); fs.writeFileSync(log,JSON.stringify(calls)); if(args.includes('--dump-single-json')) { console.log(JSON.stringify({title:'A source video', uploader:'A creator', duration:3, is_live:false,webpage_url:${JSON.stringify(sampleURL)},formats:[{format_id:'fixture',url:'https://cdn.example.test/video?signature=private-fixture',ext:'mp4',vcodec:'avc1',acodec:'mp4a'}]})); } else { const loc=args[args.indexOf('--ffmpeg-location')+1]; if(!path.isAbsolute(loc)) process.exit(42); if(!args.includes('--load-info-json')||args.includes(${JSON.stringify(sampleURL)})) process.exit(43); const info=args[args.indexOf('--load-info-json')+1]; if((fs.statSync(info).mode&511)!==384)process.exit(44);const raw=fs.readFileSync(info,'utf8');if(raw.includes('socks5h:')||!JSON.parse(raw).formats[0].url.includes('private-fixture'))process.exit(45);if(fs.existsSync(${JSON.stringify(join(folder, "fail.flag"))})){process.stderr.write('private-fixture https://cdn.example.test/video?signature=private-fixture');process.exit(1);}const output=args[args.indexOf('--output')+1].replace('%(ext)s','mp4'); fs.writeFileSync(output,'test video bytes'); }`,
      "fake-ffmpeg": `const fs = require('node:fs'); const args=process.argv.slice(2); fs.copyFileSync(args[args.indexOf('-i')+1],args.at(-1));`,
      "fake-ffprobe": `console.log(JSON.stringify({format:{duration:'3'},streams:[{codec_type:'video',codec_name:'h264',width:720,height:1280},{codec_type:'audio',codec_name:'aac'}]}));`,
    };
    for (const [name, contents] of Object.entries(scripts)) {
      const path = join(tools, name);
      await writeFile(path, `#!${process.execPath}\n${contents}\n`);
      await chmod(path, 0o755);
    }
    process.env.PATH = `${tools}${delimiter}${originalPath || ""}`;
    assert.equal(executablePath("fake-ffmpeg"), join(tools, "fake-ffmpeg"));
    const config = { ...loadConfig(), ytDlp: "fake-ytdlp", ffmpeg: "fake-ffmpeg", ffprobe: "fake-ffprobe" };
    const events: DownloadTiming[] = [];
    const download = createDownloader(config, async (source) => source, { proxyURL: "socks5h://127.0.0.1:31991" }, event => events.push(event));
    const result = await download(normalizeSource(sampleURL), output, new AbortController().signal);
    assert.equal(result.title, "A source video");
    assert.equal(result.creator, "A creator");
    assert.equal(result.duration, 3);
    assert.equal(result.hasAudio, true);
    assert.equal(result.width, 720);
    const calls = JSON.parse(await readFile(join(folder, "calls.json"), "utf8")) as string[][];
    assert.equal(calls.length, 2);
    assert.ok(calls[0]?.includes(sampleURL));
    assert.ok(calls[1]?.includes("--load-info-json"));
    assert.ok(!calls[1]?.includes(sampleURL));
    for (const args of calls) for (const required of ["--no-exec", "--no-plugin-dirs", "--no-remote-components", "--proxy", "--js-runtimes"]) assert.ok(args.includes(required));
    await assert.rejects(stat(join(output, "extractor-info.json")), { code: "ENOENT" });
    for (const stage of ["preflight", "extract", "download", "sourceProbe", "transcode", "outputProbe", "total"]) assert.ok(events.some(event => event.stage === stage));
    for (const event of events) {
      assert.deepEqual(Object.keys(event).sort(), ["elapsedMs", "event", "id", "platform", "stage"]);
      assert.match(event.id, /^[a-f0-9]{24}$/);
      assert.ok(Number.isSafeInteger(event.elapsedMs) && event.elapsedMs >= 0);
    }
    for (const privateValue of [sampleURL, "A source video", "A creator", "private-fixture", "cdn.example.test", "socks5h", "31991"]) assert.ok(!JSON.stringify(events).includes(privateValue));
    const reusedOutput = join(folder, "reused-output"); await mkdir(reusedOutput);
    const extractedInfo = { title: "Already inspected", duration: 3,
      formats: [{ format_id: "fixture", url: "https://cdn.example.test/video?signature=private-fixture", ext: "mp4", vcodec: "avc1", acodec: "mp4a" }] };
    const reusedEvents: DownloadTiming[] = [];
    const reused = createDownloader(config, async source => source, { proxyURL: "socks5h://127.0.0.1:31991" },
      event => reusedEvents.push(event), { extractedInfo });
    assert.equal((await reused(normalizeSource(sampleURL), reusedOutput, new AbortController().signal)).title, "Already inspected");
    const reusedCalls = JSON.parse(await readFile(join(folder, "calls.json"), "utf8")) as string[][];
    assert.equal(reusedCalls.length, 3, "A reused inspection must add only the media download command");
    assert.ok(reusedCalls[2]?.includes("--load-info-json"));
    assert.ok(!reusedCalls[2]?.includes("--dump-single-json"));
    assert.ok(!reusedEvents.some(event => event.stage === "extract"));
    await assert.rejects(stat(join(reusedOutput, "extractor-info.json")), { code: "ENOENT" });
    const perCallOutput = join(folder, "per-call-output"); await mkdir(perCallOutput);
    const perCallEvents: DownloadTiming[] = [];
    const perCall = createDownloader(config, async source => source, { proxyURL: "socks5h://127.0.0.1:31991" },
      event => perCallEvents.push(event));
    const perCallResult = await perCall(normalizeSource(sampleURL), perCallOutput, new AbortController().signal,
      { ...extractedInfo, title: "Same job inspection" });
    assert.equal(perCallResult.title, "Same job inspection");
    const perCallCalls = JSON.parse(await readFile(join(folder, "calls.json"), "utf8")) as string[][];
    assert.equal(perCallCalls.length, 4);
    assert.ok(perCallCalls[3]?.includes("--load-info-json"));
    assert.ok(!perCallEvents.some(event => event.stage === "extract"));
    await assert.rejects(stat(join(perCallOutput, "extractor-info.json")), { code: "ENOENT" });
    for (const invalid of [
      { _type: "playlist" }, { entries: [] }, { is_live: true }, { live_status: "post_live" },
      { duration: config.maxDuration + 1 }, { duration: -1 }, { duration: NaN },
    ]) {
      const rejectReused = createDownloader(config, async source => source, undefined, () => {});
      await assert.rejects(rejectReused(normalizeSource(sampleURL), reusedOutput, new AbortController().signal, invalid), AppError);
      await assert.rejects(stat(join(reusedOutput, "extractor-info.json")), { code: "ENOENT" });
    }
    assert.equal((JSON.parse(await readFile(join(folder, "calls.json"), "utf8")) as string[][]).length, 4,
      "Invalid reused metadata must fail before starting any extractor or download subprocess");
    await writeFile(join(folder, "fail.flag"), "fail next download");
    await assert.rejects(download(normalizeSource(sampleURL), output, new AbortController().signal), (error: unknown) => error instanceof AppError && !error.message.includes("private-fixture"));
    await assert.rejects(stat(join(output, "extractor-info.json")), { code: "ENOENT" });
  } finally {
    if (originalPath === undefined) delete process.env.PATH;
    else process.env.PATH = originalPath;
    await rm(folder, { recursive: true, force: true });
  }
});

it("classifies platform restrictions and rate limits without exposing raw process output", () => {
  const auth = classifyDownloadError(new CommandError("Sign in with browser cookies. /private/path", 1));
  assert.equal(auth.code, "SOURCE_RESTRICTED");
  assert.equal(auth.status, 422);
  assert.equal(auth.message.includes("private/path"), false);
  assert.equal(classifyDownloadError(new CommandError("HTTP 429: Too many requests", 1)).status, 429);
  assert.equal(classifyDownloadError(new CommandError("Video has been removed", 1)).code, "SOURCE_UNAVAILABLE");
  assert.throws(() => executablePath("roast-this-command-does-not-exist"), (error) => error instanceof AppError && error.code === "DEPENDENCY_MISSING");
});

it("rejects an overlong selected file before conversion when extractor duration is missing", async () => {
  const directory = await mkdtemp(join(tmpdir(), "recordpov-duration-probe-"));
  try {
    const extractor = join(directory, "extractor.cjs"), ffmpeg = join(directory, "encoder.cjs"), ffprobe = join(directory, "probe.cjs");
    const marker = join(directory, "encoder-started");
    const scripts = [
      [extractor, `const fs=require('node:fs'),a=process.argv.slice(2);if(a.includes('--dump-single-json'))console.log(JSON.stringify({title:'Synthetic',vcodec:'vp9',acodec:'none',width:720,height:1280,fps:null}));else fs.writeFileSync(a[a.indexOf('--output')+1].replace('%(ext)s','mp4'),'synthetic bytes');`],
      [ffmpeg, `require('node:fs').writeFileSync(${JSON.stringify(marker)},'started');process.exit(9);`],
      [ffprobe, `console.log(JSON.stringify({format:{duration:'3'},streams:[{codec_type:'video',codec_name:'vp9',width:720,height:1280}]}));`],
    ];
    for (const [path, script] of scripts) { await writeFile(path!, `#!${process.execPath}\n${script}\n`); await chmod(path!, 0o755); }
    const events: DownloadTiming[] = [];
    const download = createDownloader({ ...loadConfig(), ytDlp: extractor, ffmpeg, ffprobe, maxDuration: 2 }, async value => value, undefined, event => events.push(event));
    await assert.rejects(download(normalizeSource(sampleURL), directory, new AbortController().signal),
      (error: unknown) => error instanceof AppError && error.code === "VIDEO_TOO_LONG");
    assert.ok(events.some(event => event.stage === "selectedProbe"));
    assert.ok(!events.some(event => event.stage === "transcode" || event.stage === "candidateDownload"));
    await assert.rejects(stat(marker), { code: "ENOENT" });
    await assert.rejects(stat(join(directory, "extractor-info.json")), { code: "ENOENT" });
  } finally { await rm(directory, { recursive: true, force: true }); }
});

it("distinguishes platform bot challenges from private or authenticated sources", () => {
  for (const message of [
    "Sign in to confirm you’re not a bot. Use browser cookies. /private/path",
    "HTTP 403: CAPTCHA required",
    "The platform returned a bot-challenge",
  ]) {
    const error = classifyDownloadError(new CommandError(message, 1));
    assert.equal(error.code, "SOURCE_PLATFORM_BLOCKED");
    assert.equal(error.status, 422);
    assert.equal(error.message, "This platform blocked the download. Choose a video from your device instead.");
  }
  for (const message of ["HTTP 403 Forbidden", "This is a private video", "Sign in to access this age-restricted video"]) {
    assert.equal(classifyDownloadError(new CommandError(message, 1)).code, "SOURCE_RESTRICTED");
  }
});
