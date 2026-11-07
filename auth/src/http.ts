import { createServer } from 'node:http';
import { Readable } from 'node:stream';
import { clientAddress, type Config } from './config.js';

export interface NativeHTTPService {
  handle(request: Request, clientIP: string): Promise<Response>;
}

// Construction has no side effects: production explicitly listens in index.ts,
// while integration tests can bind an ephemeral loopback port and close it.
export function createNodeServer(config: Config, service: NativeHTTPService) {
  const server = createServer({ maxHeaderSize: 16_384, requestTimeout: 30_000, headersTimeout: 10_000 }, async (req, res) => {
    try {
      if (!req.url?.startsWith('/') || req.url.startsWith('//') || req.rawHeaders.filter((_, i) => i % 2 === 0 && req.rawHeaders[i].toLowerCase() === 'authorization').length > 1) {
        res.writeHead(400, { 'cache-control': 'no-store' }).end(); return;
      }
      const headers = new Headers();
      for (const name of ['authorization', 'content-type', 'content-length', 'origin', 'user-agent', 'cookie']) {
        const value = req.headers[name];
        if (typeof value === 'string') headers.set(name, value);
      }
      const forwarded = req.headers['x-forwarded-for'];
      const ip = clientAddress(req.socket.remoteAddress ?? '', typeof forwarded === 'string' ? forwarded : undefined, config);
      const hasBody = req.method !== 'GET' && req.method !== 'HEAD';
      const request = new Request(`${config.baseURL}${req.url}`, {
        method: req.method, headers,
        ...(hasBody ? { body: Readable.toWeb(req) as ReadableStream<Uint8Array>, duplex: 'half' } : {}),
      } as RequestInit);
      const response = await service.handle(request, ip);
      const responseHeaders = Object.fromEntries(response.headers);
      // Set-Cookie is not a comma-separated HTTP field. Preserve each header
      // individually, including Expires attributes containing their own commas.
      delete responseHeaders['set-cookie'];
      const cookies = response.headers.getSetCookie();
      res.writeHead(response.status, { ...responseHeaders, ...(cookies.length ? { 'set-cookie': cookies } : {}) });
      res.end(response.body ? Buffer.from(await response.arrayBuffer()) : undefined);
    } catch {
      if (!res.headersSent) res.writeHead(503, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      res.end(JSON.stringify({ error: { code: 'AUTH_UNAVAILABLE', message: 'Sign-in is temporarily unavailable.' } }));
    }
  });
  server.maxRequestsPerSocket = 100;
  server.maxConnections = 128;
  return server;
}
