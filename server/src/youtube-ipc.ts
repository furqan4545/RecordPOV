import { EventEmitter } from "node:events";
import type { Socket } from "node:net";
import { MAX_BUFFERED, MAX_FRAME } from "./youtube-protocol.js";

/** Private IPC has a four-byte frame length plus text/binary discriminator. */
export class IPCChannel extends EventEmitter {
  private pending = Buffer.alloc(0);
  constructor(readonly socket: Socket) {
    super();
    socket.on("data", (chunk: Buffer) => {
      try {
        if (this.pending.length + chunk.length > MAX_BUFFERED) throw new Error("IPC input overflow");
        this.pending = Buffer.concat([this.pending, chunk]);
        while (this.pending.length >= 4) {
          const size = this.pending.readUInt32BE(0);
          if (size < 2 || size > MAX_FRAME + 1) throw new Error("Invalid IPC frame length");
          if (this.pending.length < size + 4) break;
          const kind = this.pending[4];
          if (kind !== 0 && kind !== 1) throw new Error("Invalid IPC frame type");
          const data = Buffer.from(this.pending.subarray(5, size + 4));
          this.pending = this.pending.subarray(size + 4);
          this.emit("frame", data, kind === 1);
        }
      } catch { socket.destroy(new Error("Invalid private transport")); }
    });
    socket.on("error", () => { /* Close is the single terminal event; no raw input is logged. */ });
    socket.once("close", () => { this.pending = Buffer.alloc(0); this.emit("closed"); });
  }
  send(data: Buffer | object, binary = false): void {
    const payload = Buffer.isBuffer(data) ? data : Buffer.from(JSON.stringify(data));
    if (payload.length > MAX_FRAME || this.socket.destroyed || this.socket.writableLength + payload.length > MAX_BUFFERED) throw new Error("Private transport unavailable");
    const header = Buffer.alloc(5); header.writeUInt32BE(payload.length + 1); header[4] = binary ? 1 : 0;
    this.socket.write(Buffer.concat([header, payload]));
  }
  close(): void { this.socket.destroy(); }
}
