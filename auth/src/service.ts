import type { Config } from './config.js';
import { publicConfig } from './config.js';
import type { Identity } from './auth.js';
import { AuthError, RateLimiter } from './limits.js';
import { bearerToken, validateSignIn } from './tokens.js';
import { createAppleBrowser } from './apple-browser.js';

const MAX_BODY = 32_768;
interface NativeUser { id: string; name: string; email: string; image?: string }
interface LibrarySession { session: { expiresAt: string; createdAt: string }; user: NativeUser }

export function createService(config: Config, identity: Identity) {
  const limiter = new RateLimiter();
  let activeSignIns = 0;
  const browser = createAppleBrowser(config, identity);

  async function library(path: string, method: string, headers: Headers, body?: object) {
    return identity.auth.handler(new Request(`${config.baseURL}/api/auth${path}`, {
      method, headers, ...(body ? { body: JSON.stringify(body) } : {}),
    }));
  }

  async function session(headers: Headers): Promise<LibrarySession> {
    const response = await library('/get-session', 'GET', headers);
    const value = await response.json() as LibrarySession | null;
    if (!response.ok || !value?.session || !value.user) {
      throw new AuthError(401, 'UNAUTHENTICATED', 'Please sign in again.');
    }
    return value;
  }

  return {
    async handle(request: Request, clientIP: string): Promise<Response> {
      try {
        const url = new URL(request.url);
        if (url.origin !== config.baseURL || url.hash) throw new AuthError(404, 'NOT_FOUND', 'Not found.');
        if (!limiter.allow('global', 2000) || !limiter.allow(`ip:${clientIP}`, 120)) throw rateLimited();
        const origin = request.headers.get('origin');
        const appleCallback = url.pathname === '/api/auth/callback/apple' && origin === 'https://appleid.apple.com';
        if (origin && origin !== config.baseURL && !appleCallback) throw new AuthError(403, 'ORIGIN_NOT_ALLOWED', 'This request is not allowed.');
        if (url.pathname.startsWith('/v1/auth/apple/browser/') || url.pathname === '/api/auth/callback/apple') {
          if (!limiter.allow(`browser:${clientIP}`, 20)) throw rateLimited();
          if (url.pathname.endsWith('/start') && !limiter.allow(`browser-start:${clientIP}`, 5)) throw rateLimited();
          return await browser.handle(request, readJSON);
        }
        if (url.search) throw new AuthError(404, 'NOT_FOUND', 'Not found.');
        if (url.pathname === '/health' && request.method === 'GET') return json({ status: 'ok' });
        if (url.pathname === '/v1/auth/config' && request.method === 'GET') return json(publicConfig(config));

        const headers = new Headers({
          'content-type': 'application/json',
          'x-forwarded-for': clientIP,
          'user-agent': (request.headers.get('user-agent') ?? 'RecordPOV native').slice(0, 256),
        });
        if (origin) headers.set('origin', origin);

        if (url.pathname === '/v1/auth/sign-in' && request.method === 'POST') {
          if (!limiter.allow(`signin:${clientIP}`, 10)) throw rateLimited();
          if (activeSignIns >= 8) throw new AuthError(503, 'AUTH_BUSY', 'Sign-in is busy. Please try again shortly.');
          const input = validateSignIn(await readJSON(request), config);
          activeSignIns++;
          try {
            const appleGrant = input.provider === 'apple'
              ? await identity.apple!.exchangeNative(input.authorizationCode!, input.idToken) : undefined;
            const response = await library('/sign-in/social', 'POST', headers, {
              provider: input.provider,
              idToken: {
                token: input.idToken,
                ...(input.nonce ? { nonce: input.nonce } : {}),
                ...(input.provider === 'apple' && input.name ? { user: { name: { firstName: input.name } } } : {}),
              },
            });
            if (!response.ok) {
              const failure = await response.json().catch(() => ({})) as { code?: string };
              if (failure.code === 'OAUTH_LINK_ERROR') {
                throw new AuthError(409, 'ACCOUNT_EXISTS', 'Use the sign-in option you used for this account.');
              }
              throw new AuthError(401, 'INVALID_ID_TOKEN', 'Sign-in could not be verified. Please try again.');
            }
            // requireSignature=true: use the library's signed bearer, never its raw
            // DB identifier. Do not forward Set-Cookie or a provider token.
            const token = response.headers.get('set-auth-token');
            bearerToken(token ? `Bearer ${token}` : null);
            headers.set('authorization', `Bearer ${token}`);
            const current = await session(headers);
            if (appleGrant) await identity.apple!.storeNativeGrant(current.user.id, appleGrant);
            return json({ token, expiresAt: current.session.expiresAt, user: nativeUser(current.user) });
          } finally { activeSignIns--; }
        }

        if (url.pathname === '/v1/auth/session' && request.method === 'GET') {
          headers.set('authorization', `Bearer ${bearerToken(request.headers.get('authorization'))}`);
          const current = await session(headers);
          const appleAccount = identity.database.prepare('SELECT id FROM account WHERE userId = ? AND providerId = ?').get(current.user.id, 'apple');
          if (appleAccount && !identity.apple) throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple sign-in is temporarily unavailable. Please try again.');
          if (appleAccount) await identity.apple!.validateSessionGrant(current.user.id);
          const validated = await session(headers);
          return json({ expiresAt: validated.session.expiresAt, user: nativeUser(validated.user) });
        }
        if (url.pathname === '/v1/auth/sign-out' && request.method === 'POST') {
          await requireEmptyBody(request);
          headers.set('authorization', `Bearer ${bearerToken(request.headers.get('authorization'))}`);
          await library('/sign-out', 'POST', headers, {});
          return empty();
        }
        if (url.pathname === '/v1/auth/account' && request.method === 'DELETE') {
          await requireEmptyBody(request);
          headers.set('authorization', `Bearer ${bearerToken(request.headers.get('authorization'))}`);
          const current = await session(headers);
          if (Date.now() - new Date(current.session.createdAt).getTime() >= 5 * 60_000) {
            throw new AuthError(401, 'REAUTHENTICATION_REQUIRED', 'Please sign in again before deleting your account.');
          }
          const appleAccount = identity.database.prepare('SELECT id FROM account WHERE userId = ? AND providerId = ?').get(current.user.id, 'apple');
          if (appleAccount && !identity.apple) throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple account disconnection is temporarily unavailable. Please try again.');
          await identity.apple?.revokeForUser(current.user.id);
          const response = await library('/delete-user', 'POST', headers, {});
          if (!response.ok) throw new AuthError(401, 'REAUTHENTICATION_REQUIRED', 'Please sign in again before deleting your account.');
          return empty();
        }
        // No raw Better Auth endpoint is public. This excludes password sign-up,
        // OAuth redirects, arbitrary callbacks, token refresh and account linking.
        throw new AuthError(404, 'NOT_FOUND', 'Not found.');
      } catch (error) {
        if (error instanceof AuthError) return json({ error: { code: error.code, message: error.message } }, error.status);
        // Never serialize a provider exception, input token, DB path or secret.
        return json({ error: { code: 'AUTH_UNAVAILABLE', message: 'Sign-in is temporarily unavailable. Please try again.' } }, 503);
      }
    },
  };
}

function nativeUser(user: NativeUser): NativeUser {
  return {
    id: user.id, name: user.name, email: user.email,
    ...(typeof user.image === 'string' && user.image.startsWith('https://') ? { image: user.image } : {}),
  };
}

async function bytes(request: Request): Promise<Uint8Array> {
  const length = request.headers.get('content-length');
  if (length && (!/^\d+$/.test(length) || Number(length) > MAX_BODY)) throw new AuthError(413, 'BODY_TOO_LARGE', 'The request is too large.');
  const reader = request.body?.getReader();
  if (!reader) return new Uint8Array();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const item = await reader.read();
      if (item.done) break;
      total += item.value.byteLength;
      if (total > MAX_BODY) {
        await reader.cancel();
        throw new AuthError(413, 'BODY_TOO_LARGE', 'The request is too large.');
      }
      chunks.push(item.value);
    }
  } finally { reader.releaseLock(); }
  return Buffer.concat(chunks, total);
}

async function readJSON(request: Request): Promise<unknown> {
  if (request.headers.get('content-type')?.split(';')[0].trim().toLowerCase() !== 'application/json') {
    throw new AuthError(415, 'JSON_REQUIRED', 'Send an application/json request.');
  }
  try { return JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(await bytes(request))); }
  catch (error) {
    if (error instanceof AuthError) throw error;
    throw new AuthError(400, 'INVALID_REQUEST', 'Please check the sign-in request.');
  }
}

async function requireEmptyBody(request: Request) {
  const body = new TextDecoder().decode(await bytes(request));
  if (body.trim() && body.trim() !== '{}') throw new AuthError(400, 'INVALID_REQUEST', 'This request must have an empty body.');
}

function rateLimited() { return new AuthError(429, 'RATE_LIMITED', 'Please wait a moment before trying again.'); }
const securityHeaders = { 'cache-control': 'no-store', 'x-content-type-options': 'nosniff', 'referrer-policy': 'no-referrer' };
function json(value: unknown, status = 200) {
  return Response.json(value, { status, headers: { ...securityHeaders, ...(status === 429 ? { 'retry-after': '60' } : {}) } });
}
function empty() { return new Response(null, { status: 204, headers: securityHeaders }); }
