import { mkdir, chmod } from 'node:fs/promises';
import { dirname } from 'node:path';
import Database from 'better-sqlite3';
import { betterAuth } from 'better-auth';
import { bearer, oneTimeToken } from 'better-auth/plugins';
import { getMigrations } from 'better-auth/db/migration';
import { appleReady, type Config } from './config.js';
import { createApple } from './apple.js';

export async function createIdentity(config: Config) {
  await mkdir(dirname(config.databasePath), { recursive: true, mode: 0o700 });
  const database = new Database(config.databasePath);
  try {
    await chmod(config.databasePath, 0o600);
    database.pragma('journal_mode = WAL');
    database.pragma('foreign_keys = ON');
    database.pragma('busy_timeout = 5000');
    const apple = await createApple(config, database);
    function accountTokens(account: Record<string, unknown>) {
      const { idToken: _id, accessToken: _access, refreshToken, ...safe } = account;
      return { data: {
        ...safe, idToken: null, accessToken: null,
        // Better Auth encrypts browser-flow refresh tokens before DB hooks.
        ...(typeof refreshToken === 'string' ? {
          refreshToken, appleClientId: config.appleServicesId,
          appleGrantValidatedAt: Date.now(), appleGrantCheckAfter: Date.now() + 24 * 60 * 60_000,
        } : {}),
      } };
    }
    const auth = betterAuth({
      appName: 'RecordPOV',
      baseURL: config.baseURL,
      secret: config.secret,
      database,
      telemetry: { enabled: false },
      logger: { disabled: true },
      emailAndPassword: { enabled: false },
      socialProviders: {
        ...(config.googleServerClientId ? {
          google: { clientId: config.googleServerClientId },
        } : {}),
        ...(appleReady(config) ? {
          apple: async () => ({
            clientId: [config.appleServicesId ?? config.appleBundleId!, config.appleBundleId!],
            clientSecret: await apple!.clientSecret(config.appleServicesId ?? config.appleBundleId!),
            audience: [config.appleServicesId ?? config.appleBundleId!, config.appleBundleId!],
          }),
        } : {}),
      },
      plugins: [bearer({ requireSignature: true }), oneTimeToken({ storeToken: 'hashed', disableClientRequest: true, expiresIn: 1 })],
      session: {
        expiresIn: 60 * 60 * 24 * 30,
        updateAge: 60 * 60 * 24,
        freshAge: 60 * 5,
        cookieCache: { enabled: false },
      },
      user: { deleteUser: { enabled: true } },
      account: {
        accountLinking: { enabled: false, disableImplicitLinking: true, trustedProviders: [] },
        encryptOAuthTokens: true,
        storeAccountCookie: false,
        additionalFields: {
          appleClientId: { type: 'string', required: false, input: false },
          appleGrantValidatedAt: { type: 'number', required: false, input: false },
          appleGrantCheckAfter: { type: 'number', required: false, input: false },
        },
      },
      databaseHooks: {
        account: {
          // Native identity verification does not need to retain provider tokens.
          create: { before: async account => accountTokens(account) },
          update: { before: async account => accountTokens(account) },
        },
      },
      trustedOrigins: [config.baseURL, 'https://appleid.apple.com'],
      advanced: {
        useSecureCookies: config.baseURL.startsWith('https:'),
        ...(config.appleServicesId && config.androidCallbackURL ? { cookies: {
          state: { attributes: { sameSite: 'none' as const, secure: true, httpOnly: true } },
          oauth_state: { attributes: { sameSite: 'none' as const, secure: true, httpOnly: true } },
        } } : {}),
      },
      // The native facade enforces bounded per-IP and global budgets itself.
      rateLimit: { enabled: false },
    });
    const migrations = await getMigrations(auth.options);
    await migrations.runMigrations();
    return { auth, apple, database, close: () => database.close() };
  } catch (error) {
    database.close();
    throw error;
  }
}

export type Identity = Awaited<ReturnType<typeof createIdentity>>;
