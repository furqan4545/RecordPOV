import assert from "node:assert/strict";
import { readdir } from "node:fs/promises";
import { request as httpRequest } from "node:http";
import { join } from "node:path";
import { setImmediate as nextTurn } from "node:timers/promises";
import { it } from "node:test";
import { AppError } from "../src/errors.js";
import type { MediaRecord, MediaStore } from "../src/store.js";
import { fakeDownload, fixture, sampleURL } from "./fixtures.js";

const secondURL = "https://x.com/person/status/123456789";
const thirdURL = "https://www.instagram.com/reel/AnotherVideo/";
function deferred<T = void>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((complete) => { resolve = complete; });
  return { promise, resolve };
}
function abortReason() { return new AppError("REQUEST_CANCELLED", "Cancelled by caller.", 499); }
function waitForAbort(signal: AbortSignal, stopped = deferred()): Promise<never> {
  return new Promise((_resolve, reject) => {
    const abort = () => { stopped.resolve(); reject(signal.reason); };
    signal.addEventListener("abort", abort, { once: true });
    if (signal.aborted) abort();
  });
}
// Confirm this caller's cache lookup has completed, then allow its subscribe microtask.
// This avoids relying on sleeps to assume that a second shared waiter has joined.
async function waiter(store: MediaStore, url: string, signal?: AbortSignal) {
  const lookup = store.get.bind(store);
  const lookedUp = deferred();
  store.get = async (id) => {
    const result = await lookup(id);
    lookedUp.resolve();
    return result;
  };
  const result = store.resolve(url, signal ? { signal } : undefined);
  void result.catch(() => {});
  try { await lookedUp.promise; await nextTurn(); }
  finally { store.get = lookup; }
  return { result };
}

it("disconnecting the only active caller rejects before slow download cleanup finishes", { timeout: 5000 }, async () => {
  const started = deferred(), stopped = deferred(), cleanup = deferred(), finished = deferred();
  let downloadSignal: AbortSignal | undefined;
  const app = await fixture({ concurrency: 1 }, async (_source, _directory, signal) => {
    downloadSignal = signal; started.resolve();
    try { await waitForAbort(signal, stopped); }
    finally { await cleanup.promise; finished.resolve(); }
    throw new Error("Unreachable");
  });
  const controller = new AbortController();
  try {
    const first = app.store.resolve(sampleURL, { signal: controller.signal });
    const rejected = assert.rejects(first, (error) => error === controller.signal.reason);
    await started.promise;
    controller.abort(abortReason());
    await rejected;
    await stopped.promise;
    assert.equal(downloadSignal?.aborted, true);
    // The caller is already rejected even though the downloader still owns its worker slot.
    let cleaned = false; void finished.promise.then(() => { cleaned = true; });
    await nextTurn(); assert.equal(cleaned, false);
  } finally { cleanup.resolve(); await finished.promise; await app.close(); }
});

it("one cancelled caller does not stop a second caller sharing the normalized source", { timeout: 5000 }, async () => {
  const started = deferred(), release = deferred();
  let calls = 0, downloadSignal: AbortSignal | undefined;
  const app = await fixture({}, async (source, directory, signal) => {
    calls++; downloadSignal = signal; started.resolve(); await release.promise;
    signal.throwIfAborted(); return await fakeDownload(source, directory, signal);
  });
  const firstController = new AbortController();
  try {
    const first = app.store.resolve(sampleURL, { signal: firstController.signal });
    const rejected = assert.rejects(first, (error) => error === firstController.signal.reason);
    await started.promise;
    const second = await waiter(app.store, `${sampleURL}?tracking=ignored`);
    firstController.abort(abortReason()); await rejected;
    assert.equal(downloadSignal?.aborted, false);
    release.resolve();
    assert.equal((await second.result).sourceUrl, sampleURL);
    assert.equal(calls, 1);
  } finally { release.resolve(); await app.close(); }
});

it("the last shared waiter cancels the worker and lets a queued video run", { timeout: 5000 }, async () => {
  const started = deferred(), stopped = deferred();
  let active = 0, maximum = 0, calls = 0;
  const app = await fixture({ concurrency: 1 }, async (source, directory, signal) => {
    active++; maximum = Math.max(maximum, active); calls++;
    try {
      if (source.url === sampleURL) { started.resolve(); await waitForAbort(signal, stopped); }
      return await fakeDownload(source, directory, signal);
    } finally { active--; }
  });
  const a = new AbortController(), b = new AbortController();
  try {
    const first = app.store.resolve(sampleURL, { signal: a.signal });
    const firstRejected = assert.rejects(first);
    await started.promise;
    const second = await waiter(app.store, sampleURL, b.signal);
    const secondRejected = assert.rejects(second.result);
    const queued = await waiter(app.store, secondURL);
    a.abort(abortReason()); await firstRejected;
    assert.equal(active, 1); assert.equal(calls, 1);
    b.abort(abortReason()); await secondRejected; await stopped.promise;
    assert.equal((await queued.result).platform, "x");
    assert.equal(calls, 2); assert.equal(maximum, 1); assert.equal(active, 0);
    assert.deepEqual(await readdir(join(app.config.cacheDir, ".staging")), []);
  } finally { a.abort(); b.abort(); await app.close(); }
});

it("a cancelled queued caller frees its queue entry without starting a download", { timeout: 5000 }, async () => {
  const started = deferred(), release = deferred();
  const sources: string[] = [];
  const app = await fixture({ concurrency: 1, queueLimit: 1 }, async (source, directory, signal) => {
    sources.push(source.url);
    if (source.url === sampleURL) { started.resolve(); await release.promise; }
    return await fakeDownload(source, directory, signal);
  });
  const controller = new AbortController();
  try {
    const first = app.store.resolve(sampleURL);
    await started.promise;
    const cancelled = await waiter(app.store, secondURL, controller.signal);
    const rejected = assert.rejects(cancelled.result);
    controller.abort(abortReason()); await rejected;
    const replacement = await waiter(app.store, thirdURL);
    release.resolve();
    await first; assert.equal((await replacement.result).sourceUrl, thirdURL);
    assert.deepEqual(sources, [sampleURL, thirdURL]);
  } finally { controller.abort(); release.resolve(); await app.close(); }
});

it("HTTP disconnect propagates cancellation for an ordinary completed request body", { timeout: 5000 }, async () => {
  const started = deferred(), stopped = deferred();
  const app = await fixture({ concurrency: 1 }, async () => assert.fail("v2 must not download"), {
    lookup: async () => [{ address: "8.8.8.8", family: 4 }],
    inspect: async (source, _directory, signal) => {
      if (source.url === sampleURL) { started.resolve(); await waitForAbort(signal, stopped); }
      return { title: "Second", acodec: "none", formats: [{ ext: "mp4", protocol: "https", vcodec: "avc1.64001f", acodec: "none", width: 1280, height: 720, url: "https://video.twimg.com/second.mp4" }] };
    },
  });
  const request = httpRequest(`${app.origin}/v2/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json" } });
  request.on("error", () => {});
  request.on("response", response => response.resume());
  try {
    request.end(JSON.stringify({ url: sampleURL }));
    await started.promise;
    request.destroy();
    await stopped.promise;
    const response = await fetch(`${app.origin}/v2/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: secondURL }) });
    assert.equal(response.status, 200);
    const result = await response.json();
    assert.equal(result.platform, "x"); assert.equal("path" in result, false);
  } finally { request.destroy(); await app.close(); }
});

it("an abort after cache commit keeps the valid file for a later caller", { timeout: 5000 }, async () => {
  const controller = new AbortController();
  let calls = 0, committed: MediaRecord | undefined;
  const app = await fixture({ concurrency: 1 }, async (source, directory, signal) => {
    calls++; return await fakeDownload(source, directory, signal);
  });
  const get = app.store.get.bind(app.store);
  app.store.get = async id => {
    const result = await get(id);
    if (result && !committed) { committed = result.record; controller.abort(abortReason()); }
    return result;
  };
  try {
    await assert.rejects(app.store.resolve(sampleURL, { signal: controller.signal }));
    assert.ok(committed);
    // The next worker starts only once the cancelled job's final cleanup has completed.
    await app.store.resolve(secondURL);
    app.store.get = get;
    const cached = await app.store.resolve(sampleURL);
    assert.equal(cached.id, committed.id); assert.equal(calls, 2);
    assert.ok(await get(cached.id));
  } finally { app.store.get = get; await app.close(); }
});

it("late cleanup of an abandoned generation cannot evict a retry's shared job", { timeout: 5000 }, async () => {
  const firstStarted = deferred(), oldCleanup = deferred(), retryStarted = deferred(), finishRetry = deferred();
  let originalCalls = 0;
  const app = await fixture({ concurrency: 2 }, async (source, directory, signal) => {
    if (source.url === sampleURL) {
      originalCalls++;
      if (originalCalls === 1) {
        firstStarted.resolve();
        try { await waitForAbort(signal); } finally { await oldCleanup.promise; }
      } else { retryStarted.resolve(); await finishRetry.promise; }
    }
    return await fakeDownload(source, directory, signal);
  });
  const controller = new AbortController();
  try {
    const first = app.store.resolve(sampleURL, { signal: controller.signal });
    const rejected = assert.rejects(first);
    await firstStarted.promise; controller.abort(abortReason()); await rejected;
    const retry = app.store.resolve(sampleURL); void retry.catch(() => {});
    await retryStarted.promise;
    const afterCleanup = app.store.resolve(secondURL); void afterCleanup.catch(() => {});
    oldCleanup.resolve(); await afterCleanup;
    const joined = await waiter(app.store, sampleURL);
    finishRetry.resolve();
    assert.equal((await retry).id, (await joined.result).id);
    assert.equal(originalCalls, 2);
  } finally { controller.abort(); oldCleanup.resolve(); finishRetry.resolve(); await app.close(); }
});

it("phone-owned download options stay isolated from another owner's cancellation", { timeout: 5000 }, async () => {
  const firstStarted = deferred(), secondStarted = deferred(), release = deferred();
  const a = new AbortController(), b = new AbortController();
  const app = await fixture({ concurrency: 2 });
  try {
    const first = app.store.resolve(sampleURL, { signal: a.signal, download: async (_source, _directory, signal) => {
      firstStarted.resolve(); return await waitForAbort(signal);
    } });
    const rejected = assert.rejects(first, error => error === a.signal.reason);
    await firstStarted.promise;
    const second = app.store.resolve(sampleURL, { signal: b.signal, download: async (source, directory, signal) => {
      secondStarted.resolve(); await release.promise;
      assert.equal(signal.aborted, false);
      return { ...await fakeDownload(source, directory, signal), title: "Second phone" };
    } });
    void second.catch(() => {});
    await secondStarted.promise; a.abort(abortReason()); await rejected;
    release.resolve(); assert.equal((await second).title, "Second phone");
  } finally { a.abort(); b.abort(); release.resolve(); await app.close(); }
});
