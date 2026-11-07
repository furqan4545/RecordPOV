import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AppError } from "../src/errors.js";
import { isPublicAddress, normalizeSource } from "../src/source.js";

describe("source URL validation", () => {
  it("normalizes supported single-video links and removes tracking parameters", () => {
    const cases = [
      ["https://www.instagram.com/reels/Datls4XT4Hy/?igsh=tracking", "instagram", "https://www.instagram.com/reel/Datls4XT4Hy/"],
      ["https://instagram.com/p/ABC_123-def/", "instagram", "https://www.instagram.com/p/ABC_123-def/"],
      ["https://youtu.be/dQw4w9WgXcQ?si=tracking", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
      ["https://m.youtube.com/watch?v=dQw4w9WgXcQ&list=other", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
      ["https://youtube.com/shorts/dQw4w9WgXcQ", "youtube", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
      ["https://twitter.com/example/status/1234567890?s=20", "x", "https://x.com/example/status/1234567890"],
      ["https://x.com/i/web/status/1234567890", "x", "https://x.com/i/web/status/1234567890"],
      ["https://www.tiktok.com/@someone/video/123456789012345", "tiktok", "https://www.tiktok.com/@someone/video/123456789012345"],
      ["https://vm.tiktok.com/Abc123/", "tiktok", "https://vm.tiktok.com/Abc123/"],
    ] as const;
    for (const [input, platform, canonical] of cases) {
      const result = normalizeSource(input);
      assert.equal(result.platform, platform, input);
      assert.equal(result.url, canonical, input);
    }
  });

  it("rejects spoofed hosts, local URLs, credentials, playlists and non-video paths", () => {
    const rejected = [
      undefined, null, 42, {}, "", "http://youtube.com/watch?v=dQw4w9WgXcQ",
      "file:///etc/passwd", "https://127.0.0.1/video", "https://[::1]/video",
      "https://youtube.com.attacker.test/watch?v=dQw4w9WgXcQ",
      "https://youtube.com@attacker.test/watch?v=dQw4w9WgXcQ",
      "https://user:pass@www.youtube.com/watch?v=dQw4w9WgXcQ",
      "https://www.youtube.com:8080/watch?v=dQw4w9WgXcQ",
      "https://youtube.com/playlist?list=PL123", "https://youtube.com/watch?v=bad",
      "https://instagram.com/someone/", "https://instagram.com/reel/a%2F../../../private/",
      "https://x.com/home", "https://tiktok.com/@someone", "https://t.co/anything",
      "https://www.instagram.com./reel/Datls4XT4Hy/", "https://www.instagram.com/reel/Datls4XT4Hy/\n",
    ];
    for (const input of rejected) assert.throws(() => normalizeSource(input), (error) => error instanceof AppError && error.code === "UNSUPPORTED_URL", String(input));
  });

  it("blocks non-public DNS answers including mapped loopback addresses", () => {
    for (const address of ["127.0.0.1", "10.0.0.2", "172.16.4.2", "192.168.0.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "224.0.0.1", "192.0.2.1", "198.51.100.2", "203.0.113.1", "::1", "::", "fe80::1", "fd00::1", "ff02::1", "2001:db8::1", "::ffff:127.0.0.1", "::ffff:7f00:1"]) {
      assert.equal(isPublicAddress(address), false, address);
    }
    for (const address of ["8.8.8.8", "1.1.1.1", "2606:4700:4700::1111", "2001:4860:4860::8888"]) assert.equal(isPublicAddress(address), true, address);
  });
});
