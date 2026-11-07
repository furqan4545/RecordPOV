import { isIP } from "node:net";

export const STREAM_WINDOW = 262_144;
export const MAX_DATA = 32_768;
export const MAX_FRAME = 65_536;
export const MAX_BUFFERED = 4 * 1024 * 1024;
export const MAX_SESSION_BYTES = 750 * 1024 * 1024;
export const MAX_STREAMS = 8;
export interface Control { type: string; id?: number; host?: string; port?: number; bytes?: number; message?: string; [key: string]: unknown }

export function allowedYouTubeDestination(host: unknown, port: unknown): host is string {
  if (typeof host !== "string" || port !== 443 || host.length > 253 || isIP(host) || host !== host.toLowerCase()) return false;
  if (!host.split(".").every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(label))) return false;
  return host === "youtubei.googleapis.com" || ["youtube.com", "googlevideo.com", "ytimg.com"].some(root => host === root || host.endsWith(`.${root}`));
}
export function validStreamID(id: unknown): id is number { return Number.isInteger(id) && Number(id) > 0 && Number(id) <= 0xffff_ffff; }
export function parseControl(data: Buffer): Control {
  if (data.length > 4096) throw new Error("Control too large");
  const value: unknown = JSON.parse(data.toString("utf8"));
  if (!value || typeof value !== "object" || Array.isArray(value) || typeof (value as Control).type !== "string") throw new Error("Invalid control");
  return value as Control;
}
export function binaryFrame(id: number, payload: Buffer): Buffer {
  if (!validStreamID(id) || payload.length < 1 || payload.length > MAX_DATA) throw new Error("Invalid data");
  const frame = Buffer.allocUnsafe(payload.length + 5);
  frame[0] = 1; frame.writeUInt32BE(id, 1); payload.copy(frame, 5); return frame;
}
export function parseBinary(frame: Buffer): { id: number; payload: Buffer } {
  if (frame.length < 6 || frame.length > MAX_DATA + 5 || frame[0] !== 1) throw new Error("Invalid binary frame");
  const id = frame.readUInt32BE(1);
  if (!validStreamID(id)) throw new Error("Invalid stream");
  return { id, payload: frame.subarray(5) };
}
export class StreamCredit {
  available = STREAM_WINDOW;
  consume(bytes: number): void {
    if (!Number.isSafeInteger(bytes) || bytes < 1 || bytes > MAX_DATA || bytes > this.available) throw new Error("Stream credit exceeded");
    this.available -= bytes;
  }
  acknowledge(bytes: unknown): void {
    if (!Number.isSafeInteger(bytes) || Number(bytes) < 1 || Number(bytes) > MAX_DATA || Number(bytes) > STREAM_WINDOW - this.available) throw new Error("Invalid acknowledgement");
    this.available += Number(bytes);
  }
}
