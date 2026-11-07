# YouTube phone transport

The same pinned yt-dlp opens the public control video on the owner's local network, while both fixed Hetzner addresses receive YouTube's bot challenge. Keep yt-dlp and FFmpeg on Hetzner; use the foreground phone's connection only for the active YouTube job. The final normalized MP4 still downloads into device-local storage. No account cookies or permanent app secrets are involved.

The route passed an uncached short control video and the supplied 426-second clip on the physical iPhone. Android's production transport also passed a complete uncached download on the JVM. See [verification](verification/youtube-phone-imports.json).

## HTTP and lifetime

- `POST /v1/media/youtube/sessions`, JSON `{ "url": "https://www.youtube.com/watch?v=..." }`. Normalize the URL and require a single public YouTube video. Share the existing per-IP attempt budget or use a separately bounded session budget.
- Return `{ "sessionId": "opaque random id", "token": "256-bit random base64url capability", "socketUrl": "wss://api.recordpov.app/v1/media/youtube/sessions/ID/socket", "expiresAt": "ISO date" }`.
- The phone connects to that exact WSS origin with `X-YouTube-Session-Token: TOKEN`. The token is never placed in a URL or log. One socket and one claimed video job per session.
- Server sends `{ "type": "ready", "version": 1 }` after authenticated attachment. The phone awaits this before requesting resolution.
- Existing `POST /v1/media/resolve` adds `youtubeSessionId` to its JSON, and sends the same `X-YouTube-Session-Token` header. Validate the capability, normalized video binding, connected peer, expiry and one-use claim before queuing the job.
- The phone keeps the peer alive until resolution finishes; then closes it before downloading the returned MP4. Cancel, app backgrounding, network loss, expiry or peer failure tears down all streams and cancels the worker job.
- Session deadline: 630 seconds maximum; unclaimed attachment deadline: 20 seconds. Four sessions globally, two per client IP, eight concurrent streams per session. Assisted YouTube jobs have a server-controlled 600-second deadline (the user's supplied example is 426 seconds long); native clients allow 650 seconds for this route. Other platforms retain their 180-second deadline. Duration, queue, byte and cache limits remain enforced.

## Framing version 1

No WebSocket compression. Maximum frame 65,536 bytes. Text frames are small JSON controls. Stream ids are positive uint32 and unique within the session.

- Server → phone: `{ "type": "open", "id": N, "host": "www.youtube.com", "port": 443 }`.
- Phone → server after connection: `{ "type": "opened", "id": N }`; failures use `{ "type": "error", "id": N, "message": "Connection failed" }`.
- Either direction binary data: byte 0 is `1`; bytes 1–4 are the stream id in network byte order; remaining 1–32,768 bytes are the TCP payload.
- Receiver acknowledges only after the payload has been written to its target: `{ "type": "ack", "id": N, "bytes": payloadLength }`.
- Each direction starts with a 262,144-byte credit window. Never read/send more than available credit. Reject invalid acknowledgements, excess credit or incoming data beyond the window. Bound WebSocket buffered bytes, stream queues and total session bytes (750 MiB).
- `{ "type": "end", "id": N }` is a half-close after preceding writes are completed. `{ "type": "close", "id": N }` cancels the stream. Preserve ordering and release queued data safely. A stream error does not permit new destinations.
- WebSocket ping/pong maintains liveness; heartbeat, capability expiry and the job deadline cap every connection.

## Destination boundary

Both server and phone require TCP443 and a syntactically valid DNS hostname equal to or beneath `youtube.com`, `googlevideo.com`, or `ytimg.com`; the exact documented API hostname `youtubei.googleapis.com` is also allowed. Reject numeric IP input, userinfo, paths, alternate ports, control characters, localhost and arbitrary suffix tricks. Expand the list only for an observed, justified platform endpoint.

The phone resolves the hostname locally, rejects non-public answers, and connects to a validated numeric address to prevent DNS rebinding. Reject private, loopback, link-local, metadata, reserved, multicast and documentation ranges, including mapped IPv4. DNS64 requires deliberate handling; the well-known `64:ff9b::/96` prefix may be used only when the embedded IPv4 is public. Do not terminate TLS or import browser cookies: yt-dlp validates the actual YouTube TLS session end to end through the byte stream.

## Worker isolation

Use a separate nonroot, read-only `network_mode: none` YouTube worker. Do not expose a proxy port or mount the Docker socket. The worker starts a loopback-only SOCKS5 listener for its own yt-dlp invocation, using `--proxy socks5h://127.0.0.1:PORT` so names reach the phone. A private, owner-only Unix-socket volume connects this worker to the main API's session broker. Authenticate and bind IPC to the one job/capability; share only the source cache and IPC volumes. The main API dispatches the already normalized YouTube source; the worker's injected preflight can avoid local DNS because every outbound connection is validated and resolved on the phone.

The existing resolver and IPv4 egress guard keep serving Instagram, X and TikTok. Preserve its firewall and restart ordering. The YouTube worker has no direct network, so downloader or external-tool proxy bypasses fail closed. Local FFmpeg uses file/pipe protocols only and retains the current duration, process, memory and byte bounds.

## Verification

First prove extraction through an actual phone peer, then a complete short video's normalized H.264 video and AAC audio, HTTPS Range playback, native frame decode and durable local storage. Test the user's original YouTube link too. Synthetic tests must cover capability binding/expiry, malformed frames, destination denial, bounded backpressure, cancellation and no direct-network worker path. Recheck the other three platforms after deployment.

The phone remains in the foreground during fetching. Approximate phone traffic is `2S + M`: source download S, relaying S to Hetzner, and downloading normalized output M. Projects, camera, microphone, captions and finished takes stay local.
