import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import { connect, type Socket } from "node:net";
import { basename, join } from "node:path";
import type { IncomingMessage, Server } from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import type { Config } from "./config.js";
import { AppError } from "./errors.js";
import { normalizeSource } from "./source.js";
import { clientAddress } from "./client-address.js";
import { IPCChannel } from "./youtube-ipc.js";
import { DirectDelivery } from "./media-delivery.js";
import type { Source } from "./source.js";
import { sanitizeDirectMedia } from "./direct-media.js";
import { allowedYouTubeDestination, MAX_BUFFERED, MAX_FRAME, MAX_SESSION_BYTES, MAX_STREAMS, parseBinary, parseControl, StreamCredit, validStreamID, type Control } from "./youtube-protocol.js";

interface RelayStream { outbound: StreamCredit; inbound: StreamCredit; opened: boolean; closed: boolean; workerEnded: boolean; phoneEnded: boolean }
interface Session {
  id: string; hash: Buffer; ip: string; sourceURL: string; expiresAt: number;
  controller: AbortController; attachTimer: ReturnType<typeof setTimeout>; expiryTimer: ReturnType<typeof setTimeout>;
  peer?: WebSocket; claimed: boolean; finished: boolean; attached: boolean; bytes: number;
  worker?: IPCChannel; streams: Map<number, RelayStream>; pongAt: number; messages: number; messageWindow: number;
}
const failure = () => new AppError("YOUTUBE_SESSION_INVALID", "Reconnect to prepare this YouTube video.", 403);
const disconnected = () => new AppError("YOUTUBE_PEER_DISCONNECTED", "Keep the app open while the YouTube video downloads, then try again.", 422);
const digest = (token: string) => createHash("sha256").update(token).digest();

export class YouTubeBroker {
  private readonly sessions = new Map<string, Session>();
  private readonly sockets = new WebSocketServer({ noServer: true, perMessageDeflate: false, maxPayload: MAX_FRAME, clientTracking: false });
  private readonly heartbeat: ReturnType<typeof setInterval>;
  constructor(private readonly config: Config, private readonly ipcPath: string, private readonly lifetimeMs = 630_000, private readonly attachmentMs = 20_000) {
    this.heartbeat = setInterval(() => {
      for (const session of this.sessions.values()) {
        if (!session.peer) continue;
        if (Date.now() - session.pongAt > 25_000) this.abort(session);
        else if (session.peer.readyState === WebSocket.OPEN) session.peer.ping();
      }
    }, 10_000);
    this.heartbeat.unref();
  }
  dispose(): void { clearInterval(this.heartbeat); for (const session of this.sessions.values()) this.abort(session); this.sockets.close(); }
  create(input: unknown, ip: string, origin: string) {
    const source = normalizeSource(input);
    if (source.platform !== "youtube") throw new AppError("YOUTUBE_URL_REQUIRED", "Choose one YouTube video.", 400);
    if (this.sessions.size >= 4 || [...this.sessions.values()].filter(item => item.ip === ip).length >= 2) {
      throw new AppError("SERVER_BUSY", "A few YouTube videos are being prepared. Try again in a moment.", 503, 20);
    }
    const id = randomBytes(18).toString("base64url"), token = randomBytes(32).toString("base64url");
    const session: Session = {
      id, hash: digest(token), ip, sourceURL: source.url, expiresAt: Date.now() + this.lifetimeMs,
      controller: new AbortController(), claimed: false, finished: false, attached: false, bytes: 0,
      streams: new Map(), pongAt: Date.now(), messages: 0, messageWindow: Date.now(),
      attachTimer: setTimeout(() => this.abort(session), this.attachmentMs), expiryTimer: setTimeout(() => this.abort(session), this.lifetimeMs),
    };
    session.attachTimer.unref(); session.expiryTimer.unref(); this.sessions.set(id, session);
    const socketURL = new URL(`/v1/media/youtube/sessions/${id}/socket`, origin);
    socketURL.protocol = socketURL.protocol === "https:" ? "wss:" : "ws:";
    return { sessionId: id, token, socketUrl: socketURL.href, expiresAt: new Date(session.expiresAt).toISOString() };
  }
  private authenticate(id: unknown, token: unknown, ip: string): Session {
    if (typeof id !== "string" || typeof token !== "string" || !/^[A-Za-z0-9_-]{43}$/.test(token)) throw failure();
    const session = this.sessions.get(id);
    if (!session || session.expiresAt <= Date.now() || session.ip !== ip || !timingSafeEqual(session.hash, digest(token))) throw failure();
    return session;
  }
  attach(server: Server): void {
    server.on("upgrade", (request, socket, head) => {
      try {
        const path = new URL(request.url || "/", "http://localhost");
        const match = /^\/v1\/media\/youtube\/sessions\/([A-Za-z0-9_-]{24})\/socket$/.exec(path.pathname);
        if (!match || path.search || path.hash || (request.headers.origin && !this.config.corsOrigins.includes(request.headers.origin))) throw failure();
        const session = this.authenticate(match[1], request.headers["x-youtube-session-token"], clientAddress(request, this.config));
        if (session.attached) throw failure();
        session.attached = true;
        this.sockets.handleUpgrade(request, socket, head, peer => {
          session.peer = peer; session.pongAt = Date.now();
          peer.on("pong", () => { session.pongAt = Date.now(); });
          peer.on("error", () => this.abort(session));
          peer.once("close", () => this.abort(session));
          peer.on("message", (raw, binary) => {
            try {
              if (Date.now() - session.messageWindow > 1000) { session.messages = 0; session.messageWindow = Date.now(); }
              if (++session.messages > 8192) throw new Error("Message flood");
              const data = Buffer.isBuffer(raw) ? raw : Buffer.concat(Array.isArray(raw) ? raw : [Buffer.from(raw)]);
              this.relay(session, data, binary, false);
            } catch { this.abort(session); }
          });
          peer.send(JSON.stringify({ type: "ready", version: 1 }));
        });
      } catch { socket.end("HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"); }
    });
    server.once("close", () => this.dispose());
  }
  /** Routes can only claim links-only delivery; the worker's prepare mode is unreachable from here. */
  claim(id: unknown, token: unknown, input: unknown, ip: string): { deliver: (source: Source, directory: string, signal: AbortSignal) => Promise<DirectDelivery>; signal: AbortSignal; finish: () => void; cancel: () => void } {
    const session = this.authenticate(id, token, ip), source = normalizeSource(input);
    if (source.platform !== "youtube" || source.url !== session.sourceURL || session.claimed || session.peer?.readyState !== WebSocket.OPEN) throw failure();
    session.claimed = true; clearTimeout(session.attachTimer);
    return {
      signal: session.controller.signal,
      cancel: () => this.abort(session),
      finish: () => { session.finished = true; session.worker?.close(); delete session.worker; },
      deliver: (requested, directory, signal) => {
        if (requested.url !== session.sourceURL) return Promise.reject(failure());
        return this.runWorker(session, directory, signal);
      },
    };
  }
  private async runWorker(session: Session, directory: string, signal: AbortSignal): Promise<DirectDelivery> {
    const key = await readFile(join(this.ipcPath, "worker.key"), "utf8").catch(() => { throw new AppError("YOUTUBE_WORKER_UNAVAILABLE", "YouTube preparation is restarting. Try again shortly.", 503, 10); });
    if (signal.aborted || session.controller.signal.aborted) throw disconnected();
    return await new Promise<DirectDelivery>((resolve, reject) => {
      const socket = connect(join(this.ipcPath, "worker.sock"));
      const ipc = new IPCChannel(socket); session.worker = ipc;
      let settled = false;
      const stop = () => { if (!settled) { settled = true; reject(signal.reason || disconnected()); } ipc.close(); };
      signal.addEventListener("abort", stop, { once: true });
      socket.once("connect", () => {
        try { ipc.send({ type: "job", auth: key.trim(), jobId: session.id, sourceURL: session.sourceURL, directoryName: basename(directory), mode: "delivery", timeoutMs: this.config.youtubeTimeoutMs ?? 600_000 }); }
        catch { stop(); }
      });
      ipc.on("frame", (data: Buffer, binary: boolean) => {
        try {
          if (!binary) {
            const control = JSON.parse(data.toString("utf8")) as Control;
            if (control.type === "result" || control.type === "direct-result" || control.type === "failure") {
              if (settled) return;
              settled = true; signal.removeEventListener("abort", stop);
              // Ignore crossed TCP frames after the private result while keeping
              // WSS open through the final HTTP response (including API DNS checks).
              session.finished = true;
              // Links only: a prepared-media result is a protocol violation.
              if (control.type === "result") throw new Error("Unexpected prepared result");
              else if (control.type === "direct-result") {
                const media = control.media as { title?: unknown; creator?: unknown; duration?: unknown };
                if (!media || typeof media.title !== "string" || (media.duration !== undefined &&
                    (typeof media.duration !== "number" || !Number.isFinite(media.duration) || media.duration <= 0 || media.duration > this.config.maxDuration))) throw new Error("Invalid private delivery metadata");
                resolve(new DirectDelivery({ title: media.title.slice(0, 300),
                  ...(typeof media.creator === "string" ? { creator: media.creator.slice(0, 100) } : {}),
                  ...(typeof media.duration === "number" ? { duration: media.duration } : {}) },
                sanitizeDirectMedia(control.delivery, "youtube", this.config.maxBytes, this.config.maxDuration)));
              }
              else reject(new AppError(typeof control.code === "string" ? control.code : "SOURCE_UNAVAILABLE", typeof control.message === "string" ? control.message : "This YouTube video could not be prepared.", typeof control.status === "number" ? control.status : 422));
              ipc.close(); return;
            }
          }
          this.relay(session, data, binary, true);
        } catch { this.abort(session); settled = true; signal.removeEventListener("abort", stop); reject(disconnected()); ipc.close(); }
      });
      ipc.once("closed", () => { signal.removeEventListener("abort", stop); if (!settled) { settled = true; reject(disconnected()); } });
      if (signal.aborted) stop();
    });
  }
  private relay(session: Session, data: Buffer, binary: boolean, fromWorker: boolean): void {
    if (session.finished) return; // Late TCP acknowledgements can race with the HTTP result.
    if (!session.claimed || !session.worker) throw new Error("No active job");
    session.bytes += data.length;
    if (session.bytes > MAX_SESSION_BYTES) throw new Error("Session byte limit");
    let stream: RelayStream | undefined;
    if (binary) {
      const frame = parseBinary(data); stream = session.streams.get(frame.id);
      if (!stream) throw new Error("Unknown stream");
      const credit = fromWorker ? stream.outbound : stream.inbound;
      credit.consume(frame.payload.length);
      if (stream.closed) return;
      if (!stream.opened || (fromWorker ? stream.workerEnded : stream.phoneEnded)) throw new Error("Data before open or after end");
    } else {
      const control = parseControl(data);
      if (!validStreamID(control.id)) throw new Error("Invalid stream id");
      stream = session.streams.get(control.id);
      if (fromWorker && control.type === "open") {
        if (stream || session.streams.size >= 4096 || [...session.streams.values()].filter(item => !item.closed).length >= MAX_STREAMS || !allowedYouTubeDestination(control.host, control.port)) throw new Error("Destination or stream refused");
        stream = { outbound: new StreamCredit(), inbound: new StreamCredit(), opened: false, closed: false, workerEnded: false, phoneEnded: false };
        session.streams.set(control.id, stream);
      } else {
        if (!stream) throw new Error("Unknown stream");
        if (stream.closed) return;
        if (control.type === "ack") (fromWorker ? stream.inbound : stream.outbound).acknowledge(control.bytes);
        else if (!fromWorker && control.type === "opened" && !stream.opened) stream.opened = true;
        else if (control.type === "end" && stream.opened && !(fromWorker ? stream.workerEnded : stream.phoneEnded)) {
          if (fromWorker) stream.workerEnded = true; else stream.phoneEnded = true;
        } else if (control.type === "close" || (!fromWorker && control.type === "error")) stream.closed = true;
        else throw new Error("Unexpected control");
      }
    }
    if (fromWorker) {
      if (session.peer?.readyState !== WebSocket.OPEN || session.peer.bufferedAmount + data.length > MAX_BUFFERED) throw new Error("Phone buffer overflow");
      session.peer.send(data, { binary });
    } else session.worker.send(data, binary);
  }
  private abort(session: Session): void {
    if (!this.sessions.delete(session.id)) return;
    clearTimeout(session.attachTimer); clearTimeout(session.expiryTimer);
    session.controller.abort(disconnected()); session.worker?.close(); session.streams.clear();
    session.peer?.terminate();
  }
}
