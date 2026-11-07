import { AppError } from "./errors.js";
export interface ByteRange { start: number; end: number }

export function parseRange(header: string, size: number): ByteRange {
  const invalid = () => new AppError("INVALID_RANGE", "This byte range is not available.", 416);
  const match = /^bytes=(\d*)-(\d*)$/.exec(header);
  if (!match || (!match[1] && !match[2]) || size <= 0) throw invalid();
  const first = match[1] ? Number(match[1]) : undefined;
  const last = match[2] ? Number(match[2]) : undefined;
  if ((first !== undefined && !Number.isSafeInteger(first)) || (last !== undefined && !Number.isSafeInteger(last))) throw invalid();
  if (first === undefined) {
    if (last === undefined || last <= 0) throw invalid();
    return { start: Math.max(0, size - last), end: size - 1 };
  }
  if (first >= size || (last !== undefined && last < first)) throw invalid();
  return { start: first, end: Math.min(last ?? size - 1, size - 1) };
}
