import { isIP } from "node:net";
import type { IncomingMessage } from "node:http";
import type { Config } from "./config.js";

function canonicalIP(value: string): string | undefined {
  const family = isIP(value);
  if (family === 4) return value;
  if (family !== 6 || value.includes("%")) return undefined;
  // Collapse equivalent IPv6 spellings, including IPv4-mapped peers.
  const normalized = new URL(`http://[${value}]/`).hostname.slice(1, -1);
  const mapped = /^::ffff:([a-f0-9]{1,4}):([a-f0-9]{1,4})$/.exec(normalized);
  if (mapped) {
    const high = Number.parseInt(mapped[1]!, 16);
    const low = Number.parseInt(mapped[2]!, 16);
    return `${high >>> 8}.${high & 255}.${low >>> 8}.${low & 255}`;
  }
  return normalized;
}

/**
 * Forwarded addresses are opt-in and accepted only from explicitly listed peers.
 * The edge proxy MUST overwrite X-Forwarded-For with one verified client IP;
 * ambiguous chains and malformed values fall back to the actual socket peer.
 */
export function clientAddress(request: Pick<IncomingMessage, "headers" | "socket">, config: Pick<Config, "trustedProxyIPs">): string {
  const peer = canonicalIP(request.socket.remoteAddress || "") || "unknown";
  if (!config.trustedProxyIPs?.some((entry) => canonicalIP(entry) === peer)) return peer;
  const header = request.headers["x-forwarded-for"];
  if (typeof header !== "string" || header.length > 64 || header.includes(",")) return peer;
  return canonicalIP(header.trim()) || peer;
}
