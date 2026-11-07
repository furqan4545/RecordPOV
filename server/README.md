# RecordPOV media service

The native apps use this small Node.js service to import a **public, single-video** Instagram, YouTube, X or TikTok link using the best available source quality up to 1080p at up to 60 fps (anything above 1080p is ignored). The server only finds links: it extracts metadata and returns short-lived platform CDN links. It never downloads, converts, transcodes or stores imported videos, for any platform. Camera footage, person segmentation, PiP composition and finished recordings stay on the phone; they are never sent here.

The hosted endpoint is live at `https://api.recordpov.app` on Hetzner under `/opt/recordpov`. Native clients call `POST /v2/media/resolve`, which returns a hybrid manifest: a directly playable H.264 + AAC-LC version at 1080p is downloaded and played with no conversion; only when the playable version is below 1080p (for example 720p) and a better original up to 1080p exists does the phone download that original and convert it on the device (`convert: true`, with the playable as `fallback`). The phone validates the files and locally muxes separate video/audio files when needed. YouTube metadata uses the foreground phone's connection through [the bounded transport](../docs/youtube-phone-transport.md); the isolated Hetzner worker remains network-disabled. `POST /v1/media/resolve` is retired and answers `410 UPDATE_REQUIRED`; installed app builds that still use it fail until updated. A link depends on the source's available formats; when no plan exists v2 answers `422 NO_DIRECT_MEDIA`. See [the v2 contract](DIRECT_DELIVERY.md), [YouTube verification](../docs/verification/youtube-phone-imports.json) and [other platform results](../docs/verification/hetzner-media-imports.json). Deployment details are in [deploy/README.md](deploy/README.md). No R2 or other project storage is used. The hosted worker allows one active and four queued metadata extractions. Captures and projects stay on the device.

## Run locally

Local Mac use is temporary testing only. Run the service manually in a foreground terminal; do not install login items, LaunchAgents, background daemons or automatic restarts on the Mac. The deployment target is Hetzner.

Requires Node.js 22+, `yt-dlp`, `ffmpeg` and `ffprobe` on PATH. Install those command-line tools through your normal package manager; the service does not install them, access browser cookies or log in to platforms.

```sh
cd server
npm install
npm run dev
```

For this optional local server, the default URL is `http://127.0.0.1:8787`. Set that address explicitly in iOS Simulator Settings, or `http://10.0.2.2:8787` in Android Emulator Settings. Both apps otherwise default to the hosted HTTPS service.

For temporary physical-phone testing on the same trusted Wi-Fi, copy `.env.example` to `.env`, set `HOST` to the computer's specific active LAN address, and use that address in the app's media-server setting. `PUBLIC_BASE_URL` can explicitly set the URL the phone should use for playback. It must be an origin, such as `http://192.168.1.20:8787`. Stop the foreground process when testing finishes.

```sh
npm run typecheck
npm test
npm run build
npm start
```

## Contract

[The v2 links-only contract](DIRECT_DELIVERY.md) returns short-lived platform CDN assets for device download, on-device conversion when needed, and validation. Its metadata and signed URLs remain private and uncached. Live deployment and phone verification are separate release steps.

`GET /health` → `{ "status": "ok", "service": "roast-media", "version": "0.1.0" }`.

`POST /v2/media/resolve` with `Content-Type: application/json`:

```json
{ "url": "https://www.instagram.com/reel/Datls4XT4Hy/" }
```

Returns the title, optional creator/duration, source URL, platform, a five-minute `expiresAt` and a `delivery` manifest with `kind: "direct"`, `convert`, the primary `assets`, optional `fallback` `{ assets, expected }`, `expected` (`hasAudio`, optional `duration`, `width`, `height`, `fps`, `videoCodec`, `audioCodec`) and `maxBytes` (the configured limit, 2 GiB by default, for every video). It never returns a `playbackUrl` or prepared delivery. See [DIRECT_DELIVERY.md](DIRECT_DELIVERY.md) for the selection rules.

`POST /v1/media/resolve` responds `410` with `{"error":{"code":"UPDATE_REQUIRED","message":"Update RecordPOV to import videos."}}` and starts no work. It still counts toward the rate limit.

`GET` / `HEAD /v1/media/:id/file` are unchanged: they serve files already in the cache with single HTTP byte ranges, suffix ranges, ETags and content length. No route adds new files to that cache. The `id` is opaque; file paths are never accepted or exposed.

Errors are `{ "error": { "code": "SOURCE_RESTRICTED", "message": "A useful explanation for the person using the app." } }`. Inaccessible/private videos return 422; a source with no downloadable plan returns 422 `NO_DIRECT_MEDIA`; videos exceeding configured limits return 413; the retired v1 resolve returns 410; rate limits return 429; a full work queue returns 503 with `Retry-After`.

## Legacy media preparation modules (unused by routes)

The downloader, normalizer and Instagram progressive-trial modules below, and their unit tests, remain in the source tree, but no route calls them: imports are links-only. This section describes those modules as they are.

Cold imports extract the platform's metadata once, validate single-video/live/duration limits, then pass that job's private JSON to yt-dlp's [`--load-info-json`](https://github.com/yt-dlp/yt-dlp/tree/2026.10.26#filesystem-options) for downloading. The second command retains the same proxy, extractor allowlist, JavaScript runtime, no-plugin/no-exec/no-account flags and deadline. The JSON is mode 0600 inside private staging, never served or copied into completed cache, and removed on success or error. yt-dlp itself may retry the original webpage if a loaded media URL has expired; this remains inside the same platform restrictions and job deadline.

The YouTube v2 worker never falls back to this path: when no plan exists it returns `NO_DIRECT_MEDIA`. An otherwise compatible H.264/AAC source whose only incompatibility is an overdeclared H.264 level gets a header-only `h264_metadata=level=auto` trial. The result must pass the original native-media checks with unchanged dimensions, frame rate, duration and audio presence. Accepted trials preserve the encoded picture and audio samples; failed trials are deleted before the existing conversion path runs. The links-only selector still never treats H.264 above level 5.2 as a known codec.

Instagram sometimes labels a 720p VP9 variant fully while leaving its progressive MP4 variants' codecs/dimensions unknown. The downloader first downloads and locally probes its originally selected source, establishing the actual raster, frame rate, duration and audio presence even when platform metadata omits them. An actual duration exceeding the configured limit is rejected before conversion. For Instagram only, it can then try one opaque direct-HTTPS MP4 variant from the same private metadata, with a 32 MiB / 10-second work budget inside the overall deadline. It accepts the candidate only when its real H.264 video qualifies for copying and matches those actual source facts. No format ID is hardcoded, and a missing duration is never assumed to match. A smaller raster, missing audio, incompatible codec, oversize, timeout or failed probe deletes the trial and keeps the already-downloaded original for normal conversion. The original is replaced only after candidate validation. Canceling the request stops the trial immediately; subprocess cleanup still completes before its queue slot is released. Other platforms do not run this trial.

FFprobe checks the downloaded streams before deciding how to prepare the MP4:

- Proven compatible H.264 video and AAC audio are remuxed with stream copy and a fast-start index; video/audio samples are not re-encoded.
- If the video is compatible but audio needs conversion (for example Opus), only audio is encoded to AAC. Video samples remain unchanged.
- Unknown or incompatible video facts use the full existing H.264 conversion path, including physical orientation and square pixels. It retains source dimensions and frame rate up to 3840×2160 (or portrait 2160×3840) and 60 fps, uses H.264 CRF18 when video conversion is unavoidable, and copies already-compatible AAC audio. Only sources above those bounds are scaled or limited to 60 fps. Missing audio remains missing.

Copying requires a single progressive 8-bit `yuv420p` H.264 stream with a supported Baseline/Main/High profile, level ≤5.2, even dimensions within3840×2160 landscape or2160×3840 portrait, square pixels and both reported frame rates ≤60 fps. Square pixels must be explicit SAR 1:1, or omitted SAR in a genuine ISO MP4 brand with no contradictory display aspect ratio. [Apple documents that non-square MPEG-4 pixels require a pixel-aspect-ratio atom](https://developer.apple.com/documentation/quicktime-file-format/pixel_aspect_ratio). Missing SAR in MOV/unknown/non-MP4 containers and explicit unknown/non-square SAR still require conversion. Rotation must be zero; a display matrix must be exactly identity, excluding mirrored/skewed transforms. At most one audio track is accepted for copying; unchanged audio must be AAC-LC mono/stereo at 8–48 kHz. A failed remux or unexpected duration/output probe falls back to conversion. The final output still must contain H.264 and, when source audio exists, AAC. No source is silently trimmed.

Each actual preparation emits JSON `media.stage` logs containing **only** a 24-character cache ID, platform, stage name and elapsed milliseconds. Stages are `preflight`, `extract`, `download`, `selectedProbe`, optional `candidateDownload` / `candidateProbe`, `sourceProbe`, `remux` / `levelRepair` / `audioTranscode` / `transcode`, `outputProbe`, and `total`. They contain no original/CDN URLs, titles, headers, source metadata, relay capabilities or tokens. `total` measures the downloader after queue admission; cache hits and the subsequent phone transfer are separate from those stages. Stage time is emitted even when the operation fails, without logging its raw exception.

Synthetic FFmpeg regressions verify compressed video/audio preservation on remux, video preservation during audio-only conversion, decoded source tone/RMS, orientation and oversized/high-fps fallback, and silent sources. Docker build verification installs FFmpeg to execute these tests on Linux as well as the Mac. Other development environments without FFmpeg report explicit skipped synthetic tests rather than fake successes.

## Boundaries and configuration

Defaults: 60 minutes / 2 GiB per source, two concurrent extractions, eight queued extractions, 24-hour cache TTL and an 8 GiB cache. Direct downloads are allowed up to the 2 GiB media limit for every video, whatever its duration; known sizes must fit and the phone enforces the limit while downloading unknown sizes. Video content is never silently trimmed. Plans stay within a short side of 2160 pixels, long side of 3840 pixels and 60 fps. The duration limit rejects the import; a candidate whose known size exceeds the byte limit is skipped and the next-best candidate is offered. See `.env.example` for all settings.

Only exact platform hostnames and single-video URL shapes are accepted. Tracking parameters are removed, TikTok short-link redirects must remain on allowlisted TikTok video hosts, non-public DNS answers are rejected, generic extractors/plugins/user configuration are disabled, and subprocesses use argument arrays with deadlines and bounded output. The downloader follows platform-owned extraction flows to their media CDNs; it is **not an outbound-network sandbox**. The hosted profile therefore requires the provided private-egress firewall and HTTPS proxy, and uses per-IP import limits plus a bounded work queue. Completed-cache bounds exclude transient downloads, which are limited to three times the media limit and at most about 6 GiB per active import: reserve at least 16 GiB for the worker. The local service intentionally binds to loopback by default.

`API_TOKEN` optionally enables Bearer authentication on resolver and cache-file endpoints. An authenticated client must send the same header when downloading a cache file. It is never attached to platform CDN links. Health checks remain public. Native clients do not require CORS; web origins are allowed only when listed in `CORS_ORIGINS`. The public mobile deployment leaves `API_TOKEN` empty and never embeds an administrator secret. It has IP-based import quotas, not user accounts or per-user download-bandwidth quotas. User authentication and stronger edge quotas would be separate work before scaling access.

Forwarded client addresses are ignored by default. `TRUSTED_PROXY_IPS` accepts exact proxy IP addresses, and only a single valid `X-Forwarded-For` address from one of those peers is trusted. The HTTPS edge must overwrite that header with the verified socket client address, never append the caller's supplied chain.

Private, age-restricted, blocked, removed or otherwise unavailable sources cannot be guaranteed. Platform extractor changes can require a separately installed `yt-dlp` update. Local video/photo import remains independent of this service.

## Quality cache identity

Responses include `qualityVersion: 2`. Missing means the legacy 720p/30fps profile. Source IDs now hash `roast-quality-v2:` plus the normalized URL, so an existing low-resolution prepared entry cannot win the cache lookup for a new import. Old files remain available by their old IDs until ordinary expiration/pruning; no cache deletion or extra storage budget is introduced. Native source libraries likewise must avoid treating a version 1 file as an original-quality version 2 import. A source can only supply the quality its platform exposes: the previously inspected public YouTube example offers 1080p60, whereas the old profile selected 720p and normalized to 30 fps. This does not establish that every source has 4K available.
