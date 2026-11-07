import { readFile, stat } from 'node:fs/promises';
import { importPKCS8, SignJWT, decodeJwt } from 'jose';
import { symmetricEncrypt, symmetricDecrypt } from 'better-auth/crypto';
import type Database from 'better-sqlite3';
import { appleReady, type Config } from './config.js';
import { AuthError } from './limits.js';

export async function createApple(config: Config, database: Database.Database) {
  if (!appleReady(config)) return undefined;
  const keyStat = await stat(config.applePrivateKeyPath!);
  if (!keyStat.isFile() || keyStat.size > 16_384) throw new Error('Invalid Apple private key file.');
  const key = await importPKCS8(await readFile(config.applePrivateKeyPath!, 'utf8'), 'ES256');
  const validationJobs = new Map<string, Promise<void>>();

  async function clientSecret(clientId: string) {
    if (![config.appleBundleId, config.appleServicesId].includes(clientId)) throw new Error('Unconfigured Apple client.');
    return new SignJWT({}).setProtectedHeader({ alg: 'ES256', kid: config.appleKeyId })
      .setIssuer(config.appleTeamId!).setSubject(clientId).setAudience('https://appleid.apple.com')
      .setIssuedAt().setExpirationTime('5m').sign(key);
  }

  async function post(path: 'token' | 'revoke', values: Record<string, string>) {
    try {
      const response = await fetch(`https://appleid.apple.com/auth/${path}`, {
        method: 'POST', redirect: 'error', signal: AbortSignal.timeout(10_000),
        headers: { 'content-type': 'application/x-www-form-urlencoded' }, body: new URLSearchParams(values),
      });
      const reader = response.body?.getReader();
      const chunks: Uint8Array[] = [];
      let size = 0;
      if (reader) {
        while (true) {
          const item = await reader.read();
          if (item.done) break;
          size += item.value.length;
          if (size > 32_768) { await reader.cancel(); throw new Error('Oversized Apple response.'); }
          chunks.push(item.value);
        }
      }
      const text = Buffer.concat(chunks).toString('utf8');
      if (!response.ok) {
        const providerError = text ? JSON.parse(text) as { error?: unknown } : {};
        if (path === 'token' && values.grant_type === 'refresh_token') {
          // Only Apple's explicit OAuth response proves revocation. A timeout,
          // generic 4xx/5xx or malformed reply must not delete user sessions.
          if ([400, 401].includes(response.status) && providerError.error === 'invalid_grant') {
            throw new AuthError(401, 'APPLE_GRANT_REVOKED', 'Please sign in with Apple again.');
          }
          throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple sign-in is temporarily unavailable. Please try again.');
        }
        throw new AuthError(path === 'token' ? 401 : 503,
          path === 'token' ? 'INVALID_ID_TOKEN' : 'APPLE_REVOCATION_FAILED',
          path === 'token' ? 'Apple sign-in could not be verified. Please try again.' : 'Apple could not disconnect the account. Please try again before deleting it.');
      }
      return text ? JSON.parse(text) as Record<string, unknown> : {};
    } catch (error) {
      if (error instanceof AuthError) throw error;
      throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple sign-in is temporarily unavailable. Please try again.');
    }
  }

  interface Grant {
    id: string; accountId: string; refreshToken: string | null; appleClientId: string | null;
    appleGrantValidatedAt: number | null; appleGrantCheckAfter: number | null;
  }
  function invalidateGrant(userId: string, account: Grant): boolean {
    return database.transaction(() => {
      const current = database.prepare('SELECT refreshToken FROM account WHERE id = ?').get(account.id) as { refreshToken: string | null } | undefined;
      // An overlapping fresh Apple sign-in may have already replaced this grant.
      if (!current || current.refreshToken !== account.refreshToken) return false;
      database.prepare('DELETE FROM session WHERE userId = ?').run(userId);
      database.prepare('UPDATE account SET refreshToken = NULL, appleGrantValidatedAt = NULL, appleGrantCheckAfter = NULL WHERE id = ?').run(account.id);
      return true;
    })();
  }
  const reauthentication = () => new AuthError(401, 'REAUTHENTICATION_REQUIRED', 'Please sign in with Apple again.');

  async function validateGrants(userId: string) {
    const accounts = database.prepare('SELECT id, accountId, refreshToken, appleClientId, appleGrantValidatedAt, appleGrantCheckAfter FROM account WHERE userId = ? AND providerId = ?')
      .all(userId, 'apple') as Grant[];
    for (const account of accounts) {
      if (!account.refreshToken || !account.appleClientId || ![config.appleBundleId, config.appleServicesId].includes(account.appleClientId)) {
        if (invalidateGrant(userId, account)) throw reauthentication();
        continue;
      }
      const now = Date.now();
      if (account.appleGrantValidatedAt && account.appleGrantValidatedAt <= now && now - account.appleGrantValidatedAt < 24 * 60 * 60_000) continue;
      if (account.appleGrantCheckAfter && account.appleGrantCheckAfter > now) {
        throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple sign-in is temporarily unavailable. Please try again shortly.');
      }
      // Persistent short lease/backoff plus in-process coalescing avoids a
      // provider request on every lookup, including concurrent/outage retries.
      const claimed = database.prepare('UPDATE account SET appleGrantCheckAfter = ? WHERE id = ? AND (appleGrantCheckAfter IS NULL OR appleGrantCheckAfter <= ?)')
        .run(now + 60_000, account.id, now);
      if (claimed.changes !== 1) throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple sign-in is temporarily unavailable. Please try again shortly.');
      try {
        const refreshToken = await symmetricDecrypt({ key: config.secret, data: account.refreshToken! });
        const response = await post('token', {
          client_id: account.appleClientId!, client_secret: await clientSecret(account.appleClientId!),
          grant_type: 'refresh_token', refresh_token: refreshToken,
        });
        if (typeof response.access_token !== 'string' || !response.access_token || response.access_token.length > 8192) throw new Error('Malformed Apple refresh response.');
        if (response.id_token !== undefined) {
          if (typeof response.id_token !== 'string') throw new Error('Malformed Apple identity response.');
          const claims = decodeJwt(response.id_token);
          if (claims.sub !== account.accountId || claims.aud !== account.appleClientId || claims.iss !== 'https://appleid.apple.com') {
            throw new Error('Unexpected Apple grant binding.');
          }
        }
        const succeeded = Date.now();
        database.prepare('UPDATE account SET appleGrantValidatedAt = ?, appleGrantCheckAfter = ? WHERE id = ? AND refreshToken = ?')
          .run(succeeded, succeeded + 24 * 60 * 60_000, account.id, account.refreshToken);
      } catch (error) {
        if (error instanceof AuthError && error.code === 'APPLE_GRANT_REVOKED') {
          if (invalidateGrant(userId, account)) throw reauthentication();
          continue;
        }
        database.prepare('UPDATE account SET appleGrantCheckAfter = ? WHERE id = ? AND refreshToken = ?')
          .run(Date.now() + 5 * 60_000, account.id, account.refreshToken);
        throw new AuthError(503, 'APPLE_UNAVAILABLE', 'Apple sign-in is temporarily unavailable. Please try again shortly.');
      }
    }
  }

  return {
    clientSecret,
    async exchangeNative(code: string, identityToken: string) {
      const response = await post('token', {
        client_id: config.appleBundleId!, client_secret: await clientSecret(config.appleBundleId!),
        grant_type: 'authorization_code', code,
      });
      if (typeof response.refresh_token !== 'string' || response.refresh_token.length > 8192 ||
          typeof response.id_token !== 'string') throw new AuthError(401, 'INVALID_ID_TOKEN', 'Apple sign-in could not be verified. Please try again.');
      // The response comes directly from Apple's fixed HTTPS endpoint. Better
      // Auth independently verifies the submitted identity token next.
      const native = decodeJwt(identityToken);
      const exchanged = decodeJwt(response.id_token);
      if (exchanged.sub !== native.sub || exchanged.aud !== config.appleBundleId || exchanged.iss !== 'https://appleid.apple.com') {
        throw new AuthError(401, 'INVALID_ID_TOKEN', 'Apple sign-in could not be verified. Please try again.');
      }
      return response.refresh_token;
    },
    async storeNativeGrant(userId: string, refreshToken: string) {
      const encrypted = await symmetricEncrypt({ key: config.secret, data: refreshToken });
      const now = Date.now();
      const changed = database.prepare('UPDATE account SET refreshToken = ?, appleClientId = ?, appleGrantValidatedAt = ?, appleGrantCheckAfter = ? WHERE userId = ? AND providerId = ?')
        .run(encrypted, config.appleBundleId!, now, now + 24 * 60 * 60_000, userId, 'apple');
      if (changed.changes !== 1) throw new Error('Missing Apple account binding.');
    },
    async validateSessionGrant(userId: string) {
      const existing = validationJobs.get(userId);
      if (existing) return existing;
      if (validationJobs.size >= 8) throw new AuthError(503, 'AUTH_BUSY', 'Sign-in is busy. Please try again shortly.');
      const job = validateGrants(userId);
      validationJobs.set(userId, job);
      try { await job; } finally { if (validationJobs.get(userId) === job) validationJobs.delete(userId); }
    },
    async revokeForUser(userId: string) {
      const accounts = database.prepare('SELECT refreshToken, appleClientId FROM account WHERE userId = ? AND providerId = ?').all(userId, 'apple') as { refreshToken: string | null; appleClientId: string | null }[];
      for (const account of accounts) {
        if (!account.refreshToken || !account.appleClientId || ![config.appleBundleId, config.appleServicesId].includes(account.appleClientId)) {
          throw new AuthError(401, 'REAUTHENTICATION_REQUIRED', 'Please sign in with Apple again before deleting your account.');
        }
        const refreshToken = await symmetricDecrypt({ key: config.secret, data: account.refreshToken });
        await post('revoke', {
          client_id: account.appleClientId, client_secret: await clientSecret(account.appleClientId),
          token: refreshToken, token_type_hint: 'refresh_token',
        });
      }
    },
  };
}
