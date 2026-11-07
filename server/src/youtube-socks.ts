import { createServer, type Server, type Socket } from "node:net";
import { allowedYouTubeDestination, binaryFrame, MAX_DATA, MAX_STREAMS, parseBinary, parseControl, StreamCredit, type Control } from "./youtube-protocol.js";

interface Tunnel { id: number; socket: Socket; opened: boolean; localEnded: boolean; remoteEnded: boolean; closed: boolean; outgoing: StreamCredit; incoming: StreamCredit; pending: Buffer }
const reply = (status: number) => Buffer.from([5, status, 0, 1, 127, 0, 0, 1, 0, 0]);

/** SOCKS accepts DNS CONNECT443 only, never resolves or connects to a destination. */
export class YouTubeSocks {
  private server?: Server;
  private sequence = 0;
  private readonly tunnels = new Map<number, Tunnel>();
  private readonly sockets = new Set<Socket>();
  private closed = false;
  constructor(private readonly send: (data: Buffer | object, binary?: boolean) => void, private readonly fatal: () => void) {}
  async start(): Promise<number> {
    const server = createServer({ allowHalfOpen: true }, socket => this.accept(socket)); this.server = server;
    await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", () => { server.removeListener("error", reject); resolve(); }); });
    server.on("error", () => this.fatal());
    const address = server.address();
    if (!address || typeof address === "string") throw new Error("Loopback proxy unavailable");
    return address.port;
  }
  dispose(): void { this.closed = true; for (const socket of this.sockets) socket.destroy(); this.sockets.clear(); this.tunnels.clear(); this.server?.close(); }
  private transmit(data: Buffer | object, binary = false): void { try { if (!this.closed) this.send(data, binary); } catch { this.fatal(); } }
  private accept(socket: Socket): void {
    if (this.closed || this.sockets.size >= MAX_STREAMS) { socket.destroy(); return; }
    this.sockets.add(socket); socket.setNoDelay(true); socket.setTimeout(15_000, () => socket.destroy());
    let buffer = Buffer.alloc(0), greeted = false, tunnel: Tunnel | undefined;
    socket.on("error", () => {});
    socket.once("close", () => {
      this.sockets.delete(socket);
      if (tunnel) {
        this.tunnels.delete(tunnel.id);
        if (!tunnel.closed) { tunnel.closed = true; this.transmit({ type: "close", id: tunnel.id }); }
      }
    });
    const handshake = (chunk: Buffer) => {
      try {
        if (buffer.length + chunk.length > 65_536) throw new Error("Handshake overflow");
        buffer = Buffer.concat([buffer, chunk]);
        if (!greeted) {
          if (buffer.length < 2) return;
          if (buffer[0] !== 5 || !buffer[1]) throw new Error("SOCKS5 required");
          const size = 2 + buffer[1]; if (buffer.length < size) return;
          if (!buffer.subarray(2, size).includes(0)) { socket.end(Buffer.from([5, 255])); return; }
          socket.write(Buffer.from([5, 0])); buffer = buffer.subarray(size); greeted = true;
        }
        if (buffer.length < 5) return;
        if (buffer[0] !== 5 || buffer[1] !== 1 || buffer[2] !== 0 || buffer[3] !== 3 || !buffer[4]) { socket.end(reply(8)); return; }
        const length = buffer[4], size = 7 + length; if (buffer.length < size) return;
        const rawHost = buffer.subarray(5, 5 + length);
        if (rawHost.some(byte => byte > 127)) throw new Error("ASCII hostname required");
        const host = rawHost.toString("ascii").toLowerCase(), port = buffer.readUInt16BE(5 + length);
        if (!allowedYouTubeDestination(host, port) || ++this.sequence > 4096) { socket.end(reply(2)); return; }
        tunnel = { id: this.sequence, socket, opened: false, localEnded: false, remoteEnded: false, closed: false, outgoing: new StreamCredit(), incoming: new StreamCredit(), pending: Buffer.from(buffer.subarray(size)) };
        this.tunnels.set(tunnel.id, tunnel); socket.pause(); socket.removeListener("data", handshake);
        socket.on("readable", () => this.pump(tunnel!));
        socket.once("end", () => {
          if (tunnel && !tunnel.closed) {
            if (!tunnel.opened) { tunnel.closed = true; this.transmit({ type: "close", id: tunnel.id }); socket.destroy(); }
            else { tunnel.localEnded = true; this.transmit({ type: "end", id: tunnel.id }); }
          }
        });
        this.transmit({ type: "open", id: tunnel.id, host, port });
      } catch { socket.destroy(); }
    };
    socket.on("data", handshake);
  }
  private pump(tunnel: Tunnel): void {
    if (!tunnel.opened || tunnel.closed) return;
    while (tunnel.outgoing.available > 0) {
      const count = Math.min(MAX_DATA, tunnel.outgoing.available, tunnel.pending.length || tunnel.socket.readableLength);
      if (!count) break;
      const data: Buffer | null = tunnel.pending.length ? tunnel.pending.subarray(0, count) : tunnel.socket.read(count);
      if (!data) break;
      if (tunnel.pending.length) tunnel.pending = tunnel.pending.subarray(count);
      tunnel.outgoing.consume(data.length); this.transmit(binaryFrame(tunnel.id, data), true);
    }
  }
  receive(data: Buffer, binary: boolean): void {
    if (binary) {
      const frame = parseBinary(data), tunnel = this.tunnels.get(frame.id);
      if (!tunnel || tunnel.closed) return; // A TCP close may race with peer data already in flight.
      if (!tunnel.opened || tunnel.remoteEnded) throw new Error("Unexpected proxy data");
      tunnel.incoming.consume(frame.payload.length);
      tunnel.socket.write(frame.payload, error => {
        if (error || tunnel.closed || this.closed) return;
        tunnel.incoming.acknowledge(frame.payload.length);
        this.transmit({ type: "ack", id: tunnel.id, bytes: frame.payload.length });
      });
      return;
    }
    const control: Control = parseControl(data), tunnel = typeof control.id === "number" ? this.tunnels.get(control.id) : undefined;
    if (!tunnel || tunnel.closed) return;
    if (control.type === "opened" && !tunnel.opened) {
      tunnel.opened = true; tunnel.socket.setTimeout(0); tunnel.socket.write(reply(0)); this.pump(tunnel);
    } else if (control.type === "ack") { tunnel.outgoing.acknowledge(control.bytes); this.pump(tunnel); }
    else if (control.type === "end" && tunnel.opened && !tunnel.remoteEnded) { tunnel.remoteEnded = true; tunnel.socket.end(); }
    else if (control.type === "close" || control.type === "error") {
      tunnel.closed = true;
      if (!tunnel.opened) tunnel.socket.end(reply(1)); else tunnel.socket.destroy();
    } else throw new Error("Invalid proxy control");
  }
}
