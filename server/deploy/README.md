# Hetzner resolver deployment

Live deployment: `https://api.recordpov.app` on the existing Hetzner Linux host `77.42.83.163`, verified November 5, 2026. DNS is DNS-only in Cloudflare. Instagram, X and TikTok fetch directly on Hetzner. YouTube's foreground phone-assisted path passed the supplied 426-second video on the physical iPhone; its direct-server requests remain challenged. See [YouTube verification](../../docs/verification/youtube-phone-imports.json) and [the earlier direct-import report](../../docs/verification/hetzner-media-imports.json). Recheck the remote host, HTTPS and actual platform imports for later releases.

Install this service only on the authorized Linux server under `/opt/recordpov`. Do not install a Mac daemon, login item, LaunchAgent, Docker VM, or automatic local Node process. Local testing is a temporary foreground terminal only.

Deployment access on the owner's Mac is saved as `ssh recordpov-hetzner` in `~/.ssh/config`, using the dedicated `~/.ssh/recordpov_hetzner_ed25519` key. The server password is stored in macOS Keychain under service `recordpov-hetzner-77.42.83.163`, account `root`. Credentials and private keys do not belong in this repository or release archive.

## What runs

The server only finds links. `POST /v2/media/resolve` extracts metadata and returns a hybrid manifest of short-lived platform CDN links (`convert`, optional `fallback`, and `videoCodec`/`audioCodec`/`fps` in `expected`; see [the contract](../DIRECT_DELIVERY.md)). The phone downloads the files itself and converts the original on the device when it is better than the directly playable version. The server never downloads, converts, transcodes or stores imported videos, for any platform, YouTube included. `POST /v1/media/resolve` answers `410 UPDATE_REQUIRED` and starts no work; installed app builds that still use it fail until updated. `GET /v1/media/:id/file` is unchanged.

YouTube imports additionally use a foreground phone-assisted connection, described in [the shared protocol](../../docs/youtube-phone-transport.md). The API issues a short-lived video-bound capability; the phone carries TLS bytes without decrypting them. A separate `youtube-worker` runs the same pinned extractor with `network_mode: none`, a loopback-only SOCKS5h listener, and private authenticated Unix IPC. It has no direct outbound network or published ports, and shares only the temporary media cache and owner-only IPC volume. The IPC key is generated on worker startup, stays server-side, and is never included in media manifests, URLs or logs. It returns the hybrid plan over that private channel, or `NO_DIRECT_MEDIA` when none exists; it never falls through to downloading or preparing media. The phone remains connected until resolution completes. Assisted jobs allow 600 seconds and sessions 630 seconds; other platforms allow 900 seconds. The edge must allow the documented session HTTP/WSS paths and a 930-second response timeout. No third-party proxy or account cookies are used.

The resolver container runs as UID/GID `10001`, with a read-only root filesystem, no capabilities, no privilege escalation, a 64 MiB temporary filesystem, 1.5 GiB memory limit, 128-process limit and 1.5 CPU budget. Only `127.0.0.1:8787` is published on the host. A dedicated bridge has fixed resolver address `172.30.83.2`; confirm that subnet is unused first.

Node 22, FFmpeg/ffprobe and pinned `yt-dlp[default,curl-cffi]==2026.10.26` are included. The default extra includes the matching EJS package; the optional `curl-cffi` extra supplies browser-compatible HTTP transport used automatically by extractors such as TikTok. Image builds verify both imports and print the available transport targets. No global impersonation override, account cookies, CAPTCHA solver, login proxy or token provider is configured. The downloader explicitly enables its Node runtime and disables remote components, plugins, configuration files, cookies and login. There is no administrator token in either mobile app.

Imports allow public single-video Instagram, YouTube, X and TikTok URLs. Limits are 60 minutes and 2 GiB per direct download for every video (`maxBytes` in every manifest; the phone enforces it while downloading), a 900-second resolve deadline or 600 seconds for assisted YouTube (the relay keeps its 750 MiB phone-transport session budget), one active worker, four queued requests, and 20 import attempts per client IP per minute (the retired v1 route still counts). Proxy addresses must be exact and the proxy must replace `X-Forwarded-For` with one verified client address. Invalid or untrusted forwarding headers cannot bypass the socket-IP limit.

Imports add no videos here: routes only use private staging for metadata extraction, removed when each request settles. The existing cache (four-hour TTL, 8 GiB) still serves entries already present through `GET /v1/media/:id/file` until they expire and are pruned. The unused preparation modules' staging bound remains approximately 6 GiB (three times the 2 GiB media limit) per active worker. These are application limits, not a hard filesystem quota. Reserve at least 16 GiB of disk for cache/staging plus image/log/certificate storage; use a separate quota-limited filesystem if the host requires a hard disk ceiling. Camera footage, projects, captions and exported takes remain on the device. No R2 or other object storage is involved.

The public profile has IP-based import quotas, not user accounts, per-user download-bandwidth limits or a guarantee against distributed abuse. Monitor host disk/network/worker load; stronger authenticated quotas are separate work if access expands. Private/login-required or datacenter-blocked sources remain unavailable; do not add browser cookies, residential proxies or login workarounds.

## Inspect before installing

Check the existing OS, Docker version, reverse proxy, listeners, firewall and available disk. Keep existing sites and host firewall policies. Docker must use its iptables backend with a `DOCKER-USER` chain; the guard deliberately refuses the native Docker nftables backend. The iptables-nft compatibility frontend is supported. Required host tools are Docker Engine with Compose v2, Bash, Python 3, iptables/ip6tables and flock. Do not disable the host firewall or change Docker's global networking options to make this package work.

```sh
sudo ss -lntup
sudo docker version
sudo docker compose version
sudo docker network ls
sudo iptables -S DOCKER-USER
df -h /opt
```

Copy the `server` source to `/opt/recordpov`, excluding `.cache`, `.env`, `node_modules` and `dist`. The layout must contain `/opt/recordpov/package.json`, `/opt/recordpov/src`, and `/opt/recordpov/deploy`. Build contexts explicitly omit local caches and secrets. Work from `/opt/recordpov/deploy`:

```sh
cp .env.example .env
chmod 600 .env
chmod 755 egress-firewall.sh
```

Review all addresses in `.env`. If changing the network, keep subnet/gateway/resolver/edge/bridge values consistent. Bridge names must start with `br-recordpov` and be at most 15 characters. The network must be a dedicated unused RFC1918 `/24` through `/30`. Stop/remove the old project and its guard before changing addresses.

## Choose the HTTPS edge

If a host Caddy already serves other sites, retain `COMPOSE_FILE=compose.yaml`. Add the site from `Caddyfile` to its existing configuration, validate using that installation's `caddy validate`, and reload only after validation. The default upstream is `127.0.0.1:8787`. If a different existing proxy is used, configure the same hostname, 4 KiB request-body limit, a response-header timeout of at least 930 seconds, the documented WebSocket upgrade path, byte-range forwarding, and overwrite `X-Forwarded-For` with the socket client address. Remove untrusted `Forwarded`/`CF-Connecting-IP`. Never expose port 8787 publicly. A proxy container needs a deliberate private route; its own loopback is not the host's loopback.

Only when ports 80/443 are free, choose the supplied standalone Caddy container by setting:

```dotenv
COMPOSE_FILE=compose.yaml:compose.caddy.yaml
```

That edge runs separately as UID `10002`, publishes host 80/443 to internal unprivileged 8080/8443, and persists ACME state in its own named volumes. It reaches `resolver:8787` from exact trusted address `172.30.83.3`. The override enables communication within this dedicated bridge; the resolver's own firewall still blocks new connections to private destinations. Keep Cloudflare DNS-only for this direct-client-IP setup. If adding a CDN later, verify its IP trust chain and rate-limit behavior first.

The standalone edge uses HTTP/1.1 and HTTP/2. HTTP/3 is disabled because the internal HTTPS port would otherwise appear in its advertised address. `Alt-Svc: clear` removes the earlier cached hint to port 8443; public clients use port 443.

The standalone Caddy override sets TCP congestion control to BBR in **only its own network namespace**. A measured lossy, approximately 270 ms path reduced a sustained 8 MiB range request to 458,752 bytes in 30 seconds under CUBIC; a new BBR connection delivered all 8 MiB in 4.94 seconds. These measurements describe that route, not a guaranteed transfer speed. Existing TCP connections retain their current algorithm; new connections use the edge's configured default. The host's default stays unchanged, and neither the resolver nor the isolated YouTube worker receives this setting. See [the verification report](../../docs/verification/youtube-level-repair.json).

Before starting this optional edge, verify that the running Linux kernel has the standard `tcp_bbr` module installed. Load and persist that module without changing host-wide TCP defaults:

```sh
modinfo tcp_bbr
sudo modprobe tcp_bbr
printf 'tcp_bbr\n' | sudo tee /etc/modules-load.d/recordpov-tcp-bbr.conf >/dev/null
```

If the matching module is unavailable, do not install an unrelated kernel or alter host defaults during deployment. Resolve that prerequisite, or remove only the Caddy `sysctls` entry to retain the original congestion-control behavior. To roll back the edge setting, remove that entry and recreate Caddy through the project's guarded deployment flow. Its existing read-only filesystem, dropped capabilities, trusted proxy boundary and worker egress rules remain required.

Build and inspect configuration before starting anything:

```sh
sudo docker compose config --quiet
sudo docker compose build --pull
```

For a media-only update with the standalone edge, `IMAGE_TAG` is shared by both `recordpov-media` (resolver/YouTube worker) and `recordpov-edge` (Caddy). Building only the new media image does **not** create the edge image at that tag; changing `.env` first can prevent the entire Compose project from starting. Before changing the live `.env` or restarting, build the new media image and either build the edge too or, when its Dockerfile/base image is deliberately unchanged, verify and tag the existing edge image into the new release:

```sh
release_tag=2026-11-06-3
previous_edge_tag=2026-11-05-3
sudo docker image inspect "recordpov-media:${release_tag}" >/dev/null
sudo docker image inspect "recordpov-edge:${previous_edge_tag}" >/dev/null
sudo docker image tag "recordpov-edge:${previous_edge_tag}" "recordpov-edge:${release_tag}"
sudo docker image inspect "recordpov-media:${release_tag}" "recordpov-edge:${release_tag}" >/dev/null
sudo env IMAGE_TAG="$release_tag" docker compose config --images
```

Use the intended release and verified existing edge tags, then update `.env` only after **both** target images exist. Restart through `recordpov.service` so its network guard is reapplied. If the optional account service is installed, verify `recordpov-auth.service` restarted too; check both units are active, all containers are healthy/running, and public `/health` plus `/v1/auth/config` succeed. Main-unit recovery alone does not prove account-service recovery.

For standalone Caddy, its offline config validation can also run before publishing the service:

```sh
sudo docker compose run --rm --no-deps caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
```

## Apply the network guard and start

Platform host validation is not sufficient SSRF protection: yt-dlp follows media-CDN requests and redirects. `egress-firewall.sh` closes that boundary for this worker. It touches only `RECORDPOV-*`/`RECORDPOV6-*` chains and rules scoped to this dedicated bridge and resolver IP. It never flushes unrelated host/Docker rules. It permits established replies; denies private, loopback, link-local/metadata, reserved and multicast IPv4 destinations; then permits new public TCP 80/443 and DNS only. A separate host `INPUT` hook denies new resolver connections to any address of the Linux host, including its public address. IPv6 is disabled in Compose and rejected on the dedicated bridge as a second boundary.

The Linux systemd unit applies the guard before starting Compose. Both container restart policies are `no`, so Docker cannot restart a worker before the guard after a reboot. The unit is tied to Docker's lifecycle; normal Docker restart stops this project first, then reapplies its guard. Preflight refuses Docker `live-restore=true`, which could otherwise keep a worker alive across a daemon/firewall restart; it does not change shared Docker settings. Keep the guard installed when stopping the app. If another firewall manager flushes these chains while containers run, stop this project and restore the guard before resuming; do not blindly reload/firewall-reset a live worker.

```sh
sudo install -m 0644 recordpov.service /etc/systemd/system/recordpov.service
sudo systemctl daemon-reload
sudo systemctl enable --now recordpov.service
sudo systemctl status recordpov.service
sudo journalctl -u recordpov.service -n 80 --no-pager
sudo ./egress-firewall.sh status
```

The unit reads the exact environment from `/opt/recordpov/deploy/.env`; changing `.env` requires a unit restart. No automatic updater is installed. A Docker healthcheck reports API liveness; inspect failures in the unit/container logs rather than treating health as proof that platform extraction works.

## Verify real behavior

Run the smoke check from a machine with Node 22+. The optional second argument still calls the retired `POST /v1/media/resolve`, so against a links-only server it now reports HTTP 410 `UPDATE_REQUIRED`; verify real imports with `/v2/media/resolve` and the native apps instead:

```sh
node smoke.mjs https://api.recordpov.app
node smoke.mjs https://api.recordpov.app 'https://www.instagram.com/reel/DfR0-RNR-Y8/'
```

Test a public YouTube URL separately too. Cloud datacenter IP behavior can differ from the Mac; do not report link import as working on the strength of `/health` alone. Check that v2 responses contain only CDN links (`kind: "direct"`, `convert`, optional `fallback`) and decode the phone's imported result before release.

The guard probe can be piped into the running worker without changing its image:

```sh
sudo docker compose exec -T resolver node --input-type=module < probe-egress.mjs
sudo ./egress-firewall.sh status
```

If the gateway changed, pass `-e PROBE_GATEWAY=<gateway>` to that `exec`. The probe uses TCP handshakes, sends no payload to blocked addresses, and expects public HTTPS/DNS to work. A refused connection alone cannot distinguish an absent listener from filtering: confirm the corresponding reject counters increment. For definitive container-to-host proof, an operator can temporarily listen on the dedicated bridge gateway, verify the host `INPUT` reject counter increases when probed, then remove that listener. Do not open extra public ports for this check.

Confirm per-client quotas through the actual proxy (two real client addresses remain independent; forged XFF does not rotate quota), memory/disk bounds, playback Range 206, and Docker/service restart behavior before routing the installed apps to this endpoint. Application tests cover proxy trust and quota handling; they do not replace this host-level proof.

## Stop, update and roll back

```sh
sudo systemctl stop recordpov.service
```

That stops only this Compose project and retains its cache/certificates and guard. To update, build a tagged image, then restart the unit after reviewing the effective Compose config. Keep the prior tag for rollback; do not automatically upgrade extractor dependencies at startup.

To remove this deployment, stop/disable its unit, remove only its HTTPS site (or its optional Caddy container), and only then run `egress-firewall.sh remove` with the same network environment the unit used. Remove named volumes only if explicitly discarding cache/certificates. Never run `docker system prune`, alter other project networks or flush the host firewall.

Primary references: [Docker iptables chains](https://docs.docker.com/engine/network/firewall-iptables/), [Caddy reverse proxy](https://caddyserver.com/docs/caddyfile/directives/reverse_proxy), [Caddy internal HTTP/HTTPS ports](https://caddyserver.com/docs/caddyfile/options), [yt-dlp EJS/Node support](https://github.com/yt-dlp/yt-dlp/wiki/EJS).
