import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import type { Config } from './config.js';
import { publicConfig } from './config.js';
import type { Identity } from './auth.js';
import { AuthError } from './limits.js';

interface Pending { challenge: string; clientState: string; expiresAt: number; started: number; ottHash: string | null }
const digest = (value: string) => createHash('sha256').update(value).digest('hex');
const secureHeaders = { 'cache-control': 'no-store', 'referrer-policy': 'no-referrer', 'x-content-type-options': 'nosniff' };

export function createAppleBrowser(config: Config, identity: Identity) {
  identity.database.exec(`CREATE TABLE IF NOT EXISTS nativeAppleRequest (
    requestHash TEXT PRIMARY KEY, challenge TEXT NOT NULL, clientState TEXT NOT NULL,
    expiresAt INTEGER NOT NULL, started INTEGER NOT NULL DEFAULT 0, ottHash TEXT UNIQUE
  )`);
  const enabled = () => publicConfig(config).appleAndroidEnabled;
  const purge = () => identity.database.prepare('DELETE FROM nativeAppleRequest WHERE expiresAt < ?').run(Date.now());
  const pending = (request: string) => {
    if (!/^[A-Za-z0-9_-]{43}$/.test(request)) throw invalid();
    const row = identity.database.prepare('SELECT challenge, clientState, expiresAt, started, ottHash FROM nativeAppleRequest WHERE requestHash = ?').get(digest(request)) as Pending | undefined;
    if (!row || row.expiresAt < Date.now()) throw invalid();
    return row;
  };

  return {
    async handle(request: Request, readJSON: (request: Request) => Promise<unknown>): Promise<Response> {
      if (!enabled()) throw new AuthError(503, 'PROVIDER_UNAVAILABLE', 'Apple sign-in on Android is not configured yet.');
      const url = new URL(request.url);
      purge();
      if (url.pathname === '/v1/auth/apple/browser/start' && request.method === 'POST' && !url.search) {
        const body = await readJSON(request) as Record<string, unknown>;
        if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(k => !['codeChallenge', 'state'].includes(k)) ||
            typeof body.codeChallenge !== 'string' || !/^[A-Za-z0-9_-]{43}$/.test(body.codeChallenge) ||
            typeof body.state !== 'string' || !/^[A-Za-z0-9._~-]{16,128}$/.test(body.state)) throw invalid();
        if ((identity.database.prepare('SELECT count(*) AS n FROM nativeAppleRequest').get() as { n: number }).n >= 100) {
          throw new AuthError(503, 'AUTH_BUSY', 'Sign-in is busy. Please try again shortly.');
        }
        const ticket = randomBytes(32).toString('base64url');
        const expiresAt = Date.now() + 10 * 60_000;
        identity.database.prepare('INSERT INTO nativeAppleRequest (requestHash, challenge, clientState, expiresAt) VALUES (?, ?, ?, ?)')
          .run(digest(ticket), body.codeChallenge, body.state, expiresAt);
        return Response.json({ url: `${config.baseURL}/v1/auth/apple/browser/authorize?request=${ticket}`, expiresAt: new Date(expiresAt).toISOString() }, { headers: secureHeaders });
      }
      if (url.pathname === '/v1/auth/apple/browser/authorize' && request.method === 'GET') {
        const ticket = onlyRequest(url);
        const row = pending(ticket);
        if (row.started) throw invalid();
        const changed = identity.database.prepare('UPDATE nativeAppleRequest SET started = 1 WHERE requestHash = ? AND started = 0').run(digest(ticket));
        if (changed.changes !== 1) throw invalid();
        const response = await identity.auth.handler(new Request(`${config.baseURL}/api/auth/sign-in/social`, {
          method: 'POST', headers: { 'content-type': 'application/json', origin: config.baseURL },
          body: JSON.stringify({
            provider: 'apple', disableRedirect: true,
            callbackURL: `${config.baseURL}/v1/auth/apple/browser/complete?request=${ticket}`,
            errorCallbackURL: `${config.baseURL}/v1/auth/apple/browser/failed?request=${ticket}`,
          }),
        }));
        const result = await response.json() as { url?: string };
        if (!response.ok || !result.url || !result.url.startsWith('https://appleid.apple.com/auth/authorize?')) throw invalid();
        return redirect(result.url, response.headers.getSetCookie());
      }
      if (url.pathname === '/api/auth/callback/apple' && request.method === 'POST' && !url.search) {
        const type = request.headers.get('content-type')?.split(';')[0];
        if (type !== 'application/x-www-form-urlencoded') throw invalid();
        const body = await boundedText(request);
        const headers = new Headers({ 'content-type': 'application/x-www-form-urlencoded', origin: 'https://appleid.apple.com' });
        const cookie = request.headers.get('cookie');
        if (cookie) headers.set('cookie', cookie);
        let response = await identity.auth.handler(new Request(`${config.baseURL}/api/auth/callback/apple`, { method: 'POST', headers, body }));
        // Better Auth normalizes form_post to a GET callback. Follow that one
        // fixed internal transition here so authorization codes never enter an
        // external redirect URL or access-log request line.
        const normalized = response.headers.get('location');
        if (normalized) {
          const next = new URL(normalized);
          if (next.origin === config.baseURL && next.pathname === '/api/auth/callback/apple' && !next.hash) {
            response = await identity.auth.handler(new Request(next, { headers }));
          }
        }
        const destination = response.headers.get('location');
        // Never forward an arbitrary callback, provider exception or credential.
        if (!destination || !destination.startsWith(`${config.baseURL}/v1/auth/apple/browser/`)) throw invalid();
        const final = new URL(destination);
        if (final.pathname === '/v1/auth/apple/browser/complete') {
          const ticket = onlyRequest(final);
          pending(ticket);
          identity.database.prepare('UPDATE nativeAppleRequest SET started = 2 WHERE requestHash = ? AND started = 1').run(digest(ticket));
        }
        return redirect(destination, response.headers.getSetCookie());
      }
      if (['/v1/auth/apple/browser/complete', '/v1/auth/apple/browser/failed'].includes(url.pathname) && request.method === 'GET') {
        const ticket = onlyRequest(url, true);
        const row = pending(ticket);
        if (!row.started || row.ottHash) throw invalid();
        const destination = new URL(config.androidCallbackURL!);
        destination.searchParams.set('state', row.clientState);
        if (url.pathname.endsWith('/failed') || url.searchParams.has('error')) {
          destination.searchParams.set('error', 'SIGN_IN_CANCELLED');
          identity.database.prepare('DELETE FROM nativeAppleRequest WHERE requestHash = ?').run(digest(ticket));
          return redirect(destination.href);
        }
        if (row.started !== 2) throw invalid();
        const cookie = request.headers.get('cookie');
        if (!cookie) throw invalid();
        // Internal library API only; caller cannot choose callback or headers.
        const result = await identity.auth.api.generateOneTimeToken({ headers: new Headers({ cookie }) });
        const claimed = identity.database.prepare('UPDATE nativeAppleRequest SET ottHash = ?, expiresAt = ? WHERE requestHash = ? AND ottHash IS NULL')
          .run(digest(result.token), Date.now() + 60_000, digest(ticket));
        if (claimed.changes !== 1) throw invalid();
        destination.searchParams.set('code', result.token);
        return redirect(destination.href);
      }
      if (url.pathname === '/v1/auth/apple/browser/exchange' && request.method === 'POST' && !url.search) {
        const body = await readJSON(request) as Record<string, unknown>;
        if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(k => !['code', 'codeVerifier'].includes(k)) ||
            typeof body.code !== 'string' || !/^[A-Za-z0-9_-]{20,128}$/.test(body.code) ||
            typeof body.codeVerifier !== 'string' || !/^[A-Za-z0-9._~-]{43,128}$/.test(body.codeVerifier)) throw invalid();
        const row = identity.database.prepare('SELECT challenge, expiresAt FROM nativeAppleRequest WHERE ottHash = ?').get(digest(body.code)) as { challenge: string; expiresAt: number } | undefined;
        const challenge = createHash('sha256').update(body.codeVerifier).digest('base64url');
        if (!row || row.expiresAt < Date.now() || !timingSafeEqual(Buffer.from(row.challenge), Buffer.from(challenge))) throw invalid();
        // Claim synchronously before awaiting. The library also consumes its OTT.
        const claimed = identity.database.prepare('DELETE FROM nativeAppleRequest WHERE ottHash = ?').run(digest(body.code));
        if (claimed.changes !== 1) throw invalid();
        const response = await identity.auth.handler(new Request(`${config.baseURL}/api/auth/one-time-token/verify`, {
          method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ token: body.code }),
        }));
        if (!response.ok) throw invalid();
        const result = await response.json() as { session: { expiresAt: string }; user: { id: string; name: string; email: string; image?: string } };
        const token = response.headers.get('set-auth-token');
        if (!token) throw invalid();
        const { id, name, email, image } = result.user;
        return Response.json({ token, expiresAt: result.session.expiresAt, user: { id, name, email, ...(image?.startsWith('https://') ? { image } : {}) } }, { headers: secureHeaders });
      }
      throw new AuthError(404, 'NOT_FOUND', 'Not found.');
    },
  };
}

function onlyRequest(url: URL, allowError = false): string {
  const allowed = allowError ? ['request', 'error', 'error_description'] : ['request'];
  if ([...url.searchParams.keys()].some(key => !allowed.includes(key)) || url.searchParams.getAll('request').length !== 1) throw invalid();
  return url.searchParams.get('request') ?? '';
}
function redirect(location: string, cookies: string[] = []) {
  const headers = new Headers({ ...secureHeaders, location });
  for (const cookie of cookies) headers.append('set-cookie', cookie);
  return new Response(null, { status: 302, headers });
}
function invalid() { return new AuthError(401, 'INVALID_AUTH_FLOW', 'Sign-in expired or could not be verified. Please try again.'); }
async function boundedText(request: Request) {
  const reader = request.body?.getReader();
  if (!reader) throw invalid();
  let total = 0;
  const chunks: Uint8Array[] = [];
  while (true) {
    const item = await reader.read();
    if (item.done) break;
    total += item.value.length;
    if (total > 32_768) { await reader.cancel(); throw new AuthError(413, 'BODY_TOO_LARGE', 'The request is too large.'); }
    chunks.push(item.value);
  }
  return Buffer.concat(chunks).toString('utf8');
}
