import assert from "node:assert/strict";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { it } from "node:test";
import { AppError } from "../src/errors.js";
import { WorkQueue } from "../src/queue.js";
import { fixture, fakeDownload, sampleURL } from "./fixtures.js";

it("deduplicates simultaneous imports and reuses the persisted result", async () => {
  let calls = 0;
  const app = await fixture({}, async (source, directory, signal) => {
    calls++;
    await delay(20);
    return await fakeDownload(source, directory, signal);
  });
  try {
    const [first, second] = await Promise.all([app.store.resolve(sampleURL), app.store.resolve(sampleURL)]);
    assert.equal(first.id, second.id);
    assert.equal(calls, 1);
    assert.equal((await app.store.resolve(sampleURL)).id, first.id);
    assert.equal(calls, 1);
    const cached = await app.store.get(first.id);
    assert.ok(cached);
    await writeFile(join(app.config.cacheDir, first.id, "manifest.json"), JSON.stringify({ ...first, expiresAt: new Date(0).toISOString() }));
    assert.equal(await app.store.get(first.id), undefined);
    await app.store.resolve(sampleURL);
    assert.equal(calls, 2);
  } finally { await app.close(); }
});

it("limits concurrent work and rejects overflow without losing queued work", async () => {
  const queue = new WorkQueue(1, 1);
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const order: string[] = [];
  const first = queue.run(async () => { order.push("first"); await gate; return 1; });
  const second = queue.run(async () => { order.push("second"); return 2; });
  await assert.rejects(queue.run(async () => 3), (error) => error instanceof AppError && error.code === "SERVER_BUSY");
  release();
  assert.deepEqual(await Promise.all([first, second]), [1, 2]);
  assert.deepEqual(order, ["first", "second"]);
  assert.equal(await queue.run(async () => 4), 4);
});

it("aborts slow downloads and accepts a later retry", async () => {
  let shouldWait = true;
  const app = await fixture({ timeoutMs: 30 }, async (source, directory, signal) => {
    if (shouldWait) {
      shouldWait = false;
      await new Promise<never>((_resolve, reject) => signal.addEventListener("abort", () => reject(signal.reason), { once: true }));
    }
    return await fakeDownload(source, directory, signal);
  });
  try {
    await assert.rejects(app.store.resolve(sampleURL), (error) => error instanceof AppError && error.code === "RESOLVE_TIMEOUT");
    assert.ok((await app.store.resolve(sampleURL)).id);
  } finally { await app.close(); }
});

it("removes timed-out queued work so a later job can take its place", async () => {
  const queue = new WorkQueue(1, 1);
  let release!: () => void;
  const first = queue.run(async () => { await new Promise<void>((resolve) => { release = resolve; }); });
  const controller = new AbortController();
  const second = queue.run(async () => assert.fail("Cancelled work must not run."), controller.signal);
  controller.abort(new AppError("RESOLVE_TIMEOUT", "Timed out.", 504));
  await assert.rejects(second, (error) => error instanceof AppError && error.code === "RESOLVE_TIMEOUT");
  const third = queue.run(async () => 3);
  release();
  await first;
  assert.equal(await third, 3);
});
