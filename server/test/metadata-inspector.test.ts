import assert from 'node:assert/strict';
import { chmod, mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { it } from 'node:test';
import { loadConfig } from '../src/config.js';
import { AppError } from '../src/errors.js';
import { createMetadataInspector, validateExtractedInfo } from '../src/media-delivery.js';
import { normalizeSource } from '../src/source.js';

it('executes only bounded metadata extraction with no media output or persistent extractor cache', async () => {
  const root = await mkdtemp(join(tmpdir(), 'recordpov-metadata-'));
  const extractor = join(root, 'extractor'), argsFile = join(root, 'args.json');
  try {
    await writeFile(extractor, `#!${process.execPath}\nconst fs=require('node:fs');fs.writeFileSync(${JSON.stringify(argsFile)},JSON.stringify(process.argv.slice(2)));console.log(JSON.stringify({title:'Synthetic',duration:3,formats:[]}));\n`);
    await chmod(extractor, 0o755);
    const source = normalizeSource('https://youtu.be/jNQXAC9IVRw');
    let preflights = 0;
    const inspect = createMetadataInspector({ ...loadConfig(), ytDlp: extractor }, async value => { preflights++; return value; }, { proxyURL: 'socks5h://127.0.0.1:30199' });
    const info = await inspect(source, root, new AbortController().signal);
    assert.equal(info.title, 'Synthetic'); assert.equal(preflights, 1);
    const args = JSON.parse(await readFile(argsFile, 'utf8')) as string[];
    for (const flag of ['--ignore-config', '--no-plugin-dirs', '--no-remote-components', '--no-exec', '--no-playlist', '--no-cache-dir', '--dump-single-json', '--skip-download']) assert(args.includes(flag), flag);
    assert.equal(args[args.indexOf('--proxy') + 1], 'socks5h://127.0.0.1:30199');
    assert.equal(args.at(-1), source.url); assert(!args.includes('--output')); assert(!args.includes('--write-info-json'));
    assert.deepEqual((await readdir(root)).sort(), ['args.json', 'extractor']);
  } finally { await rm(root, { recursive: true, force: true }); }
});

it('terminates metadata subprocesses on cancellation without replacing the caller reason', async () => {
  const root = await mkdtemp(join(tmpdir(), 'recordpov-metadata-cancel-'));
  try {
    const extractor = join(root, 'extractor'), ready = join(root, 'ready');
    await writeFile(extractor, `#!${process.execPath}\nrequire('node:fs').writeFileSync(${JSON.stringify(ready)},'ready');setInterval(()=>{},1000);\n`); await chmod(extractor, 0o755);
    const controller = new AbortController(), reason = new AppError('REQUEST_CANCELLED', 'Cancelled.', 499);
    const work = createMetadataInspector({ ...loadConfig(), ytDlp: extractor }, async value => value)(normalizeSource('https://youtu.be/jNQXAC9IVRw'), root, controller.signal);
    // Observe rejection immediately; the ready marker proves an actual subprocess was running.
    const assertion = assert.rejects(work, error => error === reason);
    for (let attempt = 0; ; attempt++) {
      if (await readFile(ready, 'utf8').catch(() => '') === 'ready') break;
      assert(attempt < 200, 'extractor did not start');
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    controller.abort(reason); await assertion;
  } finally { await rm(root, { recursive: true, force: true }); }
});

it('rejects playlists, live sources and known excessive durations before direct selection', () => {
  const config = { ...loadConfig(), maxDuration: 900 };
  for (const info of [{ entries: [] }, { _type: 'multi_video' }, { live_status: 'is_live' }, { duration: 901 }, { duration: -1 }]) assert.throws(() => validateExtractedInfo(info, config), AppError);
  assert.doesNotThrow(() => validateExtractedInfo({ width: 720, height: 1280, duration: undefined }, config));
});

it('defaults to a 60-minute, 2 GiB import limit and names 60 minutes when rejecting longer sources', () => {
  const saved = { duration: process.env.MAX_DURATION_SECONDS, bytes: process.env.MAX_MEDIA_BYTES };
  delete process.env.MAX_DURATION_SECONDS; delete process.env.MAX_MEDIA_BYTES;
  try {
    const config = loadConfig();
    assert.equal(config.maxDuration, 3600); assert.equal(config.maxBytes, 2 * 1024 ** 3);
    assert.doesNotThrow(() => validateExtractedInfo({ duration: 3599 }, config));
    assert.throws(() => validateExtractedInfo({ duration: 3601 }, config), (error: unknown) => error instanceof AppError && error.message === 'Choose a video under 60 minutes.');
  } finally {
    if (saved.duration !== undefined) process.env.MAX_DURATION_SECONDS = saved.duration;
    if (saved.bytes !== undefined) process.env.MAX_MEDIA_BYTES = saved.bytes;
  }
});
