import assert from "node:assert/strict";
import type { IncomingMessage } from "node:http";
import { it } from "node:test";
import { clientAddress } from "../src/client-address.js";
import { fixture, sampleURL } from "./fixtures.js";

function request(peer: string, forwarded?: string): Pick<IncomingMessage, "headers" | "socket"> {
  return { headers: forwarded === undefined ? {} : { "x-forwarded-for": forwarded },
    socket: { remoteAddress: peer } as IncomingMessage["socket"] };
}

it("ignores spoofed forwarded headers unless the actual peer is explicitly trusted", () => {
  assert.equal(clientAddress(request("203.0.113.1", "198.51.100.2"), {}), "203.0.113.1");
  assert.equal(clientAddress(request("203.0.113.1", "198.51.100.2"), { trustedProxyIPs: ["127.0.0.1"] }), "203.0.113.1");
  assert.equal(clientAddress(request("::ffff:127.0.0.1", "198.51.100.2"), { trustedProxyIPs: ["127.0.0.1"] }), "198.51.100.2");
});

it("normalizes client IPs and rejects ambiguous/malformed proxy address chains", () => {
  const config = { trustedProxyIPs: ["::1"] };
  assert.equal(clientAddress(request("::1", "2001:0db8:0000:0000:0000:0000:0000:0001"), config), "2001:db8::1");
  assert.equal(clientAddress(request("::1", "::ffff:c000:201"), config), "192.0.2.1");
  for (const invalid of ["192.0.2.1, 198.51.100.2", "unknown", "https://example.com", "127.0.0.1:8787", "[::1]", "fe80::1%eth0"]) {
    assert.equal(clientAddress(request("::1", invalid), config), "::1", invalid);
  }
});

it("keeps per-client resolver quotas behind a trusted proxy", async () => {
  const app = await fixture({ trustedProxyIPs: ["127.0.0.1"] });
  try {
    const resolve = (ip: string) => fetch(`${app.origin}/v1/media/resolve`, {
      method: "POST", headers: { "Content-Type": "application/json", "X-Forwarded-For": ip },
      body: JSON.stringify({ url: sampleURL }),
    });
    // v1 now answers 410 but still counts toward the per-client quota.
    for (let index = 0; index < 20; index++) assert.equal((await resolve("192.0.2.1")).status, 410);
    const limited = await resolve("192.0.2.1");
    assert.equal(limited.status, 429);
    assert.ok(Number(limited.headers.get("retry-after")) > 0);
    assert.equal((await resolve("192.0.2.2")).status, 410);
  } finally { await app.close(); }
});

it("cannot evade direct-client quotas by rotating untrusted forwarded addresses", async () => {
  const app = await fixture();
  try {
    for (let index = 0; index < 21; index++) {
      const response = await fetch(`${app.origin}/v1/media/resolve`, {
        method: "POST", headers: { "Content-Type": "application/json", "X-Forwarded-For": `192.0.2.${index + 1}` },
        body: JSON.stringify({ url: sampleURL }),
      });
      assert.equal(response.status, index < 20 ? 410 : 429);
    }
  } finally { await app.close(); }
});
