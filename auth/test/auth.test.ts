import assert from 'node:assert/strict';
import { test, before, after } from 'node:test';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { generateKeyPair, exportJWK, exportPKCS8, SignJWT } from 'jose';
import { loadConfig, clientAddress } from '../src/config.js';
import { createIdentity } from '../src/auth.js';
import { createService } from '../src/service.js';
import { RateLimiter } from '../src/limits.js';
import { createNodeServer } from '../src/http.js';
import { request as nodeRequest, type IncomingHttpHeaders } from 'node:http';
import { once } from 'node:events';

const ORIGIN = 'https://api.recordpov.test';
const GOOGLE = '123456789-testserver.apps.googleusercontent.com';
const APPLE = 'com.recordpov.test';
const secret = 'test-only-not-a-production-secret-3f19d7c802af';
let keys: Awaited<ReturnType<typeof generateKeyPair>>;
let wrongKeys: Awaited<ReturnType<typeof generateKeyPair>>;
let fetchCount = 0;
let applePrivateKey: string;
const appleResponses = new Map<string, string>();
let revoked: string[] = [];
let revokeFails = false;
let refreshStatus: 'valid' | 'invalid_grant' | 'unavailable' = 'valid';
let refreshCalls = 0;
let refreshDelay: Promise<void> | undefined;
let onRefresh: (() => void) | undefined;
const originalFetch = globalThis.fetch;

before(async () => {
  keys = await generateKeyPair('RS256');
  wrongKeys = await generateKeyPair('RS256');
  applePrivateKey = await exportPKCS8((await generateKeyPair('ES256', { extractable: true })).privateKey);
  const jwk = { ...await exportJWK(keys.publicKey), kid: 'synthetic-test-key', alg: 'RS256', use: 'sig' };
  globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url === 'https://appleid.apple.com/auth/token') {
      const values = new URLSearchParams(String(init?.body));
      if (values.get('grant_type') === 'refresh_token') {
        refreshCalls++;
        const status = refreshStatus;
        onRefresh?.();
        await refreshDelay;
        if (status === 'invalid_grant') return Response.json({ error: 'invalid_grant' }, { status: 400 });
        if (status === 'unavailable') return Response.json({ error: 'temporarily_unavailable' }, { status: 503 });
        return Response.json({ access_token: 'synthetic-fresh-access-token', token_type: 'Bearer', expires_in: 3600 });
      }
      const idToken = appleResponses.get(values.get('code') ?? '');
      if (!idToken) return Response.json({ error: 'invalid_grant' }, { status: 400 });
      return Response.json({ id_token: idToken, refresh_token: 'synthetic-private-refresh-token', access_token: 'synthetic-access', expires_in: 3600, token_type: 'Bearer' });
    }
    if (url === 'https://appleid.apple.com/auth/revoke') {
      if (revokeFails) return Response.json({ error: 'temporarily_unavailable' }, { status: 503 });
      const values = new URLSearchParams(String(init?.body));
      revoked.push(values.get('token') ?? '');
      return new Response(null, { status: 200 });
    }
    if (!['https://www.googleapis.com/oauth2/v3/certs', 'https://appleid.apple.com/auth/keys'].includes(url)) {
      throw new Error('Tests never contact external services.');
    }
    fetchCount++;
    return Response.json({ keys: [jwk] });
  }) as typeof fetch;
});
after(() => { globalThis.fetch = originalFetch; });

async function fixture(providers = true, browser = false) {
  const directory = await mkdtemp(join(tmpdir(), 'recordpov-auth-test-'));
  await writeFile(join(directory, 'apple.p8'), applePrivateKey, { mode: 0o600 });
  const config = loadConfig({
    BETTER_AUTH_URL: ORIGIN, BETTER_AUTH_SECRET: secret, AUTH_DATABASE_PATH: join(directory, 'auth.sqlite'),
    ...(providers ? {
      AUTH_GOOGLE_SERVER_CLIENT_ID: GOOGLE, AUTH_APPLE_BUNDLE_ID: APPLE,
      AUTH_APPLE_TEAM_ID: 'TESTTEAM01', AUTH_APPLE_KEY_ID: 'TESTKEY001', AUTH_APPLE_PRIVATE_KEY_FILE: join(directory, 'apple.p8'),
      ...(browser ? { AUTH_APPLE_SERVICES_ID: 'com.recordpov.test.web', AUTH_ANDROID_CALLBACK_URL: `${ORIGIN}/auth/apple/return` } : {}),
    } : {}),
  });
  const identity = await createIdentity(config);
  const service = createService(config, identity);
  return {
    ...identity, config, service,
    async request(path: string, options: { method?: string; body?: unknown; rawBody?: string; token?: string; headers?: Record<string, string>; ip?: string } = {}) {
      return service.handle(new Request(`${ORIGIN}${path}`, {
        method: options.method ?? 'GET',
        headers: { 'content-type': 'application/json', ...(options.token ? { authorization: `Bearer ${options.token}` } : {}), ...options.headers },
        ...(options.rawBody !== undefined ? { body: options.rawBody } : options.body !== undefined ? { body: JSON.stringify(options.body) } : {}),
      }), options.ip ?? '198.51.100.1');
    },
    async cleanup() { identity.close(); await rm(directory, { recursive: true, force: true }); },
  };
}

async function token(provider: 'google' | 'apple' = 'google', overrides: Record<string, unknown> = {}, wrongSignature = false) {
  const now = Math.floor(Date.now() / 1000);
  return new SignJWT({
    sub: `synthetic-${provider}-subject`, email: 'test@example.test', email_verified: true, name: 'Test person',
    iss: provider === 'google' ? 'https://accounts.google.com' : 'https://appleid.apple.com',
    aud: provider === 'google' ? GOOGLE : APPLE, iat: now, exp: now + 3600, ...overrides,
  }).setProtectedHeader({ alg: 'RS256', kid: 'synthetic-test-key' }).sign(wrongSignature ? wrongKeys.privateKey : keys.privateKey);
}

async function signIn(f: Awaited<ReturnType<typeof fixture>>, provider: 'google' | 'apple' = 'google', extra = {}) {
  const idToken = await token(provider);
  const code = `synthetic-code-${Math.random().toString(36).slice(2)}`;
  appleResponses.set(code, idToken);
  const response = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider, idToken, ...(provider === 'apple' ? { authorizationCode: code } : {}), ...extra } });
  assert.equal(response.status, 200, await response.clone().text());
  return response.json() as Promise<{ token: string; expiresAt: string; user: { id: string; name: string; email: string } }>;
}

test('unconfigured providers fail closed; public config never exposes a secret or fake client', async () => {
  const f = await fixture(false);
  try {
    const response = await f.request('/v1/auth/config');
    assert.equal(response.headers.get('cache-control'), 'no-store');
    assert.deepEqual(await response.json(), { version: 1, enabled: false, providers: { google: { enabled: false }, apple: { enabled: false } }, appleAndroidEnabled: false });
    const disabled = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'google', idToken: 'anything' } });
    assert.equal(disabled.status, 503);
    assert.equal((await disabled.json()).error.code, 'PROVIDER_UNAVAILABLE');
    assert.equal((await stat(f.config.databasePath)).mode & 0o777, 0o600);
  } finally { await f.cleanup(); }
});

test('real Google signature verification creates a signed bearer session; provider tokens are not persisted', async () => {
  const f = await fixture();
  try {
    const login = await signIn(f);
    assert.equal(login.user.email, 'test@example.test');
    assert.ok(new Date(login.expiresAt).getTime() > Date.now());
    assert.ok(login.token.includes('.'));
    const response = await f.request('/v1/auth/session', { token: login.token });
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).user, login.user);
    const account = f.database.prepare('SELECT idToken, accessToken, refreshToken FROM account').get();
    assert.deepEqual(account, { idToken: null, accessToken: null, refreshToken: null });
    const raw = (f.database.prepare('SELECT token FROM session').get() as { token: string }).token;
    assert.equal((await f.request('/v1/auth/session', { token: raw })).status, 401);
  } finally { await f.cleanup(); }
});

test('native Apple signature/nonce verification accepts hashed nonce and saves first authorization name', async () => {
  const f = await fixture();
  try {
    const { createHash } = await import('node:crypto');
    const nonce = 'synthetic-client-nonce-123456789';
    const idToken = await token('apple', { nonce: createHash('sha256').update(nonce).digest('hex'), name: undefined });
    appleResponses.set('synthetic-apple-code', idToken);
    const response = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'apple', idToken, nonce, name: 'Apple person', authorizationCode: 'synthetic-apple-code' } });
    assert.equal(response.status, 200, await response.clone().text());
    assert.equal((await response.json()).user.name, 'Apple person');
    const wrong = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'apple', idToken, nonce: 'another-nonce-123456789', authorizationCode: 'synthetic-apple-code' } });
    assert.equal(wrong.status, 401);
  } finally { await f.cleanup(); }
});

test('wrong audience, issuer, expired, future and malformed tokens fail before a JWKS fetch', async () => {
  const f = await fixture();
  try {
    const initial = fetchCount;
    const now = Math.floor(Date.now() / 1000);
    for (const claims of [{ aud: 'attacker.apps.googleusercontent.com' }, { iss: 'https://attacker.test' }, { exp: now - 60 }, { iat: now + 60 }, { iat: now - 4000 }]) {
      const response = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'google', idToken: await token('google', claims) } });
      assert.equal(response.status, 401);
    }
    assert.equal(fetchCount, initial);
    assert.equal((await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'google', idToken: 'not.a.valid-token' } })).status, 401);
  } finally { await f.cleanup(); }
});

test('plausible claims with an invalid cryptographic signature never create an account', async () => {
  const f = await fixture();
  try {
    const response = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'google', idToken: await token('google', {}, true) } });
    assert.equal(response.status, 401);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM user').get() as { n: number }).n, 0);
  } finally { await f.cleanup(); }
});

test('sign-out revokes server session immediately and tampered bearer tokens fail', async () => {
  const f = await fixture();
  try {
    const login = await signIn(f);
    assert.equal((await f.request('/v1/auth/session', { token: `${login.token}a` })).status, 401);
    assert.equal((await f.request('/v1/auth/sign-out', { method: 'POST', token: login.token })).status, 204);
    assert.equal((await f.request('/v1/auth/session', { token: login.token })).status, 401);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM session').get() as { n: number }).n, 0);
  } finally { await f.cleanup(); }
});

test('account deletion requires a fresh session, then deletes identity and every session', async () => {
  const f = await fixture();
  try {
    const old = await signIn(f);
    f.database.prepare('UPDATE session SET createdAt = ?').run(Date.now() - 600_000);
    const denied = await f.request('/v1/auth/account', { method: 'DELETE', token: old.token });
    assert.equal(denied.status, 401);
    assert.equal((await denied.json()).error.code, 'REAUTHENTICATION_REQUIRED');
    const fresh = await signIn(f);
    assert.equal((await f.request('/v1/auth/account', { method: 'DELETE', token: fresh.token })).status, 204);
    for (const table of ['user', 'account', 'session']) assert.equal((f.database.prepare(`SELECT count(*) AS n FROM ${table}`).get() as { n: number }).n, 0);
    assert.equal((await f.request('/v1/auth/session', { token: old.token })).status, 401);
  } finally { await f.cleanup(); }
});

test('same-email identities are not implicitly linked, and raw auth routes are inaccessible', async () => {
  const f = await fixture();
  try {
    await signIn(f);
    const appleToken = await token('apple');
    appleResponses.set('synthetic-link-code', appleToken);
    const second = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'apple', idToken: appleToken, authorizationCode: 'synthetic-link-code' } });
    assert.equal(second.status, 409, await second.clone().text());
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM account').get() as { n: number }).n, 1);
    for (const path of ['/api/auth/sign-up/email', '/api/auth/link-social', '/api/auth/sign-in/social', '/v1/auth/config?token=secret']) {
      assert.equal((await f.request(path, { method: 'POST', body: {} })).status, 404);
    }
  } finally { await f.cleanup(); }
});

test('input sizes, unexpected fields, origins and per-IP sign-in attempts are bounded', async () => {
  const f = await fixture();
  try {
    const valid = await token();
    assert.equal((await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'google', idToken: valid, callbackURL: 'https://evil.test' } })).status, 400);
    assert.equal((await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'google', idToken: 'a'.repeat(40_000) } })).status, 413);
    assert.equal((await f.request('/v1/auth/config', { headers: { origin: 'https://evil.test' } })).status, 403);
    for (let i = 0; i < 8; i++) await f.request('/v1/auth/sign-in', { method: 'POST', body: {} });
    assert.equal((await f.request('/v1/auth/sign-in', { method: 'POST', body: {} })).status, 429);
  } finally { await f.cleanup(); }
});

test('proxy trust is exact and limiter capacity cannot be bypassed with key churn', () => {
  const config = loadConfig({ BETTER_AUTH_SECRET: secret, TRUSTED_PROXY_IPS: '127.0.0.1' });
  assert.equal(clientAddress('127.0.0.1', '198.51.100.2', config), '198.51.100.2');
  assert.equal(clientAddress('::ffff:127.0.0.1', '198.51.100.2', config), '198.51.100.2');
  assert.equal(clientAddress('198.51.100.1', '198.51.100.2', config), '198.51.100.1');
  assert.equal(clientAddress('127.0.0.1', '198.51.100.2, 127.0.0.1', config), '127.0.0.1');
  let now = 100;
  const limiter = new RateLimiter(1, () => now);
  assert.ok(limiter.allow('first', 1));
  assert.ok(!limiter.allow('first', 1));
  assert.ok(!limiter.allow('second', 1));
  now += 60_001;
  assert.ok(limiter.allow('second', 1));
});

test('Apple requires a code and revocation keys, encrypts its grant, and revokes before deletion', async () => {
  const f = await fixture();
  try {
    const missingCode = await f.request('/v1/auth/sign-in', { method: 'POST', body: { provider: 'apple', idToken: await token('apple') } });
    assert.equal(missingCode.status, 400);
    const login = await signIn(f, 'apple');
    const account = f.database.prepare('SELECT refreshToken, appleClientId, idToken, accessToken FROM account').get() as Record<string, string | null>;
    assert.ok(account.refreshToken && account.refreshToken !== 'synthetic-private-refresh-token');
    assert.equal(account.appleClientId, APPLE);
    assert.equal(account.idToken, null);
    assert.equal(account.accessToken, null);
    revoked = [];
    revokeFails = true;
    const failed = await f.request('/v1/auth/account', { method: 'DELETE', token: login.token });
    assert.equal(failed.status, 503);
    assert.equal((await failed.json()).error.code, 'APPLE_REVOCATION_FAILED');
    const browserSession = await f.request('/v1/auth/session', { token: login.token });
    assert.equal(browserSession.status, 200, JSON.stringify(f.database.prepare('SELECT appleGrantValidatedAt, appleGrantCheckAfter FROM account').get()));
    revokeFails = false;
    assert.equal((await f.request('/v1/auth/account', { method: 'DELETE', token: login.token })).status, 204);
    assert.deepEqual(revoked, ['synthetic-private-refresh-token']);
    assert.equal((await f.request('/v1/auth/session', { token: login.token })).status, 401);
  } finally { revokeFails = false; await f.cleanup(); }
});

test('Apple bundle alone cannot enable production sign-in without revocation credentials', async () => {
  const config = loadConfig({ BETTER_AUTH_SECRET: secret, AUTH_APPLE_BUNDLE_ID: APPLE });
  const { publicConfig } = await import('../src/config.js');
  assert.equal(publicConfig(config).providers.apple.enabled, false);
  assert.equal(publicConfig(config).appleAndroidEnabled, false);
});

test('Android Apple browser OAuth uses the library and a single-use verifier-bound handoff', async () => {
  const f = await fixture(true, true);
  try {
    const { createHash } = await import('node:crypto');
    const verifier = 'native-code-verifier-for-this-test-1234567890-ABC';
    const state = 'native-state-1234567890';
    const start = await f.request('/v1/auth/apple/browser/start', { method: 'POST', body: { codeChallenge: createHash('sha256').update(verifier).digest('base64url'), state } });
    assert.equal(start.status, 200, await start.clone().text());
    const startBody = await start.json() as { url: string };
    const requestURL = new URL(startBody.url);
    assert.equal(requestURL.origin, ORIGIN);
    const authorize = await f.request(requestURL.pathname + requestURL.search);
    assert.equal(authorize.status, 302, await authorize.clone().text());
    const appleURL = new URL(authorize.headers.get('location')!);
    assert.equal(appleURL.origin, 'https://appleid.apple.com');
    assert.equal(appleURL.searchParams.get('client_id'), 'com.recordpov.test.web');
    assert.equal((await f.request(requestURL.pathname + requestURL.search)).status, 401);
    const cookieJar = new Map<string, string>();
    const captureCookies = (response: Response) => {
      for (const cookie of response.headers.getSetCookie()) {
        const pair = cookie.split(';')[0];
        cookieJar.set(pair.slice(0, pair.indexOf('=')), pair);
      }
      return [...cookieJar.values()].join('; ');
    };
    const cookie = captureCookies(authorize);
    const browserToken = await token('apple', { aud: 'com.recordpov.test.web', ...(appleURL.searchParams.get('nonce') ? { nonce: appleURL.searchParams.get('nonce') } : {}) });
    appleResponses.set('synthetic-browser-code', browserToken);
    const callback = await f.request('/api/auth/callback/apple', {
      method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded', origin: 'https://appleid.apple.com', cookie },
      rawBody: new URLSearchParams({ code: 'synthetic-browser-code', state: appleURL.searchParams.get('state')!, id_token: browserToken }).toString(),
    });
    assert.equal(callback.status, 302, await callback.clone().text());
    const next = new URL(callback.headers.get('location')!);
    assert.equal(next.pathname, '/v1/auth/apple/browser/complete', next.href);
    const complete = await f.request(next.pathname + next.search, { headers: { cookie: captureCookies(callback) } });
    assert.equal(complete.status, 302, await complete.clone().text());
    const appLink = new URL(complete.headers.get('location')!);
    assert.equal(appLink.origin, ORIGIN);
    assert.equal(appLink.pathname, '/auth/apple/return');
    assert.equal(appLink.searchParams.get('state'), state);
    const code = appLink.searchParams.get('code');
    assert.ok(code);
    assert.equal((await f.request('/v1/auth/apple/browser/exchange', { method: 'POST', body: { code, codeVerifier: 'incorrect-verifier-that-still-meets-length-123456789' } })).status, 401);
    const exchanged = await f.request('/v1/auth/apple/browser/exchange', { method: 'POST', body: { code, codeVerifier: verifier } });
    assert.equal(exchanged.status, 200, await exchanged.clone().text());
    const login = await exchanged.json() as { token: string };
    const browserSession = await f.request('/v1/auth/session', { token: login.token });
    assert.equal(browserSession.status, 200, JSON.stringify(f.database.prepare('SELECT appleGrantValidatedAt, appleGrantCheckAfter FROM account').get()));
    assert.equal((await f.request('/v1/auth/apple/browser/exchange', { method: 'POST', body: { code, codeVerifier: verifier } })).status, 401);
    const account = f.database.prepare('SELECT refreshToken, appleClientId FROM account').get() as { refreshToken: string; appleClientId: string };
    assert.ok(account.refreshToken !== 'synthetic-private-refresh-token');
    assert.equal(account.appleClientId, 'com.recordpov.test.web');
    assert.equal((await f.request('/v1/auth/account', { method: 'DELETE', token: login.token })).status, 204);
  } finally { await f.cleanup(); }
});

function makeGrantDue(f: Awaited<ReturnType<typeof fixture>>) {
  const old = Date.now() - 25 * 60 * 60_000;
  f.database.prepare('UPDATE account SET appleGrantValidatedAt = ?, appleGrantCheckAfter = ? WHERE providerId = ?').run(old, old, 'apple');
  return old;
}

test('Apple grant validity is persisted and checked once daily, with concurrent lookups coalesced', async () => {
  const f = await fixture();
  try {
    refreshStatus = 'valid'; refreshCalls = 0;
    const login = await signIn(f, 'apple');
    const initial = f.database.prepare('SELECT appleGrantValidatedAt FROM account').get() as { appleGrantValidatedAt: number };
    assert.ok(Math.abs(initial.appleGrantValidatedAt - Date.now()) < 5000);
    assert.equal((await f.request('/v1/auth/session', { token: login.token })).status, 200);
    assert.equal(refreshCalls, 0, 'initial code exchange already validated the grant');
    makeGrantDue(f);
    const responses = await Promise.all(Array.from({ length: 6 }, () => f.request('/v1/auth/session', { token: login.token })));
    for (const response of responses) assert.equal(response.status, 200, await response.clone().text());
    assert.equal(refreshCalls, 1);
    const checked = f.database.prepare('SELECT appleGrantValidatedAt FROM account').get() as { appleGrantValidatedAt: number };
    assert.ok(Math.abs(checked.appleGrantValidatedAt - Date.now()) < 5000);
    assert.equal((await f.request('/v1/auth/session', { token: login.token })).status, 200);
    assert.equal(refreshCalls, 1);
  } finally { await f.cleanup(); }
});

test('confirmed Apple invalid_grant invalidates every local session while retaining the identity', async () => {
  const f = await fixture();
  try {
    refreshStatus = 'invalid_grant'; refreshCalls = 0;
    const first = await signIn(f, 'apple');
    const second = await signIn(f, 'apple');
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM session').get() as { n: number }).n, 2);
    makeGrantDue(f);
    const response = await f.request('/v1/auth/session', { token: first.token });
    assert.equal(response.status, 401);
    assert.equal((await response.json()).error.code, 'REAUTHENTICATION_REQUIRED');
    assert.equal(refreshCalls, 1);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM session').get() as { n: number }).n, 0);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM user').get() as { n: number }).n, 1);
    assert.equal((await f.request('/v1/auth/session', { token: second.token })).status, 401);
  } finally { refreshStatus = 'valid'; await f.cleanup(); }
});

test('Apple outage backs off without deleting accounts/sessions or recording a successful check', async () => {
  const f = await fixture();
  try {
    refreshStatus = 'unavailable'; refreshCalls = 0;
    const login = await signIn(f, 'apple');
    const old = makeGrantDue(f);
    for (let i = 0; i < 3; i++) {
      const response = await f.request('/v1/auth/session', { token: login.token });
      assert.equal(response.status, 503);
      assert.equal((await response.json()).error.code, 'APPLE_UNAVAILABLE');
    }
    assert.equal(refreshCalls, 1, 'persistent retry backoff prevents one provider call per lookup');
    const account = f.database.prepare('SELECT appleGrantValidatedAt, refreshToken FROM account').get() as { appleGrantValidatedAt: number; refreshToken: string };
    assert.equal(account.appleGrantValidatedAt, old);
    assert.ok(account.refreshToken);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM session').get() as { n: number }).n, 1);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM user').get() as { n: number }).n, 1);
    refreshStatus = 'valid';
    f.database.prepare('UPDATE account SET appleGrantCheckAfter = ?').run(Date.now() - 1);
    assert.equal((await f.request('/v1/auth/session', { token: login.token })).status, 200);
    assert.equal(refreshCalls, 2);
  } finally { refreshStatus = 'valid'; await f.cleanup(); }
});

test('a legacy Apple account missing its grant requires reauthentication without deleting account data', async () => {
  const f = await fixture();
  try {
    refreshCalls = 0;
    const login = await signIn(f, 'apple');
    f.database.prepare('UPDATE account SET refreshToken = NULL WHERE providerId = ?').run('apple');
    const response = await f.request('/v1/auth/session', { token: login.token });
    assert.equal(response.status, 401);
    assert.equal((await response.json()).error.code, 'REAUTHENTICATION_REQUIRED');
    assert.equal(refreshCalls, 0);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM session').get() as { n: number }).n, 0);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM user').get() as { n: number }).n, 1);
  } finally { await f.cleanup(); }
});

test('a late invalid result for an old Apple grant cannot revoke a concurrent fresh sign-in', async () => {
  const f = await fixture();
  let release!: () => void;
  try {
    const old = await signIn(f, 'apple');
    makeGrantDue(f);
    refreshStatus = 'invalid_grant';
    refreshDelay = new Promise<void>(resolve => { release = resolve; });
    const started = new Promise<void>(resolve => { onRefresh = resolve; });
    const pending = f.request('/v1/auth/session', { token: old.token });
    await started;
    const fresh = await signIn(f, 'apple');
    release();
    assert.equal((await pending).status, 200);
    assert.equal((await f.request('/v1/auth/session', { token: fresh.token })).status, 200);
    assert.equal((f.database.prepare('SELECT count(*) AS n FROM session').get() as { n: number }).n, 2);
  } finally { release?.(); refreshDelay = undefined; onRefresh = undefined; refreshStatus = 'valid'; await f.cleanup(); }
});

test('real Node HTTP adapter preserves Apple state/session cookies and distinct Set-Cookie headers', async () => {
  const f = await fixture(true, true);
  const server = createNodeServer(f.config, f.service);
  try {
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const address = server.address();
    assert.ok(address && typeof address === 'object');
    type HTTPResult = { status: number; headers: IncomingHttpHeaders; rawHeaders: string[]; body: string };
    const http = (path: string, method = 'GET', body?: string, headers: Record<string, string> = {}) => new Promise<HTTPResult>((resolve, reject) => {
      const request = nodeRequest({
        host: '127.0.0.1', port: address.port, path, method, agent: false,
        headers: { ...(body !== undefined ? { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } : {}), ...headers },
      }, response => {
        const chunks: Buffer[] = [];
        response.on('data', chunk => chunks.push(Buffer.from(chunk)));
        response.on('error', reject);
        response.on('end', () => resolve({ status: response.statusCode!, headers: response.headers, rawHeaders: response.rawHeaders, body: Buffer.concat(chunks).toString('utf8') }));
      });
      request.setTimeout(5000, () => request.destroy(new Error('Loopback HTTP test timed out.')));
      request.on('error', reject);
      request.end(body);
    });
    const jar = new Map<string, string>();
    const cookies = (response: HTTPResult) => {
      for (const cookie of response.headers['set-cookie'] ?? []) {
        const pair = cookie.split(';')[0];
        jar.set(pair.slice(0, pair.indexOf('=')), pair);
      }
      return [...jar.values()].join('; ');
    };
    const { createHash } = await import('node:crypto');
    const verifier = 'http-adapter-native-verifier-12345678901234567890';
    const state = 'http-adapter-state-123456789';
    const start = await http('/v1/auth/apple/browser/start', 'POST', JSON.stringify({
      codeChallenge: createHash('sha256').update(verifier).digest('base64url'), state,
    }));
    assert.equal(start.status, 200, start.body);
    const localAuthorize = new URL((JSON.parse(start.body) as { url: string }).url);
    const authorize = await http(localAuthorize.pathname + localAuthorize.search);
    assert.equal(authorize.status, 302, authorize.body);
    const authorizeCookies = authorize.headers['set-cookie'] ?? [];
    assert.ok(authorizeCookies.some(value => /SameSite=None/i.test(value) && /Secure/i.test(value) && /HttpOnly/i.test(value)), 'Apple form_post needs its secure cross-site state cookie');
    const apple = new URL(authorize.headers.location!);
    const idToken = await token('apple', { aud: 'com.recordpov.test.web' });
    appleResponses.set('http-adapter-authorization-code', idToken);
    const callback = await http('/api/auth/callback/apple', 'POST', new URLSearchParams({
      code: 'http-adapter-authorization-code', state: apple.searchParams.get('state')!, id_token: idToken,
    }).toString(), {
      'content-type': 'application/x-www-form-urlencoded', origin: 'https://appleid.apple.com', cookie: cookies(authorize),
    });
    assert.equal(callback.status, 302, callback.body);
    const callbackCookies = callback.headers['set-cookie'] ?? [];
    assert.ok(callbackCookies.length >= 2, 'state expiry and session cookies must remain separate HTTP fields');
    assert.equal(callback.rawHeaders.filter((value, i) => i % 2 === 0 && value.toLowerCase() === 'set-cookie').length, callbackCookies.length);
    const completeURL = new URL(callback.headers.location!);
    assert.equal(completeURL.pathname, '/v1/auth/apple/browser/complete');
    const complete = await http(completeURL.pathname + completeURL.search, 'GET', undefined, { cookie: cookies(callback) });
    assert.equal(complete.status, 302, complete.body);
    const appLink = new URL(complete.headers.location!);
    assert.equal(appLink.pathname, '/auth/apple/return');
    assert.equal(appLink.searchParams.get('state'), state);
    const exchange = await http('/v1/auth/apple/browser/exchange', 'POST', JSON.stringify({ code: appLink.searchParams.get('code'), codeVerifier: verifier }));
    assert.equal(exchange.status, 200, exchange.body);
    const login = JSON.parse(exchange.body) as { token: string };
    const session = await http('/v1/auth/session', 'GET', undefined, { authorization: `Bearer ${login.token}` });
    assert.equal(session.status, 200, session.body);
    assert.equal((JSON.parse(session.body) as { user: { email: string } }).user.email, 'test@example.test');
  } finally {
    server.closeAllConnections();
    await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
    await f.cleanup();
  }
});
