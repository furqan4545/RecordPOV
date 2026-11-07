# Optional RecordPOV accounts

This separate service provides Apple and Google accounts through self-hosted [Better Auth](https://better-auth.com/docs/installation). It needs no Supabase project or paid authentication subscription. Recordings, projects, Photos exports and captions remain on the device; signing in does not enable cloud project storage or gate recording.

Runtime dependencies are pinned in `package-lock.json`: Better Auth 1.7.17 (MIT), better-sqlite3 12.11.1 (MIT), and jose 6.2.15 (MIT). The SQLite version is deliberately compatible with the workspace's Node 22.11; the newer 13.0.3 N-API prebuilt binary crashed that runtime during a minimal database-open test. Node 22 or newer is required. No custom session JWT or password implementation is used.

## Native HTTP contract

Production origin: `https://api.recordpov.app`. Every JSON response uses `Cache-Control: no-store`. Errors are `{ "error": { "code": "...", "message": "..." } }`. The service never logs request bodies, tokens, provider responses or secrets.

| Method and route | Request | Response |
| --- | --- | --- |
| `GET /v1/auth/config` | None | `{version:1,enabled,providers:{google:{enabled,serverClientId?,iosClientId?},apple:{enabled,bundleId?}},appleAndroidEnabled,androidCallbackURL?}` |
| `POST /v1/auth/sign-in` | `{provider:"google"\|"apple",idToken,nonce?,name?,authorizationCode?}` | `{token,expiresAt,user:{id,name,email,image?}}` |
| `GET /v1/auth/session` | `Authorization: Bearer <token>` | `{expiresAt,user}`; 401 if invalid/revoked/expired |
| `POST /v1/auth/sign-out` | Bearer, empty body or `{}` | 204; server session revoked |
| `DELETE /v1/auth/account` | Bearer, empty body or `{}` | 204; account and all sessions removed |

`authorizationCode` is **required for Apple** and forbidden for Google. Apple code exchange binds the returned subject to the submitted token. Better Auth independently verifies the token signature, issuer, audience, expiry and optional nonce. Supply the raw nonce used for native Apple sign-in; Better Auth accepts its SHA-256 representation in Apple's signed token. `name` is a display name only, useful for Apple's first authorization. The backend never trusts client-supplied email or user ID.

The returned `token` is Better Auth's signed bearer token. Store it in iOS Keychain / Android Keystore-backed encrypted storage. Do not log it, put it in a URL or store provider ID tokens. Sessions expire after 30 days and slide at most once per day. Store the updated `expiresAt` returned by session lookup. Local sign-out should clear the device token even when the network is unavailable; remote revocation is best effort in that case.

Apple session lookup also validates its refresh grant with Apple's fixed token endpoint at most once per 24 hours after the last successful code exchange/check. The successful timestamp survives restarts; simultaneous lookups share one check. Apple's explicit `invalid_grant` response invalidates **all** local sessions and returns 401 `REAUTHENTICATION_REQUIRED`, retaining the account and device projects. A provider outage returns 503, keeps the account/sessions/grant, and uses a persisted five-minute retry backoff. It does not mark the grant valid or delete user data. Thus revocation made outside the app is detected on the first session lookup after the daily validation becomes due.

Deletion requires a session created within five minutes. Otherwise it returns 401 `REAUTHENTICATION_REQUIRED`: perform provider sign-in again and retry using the new bearer. For Apple accounts, revocation completes **before** local identity deletion. A failed Apple request returns 503 and preserves the account/session for retry. Deleting a server account does not delete device recordings or projects.

Legacy Apple identities missing a usable refresh grant require a fresh Apple sign-in to restore it; they are not silently treated as validated. This implementation creates/stores grants for all configured new Apple accounts. Apple's guidance also permits deleting server data and directing the user to revoke access manually when tokens cannot be recovered. That manual legacy-account recovery requires an explicit support/operator workflow; this API does not bypass its reauthentication/revocation checks or silently delete a disconnected account.

No raw `/api/auth/*` routes are exposed except the exact Apple callback described below. Email/password signup, account linking, arbitrary OAuth callbacks and provider token-access endpoints are unavailable. Same-email identities from different providers are not merged; the user must use the original provider. Provider ID/access tokens are discarded. Apple's refresh grant is encrypted with Better Auth's crypto in the private account database solely for revocation; it is never returned to the app.

## Provider configuration

Copy `.env.example` into an untracked private `.env`; supply a high-entropy `BETTER_AUTH_SECRET` (for example `openssl rand -base64 48`). The secret and SQLite database must survive redeployment together. Back them up securely; they are independent from the resolver's temporary media cache.

**Google:** create OAuth credentials in one Google Cloud project, configure the consent screen and publish/verify it as required by Google's console. No Firebase project is needed. Set `AUTH_GOOGLE_SERVER_CLIENT_ID` to a Web application client ID, the common ID-token audience for both apps. Configure the iOS SDK with its own iOS client ID (`AUTH_GOOGLE_IOS_CLIENT_ID` in public config), bundle ID and reversed client-ID URL scheme. Configure Android's OAuth client with its package and each appropriate debug/release/Play App Signing SHA-1. Android Credential Manager uses the Web/server ID for `serverClientId`. ID-token verification does not require a Google OAuth client secret; browser/code flows would. See [Google iOS backend setup](https://developers.google.com/identity/sign-in/ios/start-integrating) and [Android Credential Manager](https://developer.android.com/identity/sign-in/credential-manager-siwg-implementation).

**Apple native iOS:** enable Sign in with Apple on the real App ID and provisioning profile. Set `AUTH_APPLE_BUNDLE_ID`, `AUTH_APPLE_TEAM_ID`, `AUTH_APPLE_KEY_ID` and `AUTH_APPLE_PRIVATE_KEY_FILE` to the genuine `.p8` key. Native ID-token signature verification alone would not need this private key; the complete account lifecycle does need it to exchange the authorization code and revoke the resulting grant. Apple stays disabled until these settings are present and the key successfully loads. The key stays server-side. See [Apple's account deletion and revocation guidance](https://developer.apple.com/documentation/technotes/tn3194-handling-account-deletions-and-revoking-tokens-for-sign-in-with-apple).

**Apple Android:** additionally create a Services ID linked to the primary Apple App ID, register `api.recordpov.app` and exact HTTPS return URL `https://api.recordpov.app/api/auth/callback/apple`, and set `AUTH_APPLE_SERVICES_ID`. Set `AUTH_ANDROID_CALLBACK_URL=https://api.recordpov.app/auth/apple/return` only after the Android manifest and a genuine `/.well-known/assetlinks.json` associate that App Link with the release package/certificate. The Service ID and native bundle ID are separate audiences. Apple requires HTTPS domains, not localhost/IP callbacks. See [Apple's web/other-platform configuration](https://developer.apple.com/documentation/signinwithapple/configuring-your-environment-for-sign-in-with-apple).

When configuration is absent, the corresponding public capability is false. No fake client IDs, test keys or fallback providers are installed in production. Provider-console credentials and live end-to-end sign-in still require the owner's configuration; unit tests use synthetic keys and mock official provider endpoints.

## Android Apple browser contract

Use the system browser / Custom Tabs. Never use an embedded WebView.

1. Generate and keep a random 43–128 character unreserved `codeVerifier` and random 16–128 character `state` in the app. `codeChallenge = BASE64URL(SHA256(codeVerifier))` without padding.
2. `POST /v1/auth/apple/browser/start` JSON `{codeChallenge,state}` returns `{url,expiresAt}`. Validate that `url` has the exact API origin and `/v1/auth/apple/browser/authorize` path, then open it. The request expires in 10 minutes and can start once.
3. Better Auth owns Apple's OAuth state/cookie/code verification and token exchange. Only the short-lived state cookies use `SameSite=None; Secure` for Apple's cross-site form POST. The callback's internal normalization is followed inside the service; authorization codes are not placed in an external redirect URL.
4. The final verified App Link is exactly the configured `androidCallbackURL` with `?code=<one-time-token>&state=<original-state>` or `?error=SIGN_IN_CANCELLED&state=...`. Validate the origin, path and original state.
5. `POST /v1/auth/apple/browser/exchange` JSON `{code,codeVerifier}` returns the usual `{token,expiresAt,user}`. The library one-time token expires after 60 seconds; its hash is stored. The verifier is checked before consumption, and replay is rejected. No permanent session token is placed in a URL.

The browser flow is capability-gated until all real Apple settings and the callback are configured. App Link delivery still needs a real Android device test after deployment.

## Development and verification

```sh
npm ci
npm test
npm run typecheck
npm run build
```

Tests exercise production Better Auth cryptographic verification with synthetic RSA/EC keys and mocked official JWKS/token/revocation endpoints. They test wrong signatures/audiences/issuers/time claims, hashed Apple nonce, unavailable providers, signed sessions, revocation, fresh deletion, retained accounts on Apple failure, disabled linking, private persistence, bounded inputs/rates and the full Android Apple browser/one-time handoff. They do not activate a camera, microphone, account UI, Photos or external provider account.

A production Node HTTP adapter regression runs the entire synthetic Apple browser flow through an ephemeral loopback port, verifying incoming state/session cookies and multiple distinct `Set-Cookie` response fields. The test closes the listener immediately in its cleanup; it does not install or leave a background service.

For an explicitly needed temporary foreground development session, load a private env file and run `npm run dev`. No Mac autostart, daemon or permanent background listener is installed.

## Hetzner packaging

This folder deploys separately at `/opt/recordpov-auth`; it does not change the media Compose project. `compose.yaml` uses the existing external `recordpov-egress` network, static `172.30.83.4`, alias `recordpov-auth`, port 8789 inside the network only, UID 10003, read-only root, no capabilities, no-new-privileges, 384 MiB memory, 0.5 CPU and 64 PIDs. It mounts only its own `recordpov-auth-private-data` volume. The named-volume mountpoint is initialized with UID 10003 ownership by the image. There are no published ports or media/cache/socket mounts.

The production network's Caddy overlay enables inter-container communication (confirmed by the deployer's actual Docker inspection), so Caddy can reach `.4:8789` without an additional forwarding exception. A deployment using an ICC-disabled network would need a narrow Caddy `.3` → auth `.4:8789` exception. Existing private-egress rules scoped to resolver `.2` do not automatically cover auth `.4`; an optional separate guard must preserve fixed Google/Apple public HTTPS requests and must not flush shared chains. Auth accepts no user-selected fetch destination and refuses provider redirects.

The Caddy operator routes `/v1/auth/*` and the exact `/api/auth/callback/apple` to `recordpov-auth:8789`, preserves the fixed host/protocol, and overwrites `X-Forwarded-For` with one verified client IP. This service trusts only immediate proxy `.3`; it ignores forged/multi-hop forwarding values. Serve genuine Android asset links at the API origin. Do not put Cloudflare Access in front of consumer sign-in or the media API: [Access is an identity-policy gateway](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/choose-application-type/) with its own login barrier. Cloudflare Workers/D1 could host Better Auth, but this deployment uses the existing Hetzner machine and SQLite instead.

For Apple, store the real `.p8` outside the repository and image, owned/readable only by UID 10003 (for example mode 0400). Use `compose.apple.yaml` with `AUTH_APPLE_PRIVATE_KEY_HOST_FILE` set to its absolute host path. Never create a placeholder key. A private `service.env` can set `COMPOSE_FILE=compose.yaml:compose.apple.yaml` for systemd; otherwise the base Compose file starts with Apple disabled.

`recordpov-auth.service` is a separate Linux unit requiring/starting after/part-of `recordpov.service`. Its failure cannot stop the media unit. Container restart policy is `no`; systemd owns restart ordering. The root deployer must stage/install the unit, build/run Linux images, verify the live routes/guard and configure providers. Nothing in this packaging starts a Mac service.

## Workspace deployment verification

Deployed on November 6, 2026 at `/opt/recordpov-auth` on the existing `recordpov-hetzner` SSH host, using image `recordpov-auth:2026-11-05-3`. The private `service.env` and Apple key live only on that host; the owner-only local Apple key backup is under `~/.config/recordpov/credentials`, outside this repository. Never print these secrets. The real provider registrations and public client IDs are recorded in `../docs/verification/auth-deployment.json`.

The account service starts after and independently from the existing media service; a `recordpov.service` drop-in wants the account unit on startup. The Caddy site routes only the account facade, exact Apple callback, and Android callback path to the account service. Its development-certificate asset links are served directly by Caddy. With admin disabled and Caddy 2.11+, validate a file change, then send `SIGUSR1` to the existing file-configured Caddy process for a graceful reload; do not restart the media worker to change account routes.

The final Linux image passes 19 account/HTTP tests. The native builds pass 101 Android tests and 10 iOS account-service tests. The existing iPhone 17 simulator passes the two branding/navigation checks and the optional-account navigation check. Simulator Keychain UI checks require ad-hoc signing; an unsigned simulator build correctly cannot use secure storage. The signed phone build was installed, and the owner confirmed real Apple sign-in worked. Google is configured in Testing with the owner listed; real Google and Android provider sign-in remain device acceptance checks, not claimed verified. Public Google availability additionally needs completed consent-screen details and any required verification.
