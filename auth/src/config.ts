import { isIP } from 'node:net';
import { resolve } from 'node:path';

export interface Config {
  host: string;
  port: number;
  baseURL: string;
  secret: string;
  databasePath: string;
  trustedProxyIPs: ReadonlySet<string>;
  googleServerClientId?: string;
  googleIOSClientId?: string;
  appleBundleId?: string;
  appleTeamId?: string;
  appleKeyId?: string;
  applePrivateKeyPath?: string;
  appleServicesId?: string;
  androidCallbackURL?: string;
}

const googleClient = /^[A-Za-z0-9_-]{5,200}\.apps\.googleusercontent\.com$/;
const bundleIdentifier = /^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/;

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const base = new URL(env.BETTER_AUTH_URL ?? 'https://api.recordpov.app');
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(base.hostname);
  if ((base.protocol !== 'https:' && !(base.protocol === 'http:' && local)) ||
      base.username || base.password || base.pathname !== '/' || base.search || base.hash) {
    throw new Error('BETTER_AUTH_URL must be a fixed HTTPS origin.');
  }
  const secret = env.BETTER_AUTH_SECRET ?? '';
  if (secret.length < 32 || secret.length > 512 || /[\x00-\x20\x7f]/.test(secret)) {
    throw new Error('BETTER_AUTH_SECRET must be a high-entropy secret of at least 32 characters.');
  }
  const port = Number(env.PORT ?? '8789');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid PORT.');
  const trustedProxyIPs = new Set((env.TRUSTED_PROXY_IPS ?? '127.0.0.1,::1')
    .split(',').map(value => value.trim()).filter(Boolean).map(normalizeIP));
  if ([...trustedProxyIPs].some(ip => !isIP(ip))) throw new Error('Trusted proxies must be exact IP addresses.');
  const googleServerClientId = env.AUTH_GOOGLE_SERVER_CLIENT_ID?.trim() || undefined;
  const googleIOSClientId = env.AUTH_GOOGLE_IOS_CLIENT_ID?.trim() || undefined;
  if ([googleServerClientId, googleIOSClientId].some(id => id && !googleClient.test(id))) {
    throw new Error('Invalid Google OAuth client ID.');
  }
  if (googleIOSClientId && !googleServerClientId) throw new Error('Google requires a Web/server client ID.');
  const appleBundleId = env.AUTH_APPLE_BUNDLE_ID?.trim() || undefined;
  if (appleBundleId && (appleBundleId.length > 255 || !bundleIdentifier.test(appleBundleId))) {
    throw new Error('Invalid Apple bundle identifier.');
  }
  const appleTeamId = env.AUTH_APPLE_TEAM_ID?.trim() || undefined;
  const appleKeyId = env.AUTH_APPLE_KEY_ID?.trim() || undefined;
  const applePrivateKeyPath = env.AUTH_APPLE_PRIVATE_KEY_FILE?.trim() || undefined;
  for (const identifier of [appleTeamId, appleKeyId]) if (identifier && !/^[A-Z0-9]{10}$/.test(identifier)) throw new Error('Invalid Apple team/key ID.');
  const appleServicesId = env.AUTH_APPLE_SERVICES_ID?.trim() || undefined;
  if (appleServicesId && !bundleIdentifier.test(appleServicesId)) throw new Error('Invalid Apple Services ID.');
  const androidCallbackURL = env.AUTH_ANDROID_CALLBACK_URL?.trim() || undefined;
  if (androidCallbackURL) {
    const callback = new URL(androidCallbackURL);
    if (callback.protocol !== 'https:' || callback.origin !== base.origin || callback.username || callback.password ||
        callback.search || callback.hash || callback.pathname !== '/auth/apple/return') {
      throw new Error('Android callback must be the fixed same-origin HTTPS /auth/apple/return App Link.');
    }
  }
  return {
    host: env.HOST ?? '127.0.0.1', port, baseURL: base.origin, secret,
    databasePath: resolve(env.AUTH_DATABASE_PATH ?? './data/auth.sqlite'),
    trustedProxyIPs, googleServerClientId, googleIOSClientId, appleBundleId,
    appleTeamId, appleKeyId, applePrivateKeyPath, appleServicesId, androidCallbackURL,
  };
}

export function normalizeIP(value: string): string {
  return value.startsWith('::ffff:') && isIP(value.slice(7)) === 4 ? value.slice(7) : value;
}

export function clientAddress(peer: string, forwarded: string | undefined, config: Config): string {
  const ip = normalizeIP(peer);
  const candidate = forwarded?.trim();
  return config.trustedProxyIPs.has(ip) && candidate && isIP(candidate)
    ? normalizeIP(candidate) : ip;
}

export function publicConfig(config: Config) {
  const appleEnabled = appleReady(config);
  const appleAndroidEnabled = appleEnabled && Boolean(config.appleServicesId && config.androidCallbackURL);
  return {
    version: 1,
    enabled: Boolean(config.googleServerClientId || appleEnabled),
    providers: {
      google: {
        enabled: Boolean(config.googleServerClientId),
        ...(config.googleServerClientId ? { serverClientId: config.googleServerClientId } : {}),
        ...(config.googleIOSClientId ? { iosClientId: config.googleIOSClientId } : {}),
      },
      apple: {
        enabled: appleEnabled,
        ...(appleEnabled ? { bundleId: config.appleBundleId } : {}),
      },
    },
    appleAndroidEnabled,
    ...(appleAndroidEnabled ? { androidCallbackURL: config.androidCallbackURL } : {}),
  };
}

export function appleReady(config: Config): boolean {
  return Boolean(config.appleBundleId && config.appleTeamId && config.appleKeyId && config.applePrivateKeyPath);
}
