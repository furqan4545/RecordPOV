import assert from "node:assert/strict";
import { after, before, describe, it } from "node:test";
import { AppError } from "../src/errors.js";
import { fakeDownload, fixture, sampleBytes, sampleURL } from "./fixtures.js";

describe("media HTTP API", () => {
  let app: Awaited<ReturnType<typeof fixture>>;
  let media: { id: string; playbackUrl: string; sourceUrl: string; expiresAt: string };
  before(async () => { app = await fixture({}, fakeDownload, { inspect: async () => { throw new AppError("SOURCE_RESTRICTED", "Import a local copy instead.", 422); } }); });
  after(async () => { await app.close(); });

  it("reports health without contacting a platform", async () => {
    const response = await fetch(`${app.origin}/health`);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).status, "ok");
  });
  it("keeps serving existing cache entries from GET /v1/media/:id/file", async () => {
    // No route prepares media any more; the file endpoint still serves cache entries.
    const record = await app.store.resolve(sampleURL);
    media = { id: record.id, sourceUrl: record.sourceUrl, expiresAt: record.expiresAt, playbackUrl: `${app.origin}/v1/media/${record.id}/file` };
    assert.match(media.id, /^[a-f0-9]{24}$/);
    assert.equal(media.sourceUrl, sampleURL);
    assert.ok(Date.parse(media.expiresAt) > Date.now());
  });
  it("streams full files and precise ranges for native media players", async () => {
    const full = await fetch(media.playbackUrl);
    assert.equal(full.status, 200);
    assert.equal(full.headers.get("content-type"), "video/mp4");
    assert.equal(full.headers.get("accept-ranges"), "bytes");
    assert.deepEqual(Buffer.from(await full.arrayBuffer()), sampleBytes);
    const partial = await fetch(media.playbackUrl, { headers: { Range: "bytes=10-15" } });
    assert.equal(partial.status, 206);
    assert.equal(partial.headers.get("content-range"), `bytes 10-15/${sampleBytes.length}`);
    assert.deepEqual(Buffer.from(await partial.arrayBuffer()), sampleBytes.subarray(10, 16));
    const suffix = await fetch(media.playbackUrl, { headers: { Range: "bytes=-4" } });
    assert.deepEqual(Buffer.from(await suffix.arrayBuffer()), sampleBytes.subarray(-4));
    const head = await fetch(media.playbackUrl, { method: "HEAD", headers: { Range: "bytes=0-1" } });
    assert.equal(head.status, 206);
    assert.equal(head.headers.get("content-length"), "2");
    assert.equal((await head.arrayBuffer()).byteLength, 0);
  });
  it("supports ETags and reports unsatisfiable ranges", async () => {
    const first = await fetch(media.playbackUrl, { method: "HEAD" });
    const etag = first.headers.get("etag")!;
    assert.equal((await fetch(media.playbackUrl, { headers: { "If-None-Match": etag } })).status, 304);
    const bad = await fetch(media.playbackUrl, { headers: { Range: "bytes=999-" } });
    assert.equal(bad.status, 416);
    assert.equal(bad.headers.get("content-range"), `bytes */${sampleBytes.length}`);
    assert.equal((await bad.json()).error.code, "INVALID_RANGE");
  });
  it("rejects unsafe links, malformed JSON and unexpectedly large requests", async () => {
    const badURL = await fetch(`${app.origin}/v2/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "http://127.0.0.1/private" }) });
    assert.equal(badURL.status, 400);
    assert.equal((await badURL.json()).error.code, "UNSUPPORTED_URL");
    const malformed = await fetch(`${app.origin}/v2/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{" });
    assert.equal(malformed.status, 400);
    const oversized = await fetch(`${app.origin}/v2/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: "a".repeat(5000) }) });
    assert.equal(oversized.status, 413);
    const wrongType = await fetch(`${app.origin}/v2/media/resolve`, { method: "POST", body: "url=anything" });
    assert.equal(wrongType.status, 415);
  });
  it("does not expose filesystem paths or enable arbitrary cross-origin websites", async () => {
    const unknown = await fetch(`${app.origin}/v1/media/000000000000000000000000/file`, { headers: { Origin: "https://untrusted.example" } });
    assert.equal(unknown.status, 404);
    assert.equal(unknown.headers.get("access-control-allow-origin"), null);
    assert.equal((await unknown.json()).error.code, "MEDIA_EXPIRED");
    assert.equal((await fetch(`${app.origin}/v1/media/%2e%2e/file`)).status, 404);
  });
});

it("authenticates protected API/file endpoints while retaining health checks", async () => {
  const app = await fixture({ apiToken: "test-token" });
  try {
    assert.equal((await fetch(`${app.origin}/health`)).status, 200);
    for (const path of ["/v1/media/resolve", "/v2/media/resolve"]) {
      const unauthorized = await fetch(`${app.origin}${path}`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: sampleURL }) });
      assert.equal(unauthorized.status, 401);
    }
    const authorized = await fetch(`${app.origin}/v1/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer test-token" }, body: JSON.stringify({ url: sampleURL }) });
    assert.equal(authorized.status, 410);
    const record = await app.store.resolve(sampleURL);
    const file = `${app.origin}/v1/media/${record.id}/file`;
    assert.equal((await fetch(file)).status, 401);
    assert.equal((await fetch(file, { headers: { Authorization: "Bearer test-token" } })).status, 200);
  } finally { await app.close(); }
});

it("returns useful source errors without leaking process output", async () => {
  const app = await fixture({}, fakeDownload, { inspect: async () => { throw new AppError("SOURCE_RESTRICTED", "Import a local copy instead.", 422); } });
  try {
    const response = await fetch(`${app.origin}/v2/media/resolve`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ url: sampleURL }) });
    assert.equal(response.status, 422);
    assert.deepEqual(await response.json(), { error: { code: "SOURCE_RESTRICTED", message: "Import a local copy instead." } });
  } finally { await app.close(); }
});
