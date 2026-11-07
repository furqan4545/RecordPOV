import { decodeJwt, decodeProtectedHeader } from 'jose';
import { appleReady, type Config } from './config.js';
import { AuthError } from './limits.js';

export interface SignInInput { provider: 'google' | 'apple'; idToken: string; nonce?: string; name?: string; authorizationCode?: string }

export function validateSignIn(value: unknown, config: Config, now = Date.now()): SignInInput {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalidInput();
  const body = value as Record<string, unknown>;
  if (Object.keys(body).some(key => !['provider', 'idToken', 'nonce', 'name', 'authorizationCode'].includes(key))) throw invalidInput();
  if (body.provider !== 'google' && body.provider !== 'apple') throw invalidInput();
  const audience = body.provider === 'google' ? config.googleServerClientId : config.appleBundleId;
  if (!audience || (body.provider === 'apple' && !appleReady(config))) throw new AuthError(503, 'PROVIDER_UNAVAILABLE', 'This sign-in option is not configured yet.');
  if (body.provider === 'apple' && (typeof body.authorizationCode !== 'string' ||
      !/^[A-Za-z0-9._~-]{8,4096}$/.test(body.authorizationCode))) throw invalidInput();
  if (body.provider === 'google' && body.authorizationCode !== undefined) throw invalidInput();
  if (typeof body.idToken !== 'string' || body.idToken.length > 16_384 ||
      !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(body.idToken)) throw invalidToken();
  if (body.nonce !== undefined && (typeof body.nonce !== 'string' ||
      !/^[A-Za-z0-9._~-]{16,256}$/.test(body.nonce))) throw invalidInput();
  if (body.name !== undefined && (typeof body.name !== 'string' || body.name.length > 120 ||
      /[\x00-\x1f\x7f]/.test(body.name))) throw invalidInput();
  try {
    // This rejects malformed/irrelevant input before any network request. It is NOT
    // authentication: Better Auth then verifies the signature and claims itself.
    const header = decodeProtectedHeader(body.idToken);
    const claims = decodeJwt(body.idToken);
    const seconds = now / 1000;
    const issuers = body.provider === 'google'
      ? ['https://accounts.google.com', 'accounts.google.com'] : ['https://appleid.apple.com'];
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || header.kid.length > 200 || !header.kid ||
        header.jku !== undefined || header.x5u !== undefined || header.crit !== undefined ||
        !issuers.includes(claims.iss ?? '') ||
        !(claims.aud === audience || (Array.isArray(claims.aud) && claims.aud.includes(audience))) ||
        typeof claims.sub !== 'string' || !claims.sub || claims.sub.length > 255 ||
        typeof claims.exp !== 'number' || !Number.isFinite(claims.exp) || claims.exp < seconds - 30 ||
        typeof claims.iat !== 'number' || !Number.isFinite(claims.iat) ||
        claims.iat > seconds + 30 || seconds - claims.iat > 3630 ||
        (claims.nbf !== undefined && (typeof claims.nbf !== 'number' || claims.nbf > seconds + 30))) {
      throw invalidToken();
    }
  } catch { throw invalidToken(); }
  return body as unknown as SignInInput;
}

export function bearerToken(header: string | null): string {
  if (!header || !/^Bearer [A-Za-z0-9._~%+\/-]{20,4096}={0,2}$/.test(header)) {
    throw new AuthError(401, 'UNAUTHENTICATED', 'Please sign in again.');
  }
  return header.slice(7);
}

function invalidInput() { return new AuthError(400, 'INVALID_REQUEST', 'Please check the sign-in request.'); }
function invalidToken() { return new AuthError(401, 'INVALID_ID_TOKEN', 'Sign-in could not be verified. Please try again.'); }
