import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AppError } from "../src/errors.js";
import { parseRange } from "../src/range.js";

describe("HTTP byte ranges", () => {
  it("supports closed, open-ended, clamped and suffix requests", () => {
    assert.deepEqual(parseRange("bytes=0-9", 100), { start: 0, end: 9 });
    assert.deepEqual(parseRange("bytes=20-", 100), { start: 20, end: 99 });
    assert.deepEqual(parseRange("bytes=95-200", 100), { start: 95, end: 99 });
    assert.deepEqual(parseRange("bytes=-10", 100), { start: 90, end: 99 });
    assert.deepEqual(parseRange("bytes=-500", 100), { start: 0, end: 99 });
  });
  it("rejects unsatisfiable, ambiguous and unsafe numeric ranges", () => {
    for (const header of ["bytes=100-", "bytes=50-49", "bytes=-0", "bytes=-", "bytes=0-1,4-8", "items=0-9", "bytes=1.2-4", "bytes=9007199254740992-", "bytes=1-9007199254740992"]) {
      assert.throws(() => parseRange(header, 100), (error) => error instanceof AppError && error.status === 416, header);
    }
    assert.throws(() => parseRange("bytes=0-", 0));
  });
});
