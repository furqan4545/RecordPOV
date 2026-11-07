# Links-only import contract

The server only finds links. For every platform (YouTube included) it extracts the source's metadata and returns short-lived platform CDN links; it never downloads, converts, transcodes or stores imported videos. The phone downloads the files directly and, when the original is better than any directly playable version, converts it on the device to H.264 + AAC-LC.

`POST /v1/media/resolve` is retired. It responds `410` with `{"error":{"code":"UPDATE_REQUIRED","message":"Update RecordPOV to import videos."}}` and starts no work; it still counts toward the per-client rate limit. Installed app builds that only use v1 fail until updated. `GET /v1/media/:id/file` is unchanged and only serves files already in the cache.

`POST /v2/media/resolve` accepts:

```json
{ "url": "https://www.instagram.com/reel/PUBLIC_ID/" }
```

YouTube additionally uses the existing session-ticket route, WSS phone transport and `X-YouTube-Session-Token`, with `youtubeSessionId` in the resolve body. The isolated, network-disabled worker extracts metadata through that transport and returns the plan over its private IPC channel. Only metadata crosses the relay; the worker never falls through to downloading or preparing media. The client closes WSS after reading the HTTP response, then downloads the assets directly.

## Response

Fields are `id`, `title`, optional `creator` and `duration`, `sourceUrl`, `platform`, ISO-8601 `expiresAt`, `qualityVersion: 2` and `delivery`. There is no `playbackUrl`, no prepared delivery and no prepared-cache shortcut: v2 always extracts metadata and never reads the prepared cache.

```json
{
  "id": "0123456789abcdef01234567",
  "qualityVersion": 2,
  "title": "Original video",
  "sourceUrl": "https://www.instagram.com/reel/PUBLIC_ID/",
  "platform": "instagram",
  "expiresAt": "2026-11-07T12:05:00.000Z",
  "delivery": {
    "kind": "direct",
    "convert": true,
    "assets": [
      { "role": "video", "url": "https://scontent.cdninstagram.com/PRIVATE_SIGNED_VP9.mp4", "headers": { "User-Agent": "Extractor-required public user agent" } },
      { "role": "audio", "url": "https://scontent.cdninstagram.com/PRIVATE_SIGNED_AUDIO.m4a", "headers": { "User-Agent": "Extractor-required public user agent" } }
    ],
    "expected": { "width": 1080, "height": 1920, "hasAudio": true, "videoCodec": "vp9", "audioCodec": "he-aac" },
    "fallback": {
      "assets": [{ "role": "muxed", "url": "https://scontent.cdninstagram.com/PRIVATE_SIGNED_PROGRESSIVE.mp4", "headers": { "User-Agent": "Extractor-required public user agent" } }],
      "expected": { "hasAudio": true, "videoCodec": "unknown", "audioCodec": "unknown" }
    },
    "maxBytes": 2147483648
  }
}
```

When no plan exists, v2 responds `422` with `{"error":{"code":"NO_DIRECT_MEDIA","message":"This video can't be downloaded directly. Try another link."}}`. A plan whose CDN hosts fail validation responds `422` with `DIRECT_SOURCE_UNAVAILABLE`.

### Delivery fields

- `assets` is the primary set: either one `muxed` file (silent when `hasAudio` is false), or exactly one `video` plus one `audio` file.
- `convert: true` means the primary is the original and the phone converts it on the device to H.264 + AAC-LC. `convert: false` means the primary is directly playable (or an opaque file the phone inspects after download) and is used without conversion.
- `fallback` (optional, only with `convert: true`) is `{ assets, expected }` with the same asset rules. The phone downloads it instead when it cannot decode or convert the original.
- `expected` has `hasAudio` and optional `duration`, `width`, `height`, `fps`, `videoCodec` (`h264` | `hevc` | `vp9` | `av1` | `unknown`) and `audioCodec` (`aac-lc` | `he-aac` | `aac` | `unknown` | `none`). These are platform metadata, not a substitute for inspecting the downloaded files. `unknown` means the platform did not describe the file; the phone decides after download.
- `maxBytes` is the configured media limit (2 GiB by default) for every plan and every duration. Known sizes must fit; unknown sizes are allowed and the phone enforces `maxBytes` across all assets while downloading. The 60-minute duration limit still applies.

### Hybrid selection

Candidates are complete single-file HTTPS downloads (never HLS/DASH manifests or fragment lists), in an MP4-family container (`ext` `mp4` or `m4a`; WebM and Matroska are never offered because iOS cannot demux them), SDR, without rotation, at most 60 fps, within the 2160-short-side / 3840-long-side raster bounds, on the CDN host allowlist below and with only approved headers.

Known video codecs are H.264 (`h264`/`avc1`/`avc3` with Baseline/Main/High profile through level 5.2), HEVC (`hvc1`, `hev1`, `hevc`, `h265`, `bytevc1`), VP9 (`vp9`, `vp09.*`) and AV1 (`av1`, `av01.*`). Audio is any AAC profile: `aac`, `mp4a` and `mp4a.40.2` are AAC-LC; `mp4a.40.5` and `mp4a.40.29` are HE-AAC; other AAC profiles are `aac`. Split audio must match the selected audio language, have at most 2 channels and at most 48 kHz.

Nothing above 1080p is ever used. 1080p is measured like YouTube labels it: the short side, or the 16:9 equivalent for wider pictures (`max(shortSide, round(longSide × 9/16))`), so 1920×818 is 1080p and 2048×872 or 2560×1440 is above it.

1. **Original** = the best known-codec video up to 1080p (muxed or video-only) by raster, then frame rate (unknown = 0), then bitrate. Video-only is paired with the best AAC audio of any profile when the source has audio.
2. **Playable** = the best H.264 + AAC-LC combination up to 1080p (muxed, or split H.264 video + AAC-LC audio) by the same ranking.
3. If a playable exists and it is 1080p, or its raster and frame rate are at least the original's, it is the primary with `convert: false` and no fallback.
4. Otherwise (the playable is below 1080p and a better original exists, or there is no playable) the original is the primary with `convert: true`. The fallback is the playable when one exists, else the last-listed progressive MP4 with unknown codecs (yt-dlp lists formats worst to best) with `videoCodec: "unknown"`.
5. If no known-codec video exists but an unknown-codec progressive MP4 does, that file is the primary with `convert: false` and `videoCodec: "unknown"`.

Examples: an Instagram reel's 1080×1920 VP9 dash video plus HE-AAC audio is converted (its H.264 is only 720p), with its last opaque progressive MP4 as the fallback. A YouTube 4K60 source is delivered as H.264 1080p60 + AAC-LC itag 140 directly; its 1440p/4K tiers are ignored. A widescreen YouTube film with H.264 1920×818 plays that directly. A TikTok `bytevc1` (HEVC) 1080p original is converted when its H.264 is below 1080p, with that H.264 file as the fallback.

## Security

Only `User-Agent`, `Referer`, `Origin` and `Accept` headers can appear. Never attach API authorization, relay capabilities, cookies or other credentials to CDN requests. No cookies are requested, returned or forwarded by this route. Treat signed URLs as private, short-lived credentials: extraction stays in memory, no signed URL or header enters the cache or logs, and every manifest is `Cache-Control: no-store`. `expiresAt` is at most five minutes after response generation; a CDN can invalidate its URL sooner. A native background job may keep the descriptor privately for OS restoration and must purge it when completed, failed or expired.

HTTPS port 443 only; no IP literals, userinfo, fragments, trailing-dot hosts, control characters or unapproved domains. Host ownership is exact or dot-delimited suffix membership:

| Platform | Allowed CDN hostnames |
| --- | --- |
| Instagram | `cdninstagram.com`, `fbcdn.net`, and their subdomains |
| YouTube | `googlevideo.com` and its subdomains |
| X | exact `video.twimg.com` |
| TikTok | `tiktokcdn.com`, `tiktokcdn-us.com`, `tiktokcdn-eu.com`, `tiktokv.com`, `ibytedtos.com`, `byteoversea.com`, and their subdomains; exact `v16-webapp-prime.tiktok.com`, `v19-webapp-prime.tiktok.com` |

This is a conservative application allowlist; a format on a new CDN is not offered until reviewed. The API checks every DNS answer for every host in both the primary and the fallback set and rejects the whole manifest for any private or reserved address. The server applies the same shape, codec, size and duration rules when it validates the YouTube worker's private manifest. Android additionally pins validated public DNS per hop. iOS background URLSession uses the narrow trusted CDN policy, no sensitive headers or cookies, validates the final URL and the downloaded media; its background API does not provide per-redirect interception or DNS pinning. Do not describe the iOS implementation as having those stronger guarantees.

## Operation

v2 uses the existing trusted-proxy client addressing, authentication, 20-per-minute IP quota (shared with the retired v1 route and YouTube sessions), active/queued-work bounds, cancellation and private staging cleanup. Metadata extraction has a 60-second sub-deadline inside the job deadline and an 8 MiB output cap. It disables plugins, configuration files, remote components, execution hooks and extractor disk caching. The deployed YouTube worker remains `network_mode: none`.

`media.stage` reports `extractDirect`; `Server-Timing: resolve;dur=...` and the `media.resolve` metric measure the API response only. Neither includes the phone's CDN download, on-device conversion or validation. Deployment needs the exact `/v2/media/resolve` route in the Caddy allowlist; no additional port or outbound worker permission is needed.

The server's downloader and normalizer modules (and their unit tests) remain in the source tree but no route calls them.
