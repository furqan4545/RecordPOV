import { AppError } from "./errors.js";

export class WorkQueue {
  private active = 0;
  private readonly pending: (() => void)[] = [];
  constructor(private readonly concurrency: number, private readonly limit: number) {}

  async run<T>(task: () => Promise<T>, signal?: AbortSignal): Promise<T> {
    if (signal?.aborted) throw signal.reason;
    if (this.active >= this.concurrency) {
      if (this.pending.length >= this.limit) throw new AppError("SERVER_BUSY", "A few videos are being prepared. Please try again in a moment.", 503, 15);
      await new Promise<void>((resolve, reject) => {
        const start = () => { signal?.removeEventListener("abort", abort); resolve(); };
        const abort = () => {
          const index = this.pending.indexOf(start);
          if (index >= 0) this.pending.splice(index, 1);
          reject(signal?.reason);
        };
        this.pending.push(start);
        signal?.addEventListener("abort", abort, { once: true });
        if (signal?.aborted) abort();
      });
    } else { this.active++; }
    try {
      if (signal?.aborted) throw signal.reason;
      return await task();
    }
    finally {
      const next = this.pending.shift();
      if (next) next();
      else this.active--;
    }
  }
}
