export class RateLimiter {
  private readonly entries = new Map<string, { reset: number; count: number }>();
  constructor(private readonly maximumKeys = 10_000, private readonly clock = Date.now) {}

  allow(key: string, maximum: number, windowMs = 60_000): boolean {
    const now = this.clock();
    let entry = this.entries.get(key);
    if (!entry || entry.reset <= now) {
      if (!entry && this.entries.size >= this.maximumKeys) {
        for (const [oldKey, old] of this.entries) if (old.reset <= now) this.entries.delete(oldKey);
        // Fail closed instead of allowing attacker-controlled IP churn to reset limits.
        if (this.entries.size >= this.maximumKeys) return false;
      }
      entry = { reset: now + windowMs, count: 0 };
      this.entries.set(key, entry);
    }
    return ++entry.count <= maximum;
  }
}

export class AuthError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) { super(message); }
}
